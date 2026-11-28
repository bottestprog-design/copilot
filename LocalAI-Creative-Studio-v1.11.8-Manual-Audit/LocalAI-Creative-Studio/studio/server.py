from __future__ import annotations

import asyncio
import json
import os
import random
import re
import sqlite3
import subprocess
import time
import uuid
from contextlib import asynccontextmanager, contextmanager
from pathlib import Path, PurePosixPath
from typing import Any, AsyncIterator, Iterator
from urllib.parse import quote, urlparse

import httpx
import psutil
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse
from starlette.middleware.trustedhost import TrustedHostMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field, field_validator

PACKAGE_ROOT = Path(__file__).resolve().parents[1]
STATIC_DIR = Path(__file__).resolve().parent / "static"


def load_app_version() -> str:
    """Read the release version from the single source-of-truth file."""
    version_path = PACKAGE_ROOT / "VERSION.txt"
    assert_plain_app_path(version_path, directory=False)
    try:
        version = version_path.read_text(encoding="ascii").strip()
    except (OSError, UnicodeError) as exc:
        raise RuntimeError(f"Cannot read the LocalAI Creative Studio release version: {exc}") from exc
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise RuntimeError("VERSION.txt must contain one semantic version (major.minor.patch).")
    return version



def _is_reparse_path(path: Path) -> bool:
    """Return True for symlinks and Windows junctions without following them."""
    try:
        if path.is_symlink():
            return True
        is_junction = getattr(path, "is_junction", None)
        return bool(is_junction and is_junction())
    except OSError:
        return True


def assert_plain_app_path(path: Path, *, directory: bool | None = None) -> None:
    """Reject redirected app storage paths before reading or writing local state."""
    if _is_reparse_path(path):
        raise RuntimeError(f"Refusing a symbolic-link or junction path inside Studio storage: {path}")
    try:
        exists = path.exists()
        if not exists:
            return
        if directory is True and not path.is_dir():
            raise RuntimeError(f"Expected an application data directory, found a file: {path}")
        if directory is False and not path.is_file():
            raise RuntimeError(f"Expected an application data file, found a directory: {path}")
    except OSError as exc:
        raise RuntimeError(f"Could not safely inspect Studio storage path: {path}: {exc}") from exc


APP_VERSION = load_app_version()


_raw_data_dir = Path(os.environ.get("LOCALAI_STUDIO_DATA", str(PACKAGE_ROOT / "data"))).expanduser()
# Also reject redirected parents: resolving first would hide an ancestor symlink.
_cursor = _raw_data_dir
while True:
    if _is_reparse_path(_cursor):
        raise RuntimeError(f"Refusing a redirected parent in Studio data path: {_cursor}")
    if _cursor.parent == _cursor:
        break
    _cursor = _cursor.parent
assert_plain_app_path(_raw_data_dir, directory=True)
DATA_DIR = _raw_data_dir.resolve()
WORKFLOW_DIR = DATA_DIR / "workflows"
CONFIG_DIR = DATA_DIR / "configs"
DB_PATH = DATA_DIR / "studio.sqlite3"
SETTINGS_PATH = DATA_DIR / "settings.json"
for folder in (DATA_DIR, WORKFLOW_DIR, CONFIG_DIR):
    assert_plain_app_path(folder, directory=True)
    folder.mkdir(parents=True, exist_ok=True)
    assert_plain_app_path(folder, directory=True)
assert_plain_app_path(DB_PATH, directory=False)
assert_plain_app_path(SETTINGS_PATH, directory=False)

DEFAULT_SETTINGS = {
    "comfy_url": os.environ.get("COMFY_URL", "http://127.0.0.1:8188"),
    "ollama_url": os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434"),
    "ollama_model": os.environ.get("OLLAMA_MODEL", "local-qwen35:latest"),
}
SETTINGS_PATH = DATA_DIR / "settings.json"
DATABASE_SCHEMA_VERSION = 1
MAX_WORKFLOW_BYTES = 20 * 1024 * 1024
MAX_REFERENCE_IMAGE_BYTES = 30 * 1024 * 1024
# Includes one 30MB reference image, a 20MB workflow and bounded multipart overhead.
MAX_HTTP_REQUEST_BYTES = 52 * 1024 * 1024
BINDING_NAMES = {"positive", "negative", "seed", "steps", "cfg", "width", "height", "frames", "fps", "checkpoint", "batch_size", "init_image", "image_subfolder"}


def atomic_write_text(path: Path, content: str) -> None:
    """Write a small local state file atomically so a power loss cannot leave half JSON."""
    assert_plain_app_path(path.parent, directory=True)
    assert_plain_app_path(path, directory=False)
    path.parent.mkdir(parents=True, exist_ok=True)
    # Re-check after creating the directory. This narrows the window in which a
    # redirected path could be substituted between validation and the write.
    assert_plain_app_path(path.parent, directory=True)
    assert_plain_app_path(path, directory=False)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("x", encoding="utf-8", newline="\n") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass


