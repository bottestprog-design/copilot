from __future__ import annotations

import asyncio
import atexit
import json
import os
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

# Keep test databases away from both the package directory and real user data.
_TEMP_DATA = tempfile.TemporaryDirectory(prefix="localai-studio-tests-")
os.environ["LOCALAI_STUDIO_DATA"] = _TEMP_DATA.name

from studio import server  # noqa: E402

atexit.register(_TEMP_DATA.cleanup)


class ServerPureLogicReview(unittest.TestCase):
    def test_loopback_url_allowlist_rejects_remote_and_credential_urls(self):
        self.assertEqual(server._local_url("http://127.0.0.1:8188/", "ComfyUI"), "http://127.0.0.1:8188")
        self.assertEqual(server._local_url("http://localhost:11434", "Ollama"), "http://localhost:11434")
        for url in (
            "https://example.com",
            "http://192.168.1.20:8188",
            "http://user:secret@127.0.0.1:8188",
            "http://127.0.0.1:8188/admin",
            "file:///etc/passwd",
        ):
            with self.subTest(url=url), self.assertRaises(Exception):
                server._local_url(url, "local service")

    def test_strict_json_rejects_nonstandard_nan_and_infinity(self):
        self.assertEqual(server.strict_json_loads('{"ok":true}'), {"ok": True})
        for payload in ('{"x":NaN}', '{"x":Infinity}', '{"x":-Infinity}'):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                server.strict_json_loads(payload)

    def test_workflow_validation_checks_shape_and_internal_links(self):
        valid = {
            "1": {"class_type": "CLIPTextEncode", "inputs": {"text": "hello", "clip": ["2", 0]}},
            "2": {"class_type": "CLIPLoader", "inputs": {}},
        }
        self.assertEqual(server.validate_api_workflow(valid), valid)
        with self.assertRaises(Exception):
            server.validate_api_workflow({"nodes": [], "links": []})
        broken = {"1": {"class_type": "KSampler", "inputs": {"model": ["404", 0]}}}
        with self.assertRaises(Exception):
            server.validate_api_workflow(broken)

    def test_binding_suggestions_and_native_defaults_are_resolved(self):
        graph = {
            "1": {"class_type": "CLIPTextEncode", "_meta": {"title": "Positive Prompt"}, "inputs": {"text": "old"}},
            "2": {"class_type": "KSampler", "inputs": {"seed": 10, "steps": 24, "cfg": 5}},
            "3": {"class_type": "EmptyLatentImage", "inputs": {"width": 1024, "height": 768, "batch_size": 1}},
        }
        bindings = server.suggest_bindings(graph)
        self.assertEqual(bindings["positive"], {"node_id": "1", "input": "text"})
        self.assertEqual(server.workflow_defaults(graph, bindings), {
            "steps": 24, "cfg": 5, "width": 1024, "height": 768, "batch_size": 1
        })
        server.apply_binding(graph, bindings, "positive", "new prompt")
        self.assertEqual(graph["1"]["inputs"]["text"], "new prompt")

    def test_binding_metadata_cannot_point_to_missing_inputs(self):
        graph = {"1": {"class_type": "CLIPTextEncode", "inputs": {"text": "hello"}}}
        with self.assertRaises(Exception):
            server.workflow_bindings(graph, {"bindings": "bad"})
        with self.assertRaises(Exception):
            server.workflow_bindings(graph, {"bindings": {"positive": {"node_id": "missing", "input": "text"}}})

    def test_explicitly_empty_bindings_are_not_auto_repopulated(self):
        graph = {
            "1": {"class_type": "CLIPTextEncode", "_meta": {"title": "Positive Prompt"}, "inputs": {"text": "hello"}},
            "2": {"class_type": "KSampler", "inputs": {"seed": 1}},
        }
        # A legacy config with no bindings key still receives safe suggestions.
        self.assertIn("positive", server.workflow_bindings(graph, {}))
        # An explicitly persisted empty mapping represents the user's intentional choice.
        self.assertEqual(server.workflow_bindings(graph, {"bindings": {}}), {})

    def test_enhanced_prompt_is_capped_to_the_generator_api_limit(self):
        content = json.dumps({
            "positive_prompt": "p" * 9000,
            "negative_prompt": "n" * 9000,
            "notes": "x" * 3000,
        })
        positive, negative, notes = server.normalize_enhanced_prompt(content)
        self.assertEqual(len(positive), 8000)
        self.assertEqual(len(negative), 8000)
        self.assertEqual(len(notes), 2000)
        with self.assertRaises(ValueError):
            server.normalize_enhanced_prompt('{"positive_prompt":" "}')

    def test_media_signature_and_filename_handling(self):
        self.assertEqual(server.detect_image_type(b"\x89PNG\r\n\x1a\nrest"), ("image/png", ".png"))
        self.assertEqual(server.detect_image_type(b"\xff\xd8\xffrest"), ("image/jpeg", ".jpg"))
        self.assertEqual(server.detect_image_type(b"RIFFxxxxWEBPrest"), ("image/webp", ".webp"))
        with self.assertRaises(Exception):
            server.detect_image_type(b"not an image")

    def test_generate_request_rejects_path_traversal_in_checkpoint(self):
        for candidate in ("../secret.safetensors", r"folder\secret.safetensors", "C:/secret.safetensors"):
            with self.subTest(candidate=candidate), self.assertRaises(Exception):
                server.GenerateRequest(workflow_id="sample", task="image", prompt="test", checkpoint=candidate)
        accepted = server.GenerateRequest(
            workflow_id="sample", task="image", prompt="test", checkpoint="checkpoints/model.safetensors"
        )
        self.assertEqual(accepted.checkpoint, "checkpoints/model.safetensors")

    def test_queue_helpers_only_select_tracked_pending_prompt_ids(self):
        queue = [[1, "owned"], [2, "other"]]
        tracked = [{"id": "local-1", "prompt_id": "owned"}]
        self.assertEqual(server.tracked_prompt_ids(queue, tracked), [("local-1", "owned")])
        self.assertEqual(server.queue_items({"queue_pending": None}, "queue_pending"), [])
        self.assertEqual(server.queue_items({"queue_pending": queue}, "queue_pending"), queue)

    def test_outputs_parser_ignores_malformed_history_and_flattens_all_media_kinds(self):
        self.assertEqual(server.decode_outputs_json("{broken"), [])
        self.assertEqual(server.decode_outputs_json("null"), [])
        outputs = server.flatten_outputs({
            "1": {"images": [{"filename": "one.png"}], "gifs": [{"filename": "two.gif"}]},
            "2": {"videos": [{"filename": "clip.mp4"}], "audio": [{"filename": "sound.wav"}]},
            "3": "malformed",
        })
        self.assertEqual({x["kind"] for x in outputs}, {"images", "gifs", "videos", "audio"})
        self.assertEqual(len(outputs), 4)
        self.assertTrue(all(x["url"].startswith("/api/media?") for x in outputs))

    def test_root_subfolder_is_normalized_and_unsafe_media_paths_are_filtered(self):
        outputs = server.flatten_outputs({
            "1": {"images": [
                {"filename": "root.png", "subfolder": "."},
                {"filename": "../outside.png"},
                {"filename": "nested/file.png"},
                {"filename": "ok.png", "subfolder": "../outside"},
            ]}
        })
        self.assertEqual(len(outputs), 1)
        self.assertEqual(outputs[0]["subfolder"], "")
        self.assertIn("subfolder=", outputs[0]["url"])

    def test_media_endpoint_rejects_traversal_before_contacting_comfyui(self):
        async def call_bad_path():
            with self.assertRaises(server.HTTPException) as ctx:
                await server.get_media(filename="../outside.png")
            return ctx.exception.status_code
        self.assertEqual(asyncio.run(call_bad_path()), 400)

    def test_settings_schema_errors_fall_back_and_saved_remote_urls_are_ignored(self):
        with tempfile.TemporaryDirectory(prefix="localai-settings-test-") as folder:
            path = Path(folder) / "settings.json"
            path.write_text('["not","a","settings","object"]', encoding="utf-8")
            with patch.object(server, "SETTINGS_PATH", path):
                self.assertEqual(server.read_settings(), server.DEFAULT_SETTINGS)
            path.write_text(json.dumps({
                "comfy_url": "http://192.168.1.10:8188",
                "ollama_url": "http://127.0.0.1:11434",
                "ollama_model": "local-qwen35:latest"
            }), encoding="utf-8")
            with patch.object(server, "SETTINGS_PATH", path):
                settings = server.read_settings()
            self.assertEqual(settings["comfy_url"], server.DEFAULT_SETTINGS["comfy_url"])
            self.assertEqual(settings["ollama_url"], "http://127.0.0.1:11434")

    def test_database_initialization_is_confined_to_the_supplied_test_data_root(self):
        with tempfile.TemporaryDirectory(prefix="localai-db-review-") as folder:
            data = Path(folder)
            workflows = data / "workflows"
            configs = data / "configs"
            workflows.mkdir()
            configs.mkdir()
            with patch.object(server, "DATA_DIR", data), \
                 patch.object(server, "DB_PATH", data / "studio.sqlite3"), \
                 patch.object(server, "WORKFLOW_DIR", workflows), \
                 patch.object(server, "CONFIG_DIR", configs):
                server.init_db()
                # sqlite3.Connection.__exit__ commits/rolls back but does not close
                # the native file handle. Explicitly close it before TemporaryDirectory
                # cleanup because Windows does not allow unlinking an open SQLite DB.
                connection = sqlite3.connect(data / "studio.sqlite3")
                try:
                    row = connection.execute("PRAGMA user_version").fetchone()
                    jobs = connection.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='jobs'").fetchone()
                finally:
                    connection.close()
                self.assertEqual(row[0], server.DATABASE_SCHEMA_VERSION)
                self.assertIsNotNone(jobs)
                self.assertGreaterEqual(len(list(workflows.glob("*.json"))), 6)
                self.assertGreaterEqual(len(list(configs.glob("*.json"))), 6)


class RequestBodyLimitReview(unittest.TestCase):
    def test_streamed_body_limit_returns_413_before_downstream_finishes(self):
        async def run_case():
            messages = iter([
                {"type": "http.request", "body": b"1234", "more_body": True},
                {"type": "http.request", "body": b"5678", "more_body": False},
            ])
            sent = []

            async def receive():
                return next(messages)

            async def send(message):
                sent.append(message)

            async def downstream(scope, receive, send):
                while True:
                    chunk = await receive()
                    if not chunk.get("more_body", False):
                        break
                await send({"type": "http.response.start", "status": 200, "headers": []})

            middleware = server.RequestBodyLimitMiddleware(downstream, max_body_bytes=6)
            scope = {"type": "http", "method": "POST", "path": "/upload", "headers": []}
            await middleware(scope, receive, send)
            return sent

        messages = asyncio.run(run_case())
        start = next(m for m in messages if m["type"] == "http.response.start")
        self.assertEqual(start["status"], 413)
