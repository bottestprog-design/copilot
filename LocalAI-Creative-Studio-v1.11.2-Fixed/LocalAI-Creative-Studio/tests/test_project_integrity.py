from __future__ import annotations

import hashlib
import json
import re
import struct
import unittest
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class LocalAssetParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.references: list[str] = []
        self.ids: list[str] = []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        element_id = values.get("id")
        if element_id:
            self.ids.append(element_id)
        for key in ("src", "href"):
            value = values.get(key, "")
            if value.startswith("/static/") or value == "/manifest.webmanifest":
                self.references.append(value)


class ProjectIntegrityTests(unittest.TestCase):
    def test_manifest_hashes_every_distributable_file(self):
        manifest = ROOT / "MANIFEST-SHA256.txt"
        self.assertTrue(manifest.is_file())
        entries = {}
        for line in manifest.read_text(encoding="ascii").splitlines():
            digest, relative = line.split("  ", 1)
            self.assertRegex(digest, r"^[0-9a-f]{64}$")
            self.assertNotIn(relative.lower(), entries)
            path = ROOT / relative
            self.assertTrue(path.is_file(), relative)
            self.assertFalse(path.is_symlink(), relative)
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
            self.assertEqual(actual, digest, relative)
            entries[relative.lower()] = digest
        self.assertGreaterEqual(len(entries), 30)
        self.assertNotIn("manifest-sha256.txt", entries)

    def test_all_package_json_files_parse(self):
        for path in ROOT.rglob("*.json"):
            if any(part in {".venv", "__pycache__", ".pytest_cache", "node_modules"} for part in path.parts):
                continue
            with self.subTest(path=path.relative_to(ROOT)):
                json.loads(path.read_text(encoding="utf-8-sig"))

    def test_workflow_and_configuration_ids_match(self):
        workflows = {p.stem for p in (ROOT / "data" / "workflows").glob("*.json")}
        configs = {p.stem for p in (ROOT / "data" / "configs").glob("*.json")}
        self.assertEqual(workflows, configs)
        for workflow_id in sorted(workflows):
            graph = json.loads((ROOT / "data" / "workflows" / f"{workflow_id}.json").read_text(encoding="utf-8"))
            config = json.loads((ROOT / "data" / "configs" / f"{workflow_id}.json").read_text(encoding="utf-8"))
            self.assertTrue(graph, workflow_id)
            self.assertIn(config.get("task"), {"image", "video"}, workflow_id)
            self.assertIsInstance(config.get("bindings"), dict, workflow_id)
            for node_id, node in graph.items():
                self.assertIsInstance(node.get("class_type"), str, f"{workflow_id}:{node_id}")
                self.assertIsInstance(node.get("inputs"), dict, f"{workflow_id}:{node_id}")
                for input_name, value in node["inputs"].items():
                    if isinstance(value, list) and len(value) == 2 and isinstance(value[0], str):
                        self.assertIn(value[0], graph, f"{workflow_id}:{node_id}.{input_name}")

    def test_web_manifest_icons_exist_and_dimensions_match(self):
        manifest = json.loads((ROOT / "studio" / "static" / "manifest.webmanifest").read_text(encoding="utf-8"))
        self.assertEqual(manifest["display"], "standalone")
        for icon in manifest["icons"]:
            path = ROOT / "studio" / "static" / icon["src"].removeprefix("/static/")
            self.assertTrue(path.is_file(), str(path))
            payload = path.read_bytes()
            self.assertTrue(payload.startswith(b"\x89PNG\r\n\x1a\n"), str(path))
            self.assertGreaterEqual(len(payload), 24, str(path))
            width, height = struct.unpack(">II", payload[16:24])
            expected = tuple(int(part) for part in icon["sizes"].split("x"))
            self.assertEqual((width, height), expected)

    def test_windows_ico_contains_multiple_shell_sizes(self):
        path = ROOT / "assets" / "localai-creative-studio.ico"
        payload = path.read_bytes()
        self.assertGreaterEqual(len(payload), 6)
        reserved, image_type, count = struct.unpack_from("<HHH", payload, 0)
        self.assertEqual(reserved, 0)
        self.assertEqual(image_type, 1)
        self.assertGreaterEqual(count, 4)
        self.assertLessEqual(6 + count * 16, len(payload))
        sizes = set()
        for index in range(count):
            width, height, color_count, reserved_entry, planes, bit_count, image_size, image_offset = struct.unpack_from(
                "<BBBBHHII", payload, 6 + index * 16
            )
            width = width or 256
            height = height or 256
            sizes.add((width, height))
            self.assertEqual(reserved_entry, 0)
            self.assertEqual(planes, 0)
            self.assertEqual(bit_count, 32)
            self.assertGreater(image_size, 24)
            self.assertGreaterEqual(image_offset, 6 + count * 16)
            self.assertLessEqual(image_offset + image_size, len(payload))
            image = payload[image_offset:image_offset + image_size]
            self.assertTrue(image.startswith(b"\x89PNG\r\n\x1a\n"), (width, height))
            self.assertGreaterEqual(len(image), 24)
            actual_width, actual_height = struct.unpack(">II", image[16:24])
            self.assertEqual((actual_width, actual_height), (width, height))
        self.assertEqual(count, len(sizes), "ICO must not contain duplicate image dimensions")
        self.assertTrue({(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)}.issubset(sizes), sizes)

    def test_html_local_assets_are_present(self):
        parser = LocalAssetParser()
        parser.feed((ROOT / "studio" / "static" / "index.html").read_text(encoding="utf-8"))
        self.assertGreaterEqual(len(parser.references), 3)
        for reference in parser.references:
            relative = reference.removeprefix("/")
            self.assertTrue((ROOT / "studio" / "static" / relative.removeprefix("static/")).is_file(), reference)

    def test_html_element_ids_are_unique(self):
        parser = LocalAssetParser()
        parser.feed((ROOT / "studio" / "static" / "index.html").read_text(encoding="utf-8"))
        self.assertTrue(parser.ids)
        self.assertEqual(len(parser.ids), len(set(parser.ids)), "Duplicate DOM id can break controls and accessibility labels")

    def test_frontend_restricts_generated_media_and_external_catalog_urls(self):
        app_js = (ROOT / "studio" / "static" / "app.js").read_text(encoding="utf-8")
        self.assertIn("function safeMediaUrl(value)", app_js)
        self.assertIn("candidate.startsWith('/api/media?')", app_js)
        self.assertIn("function safeExternalUrl(value)", app_js)
        self.assertIn("parsed.protocol === 'https:'", app_js)
        self.assertIn("return esc(labels[String(status || '')] || 'غير معروف')", app_js)
        self.assertIn("const url = safeMediaUrl(output?.url)", app_js)

    def test_release_version_is_consistent(self):
        version = (ROOT / "VERSION.txt").read_text(encoding="ascii").strip()
        server = (ROOT / "studio" / "server.py").read_text(encoding="utf-8")
        html = (ROOT / "studio" / "static" / "index.html").read_text(encoding="utf-8")
        self.assertRegex(version, r"^\d+\.\d+\.\d+$")
        self.assertIn("APP_VERSION = load_app_version()", server)
        self.assertIn('version_path = PACKAGE_ROOT / "VERSION.txt"', server)
        self.assertGreaterEqual(html.count("v__APP_VERSION__"), 2)

    def test_runtime_requirements_are_explicit_and_not_empty(self):
        lines = [line.strip() for line in (ROOT / "requirements.txt").read_text(encoding="utf-8").splitlines() if line.strip() and not line.lstrip().startswith("#")]
        self.assertGreaterEqual(len(lines), 5)
        self.assertTrue(all(">=" in line and "<" in line for line in lines))
        self.assertEqual(len(lines), len(set(line.split(">=", 1)[0].lower() for line in lines)))

    def test_runtime_dependency_ranges_have_compatible_major_caps(self):
        requirements = (ROOT / "requirements.txt").read_text(encoding="utf-8")
        self.assertRegex(requirements, r"psutil>=7\.2\.2,<8\.0")
        self.assertRegex(requirements, r"python-multipart>=0\.0\.29,<1\.0")
        self.assertRegex(requirements, r"fastapi>=0\.128\.2,<1\.0")
        self.assertRegex(requirements, r"pydantic>=2\.13\.5,<3\.0")

    def test_installer_and_updater_do_not_use_mirroring_or_delete_desktop_apps(self):
        installer = (ROOT / "scripts" / "INSTALL-DESKTOP-APP.ps1").read_text(encoding="utf-8-sig")
        updater = (ROOT / "scripts" / "APPLY-UPDATE.ps1").read_text(encoding="utf-8-sig")
        for script in (installer, updater):
            self.assertNotRegex(script, re.compile(r"(?i)(Remove-Item|rmdir|rd)\s+[^\r\n]*(Desktop|StartMenu|DesktopDirectory)"))
            self.assertNotIn("/MIR", script.upper())
        self.assertIn("Get-SafeShortcutPath", installer)
        self.assertIn("Test-OwnedShortcut", installer)
        self.assertIn("[System.IO.File]::Move($temporary, $ShortcutPath)", installer)
        self.assertIn("Select-Object -Skip 4", updater)
        self.assertIn("Test-OwnedUpdateFolder", updater)

    def test_build_manifest_excludes_symlinks_and_junctions(self):
        builder = (ROOT / "scripts" / "build_manifest.py").read_text(encoding="utf-8")
        self.assertIn("path.is_symlink()", builder)
        self.assertIn("getattr(path, \"is_junction\", None)", builder)

    def test_manifest_and_windows_verifier_exclude_all_sqlite_sidecars(self):
        builder = (ROOT / "scripts" / "build_manifest.py").read_text(encoding="utf-8")
        verifier = (ROOT / "scripts" / "VERIFY-PACKAGE.ps1").read_text(encoding="utf-8-sig")
        for suffix in (".sqlite-journal", ".sqlite3-journal", ".db-wal", ".db-shm", ".db-journal"):
            with self.subTest(suffix=suffix):
                self.assertIn(suffix, builder)
                self.assertIn(suffix, verifier)
        self.assertIn("*.sqlite*", (ROOT / "scripts" / "INSTALL-DESKTOP-APP.ps1").read_text(encoding="utf-8-sig"))
        self.assertIn("*.db*", (ROOT / "scripts" / "APPLY-UPDATE.ps1").read_text(encoding="utf-8-sig"))

    def test_powershell_scripts_have_balanced_strings_and_delimiters(self):
        # Windows PowerShell 5.1 is the supported installer host. This is a
        # lexical guard, not a substitute for executing the scripts on Windows.
        pairs = {')': '(', ']': '[', '}': '{'}
        scripts = sorted((ROOT / "scripts").glob("*.ps1"))
        self.assertGreaterEqual(len(scripts), 7)
        for path in scripts:
            with self.subTest(path=path.relative_to(ROOT)):
                source = path.read_text(encoding="utf-8-sig")
                stack = []
                state = "code"
                line = 1
                index = 0
                while index < len(source):
                    char = source[index]
                    next_char = source[index + 1] if index + 1 < len(source) else ""
                    if char == "\n":
                        line += 1
                    if state == "comment":
                        if char == "\n":
                            state = "code"
                        index += 1
                        continue
                    if state == "single":
                        if char == "'":
                            if next_char == "'":
                                index += 2
                                continue
                            state = "code"
                        index += 1
                        continue
                    if state == "double":
                        if char == "`":
                            index += 2
                            continue
                        if char == '"':
                            state = "code"
                        index += 1
                        continue
                    if char == "#":
                        state = "comment"
                    elif char == "'":
                        state = "single"
                    elif char == '"':
                        state = "double"
                    elif char in "([{":
                        stack.append((char, line))
                    elif char in ")]}":
                        self.assertTrue(stack, f"Unexpected {char} at line {line}")
                        opening, opening_line = stack.pop()
                        self.assertEqual(opening, pairs[char], f"Mismatched {opening} from line {opening_line} at line {line}")
                    index += 1
                self.assertEqual(state, "code", f"Unterminated PowerShell string in {path.name}")
                self.assertEqual(stack, [], f"Unclosed PowerShell delimiter in {path.name}: {stack}")
                raw = path.read_bytes()
                if any(ord(character) > 127 for character in source):
                    self.assertTrue(raw.startswith(b"\xef\xbb\xbf"), f"UTF-8 BOM required for non-ASCII PowerShell source: {path.name}")

    def test_gitignore_excludes_all_sqlite_database_sidecars(self):
        ignored = (ROOT / ".gitignore").read_text(encoding="utf-8")
        for pattern in ("*.sqlite-wal", "*.sqlite-shm", "*.sqlite-journal", "*.sqlite3-journal", "*.db-wal", "*.db-shm", "*.db-journal"):
            with self.subTest(pattern=pattern):
                self.assertIn(pattern, ignored)

    def test_server_rejects_oversized_declared_requests_before_form_parsing(self):
        server = (ROOT / "studio" / "server.py").read_text(encoding="utf-8")
        self.assertIn("MAX_HTTP_REQUEST_BYTES = 52 * 1024 * 1024", server)
        self.assertIn("declared_length > MAX_HTTP_REQUEST_BYTES", server)
        self.assertIn("status_code=413", server)


    def test_installed_owner_marker_is_runtime_metadata_not_a_release_payload_file(self):
        builder = (ROOT / "scripts" / "build_manifest.py").read_text(encoding="utf-8")
        verifier = (ROOT / "scripts" / "VERIFY-PACKAGE.ps1").read_text(encoding="utf-8-sig")
        self.assertIn(".localai-creative-studio-owner.json", builder)
        self.assertIn("$_.FullName -ine $ownerMarker", verifier)
        self.assertIn("INVALID LOCALAI INSTALLATION MARKER", verifier)

    def test_recovery_staging_venv_directories_are_ignored_by_release_tools(self):
        builder = (ROOT / "scripts" / "build_manifest.py").read_text(encoding="utf-8")
        verifier = (ROOT / "scripts" / "VERIFY-PACKAGE.ps1").read_text(encoding="utf-8-sig")
        self.assertIn(".venv.next.incomplete-", builder)
        self.assertIn(r".venv\.next\.incomplete-", verifier)



if __name__ == "__main__":
    unittest.main()