def atomic_write_json(path: Path, value: Any) -> None:
    atomic_write_text(path, json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n")


def _reject_json_constant(value: str) -> None:
    raise ValueError(f"Invalid JSON constant: {value}")


def strict_json_loads(value: str | bytes) -> Any:
    """Decode RFC-compliant JSON; reject NaN/Infinity accepted by Python by default."""
    return json.loads(value, parse_constant=_reject_json_constant)

class RequestBodyTooLarge(Exception):
    """Raised by the ASGI receive wrapper when streamed request data exceeds the limit."""


class RequestBodyLimitMiddleware:
    """Enforce the upload cap even for chunked requests without Content-Length."""

    def __init__(self, app: Any, max_body_bytes: int):
        self.app = app
        self.max_body_bytes = max_body_bytes

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        if scope.get("type") != "http":
            await self.app(scope, receive, send)
            return

        received_bytes = 0
        response_started = False

        async def limited_receive() -> dict[str, Any]:
            nonlocal received_bytes
            message = await receive()
            if message.get("type") == "http.request":
                received_bytes += len(message.get("body", b""))
                if received_bytes > self.max_body_bytes:
                    raise RequestBodyTooLarge
            return message

        async def tracked_send(message: dict[str, Any]) -> None:
            nonlocal response_started
            if message.get("type") == "http.response.start":
                response_started = True
            await send(message)

        try:
            await self.app(scope, limited_receive, tracked_send)
        except RequestBodyTooLarge:
            if response_started:
                raise
            response = JSONResponse(
                {"detail": f"Request body exceeds the {self.max_body_bytes // (1024 * 1024)}MB local upload limit."},
                status_code=413,
            )
            await response(scope, receive, send)
# Only local services are accepted. The studio binds to loopback and does not expose a remote API.
def _local_url(raw: str, label: str) -> str:
    value = (raw or "").strip().rstrip("/")
    try:
        parsed = urlparse(value)
        # Do not permit credentials, arbitrary paths, query strings or fragments.
        # Only the explicitly supported loopback names can reach local services.
        valid = (
            parsed.scheme in {"http", "https"}
            and parsed.hostname in {"127.0.0.1", "localhost", "::1"}
            and parsed.username is None and parsed.password is None
            and parsed.path in {"", "/"} and not parsed.query and not parsed.fragment
        )
        _ = parsed.port  # raises ValueError for malformed/out-of-range ports
    except ValueError:
        valid = False
    if not valid:
        raise HTTPException(400, f"{label} must be a plain local loopback URL (127.0.0.1 / localhost), without credentials or paths.")
    return value


def read_settings() -> dict[str, str]:
    result = dict(DEFAULT_SETTINGS)
    assert_plain_app_path(SETTINGS_PATH, directory=False)
    if SETTINGS_PATH.exists():
        try:
            if SETTINGS_PATH.stat().st_size > 64 * 1024:
                return result
            saved = strict_json_loads(SETTINGS_PATH.read_text(encoding="utf-8"))
            # A syntactically valid JSON scalar/list is still corrupt for this schema.
            # Ignore it safely and retain defaults instead of raising TypeError on `key in saved`.
            if not isinstance(saved, dict):
                return result
            for key in result:
                if key not in saved or not isinstance(saved[key], str):
                    continue
                if key in {"comfy_url", "ollama_url"}:
                    try:
                        result[key] = _local_url(saved[key], key)
                    except HTTPException:
                        # Ignore unsafe/stale endpoints from a manually edited settings file.
                        continue
                else:
                    candidate = saved[key].strip()
                    if candidate:
                        result[key] = candidate[:200]
        except (OSError, ValueError, RecursionError, UnicodeError):
            pass
    return result


SETTINGS = read_settings()


@contextmanager
def get_db() -> Iterator[sqlite3.Connection]:
    assert_plain_app_path(DATA_DIR, directory=True)
    assert_plain_app_path(DB_PATH, directory=False)
    for suffix in ("-wal", "-shm", "-journal"):
        assert_plain_app_path(DB_PATH.with_name(DB_PATH.name + suffix), directory=False)
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=10000")
    conn.execute("PRAGMA foreign_keys=ON")
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def init_db() -> None:
    with get_db() as conn:
        # WAL lets UI polling/readers coexist with short job-history writes.
        # It is configured once at startup, never on every connection.
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")
        schema_version = int(conn.execute("PRAGMA user_version").fetchone()[0])
        if schema_version > DATABASE_SCHEMA_VERSION:
            raise RuntimeError(
                f"Studio database schema {schema_version} is newer than this app supports "
                f"({DATABASE_SCHEMA_VERSION}). Update LocalAI Creative Studio before opening this data folder."
            )
        conn.execute(
            """CREATE TABLE IF NOT EXISTS jobs (
                id TEXT PRIMARY KEY,
                prompt_id TEXT NOT NULL,
                task TEXT NOT NULL,
                workflow_id TEXT NOT NULL,
                prompt TEXT NOT NULL,
                status TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                outputs_json TEXT NOT NULL DEFAULT '[]',
                error TEXT
            )"""
        )
        conn.execute("CREATE INDEX IF NOT EXISTS ix_jobs_created ON jobs(created_at DESC)")
        if schema_version < DATABASE_SCHEMA_VERSION:
            conn.execute(f"PRAGMA user_version={DATABASE_SCHEMA_VERSION}")
    # Keep the user's history/settings in a separate data directory while seeding
    # built-in examples on first run. Never overwrite a user's edited workflows.
    seed_workflows = PACKAGE_ROOT / "data" / "workflows"
    seed_configs = PACKAGE_ROOT / "data" / "configs"
    for seed_dir, destination_dir in ((seed_workflows, WORKFLOW_DIR), (seed_configs, CONFIG_DIR)):
        assert_plain_app_path(seed_dir, directory=True)
        assert_plain_app_path(destination_dir, directory=True)
        for source in seed_dir.glob("*.json"):
            assert_plain_app_path(source, directory=False)
            destination = destination_dir / source.name
            assert_plain_app_path(destination, directory=False)
            if not destination.exists():
                # Atomic copy: an interrupted first launch must not leave truncated JSON.
                atomic_write_text(destination, source.read_text(encoding="utf-8-sig"))


@asynccontextmanager
async def lifespan(_: FastAPI):
    init_db()
    yield


app = FastAPI(title="LocalAI Creative Studio", version=APP_VERSION, lifespan=lifespan)
# Uvicorn is also explicitly bound to loopback. TrustedHost is a second barrier
# against DNS-rebinding requests that point an attacker-controlled host at localhost.
app.add_middleware(TrustedHostMiddleware, allowed_hosts=["127.0.0.1", "localhost", "[::1]", "testserver"])
# Added after TrustedHost so the body guard wraps it and can cap chunked bodies.
app.add_middleware(RequestBodyLimitMiddleware, max_body_bytes=MAX_HTTP_REQUEST_BYTES)

@app.middleware("http")
async def same_origin_for_mutations(request, call_next):
    # Reject oversized declared bodies before Starlette/FastAPI parses multipart uploads.
    content_length = request.headers.get("content-length")
    if content_length:
        try:
            declared_length = int(content_length)
        except ValueError:
            return JSONResponse({"detail": "Invalid Content-Length header."}, status_code=400)
        if declared_length < 0:
            return JSONResponse({"detail": "Invalid Content-Length header."}, status_code=400)
        if declared_length > MAX_HTTP_REQUEST_BYTES:
            return JSONResponse({"detail": "Request body exceeds the 52MB local upload limit."}, status_code=413)
    if request.method in {"POST", "PUT", "PATCH", "DELETE"}:
        origin = request.headers.get("origin")
        if origin:
            try:
                parsed = urlparse(origin)
                origin_host = parsed.hostname
                request_host = request.url.hostname
                origin_port = parsed.port or (443 if parsed.scheme == "https" else 80)
                request_port = request.url.port or (443 if request.url.scheme == "https" else 80)
                allowed = (
                    parsed.scheme == request.url.scheme
                    and parsed.scheme in {"http", "https"}
                    and not parsed.username and not parsed.password
                    and parsed.path in {"", "/"} and not parsed.query and not parsed.fragment
                    and origin_host in {"127.0.0.1", "localhost", "::1"}
                    and request_host in {"127.0.0.1", "localhost", "::1"}
                    and origin_host == request_host and origin_port == request_port
                )
            except ValueError:
                allowed = False
            if not allowed:
                return JSONResponse({"detail": "Cross-origin local requests are blocked."}, status_code=403)
    return await call_next(request)
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


class SettingsUpdate(BaseModel):
    comfy_url: str = Field(default="http://127.0.0.1:8188", min_length=1, max_length=256)
    ollama_url: str = Field(default="http://127.0.0.1:11434", min_length=1, max_length=256)
    ollama_model: str = Field(default="local-qwen35:latest", min_length=1, max_length=200)

    @field_validator("ollama_model")
    @classmethod
    def valid_model_name(cls, value: str) -> str:
        value = value.strip()
        if not value or any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("Ollama model name must be a non-empty single-line value.")
        return value

    @field_validator("comfy_url")
    @classmethod
    def valid_comfy(cls, value: str) -> str:
        return _local_url(value, "ComfyUI URL")

    @field_validator("ollama_url")
    @classmethod
    def valid_ollama(cls, value: str) -> str:
        return _local_url(value, "Ollama URL")


class PromptEnhanceRequest(BaseModel):
    prompt: str = Field(min_length=2, max_length=8000)
    task: str = "image"
    style: str = Field(default="photorealistic", max_length=80)

    @field_validator("task")
    @classmethod
    def valid_task(cls, value: str) -> str:
        if value not in {"image", "video"}:
            raise ValueError("Task must be image or video.")
        return value


class GenerateRequest(BaseModel):
    workflow_id: str
    task: str
    prompt: str = Field(min_length=1, max_length=8000)
    negative_prompt: str = Field(default="", max_length=8000)
    seed: int | None = Field(default=None, ge=0, le=2**63 - 1)
    # None means inherit the value saved in the ComfyUI workflow. This matters
    # for distilled models (for example Z-Image Turbo) with model-specific steps/CFG.
    width: int | None = Field(default=None, ge=256, le=4096)
    height: int | None = Field(default=None, ge=256, le=4096)
    steps: int | None = Field(default=None, ge=1, le=150)
    cfg: float | None = Field(default=None, ge=0, le=30)
    frames: int | None = Field(default=None, ge=8, le=241)
    fps: int | None = Field(default=None, ge=1, le=120)
    checkpoint: str | None = Field(default=None, max_length=240)
    batch_size: int | None = Field(default=None, ge=1, le=4)

    @field_validator("checkpoint")
    @classmethod
    def valid_checkpoint(cls, value: str | None) -> str | None:
        if value is None or not value.strip():
            return None
        candidate = value.strip()
        parts = candidate.split("/")
        if (
            candidate.startswith("/")
            or "\\" in candidate
            or ":" in candidate
            or any(part in {"", ".", ".."} for part in parts)
            or any(ord(ch) < 32 for ch in candidate)
        ):
            raise ValueError("Checkpoint must be a relative ComfyUI model name without traversal or control characters.")
        return candidate


def client(timeout: float = 12.0) -> httpx.AsyncClient:
    # These connectors are intentionally loopback-only; ignore proxy environment variables.
    return httpx.AsyncClient(timeout=httpx.Timeout(timeout, connect=3.0), trust_env=False)


def comfy_url() -> str:
    return _local_url(SETTINGS["comfy_url"], "ComfyUI URL")


def ollama_url() -> str:
    return _local_url(SETTINGS["ollama_url"], "Ollama URL")


def safe_id(value: str) -> str:
    value = re.sub(r"[^a-zA-Z0-9_-]+", "-", value).strip("-_")[:72]
    if not value:
        raise HTTPException(400, "Invalid workflow identifier.")
    return value


def read_workflow(workflow_id: str) -> tuple[dict[str, Any], dict[str, Any]]:
    wf_id = safe_id(workflow_id)
    assert_plain_app_path(WORKFLOW_DIR, directory=True)
    assert_plain_app_path(CONFIG_DIR, directory=True)
    path = WORKFLOW_DIR / f"{wf_id}.json"
    cfg_path = CONFIG_DIR / f"{wf_id}.json"
    assert_plain_app_path(path, directory=False)
    if not path.is_file():
        raise HTTPException(404, "Workflow not found. Import an API-format workflow first.")
    try:
        if path.stat().st_size > MAX_WORKFLOW_BYTES:
            raise HTTPException(413, "Stored workflow JSON exceeds the 20MB safety limit.")
        workflow = strict_json_loads(path.read_text(encoding="utf-8-sig"))
    except HTTPException:
        raise
    except (OSError, ValueError, RecursionError, UnicodeError) as exc:
        raise HTTPException(400, f"Cannot read workflow JSON: {exc}") from exc
    assert_plain_app_path(cfg_path, directory=False)
    try:
        if cfg_path.exists() and cfg_path.stat().st_size > 1024 * 1024:
            raise ValueError("Workflow config exceeds the 1MB safety limit.")
        loaded_config = strict_json_loads(cfg_path.read_text(encoding="utf-8")) if cfg_path.exists() else {}
        config = loaded_config if isinstance(loaded_config, dict) else {}
    except (OSError, ValueError, RecursionError, UnicodeError):
        # A damaged config must not break opening the app. The workflow graph is
        # retained and safe bindings can be suggested again in the workflow tab.
        config = {}
    return workflow, config


def validate_api_workflow(data: Any) -> dict[str, Any]:
    if not isinstance(data, dict) or not data:
        raise HTTPException(400, "Workflow must be a non-empty ComfyUI API-format JSON object.")
    if "nodes" in data and isinstance(data.get("nodes"), list):
        raise HTTPException(
            400,
            "This is a normal ComfyUI canvas workflow, not API format. In ComfyUI enable Settings → Developer mode, then use Save (API Format) and import that JSON.",
        )
    if len(data) > 1000:
        raise HTTPException(400, "Workflow exceeds the 1000-node safety limit.")
    nodes: dict[str, dict[str, Any]] = {}
    for node_id, node in data.items():
        node_key = str(node_id)
        class_type = node.get("class_type") if isinstance(node, dict) else None
        inputs = node.get("inputs") if isinstance(node, dict) else None
        if not node_key or len(node_key) > 40 or any(ord(ch) < 32 or ord(ch) == 127 for ch in node_key):
            raise HTTPException(400, "Workflow contains an invalid node identifier.")
        if not isinstance(class_type, str) or not class_type.strip() or len(class_type) > 160:
            raise HTTPException(400, f"Invalid class_type for node '{node_key}'.")
        if not isinstance(inputs, dict):
            raise HTTPException(400, f"Invalid node '{node_key}'. Expected an inputs object (API format).")
        if len(inputs) > 500:
            raise HTTPException(400, f"Node '{node_key}' has too many inputs.")
        nodes[node_key] = node

    # ComfyUI API links are [node_id, output_slot]. Verify references up front
    # rather than letting a broken imported graph fail after a long model load.
    for node_id, node in nodes.items():
        stack = list(node["inputs"].values())
        while stack:
            value = stack.pop()
            if isinstance(value, dict):
                stack.extend(value.values())
            elif isinstance(value, list):
                if (len(value) == 2 and isinstance(value[0], str)
                        and isinstance(value[1], int) and not isinstance(value[1], bool)):
                    if value[0] not in nodes or value[1] < 0:
                        raise HTTPException(400, f"Node '{node_id}' contains a link to a missing node or invalid output slot: {value!r}.")
                else:
                    stack.extend(value)
    return nodes
def get_workflow_fields(workflow: dict[str, Any]) -> list[dict[str, Any]]:
    fields: list[dict[str, Any]] = []
    for node_id, node in workflow.items():
        inputs = node.get("inputs", {})
        for input_name, value in inputs.items():
            if isinstance(value, (str, int, float, bool)) or value is None:
                meta = node.get("_meta") if isinstance(node.get("_meta"), dict) else {}
                fields.append({
                    "node_id": str(node_id),
                    "node_type": node.get("class_type", ""),
                    "node_title": meta.get("title", node.get("class_type", "")),
                    "input": input_name,
                    "value": value,
                    "value_type": type(value).__name__,
                })
    return fields


def suggest_bindings(workflow: dict[str, Any]) -> dict[str, dict[str, str]]:
    suggestions: dict[str, dict[str, str]] = {}

    def put(key: str, node_id: str, input_name: str) -> None:
        suggestions.setdefault(key, {"node_id": node_id, "input": input_name})

    for node_id, node in workflow.items():
        cls = str(node.get("class_type", "")).lower()
        meta = node.get("_meta") if isinstance(node.get("_meta"), dict) else {}
        title = str(meta.get("title", "")).lower()
        inputs = node.get("inputs", {})
        text_candidates = [name for name in ("text", "prompt", "positive", "prompt_text", "text_prompt") if name in inputs]
        is_text_encoder = any(token in cls for token in ("textencode", "cliptext", "promptencode", "positiveprompt"))
        is_negative = "negative" in cls or "negative" in title or "uncond" in title
        if is_text_encoder and text_candidates:
            target = "negative" if is_negative else "positive"
            put(target, str(node_id), text_candidates[0])
        elif "negative_prompt" in inputs:
            put("negative", str(node_id), "negative_prompt")
        elif "positive_prompt" in inputs:
            put("positive", str(node_id), "positive_prompt")

        for name in inputs:
            lname = str(name).lower()
            if lname in {"seed", "noise_seed"}: put("seed", str(node_id), name)
            elif lname in {"steps", "sampling_steps", "num_inference_steps"}: put("steps", str(node_id), name)
            elif lname in {"cfg", "cfg_scale", "guidance", "guidance_scale"}: put("cfg", str(node_id), name)
            elif lname in {"width", "target_width"}: put("width", str(node_id), name)
            elif lname in {"height", "target_height"}: put("height", str(node_id), name)
            elif lname in {"length", "num_frames", "frames", "frame_count"}: put("frames", str(node_id), name)
            elif lname in {"fps", "frame_rate"}: put("fps", str(node_id), name)
            elif lname in {"batch_size", "batch_count"}: put("batch_size", str(node_id), name)
            elif lname in {"ckpt_name", "checkpoint"}: put("checkpoint", str(node_id), name)
            elif lname in {"image", "start_image", "reference_image"} and "loadimage" in cls:
                put("init_image", str(node_id), name)
    return suggestions


def workflow_bindings(workflow: dict[str, Any], config: dict[str, Any]) -> dict[str, dict[str, str]]:
    """Return only bindings that target real API inputs; malformed metadata fails clearly."""
    # Only older configs that predate the bindings field receive automatic
    # suggestions. An explicitly saved empty object means the user intentionally
    # removed every binding and must not be silently repopulated on the next load.
    if "bindings" not in config:
        return suggest_bindings(workflow)
    raw = config["bindings"]
    if not isinstance(raw, dict):
        raise HTTPException(400, "This workflow has invalid binding metadata. Reconfigure its inputs in the Workflows tab.")
    clean: dict[str, dict[str, str]] = {}
    for name, item in raw.items():
        if name not in BINDING_NAMES:
            continue
        if not isinstance(item, dict):
            raise HTTPException(400, f"Workflow binding '{name}' is malformed. Reconfigure this workflow.")
        node_id = item.get("node_id")
        input_name = item.get("input")
        if not isinstance(node_id, str) or not isinstance(input_name, str):
            raise HTTPException(400, f"Workflow binding '{name}' has no valid node/input pair.")
        if node_id not in workflow or input_name not in workflow[node_id].get("inputs", {}):
            raise HTTPException(400, f"Workflow binding '{name}' points to a missing node/input. Reconfigure this workflow.")
        clean[name] = {"node_id": node_id, "input": input_name}
    return clean


def decode_outputs_json(raw: str | None) -> list[dict[str, Any]]:
    """Return a safe empty list for malformed historical output metadata."""
    try:
        decoded = strict_json_loads(raw or "[]")
    except (TypeError, ValueError, RecursionError, UnicodeError):
        return []
    if not isinstance(decoded, list):
        return []
    return [item for item in decoded if isinstance(item, dict)]


def apply_binding(workflow: dict[str, Any], bindings: dict[str, Any], name: str, value: Any) -> None:
    binding = bindings.get(name)
    if not binding or value is None:
        return
    node_id = str(binding.get("node_id", ""))
    input_name = str(binding.get("input", ""))
    if node_id not in workflow or input_name not in workflow[node_id].get("inputs", {}):
        raise HTTPException(400, f"Workflow binding '{name}' points to a missing node/input. Reconfigure this workflow.")
    workflow[node_id]["inputs"][input_name] = value


def workflow_defaults(workflow: dict[str, Any], bindings: dict[str, Any]) -> dict[str, Any]:
    defaults: dict[str, Any] = {}
    for key in ("steps", "cfg", "width", "height", "frames", "fps", "batch_size", "checkpoint"):
        binding = bindings.get(key)
        if not isinstance(binding, dict):
            continue
        node = workflow.get(str(binding.get("node_id", "")), {})
        value = node.get("inputs", {}).get(str(binding.get("input", "")))
        if isinstance(value, (str, int, float)) and not isinstance(value, bool):
            defaults[key] = value
    return defaults


async def check_service(base: str, endpoint: str, timeout: float = 3.5) -> dict[str, Any]:
    try:
        async with client(timeout) as c:
            response = await c.get(f"{base}{endpoint}")
            response.raise_for_status()
            data = response.json()
            if not isinstance(data, dict):
                return {"ok": False, "error": "Local service returned an unexpected JSON response."}
            return {"ok": True, "data": data}
    except Exception as exc:
        return {"ok": False, "error": str(exc)}


def hardware_snapshot() -> dict[str, Any]:
    result: dict[str, Any] = {
        "platform": os.name,
        "cpu_logical": None,
        "ram_total_gb": None,
        "ram_available_gb": None,
        "disk_free_gb": None,
        "gpus": [],
        "warnings": [],
    }
    try:
        vm = psutil.virtual_memory()
        result["ram_total_gb"] = round(vm.total / (1024 ** 3), 1)
        result["ram_available_gb"] = round(vm.available / (1024 ** 3), 1)
    except (OSError, RuntimeError):
        result["warnings"].append("System memory information is unavailable.")
    try:
        result["cpu_logical"] = psutil.cpu_count(logical=True)
    except (OSError, RuntimeError):
        result["warnings"].append("CPU information is unavailable.")
    try:
        usage = psutil.disk_usage(str(DATA_DIR))
        result["disk_free_gb"] = round(usage.free / (1024 ** 3), 1)
    except (OSError, RuntimeError):
        result["warnings"].append("The Studio data drive is currently unavailable.")
    executable = "nvidia-smi.exe" if os.name == "nt" else "nvidia-smi"
    try:
        proc = subprocess.run(
            [executable, "--query-gpu=name,memory.total,memory.free", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5, check=False,
        )
        if proc.returncode == 0:
            for line in proc.stdout.splitlines():
                cols = [x.strip() for x in line.split(",")]
                if len(cols) >= 3:
                    try:
                        result["gpus"].append({"name": cols[0], "vram_total_gb": round(float(cols[1]) / 1024, 1), "vram_free_gb": round(float(cols[2]) / 1024, 1)})
                    except ValueError:
                        result["gpus"].append({"name": cols[0]})
    except (OSError, subprocess.TimeoutExpired):
        pass
    return result
MODEL_CATALOG = [
    {
        "id": "flux2-klein-4b", "name": "FLUX.2 Klein 4B", "kind": "image", "tier": "balanced",
        "license": "Apache 2.0", "strength": "توليد وتعديل سريع، مع دعم الصور المرجعية المتعددة",
        "hardware": "النسخ المكمّمة FP8/INT8/GGUF تقلل الذاكرة؛ يعتمد الحد الفعلي على text encoder والدقة والـ offload",
        "url": "https://github.com/black-forest-labs/flux2", "source": "Black Forest Labs",
        "recommended": True,
    },
    {
        "id": "z-image-turbo", "name": "Z-Image Turbo 6B", "kind": "image", "tier": "balanced",
        "license": "Apache 2.0", "strength": "واقعية فوتوغرافية وسرعة جيدة واتباع أوامر قوي",
        "hardware": "الناشر يذكر أنه يلائم أجهزة استهلاكية بفئة 16GB VRAM؛ النسخة والـ offload يغيّران ذلك",
        "url": "https://github.com/Tongyi-MAI/Z-Image", "source": "Tongyi-MAI", "recommended": True,
    },
    {
        "id": "qwen-image-2512", "name": "Qwen-Image-2512 20B", "kind": "image", "tier": "quality",
        "license": "Apache 2.0", "strength": "تفاصيل واقعية ونصوص وتركيب بصري معقد داخل الصورة",
        "hardware": "ثقيل؛ يحتاج ذاكرة GPU كبيرة أو offload، لا يُفترض أنه مناسب لكل جهاز",
        "url": "https://huggingface.co/Qwen/Qwen-Image-2512", "source": "Qwen", "recommended": False,
    },
    {
        "id": "qwen-image-2.1", "name": "Qwen-Image 2.1 · 7B", "kind": "image", "tier": "quality",
        "license": "Qwen Research License (non-commercial only)", "strength": "جيل أحدث لتوليد الصور وتحريرها، يدعم RGBA والنصوص ومرجعيات متعددة",
        "hardware": "نسخة INT8 المرفقة: 6.76GB diffusion + 8.71GB text encoder + VAE؛ تتطلب ComfyUI حديثاً وذاكرة GPU/offload كافية",
        "url": "https://github.com/QwenLM/Qwen-Image-2.1", "source": "Qwen", "recommended": True,
    },
    {
        "id": "wan22-ti2v-5b", "name": "Wan 2.2 TI2V 5B", "kind": "video", "tier": "balanced",
        "license": "Apache 2.0", "strength": "نص إلى فيديو وصورة إلى فيديو حتى 720p/24fps",
        "hardware": "ComfyUI يذكر إمكانية تشغيل 5B على فئة 8GB VRAM مع offloading الأصلي؛ التوليد قد يكون بطيئاً",
        "url": "https://github.com/Wan-Video/Wan2.2", "source": "Wan-Video", "recommended": True,
    },
    {
        "id": "wan22-14b", "name": "Wan 2.2 14B", "kind": "video", "tier": "quality",
        "license": "Apache 2.0", "strength": "جودة سينمائية وحركة أغنى في مسارات T2V/I2V",
        "hardware": "أثقل بكثير من 5B؛ استخدم FP8/offload مع GPU مناسب",
        "url": "https://github.com/Wan-Video/Wan2.2", "source": "Wan-Video", "recommended": False,
    },
    {
        "id": "hunyuan-video-15", "name": "HunyuanVideo 1.5 · 8.3B", "kind": "video", "tier": "quality",
        "license": "Tencent Hunyuan Community License", "strength": "فيديو 480p/720p من النص أو الصورة؛ تتوفر نسخ step-distilled لبعض المسارات",
        "hardware": "يحتاج نسخة ComfyUI workflow متوافقة؛ متطلبات الذاكرة تختلف بشدة حسب الدقة والنسخة",
        "url": "https://github.com/Tencent-Hunyuan/HunyuanVideo-1.5", "source": "Tencent Hunyuan", "recommended": False,
    },
    {
        "id": "ltx25", "name": "LTX-2.5", "kind": "video", "tier": "quality",
        "license": "LTX-2 Community License", "strength": "فيديو وصوت متزامنان ومشاهد متعددة وامتداد/تعديل",
        "hardware": "الحد الأدنى المنشور 32GB VRAM و32GB RAM و100GB مساحة",
        "url": "https://docs.ltx.io/models/ltx-2-5", "source": "Lightricks", "recommended": False,
    },
]


@app.get("/", response_class=HTMLResponse)
async def home() -> HTMLResponse:
    index_path = STATIC_DIR / "index.html"
    assert_plain_app_path(index_path, directory=False)
    html = index_path.read_text(encoding="utf-8")
    # The HTML uses a placeholder so release versions are not duplicated manually.
    return HTMLResponse(html.replace("__APP_VERSION__", APP_VERSION))


@app.get("/api/ready")
async def ready() -> dict[str, Any]:
    """Fast process-readiness probe. It deliberately does not wait for external engines."""
    return {"ok": True, "app": "LocalAI Creative Studio", "version": APP_VERSION}


@app.get("/api/health")
async def health() -> dict[str, Any]:
    comfy, ollama = await asyncio.gather(
        check_service(comfy_url(), "/system_stats", timeout=2.2),
        check_service(ollama_url(), "/api/version", timeout=2.2),
    )
    return {
        "app": "LocalAI Creative Studio", "version": APP_VERSION,
        "comfyui": {"ok": comfy["ok"], "error": comfy.get("error"), "url": comfy_url()},
        "ollama": {"ok": ollama["ok"], "error": ollama.get("error"), "url": ollama_url()},
        "local_only": True,
    }


@app.get("/api/system")
async def system_info() -> dict[str, Any]:
    h = hardware_snapshot()
    comfy, queue, ollama_version, tags = await asyncio.gather(
        check_service(comfy_url(), "/system_stats"),
        check_service(comfy_url(), "/queue"),
        check_service(ollama_url(), "/api/version"),
        check_service(ollama_url(), "/api/tags"),
    )
    models = []
    if tags["ok"]:
        raw_models = tags["data"].get("models", [])
        if isinstance(raw_models, list):
            models = [str(model["name"])[:200] for model in raw_models if isinstance(model, dict) and isinstance(model.get("name"), str) and model["name"].strip()]
    return {
        "hardware": h,
        "comfyui": {"ok": comfy["ok"], "error": comfy.get("error"), "system": comfy.get("data"), "queue": queue.get("data") if queue["ok"] else None},
        "ollama": {"ok": ollama_version["ok"], "version": ollama_version.get("data"), "error": ollama_version.get("error"), "models": models},
        "settings": SETTINGS,
    }


@app.get("/api/settings")
async def get_settings() -> dict[str, str]:
    return dict(SETTINGS)


@app.put("/api/settings")
async def update_settings(data: SettingsUpdate) -> dict[str, str]:
    model_name = data.ollama_model.strip()
    if not model_name:
        raise HTTPException(400, "Ollama model name cannot be empty.")
    candidate = {
        "comfy_url": data.comfy_url.rstrip("/"),
        "ollama_url": data.ollama_url.rstrip("/"),
        "ollama_model": model_name[:200],
    }
    try:
        atomic_write_json(SETTINGS_PATH, candidate)
    except (OSError, RuntimeError) as exc:
        raise HTTPException(500, f"Could not save local Studio settings: {exc}") from exc
    # Publish the new in-memory settings only after the atomic disk write succeeds.
    SETTINGS.update(candidate)
    return dict(SETTINGS)


@app.get("/api/catalog")
async def model_catalog() -> dict[str, Any]:
    hardware = hardware_snapshot()
    vram = max((g.get("vram_total_gb", 0) for g in hardware["gpus"]), default=0)
    enriched = []
    for model in MODEL_CATALOG:
        item = dict(model)
        if item["id"] == "ltx25" and vram:
            item["fit"] = "candidate" if vram >= 32 else "not-recommended"
        elif item["id"] == "ltx25":
            item["fit"] = "check-hardware"
        elif item["id"] == "qwen-image-2.1" and vram:
            item["fit"] = "candidate" if vram >= 20 else "check-offload"
        elif item["id"] in {"qwen-image-2512", "hunyuan-video-15"} and vram:
            item["fit"] = "candidate" if vram >= 24 else "heavy"
        elif item["id"] == "wan22-14b" and vram:
            item["fit"] = "candidate" if vram >= 32 else "heavy"
        elif item["id"] == "z-image-turbo" and vram:
            item["fit"] = "candidate" if vram >= 16 else "check-offload"
        elif item["id"] == "flux2-klein-4b" and vram:
            item["fit"] = "candidate" if vram >= 12 else "check-offload"
        elif item["id"] == "wan22-ti2v-5b" and vram:
            item["fit"] = "candidate" if vram >= 8 else "check-offload"
        else:
            item["fit"] = "check-hardware"
        enriched.append(item)
    return {"models": enriched, "hardware": hardware}
@app.get("/api/models")
async def installed_models() -> dict[str, Any]:
    folders = ["checkpoints", "diffusion_models", "unet", "text_encoders", "clip", "vae", "loras", "upscale_models", "controlnet", "model_patches"]
    async with client() as c:
        async def fetch_folder(folder: str) -> tuple[str, list[Any]]:
            try:
                response = await c.get(f"{comfy_url()}/models/{folder}")
                if response.is_success:
                    data = response.json()
                    return folder, data if isinstance(data, list) else []
            except Exception:
                pass
            return folder, []
        pairs = await asyncio.gather(*(fetch_folder(folder) for folder in folders))
    return {"folders": dict(pairs)}


@app.get("/api/workflows")
async def list_workflows() -> dict[str, Any]:
    assert_plain_app_path(WORKFLOW_DIR, directory=True)
    assert_plain_app_path(CONFIG_DIR, directory=True)
    items = []
    for path in sorted(WORKFLOW_DIR.glob("*.json")):
        try:
            wf, config = read_workflow(path.stem)
            wf = validate_api_workflow(wf)
            task = config.get("task", "image")
            if task not in {"image", "video"}:
                task = "image"
            bindings = workflow_bindings(wf, config)
            items.append({"id": path.stem, "name": config.get("name", path.stem), "task": task, "nodes": len(wf), "bindings": bindings, "defaults": workflow_defaults(wf, bindings), "model_id": config.get("model_id"), "model_name": config.get("model_name"), "requirements": config.get("requirements", []), "optional_requirements": config.get("optional_requirements", []), "source_url": config.get("source_url"), "license": config.get("license")})
        except Exception as exc:
            items.append({"id": path.stem, "name": path.stem, "task": "unknown", "error": str(exc)})
    return {"workflows": items}


@app.get("/api/workflows/{workflow_id}")
async def workflow_detail(workflow_id: str) -> dict[str, Any]:
    workflow, config = read_workflow(workflow_id)
    workflow = validate_api_workflow(workflow)
    return {
        "id": safe_id(workflow_id), "name": config.get("name", workflow_id),
        "task": config.get("task", "image"), "nodes": len(workflow),
        "fields": get_workflow_fields(workflow),
        "bindings": workflow_bindings(workflow, config),
        "defaults": workflow_defaults(workflow, workflow_bindings(workflow, config)),
        "model_id": config.get("model_id"), "model_name": config.get("model_name"),
        "requirements": config.get("requirements", []), "optional_requirements": config.get("optional_requirements", []),
        "source_url": config.get("source_url"), "license": config.get("license"),
    }


@app.post("/api/workflows/import")
async def import_workflow(file: UploadFile = File(...), task: str = Form("image"), name: str = Form("")) -> dict[str, Any]:
    if not file.filename or not file.filename.lower().endswith(".json"):
        raise HTTPException(400, "Choose a .json API workflow exported by ComfyUI.")
    raw = await file.read(MAX_WORKFLOW_BYTES + 1)
    if len(raw) > MAX_WORKFLOW_BYTES:
        raise HTTPException(413, "Workflow JSON exceeds 20MB.")
    try:
        data = strict_json_loads(raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, ValueError, RecursionError) as exc:
        raise HTTPException(400, f"Invalid JSON file: {exc}") from exc
    if task not in {"image", "video"}:
        raise HTTPException(400, "Workflow task must be image or video.")
    assert_plain_app_path(WORKFLOW_DIR, directory=True)
    assert_plain_app_path(CONFIG_DIR, directory=True)
    workflow = validate_api_workflow(data)
    clean_filename = file.filename.replace("\\", "/")
    stem = safe_id(Path(clean_filename).stem)
    # Avoid overwriting a previous workflow without changing its identifier.
    wf_id = stem
    suffix = 2
    while (WORKFLOW_DIR / f"{wf_id}.json").exists() or (CONFIG_DIR / f"{wf_id}.json").exists():
        wf_id = f"{stem}-{suffix}"
        suffix += 1
    workflow_path = WORKFLOW_DIR / f"{wf_id}.json"
    config_path = CONFIG_DIR / f"{wf_id}.json"
    config = {"name": (name or Path(clean_filename).stem)[:100], "task": task, "bindings": suggest_bindings(workflow)}
    try:
        atomic_write_json(workflow_path, workflow)
        atomic_write_json(config_path, config)
    except (OSError, RuntimeError) as exc:
        # Do not leave a half-imported workflow visible if one of the paired files fails.
        try:
            assert_plain_app_path(workflow_path, directory=False)
            workflow_path.unlink(missing_ok=True)
        except (OSError, RuntimeError):
            pass
        raise HTTPException(500, f"Could not save the workflow and its configuration: {exc}") from exc
    return {"id": wf_id, "name": config["name"], "task": config["task"], "nodes": len(workflow), "bindings": config["bindings"], "fields": get_workflow_fields(workflow)}


@app.put("/api/workflows/{workflow_id}/config")
async def save_workflow_config(workflow_id: str, data: dict[str, Any]) -> dict[str, Any]:
    wf_id = safe_id(workflow_id)
    assert_plain_app_path(CONFIG_DIR, directory=True)
    workflow, old = read_workflow(wf_id)
    task = data.get("task", old.get("task", "image"))
    if task not in {"image", "video"}:
        raise HTTPException(400, "Workflow task must be image or video.")
    bindings = data.get("bindings", {})
    allowed = {"positive", "negative", "seed", "steps", "cfg", "width", "height", "frames", "fps", "checkpoint", "batch_size", "init_image", "image_subfolder"}
    clean: dict[str, dict[str, str]] = {}
    if not isinstance(bindings, dict):
        raise HTTPException(400, "bindings must be an object.")
    for key, value in bindings.items():
        if key not in allowed or value is None:
            continue
        if not isinstance(value, dict):
            raise HTTPException(400, f"Invalid binding for {key}.")
        node_id, input_name = str(value.get("node_id", "")), str(value.get("input", ""))
        if node_id not in workflow or input_name not in workflow[node_id].get("inputs", {}):
            raise HTTPException(400, f"Binding {key} refers to a missing workflow input.")
        clean[key] = {"node_id": node_id, "input": input_name}
    # Preserve every metadata field not explicitly edited by the UI, including
    # provenance, licensing, model requirements, author notes and future fields.
    config = {key: value for key, value in old.items() if key not in {"name", "task", "bindings"}}
    config.update({"name": str(data.get("name", old.get("name", wf_id)))[:100], "task": task, "bindings": clean})
    config_path = CONFIG_DIR / f"{wf_id}.json"
    assert_plain_app_path(config_path, directory=False)
    atomic_write_json(config_path, config)
    return config


@app.delete("/api/workflows/{workflow_id}")
async def delete_workflow(workflow_id: str) -> dict[str, bool]:
    wf_id = safe_id(workflow_id)
    assert_plain_app_path(WORKFLOW_DIR, directory=True)
    assert_plain_app_path(CONFIG_DIR, directory=True)
    path = WORKFLOW_DIR / f"{wf_id}.json"
    config = CONFIG_DIR / f"{wf_id}.json"
    try:
        assert_plain_app_path(path, directory=False)
        assert_plain_app_path(config, directory=False)
    except RuntimeError as exc:
        # A redirected graph/config is a client-visible safety refusal, not an
        # unhandled server error. In particular, leave the original graph untouched.
        raise HTTPException(400, f"Workflow files are not safe to modify: {exc}") from exc
    if not path.is_file():
        raise HTTPException(404, "Workflow not found.")

    # Move both files to app-created tombstone names first. If the second move
    # fails, restore the graph so the workflow does not disappear half-way.
    token = uuid.uuid4().hex
    workflow_tombstone = WORKFLOW_DIR / f".{wf_id}.{token}.delete"
    config_tombstone = CONFIG_DIR / f".{wf_id}.{token}.delete"
    moved_workflow = False
    try:
        os.replace(path, workflow_tombstone)
        moved_workflow = True
        if config.exists():
            os.replace(config, config_tombstone)
    except OSError as exc:
        if moved_workflow and workflow_tombstone.exists() and not path.exists():
            os.replace(workflow_tombstone, path)
        raise HTTPException(500, f"Could not safely remove workflow files: {exc}") from exc
    for tombstone in (workflow_tombstone, config_tombstone):
        if tombstone.exists():
            tombstone.unlink()
    return {"deleted": True}
@app.post("/api/prompt/enhance")
async def enhance_prompt(data: PromptEnhanceRequest) -> dict[str, Any]:
    system = (
        "You are an expert visual prompt director. Expand the user's idea into a precise, visually coherent prompt. "
        "Preserve the user's intended subject and action. Specify composition, lens/camera, lighting, materials, "
        "environment, color, motion and temporal continuity when useful. Avoid contradictory adjectives and impossible camera moves. "
        "Return ONLY valid JSON with keys positive_prompt, negative_prompt, and notes. Prompts should be in English for broad diffusion-model compatibility; notes may be Arabic. "
        "Do not add copyrighted character names or brand logos unless explicitly requested."
    )
    user = f"Task: {data.task}. Style: {data.style}. User idea: {data.prompt}"
    payload = {"model": SETTINGS["ollama_model"], "stream": False, "format": "json", "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}], "options": {"temperature": 0.35}}
    try:
        async with client(90) as c:
            response = await c.post(f"{ollama_url()}/api/chat", json=payload)
            response.raise_for_status()
            body = response.json()
            content = body.get("message", {}).get("content", "")
        positive, negative, notes = normalize_enhanced_prompt(content)
        return {"ok": True, "positive_prompt": positive, "negative_prompt": negative, "notes": notes}
    except Exception as exc:
        raise HTTPException(502, f"Local prompt enhancement failed. Check that Ollama is running and the selected model is installed. Details: {exc}") from exc


def normalize_comfy_filename(value: Any) -> str:
    raw = str(value or "").replace("\\", "/")
    if (
        not raw or raw in {".", ".."} or PurePosixPath(raw).name != raw or
        ":" in raw or any(ord(ch) < 32 or ord(ch) == 127 for ch in raw)
    ):
        raise ValueError("ComfyUI returned an unsafe media filename.")
    return raw


def normalize_comfy_subfolder(value: Any) -> str:
    raw = str(value or "").replace("\\", "/")
    if ":" in raw or any(ord(ch) < 32 or ord(ch) == 127 for ch in raw):
        raise ValueError("ComfyUI returned an unsafe media subfolder.")
    path = PurePosixPath(raw) if raw else PurePosixPath("")
    if path.is_absolute() or ".." in path.parts:
        raise ValueError("ComfyUI returned an unsafe media subfolder.")
    normalized = str(path)
    return "" if normalized in {"", "."} else normalized


def normalize_enhanced_prompt(content: str) -> tuple[str, str, str]:
    """Validate and cap the local model response to the generator's input contract."""
    parsed = strict_json_loads(content)
    if not isinstance(parsed, dict) or not parsed.get("positive_prompt"):
        raise ValueError("Model returned incomplete prompt JSON")
    positive = str(parsed.get("positive_prompt", "")).strip()[:8000]
    negative = str(parsed.get("negative_prompt", "")).strip()[:8000]
    notes = str(parsed.get("notes", "")).strip()[:2000]
    if len(positive) < 2:
        raise ValueError("Model returned an empty positive prompt")
    return positive, negative, notes


def detect_image_type(contents: bytes) -> tuple[str, str]:
    """Check file signatures rather than trusting a browser-supplied MIME header."""
    if contents.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png", ".png"
    if contents.startswith(b"\xff\xd8\xff"):
        return "image/jpeg", ".jpg"
    if len(contents) >= 12 and contents[:4] == b"RIFF" and contents[8:12] == b"WEBP":
        return "image/webp", ".webp"
    raise HTTPException(400, "Reference file contents are not a valid PNG, JPEG, or WebP signature.")


def queue_items(payload: Any, key: str) -> list[Any]:
    """Normalize optional ComfyUI queue collections; malformed responses are empty."""
    if not isinstance(payload, dict):
        return []
    value = payload.get(key)
    return value if isinstance(value, list) else []


def tracked_prompt_ids(queue_items: Any, tracked: list[sqlite3.Row] | list[dict[str, Any]]) -> list[tuple[str, str]]:
    """Return only Studio-owned prompt IDs that are still in ComfyUI's pending queue."""
    pending_ids = {
        str(item[1]) for item in (queue_items or [])
        if isinstance(item, (list, tuple)) and len(item) > 1
    }
    selected: list[tuple[str, str]] = []
    for row in tracked:
        local_id = str(row["id"])
        prompt_id = str(row["prompt_id"])
        if prompt_id in pending_ids:
            selected.append((local_id, prompt_id))
    return selected


@app.post("/api/generate")
async def generate(request_json: str = Form(...), image: UploadFile | None = File(None)) -> dict[str, Any]:
    try:
        req = GenerateRequest.model_validate_json(request_json)
    except Exception as exc:
        raise HTTPException(422, f"Invalid generation request: {exc}") from exc
    wf_id = safe_id(req.workflow_id)
    if req.task not in {"image", "video"}:
        raise HTTPException(400, "Task must be image or video.")
    workflow, config = read_workflow(wf_id)
    workflow = validate_api_workflow(workflow)
    if config.get("task", "image") != req.task:
        raise HTTPException(400, f"Selected workflow is for {config.get('task', 'image')}, not {req.task}.")
    bindings = workflow_bindings(workflow, config)
    if "positive" not in bindings:
        raise HTTPException(400, "This workflow has no positive-prompt binding. Configure it in the Workflows tab first.")
    if "init_image" in bindings and image is None:
        raise HTTPException(400, "The selected workflow requires a reference image. Upload a PNG, JPEG, or WebP image, or select a text-to-video workflow.")
    if "checkpoint" in bindings and not req.checkpoint:
        checkpoint_binding = bindings["checkpoint"]
        node = workflow.get(str(checkpoint_binding.get("node_id", "")), {})
        current_checkpoint = node.get("inputs", {}).get(str(checkpoint_binding.get("input", "")), "")
        if not current_checkpoint or str(current_checkpoint).startswith("CHOOSE_"):
            raise HTTPException(400, "Choose an installed compatible checkpoint before generating.")
    seed = req.seed if req.seed is not None and req.seed >= 0 else random.SystemRandom().randint(0, 2**63 - 1)
    values: dict[str, Any] = {
        "positive": req.prompt, "negative": req.negative_prompt,
        "seed": seed,
        "steps": req.steps, "cfg": req.cfg,
        "width": max(256, (req.width // 64) * 64) if req.width is not None else None,
        "height": max(256, (req.height // 64) * 64) if req.height is not None else None,
        "frames": req.frames, "fps": req.fps, "checkpoint": req.checkpoint, "batch_size": req.batch_size,
    }
    async with client(60) as c:
        # Image upload is handled by ComfyUI itself so the workflow only receives a safe input filename.
        if image is not None:
            if "init_image" not in bindings:
                raise HTTPException(400, "This workflow has no image-input binding. Configure init_image before uploading a reference.")
            contents = await image.read(MAX_REFERENCE_IMAGE_BYTES + 1)
            if not contents:
                raise HTTPException(400, "Reference image is empty.")
            if len(contents) > MAX_REFERENCE_IMAGE_BYTES:
                raise HTTPException(413, "Reference image exceeds 30MB.")
            actual_mime, extension = detect_image_type(contents)
            upload_name = f"localai-reference-{uuid.uuid4().hex}{extension}"
            try:
                uploaded = await c.post(
                    f"{comfy_url()}/upload/image",
                    files={"image": (upload_name, contents, actual_mime)},
                    data={"type": "input", "overwrite": "false"},
                )
                uploaded.raise_for_status()
                upload_data = uploaded.json()
                if not isinstance(upload_data, dict):
                    raise ValueError("ComfyUI returned an unexpected upload response.")
            except Exception as exc:
                raise HTTPException(502, f"ComfyUI reference upload failed: {exc}") from exc
            try:
                returned_name = normalize_comfy_filename(upload_data.get("name") or upload_name)
                returned_subfolder = normalize_comfy_subfolder(upload_data.get("subfolder"))
            except ValueError as exc:
                raise HTTPException(502, str(exc)) from exc
            values["init_image"] = f"{returned_subfolder}/{returned_name}" if returned_subfolder else returned_name
            values["image_subfolder"] = returned_subfolder
        for key, value in values.items():
            apply_binding(workflow, bindings, key, value)

        # Reserve a local history row before sending a job to ComfyUI. If ComfyUI
        # accepts a prompt but the response/database update fails, the submission
        # remains visible as `submitting` instead of becoming an untracked queue item.
        local_id = uuid.uuid4().hex
        now = time.time()
        placeholder_prompt_id = f"submitting:{local_id}"
        with get_db() as conn:
            conn.execute(
                "INSERT INTO jobs (id,prompt_id,task,workflow_id,prompt,status,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?)",
                (local_id, placeholder_prompt_id, req.task, wf_id, req.prompt[:8000], "submitting", now, now),
            )
        try:
            response = await c.post(f"{comfy_url()}/prompt", json={"prompt": workflow, "client_id": local_id})
            try:
                body = response.json()
            except ValueError as exc:
                raise HTTPException(502, f"ComfyUI returned a non-JSON response (HTTP {response.status_code}).") from exc
            if response.status_code >= 400 or (isinstance(body, dict) and body.get("error")):
                details = body.get("error", body) if isinstance(body, dict) else body
                raise HTTPException(422, f"ComfyUI rejected this workflow: {details}")
            if not isinstance(body, dict) or not body.get("prompt_id"):
                raise HTTPException(502, f"ComfyUI did not return a prompt_id: {body}")
            prompt_id = str(body["prompt_id"])
            if len(prompt_id) > 128 or any(ord(ch) < 32 or ord(ch) == 127 for ch in prompt_id):
                raise HTTPException(502, "ComfyUI returned an invalid prompt identifier.")
            completed_at = time.time()
            with get_db() as conn:
                conn.execute(
                    "UPDATE jobs SET prompt_id=?,status='queued',updated_at=?,error=NULL WHERE id=?",
                    (prompt_id, completed_at, local_id),
                )
        except HTTPException as exc:
            try:
                with get_db() as conn:
                    conn.execute("UPDATE jobs SET status='failed',updated_at=?,error=? WHERE id=?", (time.time(), str(exc.detail)[:3000], local_id))
            except Exception:
                pass
            raise
        except Exception as exc:
            try:
                with get_db() as conn:
                    conn.execute("UPDATE jobs SET status='failed',updated_at=?,error=? WHERE id=?", (time.time(), str(exc)[:3000], local_id))
            except Exception:
                pass
            raise HTTPException(502, f"Could not submit workflow to ComfyUI. A local failed/submitting record was retained: {exc}") from exc
    return {"id": local_id, "prompt_id": prompt_id, "task": req.task, "seed": seed, "queue_number": body.get("number")}


def flatten_outputs(outputs: Any) -> list[dict[str, Any]]:
    """Flatten well-formed ComfyUI media outputs; ignore malformed history payloads."""
    if not isinstance(outputs, dict):
        return []
    result: list[dict[str, Any]] = []
    for node_id, node_out in outputs.items():
        if not isinstance(node_out, dict):
            continue
        for kind in ("images", "gifs", "videos", "audio"):
            values = node_out.get(kind, [])
            if not isinstance(values, list):
                continue
            for item in values:
                if not isinstance(item, dict) or not item.get("filename"):
                    continue
                try:
                    filename = normalize_comfy_filename(item["filename"])
                    subfolder = normalize_comfy_subfolder(item.get("subfolder"))
                except ValueError:
                    continue
                media_type = str(item.get("type", "output"))
                if media_type not in {"output", "temp", "input"}:
                    continue
                result.append({
                    "node_id": str(node_id), "kind": kind,
                    "filename": filename, "subfolder": subfolder, "type": media_type,
                    "url": f"/api/media?filename={quote(filename, safe='')}&subfolder={quote(subfolder, safe='')}&type={quote(media_type, safe='')}",
                })
    return result
@app.get("/api/jobs")
async def list_jobs(limit: int = 40) -> dict[str, Any]:
    limit = max(1, min(limit, 200))
    with get_db() as conn:
        rows = conn.execute("SELECT * FROM jobs ORDER BY created_at DESC LIMIT ?", (limit,)).fetchall()
    return {"jobs": [dict(row) | {"outputs": decode_outputs_json(row["outputs_json"])} for row in rows]}


@app.get("/api/jobs/{local_id}")
async def get_job(local_id: str) -> dict[str, Any]:
    with get_db() as conn:
        row = conn.execute("SELECT * FROM jobs WHERE id=?", (local_id,)).fetchone()
    if not row:
        raise HTTPException(404, "Job not found.")
    prompt_id = row["prompt_id"]
    if row["status"] in {"submitting", "failed", "cancelled"} or str(prompt_id).startswith("submitting:"):
        return dict(row) | {"outputs": decode_outputs_json(row["outputs_json"]), "status": row["status"], "error": row["error"]}
    try:
        async with client() as c:
            history_response = await c.get(f"{comfy_url()}/history/{prompt_id}")
            history_response.raise_for_status()
            history_payload = history_response.json()
            if not isinstance(history_payload, dict):
                raise ValueError("ComfyUI returned an unexpected history response.")
            history = history_payload.get(prompt_id)
            if not isinstance(history, dict):
                history = None
            queue_response = await c.get(f"{comfy_url()}/queue")
            queue_payload = queue_response.json() if queue_response.is_success else {}
            queue = queue_payload if isinstance(queue_payload, dict) else {}
    except Exception as exc:
        return dict(row) | {"outputs": decode_outputs_json(row["outputs_json"]), "status": row["status"], "backend_error": str(exc)}
    status = row["status"]
    outputs: list[dict[str, Any]] = decode_outputs_json(row["outputs_json"])
    error = row["error"]
    if history:
        outputs = flatten_outputs(history.get("outputs", {}))
        status_info = history.get("status", {})
        if not isinstance(status_info, dict):
            status_info = {}
        status_str = str(status_info.get("status_str", "")).lower()
        messages = status_info.get("messages", [])
        if not isinstance(messages, list):
            messages = []
        has_execution_error = any("execution_error" in str(message).lower() for message in messages)
        if status_info.get("completed") or status_str in {"success", "completed"}:
            status = "completed"
        elif status_str in {"error", "failed"} or has_execution_error:
            status = "failed"
            error = json.dumps(messages, ensure_ascii=False)[:3000]
        else:
            status = "running"
    else:
        running_ids = {str(x[1]) for x in queue_items(queue, "queue_running") if isinstance(x, (list, tuple)) and len(x) > 1}
        pending_ids = {str(x[1]) for x in queue_items(queue, "queue_pending") if isinstance(x, (list, tuple)) and len(x) > 1}
        status = "running" if prompt_id in running_ids else "queued" if prompt_id in pending_ids else "missing"
    now = time.time()
    with get_db() as conn:
        conn.execute("UPDATE jobs SET status=?,updated_at=?,outputs_json=?,error=? WHERE id=?", (status, now, json.dumps(outputs), error, local_id))
    return dict(row) | {"status": status, "outputs": outputs, "error": error}


@app.get("/api/queue")
async def queue_status() -> dict[str, Any]:
    try:
        async with client() as c:
            r = await c.get(f"{comfy_url()}/queue")
            r.raise_for_status()
            payload = r.json()
            if not isinstance(payload, dict):
                raise ValueError("ComfyUI returned an unexpected queue response.")
            return payload
    except Exception as exc:
        raise HTTPException(503, f"ComfyUI queue is unavailable: {exc}") from exc


@app.post("/api/queue/interrupt")
async def interrupt_queue() -> dict[str, Any]:
    try:
        async with client() as c:
            queue_response = await c.get(f"{comfy_url()}/queue")
            queue_response.raise_for_status()
            queue = queue_response.json()
            with get_db() as conn:
                tracked = conn.execute("SELECT id,prompt_id FROM jobs WHERE status IN ('queued','running')").fetchall()
            # A malformed/nullable queue is treated as unknown, never as permission
            # to interrupt an arbitrary currently running ComfyUI task.
            queue_running = [
                str(item[1]) for item in queue_items(queue, "queue_running")
                if isinstance(item, (list, tuple)) and len(item) > 1
            ]
            owned_running = {str(row["prompt_id"]) for row in tracked}
            # ComfyUI's /interrupt endpoint interrupts the current engine task, not a
            # specific prompt_id. Never call it if the active task cannot be identified
            # as the sole Studio-owned task.
            if len(queue_running) != 1 or queue_running[0] not in owned_running:
                return {"ok": True, "interrupted": False, "message": "The current ComfyUI task is not uniquely identified as a Studio task; nothing was interrupted."}
            response = await c.post(f"{comfy_url()}/interrupt")
            response.raise_for_status()
        return {"ok": True, "interrupted": True, "message": "Studio generation interrupt requested."}
    except Exception as exc:
        raise HTTPException(502, f"Could not interrupt the Studio generation: {exc}") from exc


@app.post("/api/queue/clear")
async def clear_queue() -> dict[str, Any]:
    """Delete only pending jobs submitted from this Studio, never all ComfyUI work."""
    try:
        async with client() as c:
            queue_response = await c.get(f"{comfy_url()}/queue")
            queue_response.raise_for_status()
            queue = queue_response.json()
            with get_db() as conn:
                tracked = conn.execute("SELECT id,prompt_id FROM jobs WHERE status='queued'").fetchall()
            selected = tracked_prompt_ids(queue_items(queue, "queue_pending"), tracked)
            if not selected:
                return {"ok": True, "deleted": 0, "message": "No pending Studio jobs were found; other ComfyUI queue items were left untouched."}
            prompt_ids = [prompt_id for _, prompt_id in selected]
            response = await c.post(f"{comfy_url()}/queue", json={"delete": prompt_ids})
            response.raise_for_status()
            now = time.time()
            with get_db() as conn:
                conn.executemany(
                    "UPDATE jobs SET status='cancelled',updated_at=? WHERE id=? AND status='queued'",
                    [(now, local_id) for local_id, _ in selected],
                )
        return {"ok": True, "deleted": len(selected), "message": "Only queued jobs submitted from this Studio were deleted."}
    except Exception as exc:
        raise HTTPException(502, f"Could not clear Studio pending jobs: {exc}") from exc
@app.get("/api/media")
async def get_media(filename: str, subfolder: str = "", type: str = "output") -> StreamingResponse:
    if type not in {"output", "temp", "input"}:
        raise HTTPException(400, "Invalid media type.")
    safe_filename = PurePosixPath(filename).name
    normalized_subfolder = (subfolder or "").replace("\\", "/")
    safe_subfolder = str(PurePosixPath(normalized_subfolder)) if normalized_subfolder else ""
    if (safe_filename != filename or not filename or filename in {".", ".."} or len(filename) > 255
            or len(safe_subfolder) > 512 or "/" in filename or "\\" in filename or ":" in filename
            or "\\" in subfolder or ".." in PurePosixPath(safe_subfolder).parts
            or safe_subfolder.startswith("/") or safe_subfolder == "." or ":" in safe_subfolder
            or any(ord(ch) < 32 or ord(ch) == 127 for ch in filename + safe_subfolder)):
        raise HTTPException(400, "Invalid media path.")
    params = {"filename": safe_filename, "subfolder": safe_subfolder, "type": type}
    upstream = httpx.AsyncClient(timeout=httpx.Timeout(300.0, connect=5.0), trust_env=False)
    try:
        request = upstream.build_request("GET", f"{comfy_url()}/view", params=params)
        response = await upstream.send(request, stream=True)
        if not response.is_success:
            status = response.status_code
            await response.aread()
            await response.aclose()
            await upstream.aclose()
            raise HTTPException(status, "ComfyUI could not find the requested media file.")
        content_type = response.headers.get("content-type", "application/octet-stream").split(";", 1)[0].strip().lower()
        allowed_media_types = {
            "image/png", "image/jpeg", "image/webp", "image/gif", "image/avif",
            "video/mp4", "video/webm", "video/quicktime", "video/x-matroska",
            "audio/wav", "audio/x-wav", "audio/mpeg", "audio/ogg", "audio/flac",
            "application/octet-stream",
        }
        if content_type not in allowed_media_types:
            await response.aclose()
            await upstream.aclose()
            raise HTTPException(415, "ComfyUI returned a file type that this local media viewer will not serve.")

        async def stream_content() -> AsyncIterator[bytes]:
            try:
                async for chunk in response.aiter_bytes():
                    yield chunk
            finally:
                await response.aclose()
                await upstream.aclose()

        return StreamingResponse(stream_content(), media_type=content_type, headers={
            "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
            "Content-Security-Policy": "default-src 'none'; sandbox",
        })
    except HTTPException:
        raise
    except Exception as exc:
        await upstream.aclose()
        raise HTTPException(502, f"Could not read generated media: {exc}") from exc


@app.get("/api/diagnostic")
async def diagnostic() -> dict[str, Any]:
    system = await system_info()
    storage_warnings: list[str] = []
    try:
        assert_plain_app_path(WORKFLOW_DIR, directory=True)
        workflow_count: int | None = sum(1 for item in WORKFLOW_DIR.glob("*.json") if item.is_file() and not _is_reparse_path(item))
    except (OSError, RuntimeError):
        workflow_count = None
        storage_warnings.append("The Studio workflow directory is unavailable or redirected.")
    data_writable = False
    try:
        assert_plain_app_path(DATA_DIR, directory=True)
        data_writable = DATA_DIR.is_dir() and os.access(DATA_DIR, os.W_OK)
    except (OSError, RuntimeError):
        storage_warnings.append("The Studio data directory is unavailable or redirected.")
    return {
        "app_version": APP_VERSION,
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "python": os.sys.version.split()[0],
        "hardware": system["hardware"],
        "comfyui": system["comfyui"],
        "ollama": system["ollama"],
        "workflow_count": workflow_count,
        "data_dir": str(DATA_DIR),
        "storage_warnings": storage_warnings,
        "checks": {
            "studio_data_writable": data_writable,
            "workflow_dir_exists": WORKFLOW_DIR.is_dir(),
            "ollama_local_model_present": any("local-qwen35" in m for m in system["ollama"].get("models", [])),
        },
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("studio.server:app", host="127.0.0.1", port=int(os.environ.get("STUDIO_PORT", "7865")), reload=False)
