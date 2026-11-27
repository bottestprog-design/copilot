import atexit
import asyncio
import json
import os
import tempfile
import unittest
from unittest.mock import AsyncMock, patch
from pathlib import Path

# Isolate the tests from real user data and from the bundled workflow files.
_TEMP_DATA = tempfile.TemporaryDirectory(prefix="localai-studio-tests-")
os.environ["LOCALAI_STUDIO_DATA"] = _TEMP_DATA.name

from fastapi.testclient import TestClient
from studio import server

# Keep isolated data alive until every test class has completed.
atexit.register(_TEMP_DATA.cleanup)


class RequestBodyLimitMiddlewareTests(unittest.TestCase):
    def test_chunked_request_without_content_length_is_still_limited(self):
        async def run_test():
            messages = iter([
                {"type": "http.request", "body": b"1234", "more_body": True},
                {"type": "http.request", "body": b"5678", "more_body": False},
            ])
            sent = []

            async def fake_receive():
                return next(messages)

            async def fake_send(message):
                sent.append(message)

            async def downstream(scope, receive, send):
                while True:
                    message = await receive()
                    if not message.get("more_body", False):
                        break
                await send({"type": "http.response.start", "status": 200, "headers": []})
                await send({"type": "http.response.body", "body": b"ok"})

            middleware = server.RequestBodyLimitMiddleware(downstream, max_body_bytes=6)
            scope = {"type": "http", "method": "POST", "path": "/upload", "headers": []}
            await middleware(scope, fake_receive, fake_send)
            return sent

        sent = asyncio.run(run_test())
        starts = [message for message in sent if message["type"] == "http.response.start"]
        self.assertEqual(len(starts), 1)
        self.assertEqual(starts[0]["status"], 413)


