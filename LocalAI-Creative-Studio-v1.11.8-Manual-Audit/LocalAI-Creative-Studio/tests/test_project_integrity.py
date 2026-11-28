from __future__ import annotations

import ast
import importlib.util
import hashlib
import json
import re
import struct
import tempfile
import unittest
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class AssetParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids: list[str] = []
        self.local_assets: list[str] = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if attrs.get("id"):
            self.ids.append(attrs["id"])
        for key in ("src", "href"):
            value = attrs.get(key, "")
            if value.startswith("/static/"):
                self.local_assets.append(value.removeprefix("/static/"))


class ProjectIntegrityReview(unittest.TestCase):
    def test_release_manifest_matches_every_packaged_file(self):
        manifest_path = ROOT / "MANIFEST-SHA256.txt"
        self.assertTrue(manifest_path.is_file(), "The release manifest is required.")
        entries: dict[str, str] = {}
        for number, line in enumerate(manifest_path.read_text(encoding="ascii").splitlines(), 1):
            digest, separator, relative = line.partition("  ")
            self.assertTrue(separator and re.fullmatch(r"[0-9a-f]{64}", digest), f"Bad manifest line {number}")
            key = relative.casefold()
            self.assertNotIn(key, entries, f"Duplicate path at manifest line {number}")
            path = ROOT / relative
            self.assertTrue(path.is_file(), f"Missing manifest file: {relative}")
            self.assertFalse(path.is_symlink(), f"Symlink in release: {relative}")
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), digest, relative)
            entries[key] = digest
        self.assertNotIn("manifest-sha256.txt", entries)
        excluded_dirs = {".git", ".venv", ".venv.next", "__pycache__", ".pytest_cache", "node_modules"}
        # Created by the installer after package extraction; verified independently
        # by scripts/VERIFY-PACKAGE.ps1 and intentionally excluded by build_manifest.py.
        ignored_names = {".DS_Store", "Thumbs.db", "desktop.ini", ".localai-creative-studio-owner.json"}
        for path in ROOT.rglob("*"):
            rel = path.relative_to(ROOT)
            if any(part in excluded_dirs for part in rel.parts) or path.is_dir():
                continue
            if path.name in ignored_names or path.suffix.lower() in {
                ".pyc", ".pyo", ".sqlite", ".sqlite3", ".db", ".log", ".tmp", ".bak"
            }:
                continue
            if path == manifest_path:
                continue
            self.assertIn(rel.as_posix().casefold(), entries, f"Unlisted package file: {rel}")

    def test_manifest_builder_refuses_non_file_targets(self):
        builder_path = ROOT / "scripts" / "build_manifest.py"
        spec = importlib.util.spec_from_file_location("localai_manifest_builder", builder_path)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        with tempfile.TemporaryDirectory(prefix="localai-manifest-target-") as temp:
            directory_target = Path(temp) / "MANIFEST-SHA256.txt"
            directory_target.mkdir()
            with self.assertRaises(RuntimeError):
                builder.ensure_safe_manifest_target(directory_target)
            directory_target.rmdir()
            file_target = Path(temp) / "MANIFEST-SHA256.txt"
            file_target.write_text("safe\n", encoding="ascii")
            builder.ensure_safe_manifest_target(file_target)

    def test_all_json_files_are_strictly_valid(self):
        for path in ROOT.rglob("*.json"):
            if any(part in {".venv", "__pycache__", ".pytest_cache", "node_modules"} for part in path.parts):
                continue
            with self.subTest(file=path.relative_to(ROOT)):
                json.loads(path.read_text(encoding="utf-8-sig"), parse_constant=lambda x: (_ for _ in ()).throw(ValueError(x)))

    def test_bundled_workflows_and_configs_are_paired(self):
        workflow_dir = ROOT / "data" / "workflows"
        config_dir = ROOT / "data" / "configs"
        workflow_ids = {p.stem for p in workflow_dir.glob("*.json")}
        config_ids = {p.stem for p in config_dir.glob("*.json")}
        self.assertTrue(workflow_ids)
        self.assertEqual(workflow_ids, config_ids)
        for workflow_id in sorted(workflow_ids):
            graph = json.loads((workflow_dir / f"{workflow_id}.json").read_text(encoding="utf-8"))
            config = json.loads((config_dir / f"{workflow_id}.json").read_text(encoding="utf-8"))
            self.assertIsInstance(graph, dict)
            self.assertTrue(graph)
            self.assertIn(config.get("task"), {"image", "video"})
            self.assertIsInstance(config.get("bindings"), dict)
            for node_id, node in graph.items():
                self.assertIsInstance(node.get("class_type"), str)
                self.assertIsInstance(node.get("inputs"), dict)
                for input_name, value in node["inputs"].items():
                    if (isinstance(value, list) and len(value) == 2
                            and isinstance(value[0], str)
                            and isinstance(value[1], int) and not isinstance(value[1], bool)):
                        self.assertIn(value[0], graph, f"{workflow_id}:{node_id}.{input_name}")
                        self.assertGreaterEqual(value[1], 0)
            for binding_name, binding in config["bindings"].items():
                with self.subTest(workflow=workflow_id, binding=binding_name):
                    self.assertIsInstance(binding, dict)
                    self.assertIn(binding.get("node_id"), graph)
                    self.assertIn(binding.get("input"), graph[binding["node_id"]]["inputs"])

    def test_python_sources_parse_without_importing_or_running_them(self):
        for path in ROOT.rglob("*.py"):
            if any(part in {".venv", "__pycache__", ".pytest_cache"} for part in path.parts):
                continue
            with self.subTest(file=path.relative_to(ROOT)):
                ast.parse(path.read_text(encoding="utf-8-sig"), filename=str(path))

    def test_html_ids_are_unique_and_local_assets_exist(self):
        parser = AssetParser()
        parser.feed((ROOT / "studio" / "static" / "index.html").read_text(encoding="utf-8"))
        self.assertEqual(len(parser.ids), len(set(parser.ids)), "Duplicate HTML IDs can break controls.")
        for relative in parser.local_assets:
            self.assertTrue((ROOT / "studio" / "static" / relative).is_file(), relative)

    def test_qwen_image_21_source_points_to_the_api_format_benchmark(self):
        config = json.loads((ROOT / "data/configs/qwen-image-21-text-to-image-api.json").read_text(encoding="utf-8"))
        self.assertEqual(
            config["source_url"],
            "https://github.com/Comfy-Org/workflow_templates/blob/main/benchmarks/image_qwen_image_2_1_t2i.json",
        )
        self.assertIn("benchmarks/", config["source_url"])
        self.assertNotIn("/templates/", config["source_url"])

    def test_frontend_static_selectors_match_html(self):
        parser = AssetParser()
        parser.feed((ROOT / "studio" / "static" / "index.html").read_text(encoding="utf-8"))
        html_ids = set(parser.ids)
        js = (ROOT / "studio" / "static" / "app.js").read_text(encoding="utf-8")
        selectors = set(re.findall(r"""\$\(['"]#([A-Za-z][A-Za-z0-9_-]*)['"]\)""", js))
        # These controls are created only after the relevant user interaction.
        dynamic_ids = {"clear-reference", "map-task"}
        missing = sorted(selectors - html_ids - dynamic_ids)
        self.assertEqual(missing, [], f"Static JS selectors missing from HTML: {missing}")

    def test_frontend_uses_only_local_generated_media_and_no_remote_font_import(self):
        js = (ROOT / "studio" / "static" / "app.js").read_text(encoding="utf-8")
        css = (ROOT / "studio" / "static" / "app.css").read_text(encoding="utf-8")
        self.assertIn("function safeMediaUrl(value)", js)
        self.assertIn("candidate.startsWith('/api/media?')", js)
        self.assertNotIn("@import", css.lower())
        self.assertNotIn("fonts.googleapis.com", css.lower())

    def test_web_manifest_icons_have_declared_png_dimensions(self):
        web_manifest = json.loads((ROOT / "studio" / "static" / "manifest.webmanifest").read_text(encoding="utf-8"))
        self.assertEqual(web_manifest["display"], "standalone")
        for icon in web_manifest["icons"]:
            path = ROOT / "studio" / "static" / icon["src"].removeprefix("/static/")
            payload = path.read_bytes()
            self.assertTrue(payload.startswith(b"\x89PNG\r\n\x1a\n"))
            width, height = struct.unpack(">II", payload[16:24])
            expected = tuple(int(part) for part in icon["sizes"].split("x"))
            self.assertEqual((width, height), expected)

    def test_windows_icon_contains_unique_multi_size_png_frames(self):
        payload = (ROOT / "assets" / "localai-creative-studio.ico").read_bytes()
        reserved, image_type, count = struct.unpack_from("<HHH", payload, 0)
        self.assertEqual((reserved, image_type), (0, 1))
        self.assertGreaterEqual(count, 7)
        self.assertLessEqual(6 + count * 16, len(payload))
        found = set()
        for index in range(count):
            width, height, color_count, reserved_entry, planes, bits, size, offset = struct.unpack_from(
                "<BBBBHHII", payload, 6 + index * 16
            )
            width, height = width or 256, height or 256
            self.assertEqual(reserved_entry, 0)
            self.assertEqual((planes, bits), (0, 32))
            self.assertGreaterEqual(offset, 6 + count * 16)
            self.assertLessEqual(offset + size, len(payload))
            frame = payload[offset:offset + size]
            self.assertTrue(frame.startswith(b"\x89PNG\r\n\x1a\n"))
            self.assertEqual(struct.unpack(">II", frame[16:24]), (width, height))
            self.assertNotIn((width, height), found)
            found.add((width, height))
        self.assertTrue({(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)}.issubset(found))

    def test_release_version_and_static_substitution_are_consistent(self):
        version = (ROOT / "VERSION.txt").read_text(encoding="ascii").strip()
        server = (ROOT / "studio" / "server.py").read_text(encoding="utf-8")
        html = (ROOT / "studio" / "static" / "index.html").read_text(encoding="utf-8")
        self.assertEqual(version, "1.11.8")
        self.assertIn("APP_VERSION = load_app_version()", server)
        self.assertIn('version_path = PACKAGE_ROOT / "VERSION.txt"', server)
        self.assertEqual(html.count("v__APP_VERSION__"), 2)

    def test_installer_never_uses_destructive_mirror_or_model_directories(self):
        installer = (ROOT / "scripts" / "INSTALL-DESKTOP-APP.ps1").read_text(encoding="utf-8-sig")
        updater = (ROOT / "scripts" / "APPLY-UPDATE.ps1").read_text(encoding="utf-8-sig")
        for source in (installer, updater):
            self.assertNotIn("/MIR", source.upper())
            self.assertNotIn("ollama", source.lower().split("function install-officialpython", 1)[-1].split("try {", 1)[0])
        self.assertIn("*.sqlite*", installer)
        self.assertIn("*.db*", updater)
        self.assertIn("NoLaunch", installer)