class WorkflowUnitTests(unittest.TestCase):
    def test_safe_identifier(self):
        self.assertEqual(server.safe_id("wan 2.2 / t2v"), "wan-2-2-t2v")
        with self.assertRaises(Exception):
            server.safe_id("../../")

    def test_validate_api_workflow_accepts_api_graph(self):
        workflow = {
            "1": {"class_type": "CLIPTextEncode", "inputs": {"text": "test", "clip": ["2", 0]}},
            "2": {"class_type": "CLIPLoader", "inputs": {}},
        }
        self.assertEqual(server.validate_api_workflow(workflow), workflow)

    def test_validate_api_workflow_rejects_broken_node_references(self):
        workflow = {"1": {"class_type": "CLIPTextEncode", "inputs": {"clip": ["missing-node", 0]}}}
        with self.assertRaises(Exception) as ctx:
            server.validate_api_workflow(workflow)
        self.assertIn("missing node", str(ctx.exception).lower())

    def test_validate_api_workflow_rejects_invalid_output_slot(self):
        workflow = {
            "1": {"class_type": "CLIPTextEncode", "inputs": {"clip": ["2", -1]}},
            "2": {"class_type": "CLIPLoader", "inputs": {}},
        }
        with self.assertRaises(Exception):
            server.validate_api_workflow(workflow)

    def test_workflow_bindings_reject_malformed_or_stale_config(self):
        workflow = {"1": {"class_type": "CLIPTextEncode", "inputs": {"text": "hello"}}}
        with self.assertRaises(Exception):
            server.workflow_bindings(workflow, {"bindings": "not-an-object"})
        with self.assertRaises(Exception):
            server.workflow_bindings(workflow, {"bindings": {"positive": {"node_id": "missing", "input": "text"}}})

    def test_decode_outputs_json_is_resilient_to_corrupt_history(self):
        self.assertEqual(server.decode_outputs_json("{broken"), [])
        self.assertEqual(server.decode_outputs_json("null"), [])
        self.assertEqual(server.decode_outputs_json('[{"kind":"images"}, 3, null]'), [{"kind": "images"}])

    def test_queue_items_normalizes_null_and_wrong_type_collections(self):
        self.assertEqual(server.queue_items(None, "queue_pending"), [])
        self.assertEqual(server.queue_items({"queue_pending": None}, "queue_pending"), [])
        self.assertEqual(server.queue_items({"queue_pending": "bad"}, "queue_pending"), [])
        self.assertEqual(server.queue_items({"queue_pending": [[1, "prompt"]]}, "queue_pending"), [[1, "prompt"]])

    def test_validate_api_workflow_rejects_canvas_format(self):
        with self.assertRaises(Exception) as ctx:
            server.validate_api_workflow({"nodes": [], "links": []})
        self.assertIn("API format", str(ctx.exception))

    def test_suggest_bindings_maps_common_image_nodes(self):
        workflow = {
            "1": {"class_type": "CLIPTextEncode", "_meta": {"title": "Positive Prompt"}, "inputs": {"text": "x"}},
            "2": {"class_type": "CLIPTextEncode", "_meta": {"title": "Negative Prompt"}, "inputs": {"text": "y"}},
            "3": {"class_type": "KSampler", "inputs": {"seed": 1, "steps": 20, "cfg": 7, "latent_image": ["4", 0]}},
            "4": {"class_type": "EmptyLatentImage", "inputs": {"width": 1024, "height": 1024, "batch_size": 1}},
            "5": {"class_type": "SaveImage", "inputs": {"filename_prefix": "test"}},
        }
        bindings = server.suggest_bindings(workflow)
        self.assertEqual(bindings["positive"], {"node_id": "1", "input": "text"})
        self.assertEqual(bindings["negative"], {"node_id": "2", "input": "text"})
        self.assertIn("batch_size", bindings)
        self.assertIn("seed", bindings)

    def test_apply_binding_updates_expected_input(self):
        workflow = {"1": {"class_type": "CLIPTextEncode", "inputs": {"text": "old"}}}
        server.apply_binding(workflow, {"positive": {"node_id": "1", "input": "text"}}, "positive", "new")
        self.assertEqual(workflow["1"]["inputs"]["text"], "new")

    def test_bundled_api_graphs_have_resolved_links(self):
        for workflow_path in (
            server.PACKAGE_ROOT / "data/workflows/wan22-ti2v-5b-text-to-video-api.json",
            server.PACKAGE_ROOT / "data/workflows/wan22-ti2v-5b-image-to-video-api.json",
            server.PACKAGE_ROOT / "data/workflows/flux2-klein-4b-text-to-image-api.json",
            server.PACKAGE_ROOT / "data/workflows/qwen-image-2512-text-to-image-api.json",
            server.PACKAGE_ROOT / "data/workflows/qwen-image-21-text-to-image-api.json",
        ):
            with self.subTest(workflow=workflow_path.name):
                graph = json.loads(workflow_path.read_text(encoding="utf-8"))
                node_ids = set(graph)
                for node_id, node in graph.items():
                    for input_name, value in node.get("inputs", {}).items():
                        if isinstance(value, list) and len(value) == 2 and isinstance(value[0], str):
                            self.assertIn(value[0], node_ids, f"{workflow_path.name}: {node_id}.{input_name}")

    def test_flux2_workflow_has_prompt_and_native_defaults_mapped(self):
        wf_id = "flux2-klein-4b-text-to-image-api"
        graph = json.loads((server.PACKAGE_ROOT / f"data/workflows/{wf_id}.json").read_text(encoding="utf-8"))
        config = json.loads((server.PACKAGE_ROOT / f"data/configs/{wf_id}.json").read_text(encoding="utf-8"))
        bindings = config["bindings"]
        self.assertEqual(bindings["positive"], {"node_id": "76", "input": "value"})
        self.assertEqual(server.workflow_defaults(graph, bindings), {"steps": 20, "cfg": 5, "width": 1344, "height": 768, "batch_size": 1})
        server.apply_binding(graph, bindings, "positive", "new Flux prompt")
        self.assertEqual(graph["76"]["inputs"]["value"], "new Flux prompt")

    def test_qwen_image_21_workflow_maps_prompt_and_quantized_models(self):
        wf_id = "qwen-image-21-text-to-image-api"
        graph = json.loads((server.PACKAGE_ROOT / f"data/workflows/{wf_id}.json").read_text(encoding="utf-8"))
        config = json.loads((server.PACKAGE_ROOT / f"data/configs/{wf_id}.json").read_text(encoding="utf-8"))
        bindings = config["bindings"]
        self.assertEqual(bindings["positive"], {"node_id": "459:452", "input": "prompt"})
        self.assertEqual(server.workflow_defaults(graph, bindings), {"steps": 25, "cfg": 1, "width": 1024, "height": 1024, "batch_size": 1})
        self.assertEqual(graph["459:451"]["inputs"]["unet_name"], "qwen_image_2.1_int8_convrot.safetensors")
        self.assertEqual(graph["459:453"]["inputs"]["clip_name"], "qwen3vl_8b_int8_convrot.safetensors")
        server.apply_binding(graph, bindings, "positive", "new Qwen 2.1 prompt")
        self.assertEqual(graph["459:452"]["inputs"]["prompt"], "new Qwen 2.1 prompt")
        self.assertEqual(config["license"], "Qwen Research License (non-commercial only)")

    def test_qwen_image_2512_workflow_maps_positive_and_quality_settings(self):
        wf_id = "qwen-image-2512-text-to-image-api"
        graph = json.loads((server.PACKAGE_ROOT / f"data/workflows/{wf_id}.json").read_text(encoding="utf-8"))
        config = json.loads((server.PACKAGE_ROOT / f"data/configs/{wf_id}.json").read_text(encoding="utf-8"))
        bindings = config["bindings"]
        self.assertEqual(bindings["positive"], {"node_id": "238:227", "input": "text"})
        self.assertEqual(server.workflow_defaults(graph, bindings), {"steps": 50, "cfg": 4, "width": 1328, "height": 1328, "batch_size": 1})
        server.apply_binding(graph, bindings, "positive", "new Qwen prompt")
        self.assertEqual(graph["238:227"]["inputs"]["text"], "new Qwen prompt")

    def test_official_image_workflows_have_model_metadata_and_sources(self):
        for wf_id in ("flux2-klein-4b-text-to-image-api", "qwen-image-2512-text-to-image-api"):
            cfg = json.loads((server.PACKAGE_ROOT / f"data/configs/{wf_id}.json").read_text(encoding="utf-8"))
            self.assertEqual(cfg["task"], "image")
            self.assertTrue(cfg["model_id"])
            self.assertEqual(cfg["license"], "Apache 2.0")
            self.assertTrue(cfg["source_url"].startswith("https://comfy.org/"))
            self.assertGreaterEqual(len(cfg["requirements"]), 3)

    def test_checkpoint_binding_rejects_path_traversal(self):
        for checkpoint in ("../secret.safetensors", "folder/../../secret.safetensors", r"folder\secret.safetensors", "C:/secret.safetensors"):
            with self.subTest(checkpoint=checkpoint), self.assertRaises(Exception):
                server.GenerateRequest(workflow_id="x", task="image", prompt="test", checkpoint=checkpoint)
        accepted = server.GenerateRequest(workflow_id="x", task="image", prompt="test", checkpoint="checkpoints/model.safetensors")
        self.assertEqual(accepted.checkpoint, "checkpoints/model.safetensors")

    def test_flatten_outputs_ignores_malformed_non_object_payloads(self):
        for malformed in (None, [], "invalid", 3):
            with self.subTest(payload=malformed):
                self.assertEqual(server.flatten_outputs(malformed), [])

    def test_flatten_outputs_ignores_malformed_status_messages(self):
        # The endpoint's status parser must treat non-list messages as empty, not
        # iterate individual characters and crash or misclassify the task.
        messages = "not a list"
        self.assertFalse(any("execution_error" in str(message).lower() for message in (messages if isinstance(messages, list) else [])))

    def test_flatten_outputs_supports_images_videos_gifs_and_audio(self):
        flattened = server.flatten_outputs({
            "1": {"images": [{"filename": "still.png"}], "gifs": [{"filename": "motion.gif"}]},
            "2": {"videos": [{"filename": "clip.mp4", "subfolder": "ComfyUI", "type": "output"}], "audio": [{"filename": "voice.wav"}]},
        })
        self.assertEqual({item["kind"] for item in flattened}, {"images", "gifs", "videos", "audio"})
        self.assertTrue(any(item["filename"] == "voice.wav" for item in flattened))

    def test_prompt_enhance_rejects_unknown_task(self):
        with self.assertRaises(Exception):
            server.PromptEnhanceRequest(prompt="A cinematic scene", task="audio")

    def test_workflow_defaults_are_detected_and_preserved(self):
        workflow = {
            "1": {"class_type": "KSampler", "inputs": {"steps": 8, "cfg": 1.0}},
            "2": {"class_type": "EmptyLatentImage", "inputs": {"width": 1024, "height": 768, "batch_size": 1}},
            "3": {"class_type": "Wan22ImageToVideoLatent", "inputs": {"length": 41}},
        }
        bindings = {
            "steps": {"node_id": "1", "input": "steps"},
            "cfg": {"node_id": "1", "input": "cfg"},
            "width": {"node_id": "2", "input": "width"},
            "height": {"node_id": "2", "input": "height"},
            "batch_size": {"node_id": "2", "input": "batch_size"},
            "frames": {"node_id": "3", "input": "length"},
        }
        self.assertEqual(server.workflow_defaults(workflow, bindings), {
            "steps": 8, "cfg": 1.0, "width": 1024, "height": 768,
            "frames": 41, "batch_size": 1,
        })
        # Null request fields deliberately mean "keep the graph's native value".
        server.apply_binding(workflow, bindings, "steps", None)
        server.apply_binding(workflow, bindings, "cfg", None)
        self.assertEqual(workflow["1"]["inputs"], {"steps": 8, "cfg": 1.0})

    def test_settings_file_with_json_array_falls_back_to_defaults(self):
        with tempfile.TemporaryDirectory(prefix="localai-settings-test-") as temp_dir:
            settings_path = Path(temp_dir) / "settings.json"
            settings_path.write_text('["not", "a", "settings", "object"]', encoding="utf-8")
            with patch.object(server, "SETTINGS_PATH", settings_path):
                self.assertEqual(server.read_settings(), server.DEFAULT_SETTINGS)

    def test_settings_file_with_json_scalar_falls_back_to_defaults(self):
        with tempfile.TemporaryDirectory(prefix="localai-settings-test-") as temp_dir:
            settings_path = Path(temp_dir) / "settings.json"
            settings_path.write_text('null', encoding="utf-8")
            with patch.object(server, "SETTINGS_PATH", settings_path):
                self.assertEqual(server.read_settings(), server.DEFAULT_SETTINGS)

    def test_external_services_are_rejected(self):
        with self.assertRaises(Exception):
            server._local_url("https://example.com", "service")
        with self.assertRaises(Exception):
            server._local_url("http://192.168.1.20:8188", "service")

    def test_loopback_url_rejects_userinfo_and_paths(self):
        for url in (
            "http://user:pass@127.0.0.1:8188",
            "http://127.0.0.1:8188/api",
            "http://127.0.0.1:99999",
            "http://localhost:8188/?next=evil",
        ):
            with self.subTest(url=url), self.assertRaises(Exception):
                server._local_url(url, "service")

    def test_image_magic_detection(self):
        self.assertEqual(server.detect_image_type(b"\x89PNG\r\n\x1a\nrest"), ("image/png", ".png"))
        self.assertEqual(server.detect_image_type(b"\xff\xd8\xffrest"), ("image/jpeg", ".jpg"))
        self.assertEqual(server.detect_image_type(b"RIFF1234WEBPrest"), ("image/webp", ".webp"))
        with self.assertRaises(Exception):
            server.detect_image_type(b"<html>not an image</html>")

    def test_only_studio_pending_prompts_are_selected_for_queue_clear(self):
        queue_items = [[1, "studio-prompt"], [2, "another-user-prompt"]]
        tracked = [
            {"id": "local-1", "prompt_id": "studio-prompt"},
            {"id": "local-2", "prompt_id": "already-finished"},
        ]
        self.assertEqual(server.tracked_prompt_ids(queue_items, tracked), [("local-1", "studio-prompt")])



    def test_app_storage_guard_rejects_symlinked_directories_and_files(self):
        with tempfile.TemporaryDirectory(prefix="localai-path-guard-") as folder:
            root = Path(folder)
            real = root / "real"
            real.mkdir()
            redirected = root / "redirected"
            redirected.symlink_to(real, target_is_directory=True)
            with self.assertRaises(RuntimeError):
                server.assert_plain_app_path(redirected, directory=True)
            external_file = root / "outside.json"
            external_file.write_text("{}", encoding="utf-8")
            file_link = root / "settings.json"
            file_link.symlink_to(external_file)
            with self.assertRaises(RuntimeError):
                server.assert_plain_app_path(file_link, directory=False)

    def test_database_connection_refuses_a_symlinked_rollback_journal_sidecar(self):
        with tempfile.TemporaryDirectory(prefix="localai-db-journal-") as folder:
            root = Path(folder)
            outside = root / "outside-journal"
            outside.write_text("not-a-journal", encoding="utf-8")
            journal = root / "studio.sqlite3-journal"
            try:
                journal.symlink_to(outside)
            except OSError:
                self.skipTest("The test filesystem does not support symbolic links.")
            with patch.object(server, "DB_PATH", root / "studio.sqlite3"):
                with self.assertRaises(RuntimeError):
                    with server.get_db():
                        pass

    def test_database_connection_refuses_a_symlinked_database_file(self):
        with tempfile.TemporaryDirectory(prefix="localai-db-guard-") as folder:
            root = Path(folder)
            target = root / "external.sqlite3"
            target.write_bytes(b"")
            link = root / "studio.sqlite3"
            link.symlink_to(target)
            with patch.object(server, "DB_PATH", link):
                with self.assertRaises(RuntimeError):
                    with server.get_db():
                        pass

    def test_database_connections_use_busy_timeout_and_foreign_keys(self):
        with server.get_db() as conn:
            self.assertEqual(conn.execute("PRAGMA busy_timeout").fetchone()[0], 10000)
            self.assertEqual(conn.execute("PRAGMA foreign_keys").fetchone()[0], 1)

    def test_database_migration_sets_a_schema_version_without_dropping_history(self):
        with tempfile.TemporaryDirectory(prefix="localai-schema-test-") as folder:
            path = Path(folder) / "studio.sqlite3"
            connection = __import__("sqlite3").connect(path)
            connection.execute("CREATE TABLE jobs (id TEXT PRIMARY KEY, prompt_id TEXT NOT NULL, task TEXT NOT NULL, workflow_id TEXT NOT NULL, prompt TEXT NOT NULL, status TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL, outputs_json TEXT NOT NULL DEFAULT '[]', error TEXT)")
            connection.execute("INSERT INTO jobs (id,prompt_id,task,workflow_id,prompt,status,created_at,updated_at) VALUES ('keep','p','image','w','prompt','completed',1,1)")
            connection.commit()
            connection.close()
            with patch.object(server, "DB_PATH", path):
                server.init_db()
                with server.get_db() as conn:
                    self.assertEqual(conn.execute("PRAGMA user_version").fetchone()[0], server.DATABASE_SCHEMA_VERSION)
                    self.assertEqual(conn.execute("SELECT id FROM jobs WHERE id='keep'").fetchone()[0], "keep")

    def test_database_refuses_a_schema_from_a_newer_release(self):
        with tempfile.TemporaryDirectory(prefix="localai-future-schema-") as folder:
            path = Path(folder) / "studio.sqlite3"
            connection = __import__("sqlite3").connect(path)
            connection.execute("PRAGMA user_version=999")
            connection.close()
            with patch.object(server, "DB_PATH", path), self.assertRaises(RuntimeError):
                server.init_db()

    def test_workflow_reads_refuse_a_symlinked_workflow_directory(self):
        with tempfile.TemporaryDirectory(prefix="localai-workflow-guard-") as folder:
            root = Path(folder)
            real = root / "real-workflows"
            real.mkdir()
            (real / "sample.json").write_text("{}", encoding="utf-8")
            redirected = root / "workflows"
            redirected.symlink_to(real, target_is_directory=True)
            with patch.object(server, "WORKFLOW_DIR", redirected):
                with self.assertRaises(RuntimeError):
                    server.read_workflow("sample")

    def test_settings_reader_refuses_a_symlinked_settings_file(self):
        with tempfile.TemporaryDirectory(prefix="localai-settings-guard-") as folder:
            root = Path(folder)
            target = root / "outside.json"
            target.write_text("{}", encoding="utf-8")
            link = root / "settings.json"
            link.symlink_to(target)
            with patch.object(server, "SETTINGS_PATH", link):
                with self.assertRaises(RuntimeError):
                    server.read_settings()


class ApiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.client = TestClient(server.app)
        cls.client.__enter__()

    @classmethod
    def tearDownClass(cls):
        cls.client.__exit__(None, None, None)

    def test_workflow_config_edit_preserves_provenance_and_future_metadata(self):
        wf_id = "flux2-klein-4b-text-to-image-api"
        config_path = server.CONFIG_DIR / f"{wf_id}.json"
        original = json.loads(config_path.read_text(encoding="utf-8"))
        original["upstream_revision"] = "test-revision-123"
        config_path.write_text(json.dumps(original, ensure_ascii=False), encoding="utf-8")
        detail = self.client.get(f"/api/workflows/{wf_id}")
        self.assertEqual(detail.status_code, 200, detail.text)
        updated = self.client.put(
            f"/api/workflows/{wf_id}/config",
            json={"name": detail.json()["name"], "task": "image", "bindings": detail.json()["bindings"]},
        )
        self.assertEqual(updated.status_code, 200, updated.text)
        saved = updated.json()
        self.assertEqual(saved["license"], original["license"])
        self.assertEqual(saved["source_url"], original["source_url"])
        self.assertEqual(saved["requirements"], original["requirements"])
        self.assertEqual(saved["upstream_revision"], "test-revision-123")

    def test_ready_probe_is_fast_and_does_not_depend_on_comfyui_or_ollama(self):
        response = self.client.get("/api/ready")
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json()["ok"])
        self.assertEqual(response.json()["app"], "LocalAI Creative Studio")

    def test_health_reports_current_version_without_dependency_on_running_engines(self):
        mock_check = AsyncMock(return_value={"ok": False, "error": "engine not running"})
        with patch.object(server, "check_service", new=mock_check):
            response = self.client.get("/api/health")
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["version"], server.APP_VERSION)
        self.assertFalse(response.json()["comfyui"]["ok"])
        self.assertFalse(response.json()["ollama"]["ok"])
        self.assertEqual(mock_check.await_count, 2)

    def test_home_serves_arabic_workspace(self):
        response = self.client.get("/")
        self.assertEqual(response.status_code, 200)
        self.assertIn("الاستوديو الإبداعي", response.text)

    def test_home_injects_release_version_from_single_source(self):
        response = self.client.get("/")
        self.assertEqual(response.status_code, 200)
        self.assertIn(f"v{server.APP_VERSION}", response.text)
        self.assertNotIn("__APP_VERSION__", response.text)

    def test_system_endpoint_handles_malformed_ollama_model_list(self):
        async def fake_check(base, endpoint, timeout=3.5):
            if endpoint == "/api/tags":
                return {"ok": True, "data": {"models": None}}
            if endpoint == "/api/version":
                return {"ok": True, "data": {"version": "test"}}
            return {"ok": True, "data": {}}
        with patch.object(server, "check_service", new=AsyncMock(side_effect=fake_check)):
            response = self.client.get("/api/system")
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["ollama"]["models"], [])

    def test_static_assets_are_served_locally(self):
        css = self.client.get("/static/app.css")
        js = self.client.get("/static/app.js")
        self.assertEqual(css.status_code, 200)
        self.assertIn(".sidebar", css.text)
        self.assertEqual(js.status_code, 200)
        self.assertIn("function boot()", js.text)

    def test_desktop_manifest_uses_standalone_window_display(self):
        response = self.client.get("/static/manifest.webmanifest")
        self.assertEqual(response.status_code, 200)
        manifest = response.json()
        self.assertEqual(manifest["display"], "standalone")
        self.assertEqual(manifest["name"], "LocalAI Creative Studio")
        self.assertTrue(any(icon["sizes"] == "512x512" for icon in manifest["icons"]))

    def test_desktop_application_icon_is_served(self):
        response = self.client.get("/static/icons/localai-creative-studio-512.png")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers.get("content-type", "").split(";")[0], "image/png")
        self.assertTrue(response.content.startswith(b"\x89PNG\r\n\x1a\n"))

    def test_system_endpoint_survives_unavailable_data_drive(self):
        with patch.object(server.psutil, "disk_usage", side_effect=OSError("drive not mounted")):
            response = self.client.get("/api/system")
        self.assertEqual(response.status_code, 200, response.text)
        self.assertIsNone(response.json()["hardware"]["disk_free_gb"])
        self.assertTrue(any("drive" in warning.lower() for warning in response.json()["hardware"]["warnings"]))

    def test_catalog_has_image_and_video_models(self):
        response = self.client.get("/api/catalog")
        self.assertEqual(response.status_code, 200)
        kinds = {item["kind"] for item in response.json()["models"]}
        self.assertEqual(kinds, {"image", "video"})

    def test_bundled_official_image_workflows_are_seeded_and_listed(self):
        response = self.client.get("/api/workflows")
        self.assertEqual(response.status_code, 200, response.text)
        workflows = {item["id"]: item for item in response.json()["workflows"]}
        for wf_id, model in (("flux2-klein-4b-text-to-image-api", "FLUX.2 Klein 4B"), ("qwen-image-2512-text-to-image-api", "Qwen-Image-2512 20B"), ("qwen-image-21-text-to-image-api", "Qwen-Image 2.1 · 7B")):
            self.assertIn(wf_id, workflows)
            self.assertEqual(workflows[wf_id]["model_name"], model)
            self.assertTrue(workflows[wf_id]["requirements"])

    def test_catalog_discloses_model_licenses_and_ltx_requirements(self):
        response = self.client.get("/api/catalog")
        self.assertEqual(response.status_code, 200)
        models = {item["id"]: item for item in response.json()["models"]}
        self.assertEqual(models["flux2-klein-4b"]["license"], "Apache 2.0")
        self.assertEqual(models["z-image-turbo"]["license"], "Apache 2.0")
        self.assertIn("32GB VRAM", models["ltx25"]["hardware"])
        self.assertIn("Community License", models["hunyuan-video-15"]["license"])

    def test_seed_workflow_is_present(self):
        response = self.client.get("/api/workflows")
        self.assertEqual(response.status_code, 200)
        self.assertIn("sdxl-standard-api", {item["id"] for item in response.json()["workflows"]})

    def test_wan_text_to_video_and_image_to_video_workflows_are_seeded(self):
        response = self.client.get("/api/workflows")
        self.assertEqual(response.status_code, 200)
        workflows = {item["id"]: item for item in response.json()["workflows"]}
        t2v_id = "wan22-ti2v-5b-text-to-video-api"
        i2v_id = "wan22-ti2v-5b-image-to-video-api"
        self.assertIn(t2v_id, workflows)
        self.assertIn(i2v_id, workflows)
        self.assertEqual(workflows[t2v_id]["task"], "video")
        self.assertEqual(workflows[t2v_id]["defaults"]["frames"], 41)
        t2v_detail = self.client.get(f"/api/workflows/{t2v_id}")
        self.assertEqual(t2v_detail.status_code, 200, t2v_detail.text)
        t2v_graph = json.loads((server.WORKFLOW_DIR / f"{t2v_id}.json").read_text(encoding="utf-8"))
        self.assertEqual(t2v_graph["57"]["class_type"], "CreateVideo")
        self.assertEqual(t2v_graph["58"]["class_type"], "SaveVideo")
        self.assertEqual(t2v_graph["3"]["inputs"]["steps"], 20)
        detail = self.client.get(f"/api/workflows/{i2v_id}")
        self.assertEqual(detail.status_code, 200, detail.text)
        self.assertEqual(detail.json()["bindings"]["init_image"], {"node_id": "56", "input": "image"})
        i2v_graph = json.loads((server.WORKFLOW_DIR / f"{i2v_id}.json").read_text(encoding="utf-8"))
        self.assertEqual(i2v_graph["55"]["inputs"]["start_image"], ["56", 0])

    def test_import_api_workflow_and_detect_bindings(self):
        payload = {
            "1": {"class_type": "CLIPTextEncode", "_meta": {"title": "Positive Prompt"}, "inputs": {"text": "starter"}},
            "2": {"class_type": "SaveImage", "inputs": {"filename_prefix": "test"}},
        }
        response = self.client.post(
            "/api/workflows/import",
            files={"file": ("test-image.json", json.dumps(payload), "application/json")},
            data={"task": "image", "name": "Test workflow"},
        )
        self.assertEqual(response.status_code, 200, response.text)
        data = response.json()
        self.assertEqual(data["name"], "Test workflow")
        self.assertEqual(data["bindings"]["positive"], {"node_id": "1", "input": "text"})

    def test_workflow_import_rejects_canvas_json(self):
        response = self.client.post(
            "/api/workflows/import",
            files={"file": ("canvas.json", json.dumps({"nodes": [], "links": []}), "application/json")},
            data={"task": "video"},
        )
        self.assertEqual(response.status_code, 400)

    def test_settings_reject_non_loopback_url(self):
        response = self.client.put(
            "/api/settings",
            json={"comfy_url": "http://example.com", "ollama_url": "http://127.0.0.1:11434", "ollama_model": "local-qwen35:latest"},
        )
        self.assertIn(response.status_code, (400, 422))

    def test_settings_memory_is_not_changed_when_atomic_persistence_fails(self):
        before = dict(server.SETTINGS)
        with patch.object(server, "atomic_write_json", side_effect=OSError("disk unavailable")):
            response = self.client.put("/api/settings", json={
                "comfy_url": "http://127.0.0.1:8188",
                "ollama_url": "http://127.0.0.1:11434",
                "ollama_model": "replacement-model:latest",
            })
        self.assertEqual(response.status_code, 500)
        self.assertEqual(server.SETTINGS, before)

    def test_job_history_survives_non_object_outputs_and_messages(self):
        now = server.time.time()
        with server.get_db() as conn:
            conn.execute(
                "INSERT OR REPLACE INTO jobs (id,prompt_id,task,workflow_id,prompt,status,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?)",
                ("malformed-history", "prompt-malformed-history", "image", "test", "prompt", "queued", now, now),
            )

        class FakeResponse:
            is_success = True
            def __init__(self, payload):
                self.payload = payload
            def raise_for_status(self):
                return None
            def json(self):
                return self.payload

        class FakeClient:
            async def __aenter__(self):
                return self
            async def __aexit__(self, *args):
                return None
            async def get(self, url, **kwargs):
                if "/history/" in url:
                    return FakeResponse({"prompt-malformed-history": {"outputs": None, "status": {"status_str": "error", "messages": "malformed"}}})
                return FakeResponse({"queue_running": None, "queue_pending": "bad"})

        with patch.object(server, "client", return_value=FakeClient()):
            response = self.client.get("/api/jobs/malformed-history")
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["status"], "failed")
        self.assertEqual(response.json()["outputs"], [])

    def test_job_listing_survives_a_corrupt_outputs_json_field(self):
        now = server.time.time()
        with server.get_db() as conn:
            conn.execute(
                "INSERT OR REPLACE INTO jobs (id,prompt_id,task,workflow_id,prompt,status,created_at,updated_at,outputs_json) VALUES (?,?,?,?,?,?,?,?,?)",
                ("corrupt-outputs", "external-id", "image", "test", "prompt", "completed", now, now, "not-json"),
            )
        response = self.client.get("/api/jobs")
        self.assertEqual(response.status_code, 200, response.text)
        job = next(item for item in response.json()["jobs"] if item["id"] == "corrupt-outputs")
        self.assertEqual(job["outputs"], [])

    def test_delete_workflow_refuses_symlinked_config_before_deleting_graph(self):
        workflow_id = "symlink-config-delete"
        graph_path = server.WORKFLOW_DIR / f"{workflow_id}.json"
        config_path = server.CONFIG_DIR / f"{workflow_id}.json"
        outside = server.DATA_DIR / "outside-config.json"
        graph_path.write_text(json.dumps({"1": {"class_type": "SaveImage", "inputs": {}}}), encoding="utf-8")
        outside.write_text("{}", encoding="utf-8")
        try:
            config_path.symlink_to(outside)
        except OSError:
            graph_path.unlink(missing_ok=True)
            outside.unlink(missing_ok=True)
            self.skipTest("The test filesystem does not support symbolic links.")
        response = self.client.delete(f"/api/workflows/{workflow_id}")
        self.assertEqual(response.status_code, 400, response.text)
        self.assertTrue(graph_path.is_file())
        graph_path.unlink(missing_ok=True)
        config_path.unlink(missing_ok=True)
        outside.unlink(missing_ok=True)


    def test_strict_json_rejects_nonstandard_nan_and_infinity(self):
        for raw in ('NaN', 'Infinity', '-Infinity'):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                server.strict_json_loads(raw)

    def test_database_connection_refuses_symlinked_wal_or_shm_sidecar(self):
        with tempfile.TemporaryDirectory(prefix="localai-db-sidecar-") as folder:
            root = Path(folder)
            outside = root / "outside-wal"
            outside.write_bytes(b"not-a-database-sidecar")
            wal = root / "studio.sqlite3-wal"
            try:
                wal.symlink_to(outside)
            except OSError:
                self.skipTest("The test filesystem does not support symbolic links.")
            with patch.object(server, "DB_PATH", root / "studio.sqlite3"):
                with self.assertRaises(RuntimeError):
                    with server.get_db():
                        pass

    def test_get_job_returns_local_submitting_reservation_without_polling_comfy(self):
        now = server.time.time()
        with server.get_db() as conn:
            conn.execute(
                "INSERT OR REPLACE INTO jobs (id,prompt_id,task,workflow_id,prompt,status,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?)",
                ("submitting-reservation", "submitting:submitting-reservation", "image", "test", "prompt", "submitting", now, now),
            )
        with patch.object(server, "client", side_effect=AssertionError("ComfyUI should not be polled for a local reservation")):
            response = self.client.get("/api/jobs/submitting-reservation")
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["status"], "submitting")

    def test_get_job_returns_local_failed_record_without_polling_comfy(self):
        now = server.time.time()
        with server.get_db() as conn:
            conn.execute(
                "INSERT OR REPLACE INTO jobs (id,prompt_id,task,workflow_id,prompt,status,created_at,updated_at,error) VALUES (?,?,?,?,?,?,?,?,?)",
                ("failed-reservation", "submitting:failed-reservation", "image", "test", "prompt", "failed", now, now, "ComfyUI unavailable"),
            )
        with patch.object(server, "client", side_effect=AssertionError("ComfyUI should not be polled for a locally failed record")):
            response = self.client.get("/api/jobs/failed-reservation")
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["status"], "failed")
        self.assertEqual(response.json()["error"], "ComfyUI unavailable")

    def test_import_does_not_overwrite_an_orphaned_config_with_the_same_stem(self):
        workflow_id = "orphaned-import"
        config_path = server.CONFIG_DIR / f"{workflow_id}.json"
        config_path.write_text(json.dumps({"name": "Do not overwrite", "task": "video", "bindings": {}}), encoding="utf-8")
        response = self.client.post(
            "/api/workflows/import",
            data={"task": "image", "name": "New workflow"},
            files={"file": (f"{workflow_id}.json", json.dumps({"1": {"class_type": "SaveImage", "inputs": {}}}), "application/json")},
        )
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()["id"], f"{workflow_id}-2")
        self.assertEqual(json.loads(config_path.read_text(encoding="utf-8"))["name"], "Do not overwrite")

    def test_diagnostic_survives_redirected_workflow_directory(self):
        with tempfile.TemporaryDirectory(prefix="localai-diagnostic-") as folder:
            outside = Path(folder) / "outside"
            outside.mkdir()
            redirected = Path(folder) / "workflows"
            try:
                redirected.symlink_to(outside, target_is_directory=True)
            except OSError:
                self.skipTest("The test filesystem does not support symbolic links.")
            with patch.object(server, "WORKFLOW_DIR", redirected):
                response = self.client.get("/api/diagnostic")
        self.assertEqual(response.status_code, 200, response.text)
        self.assertIsNone(response.json()["workflow_count"])
        self.assertTrue(response.json()["storage_warnings"])


    def test_request_body_limit_rejects_declared_oversized_upload(self):
        from starlette.requests import Request

        async def receive():
            return {"type": "http.request", "body": b"{}", "more_body": False}

        scope = {
            "type": "http", "asgi": {"version": "3.0", "spec_version": "2.3"},
            "http_version": "1.1", "method": "POST", "scheme": "http",
            "path": "/api/settings", "raw_path": b"/api/settings",
            "query_string": b"", "headers": [(b"content-length", str(server.MAX_HTTP_REQUEST_BYTES + 1).encode())],
            "client": ("127.0.0.1", 1234), "server": ("127.0.0.1", 7865),
        }
        request = Request(scope, receive)
        middleware = server.same_origin_for_mutations
        async def call_next(_request):
            raise AssertionError("Oversized body must be rejected before the route executes")
        response = __import__("asyncio").run(middleware(request, call_next))
        self.assertEqual(response.status_code, 413)

    def test_invalid_media_path_is_rejected(self):
        response = self.client.get("/api/media", params={"filename": "../../secret.txt"})
        self.assertEqual(response.status_code, 400)

    def test_windows_style_media_path_is_rejected(self):
        response = self.client.get("/api/media", params={"filename": r"..\secret.png"})
        self.assertEqual(response.status_code, 400)

    def test_cross_origin_mutation_is_blocked(self):
        response = self.client.post(
            "/api/workflows/import",
            headers={"Origin": "https://attacker.example"},
            files={"file": ("x.json", json.dumps({"1": {"class_type": "SaveImage", "inputs": {}}}), "application/json")},
        )
        self.assertEqual(response.status_code, 403)

    def test_invalid_workflow_task_is_rejected(self):
        payload = {"1": {"class_type": "SaveImage", "inputs": {}}}
        response = self.client.post(
            "/api/workflows/import",
            files={"file": ("invalid-task.json", json.dumps(payload), "application/json")},
            data={"task": "audio"},
        )
        self.assertEqual(response.status_code, 400)

    def test_interrupt_treats_malformed_queue_payload_as_unknown_and_does_not_interrupt(self):
        class FakeResponse:
            def raise_for_status(self):
                return None
            def json(self):
                return None

        class FakeClient:
            async def __aenter__(self):
                return self
            async def __aexit__(self, *args):
                return None
            async def get(self, *args, **kwargs):
                return FakeResponse()
            async def post(self, *args, **kwargs):
                raise AssertionError("The interrupt endpoint must not be called for an unknown queue")

        with patch.object(server, "client", return_value=FakeClient()):
            response = self.client.post("/api/queue/interrupt")
        self.assertEqual(response.status_code, 200, response.text)
        self.assertFalse(response.json()["interrupted"])

    def test_interrupt_does_not_interrupt_when_external_job_is_also_running(self):
        now = server.time.time()
        with server.get_db() as conn:
            conn.execute(
                "INSERT OR REPLACE INTO jobs (id,prompt_id,task,workflow_id,prompt,status,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?)",
                ("local-running-1", "studio-running-1", "video", "workflow", "p", "running", now, now),
            )
        calls = {"post": 0}
        class FakeResponse:
            def __init__(self, data=None): self.data = data or {}
            def json(self): return self.data
            def raise_for_status(self): return None
        class FakeClient:
            async def __aenter__(self): return self
            async def __aexit__(self, *args): return None
            async def get(self, url):
                return FakeResponse({"queue_running": [[1, "studio-running-1"], [2, "other-running-1"]]})
            async def post(self, url, json=None):
                calls["post"] += 1
                return FakeResponse()
        with patch.object(server, "client", return_value=FakeClient()):
            response = self.client.post("/api/queue/interrupt")
        self.assertEqual(response.status_code, 200, response.text)
        self.assertFalse(response.json()["interrupted"])
        self.assertEqual(calls["post"], 0)

    def test_clear_queue_deletes_only_studio_pending_jobs(self):
        now = server.time.time()
        with server.get_db() as conn:
            conn.execute(
                "INSERT OR REPLACE INTO jobs (id,prompt_id,task,workflow_id,prompt,status,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?)",
                ("local-clear-1", "studio-clear-1", "video", "workflow", "p", "queued", now, now),
            )
        captured = {}
        class FakeResponse:
            def __init__(self, data=None): self.data = data or {}
            def json(self): return self.data
            def raise_for_status(self): return None
        class FakeClient:
            async def __aenter__(self): return self
            async def __aexit__(self, *args): return None
            async def get(self, url):
                return FakeResponse({"queue_pending": [[1, "studio-clear-1"], [2, "other-user"]], "queue_running": []})
            async def post(self, url, json=None):
                captured["url"], captured["json"] = url, json
                return FakeResponse()
        with patch.object(server, "client", return_value=FakeClient()):
            response = self.client.post("/api/queue/clear")
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(captured["json"], {"delete": ["studio-clear-1"]})
        self.assertEqual(response.json()["deleted"], 1)
        with server.get_db() as conn:
            row = conn.execute("SELECT status FROM jobs WHERE id='local-clear-1'").fetchone()
        self.assertEqual(row["status"], "cancelled")

    def test_wan_t2v_generation_keeps_official_graph_defaults(self):
        captured = {}
        class FakeResponse:
            status_code = 200
            def json(self): return {"prompt_id": "wan-prompt-test", "number": 3}
            def raise_for_status(self): return None
        class FakeClient:
            async def __aenter__(self): return self
            async def __aexit__(self, *args): return None
            async def post(self, url, files=None, data=None, json=None):
                self_outer = captured
                self_outer["url"] = url
                self_outer["graph"] = json["prompt"]
                return FakeResponse()
        with patch.object(server, "client", return_value=FakeClient()):
            response = self.client.post("/api/generate", data={"request_json": json.dumps({
                "workflow_id": "wan22-ti2v-5b-text-to-video-api",
                "task": "video",
                "prompt": "A camera tracks a falcon over the sea at sunrise",
            })})
        self.assertEqual(response.status_code, 200, response.text)
        graph = captured["graph"]
        self.assertEqual(graph["6"]["inputs"]["text"], "A camera tracks a falcon over the sea at sunrise")
        self.assertEqual(graph["3"]["inputs"]["steps"], 20)
        self.assertEqual(graph["3"]["inputs"]["cfg"], 5)
        self.assertEqual(graph["55"]["inputs"]["width"], 1280)
        self.assertEqual(graph["55"]["inputs"]["height"], 704)
        self.assertEqual(graph["55"]["inputs"]["length"], 41)
        self.assertEqual(graph["57"]["inputs"]["fps"], 24)
        self.assertNotEqual(graph["3"]["inputs"]["seed"], 898471028164125)

    def test_flux2_generation_submits_bound_prompt_and_native_defaults(self):
        captured = {}
        class FakeResponse:
            status_code = 200
            def json(self): return {"prompt_id": "flux-prompt-test", "number": 2}
            def raise_for_status(self): return None
        class FakeClient:
            async def __aenter__(self): return self
            async def __aexit__(self, *args): return None
            async def post(self, url, files=None, data=None, json=None):
                captured["graph"] = json["prompt"]
                return FakeResponse()
        with patch.object(server, "client", return_value=FakeClient()):
            response = self.client.post("/api/generate", data={"request_json": json.dumps({
                "workflow_id": "flux2-klein-4b-text-to-image-api", "task": "image", "prompt": "A glass sculpture in a desert museum"
            })})
        self.assertEqual(response.status_code, 200, response.text)
        graph = captured["graph"]
        self.assertEqual(graph["76"]["inputs"]["value"], "A glass sculpture in a desert museum")
        self.assertEqual(graph["75:62"]["inputs"]["steps"], 20)
        self.assertEqual(graph["75:63"]["inputs"]["cfg"], 5)
        self.assertEqual(graph["75:68"]["inputs"]["value"], 1344)
        self.assertEqual(graph["75:69"]["inputs"]["value"], 768)
        self.assertTrue(response.json()["prompt_id"].startswith("flux-"))

    def test_qwen_image_generation_submits_bound_prompt_and_native_defaults(self):
        captured = {}
        class FakeResponse:
            status_code = 200
            def json(self): return {"prompt_id": "qwen-prompt-test", "number": 4}
            def raise_for_status(self): return None
        class FakeClient:
            async def __aenter__(self): return self
            async def __aexit__(self, *args): return None
            async def post(self, url, files=None, data=None, json=None):
                captured["graph"] = json["prompt"]
                return FakeResponse()
        with patch.object(server, "client", return_value=FakeClient()):
            response = self.client.post("/api/generate", data={"request_json": json.dumps({
                "workflow_id": "qwen-image-2512-text-to-image-api", "task": "image", "prompt": "An ornate Arabic calligraphy installation in a gallery"
            })})
        self.assertEqual(response.status_code, 200, response.text)
        graph = captured["graph"]
        self.assertEqual(graph["238:227"]["inputs"]["text"], "An ornate Arabic calligraphy installation in a gallery")
        self.assertEqual(graph["238:224"]["inputs"]["value"], 50)
        self.assertEqual(graph["238:223"]["inputs"]["value"], 4)
        self.assertEqual(graph["238:232"]["inputs"]["width"], 1328)
        self.assertEqual(graph["238:232"]["inputs"]["height"], 1328)
        self.assertNotIn("238:221", graph)

    def test_qwen_image_21_generation_submits_native_prompt_and_sampler_settings(self):
        captured = {}
        class FakeResponse:
            status_code = 200
            def json(self): return {"prompt_id": "qwen21-prompt-test", "number": 5}
            def raise_for_status(self): return None
        class FakeClient:
            async def __aenter__(self): return self
            async def __aexit__(self, *args): return None
            async def post(self, url, files=None, data=None, json=None):
                captured["graph"] = json["prompt"]
                return FakeResponse()
        with patch.object(server, "client", return_value=FakeClient()):
            response = self.client.post("/api/generate", data={"request_json": json.dumps({
                "workflow_id": "qwen-image-21-text-to-image-api", "task": "image", "prompt": "A traditional Omani silver khanjar on velvet"
            })})
        self.assertEqual(response.status_code, 200, response.text)
        graph = captured["graph"]
        self.assertEqual(graph["459:452"]["inputs"]["prompt"], "A traditional Omani silver khanjar on velvet")
        self.assertEqual(graph["459:458"]["inputs"]["steps"], 25)
        self.assertEqual(graph["459:458"]["inputs"]["cfg"], 1)
        self.assertEqual(graph["459:460"]["inputs"]["value"], 1024)
        self.assertEqual(graph["459:461"]["inputs"]["value"], 1024)

    def test_failed_comfy_submission_is_retained_in_local_history(self):
        class FakeResponse:
            status_code = 503
            def json(self): return {"error": "temporary failure"}
        class FakeClient:
            async def __aenter__(self): return self
            async def __aexit__(self, *args): return None
            async def post(self, url, files=None, data=None, json=None):
                if url.endswith("/prompt"):
                    return FakeResponse()
                raise AssertionError(url)
        with patch.object(server, "client", return_value=FakeClient()):
            response = self.client.post("/api/generate", data={"request_json": json.dumps({
                "workflow_id": "flux2-klein-4b-text-to-image-api", "task": "image", "prompt": "test tracked failure"
            })})
        self.assertEqual(response.status_code, 422, response.text)
        with server.get_db() as conn:
            row = conn.execute("SELECT status,prompt_id,error FROM jobs WHERE prompt='test tracked failure' ORDER BY created_at DESC LIMIT 1").fetchone()
        self.assertIsNotNone(row)
        self.assertEqual(row["status"], "failed")
        self.assertTrue(row["prompt_id"].startswith("submitting:"))
        self.assertIn("temporary failure", row["error"])

    def test_reference_image_generation_uploads_subfolder_qualified_path(self):
        workflow = {
            "1": {"class_type": "CLIPTextEncode", "_meta": {"title": "Positive Prompt"}, "inputs": {"text": "old"}},
            "2": {"class_type": "LoadImage", "inputs": {"image": "old.png"}},
            "3": {"class_type": "SaveAnimatedWEBP", "inputs": {"images": ["2", 0]}},
        }
        wf_id = "test-video-reference"
        (server.WORKFLOW_DIR / f"{wf_id}.json").write_text(json.dumps(workflow), encoding="utf-8")
        config = {
            "name": "Test I2V", "task": "video",
            "bindings": {
                "positive": {"node_id": "1", "input": "text"},
                "init_image": {"node_id": "2", "input": "image"},
            },
        }
        (server.CONFIG_DIR / f"{wf_id}.json").write_text(json.dumps(config), encoding="utf-8")
        calls = {}

        class FakeResponse:
            status_code = 200
            def __init__(self, data): self.data = data
            def json(self): return self.data
            def raise_for_status(self): return None

        class FakeClient:
            async def __aenter__(self): return self
            async def __aexit__(self, *args): return None
            async def post(self, url, files=None, data=None, json=None):
                if url.endswith("/upload/image"):
                    calls["upload_mime"] = files["image"][2]
                    return FakeResponse({"name": files["image"][0], "subfolder": "studio-inputs"})
                if url.endswith("/prompt"):
                    calls["workflow"] = json["prompt"]
                    return FakeResponse({"prompt_id": "comfy-prompt-123", "number": 7})
                raise AssertionError(url)

        with patch.object(server, "client", return_value=FakeClient()):
            response = self.client.post(
                "/api/generate",
                data={"request_json": json.dumps({
                    "workflow_id": wf_id, "task": "video", "prompt": "A gentle camera pan",
                    "frames": 41, "fps": 24,
                })},
                files={"image": ("reference.png", b"\x89PNG\r\n\x1a\nvalid-test-data", "image/png")},
            )
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(calls["upload_mime"], "image/png")
        self.assertEqual(calls["workflow"]["2"]["inputs"]["image"], "studio-inputs/localai-reference-" + calls["workflow"]["2"]["inputs"]["image"].split("localai-reference-")[-1])
        self.assertTrue(calls["workflow"]["2"]["inputs"]["image"].endswith(".png"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
