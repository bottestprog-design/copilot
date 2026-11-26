#!/usr/bin/env python3
"""Offline release-contract checks for LocalAI Studio. No Windows services are touched."""
from __future__ import annotations
import hashlib
import json
import re
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parent

def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)
    print(f"[PASS] {message}")

def main() -> int:
    manifest = ROOT / "MANIFEST-SHA256.txt"
    lines = [line.strip() for line in manifest.read_text(encoding="utf-8-sig").splitlines() if line.strip() and not line.lstrip().startswith("#")]
    entries: dict[str, str] = {}
    relative_paths: dict[str, str] = {}
    for line in lines:
        digest, relative = line.split(None, 1)
        key = relative.replace("\\", "/").casefold()
        require(key not in entries, f"manifest path is unique: {relative}")
        entries[key] = digest.lower()
        relative_paths[key] = relative
        path = (ROOT / relative).resolve()
        require(ROOT.resolve() in path.parents, f"manifest path stays inside release: {relative}")
        require(path.is_file(), f"manifest file exists: {relative}")
        require(hashlib.sha256(path.read_bytes()).hexdigest() == digest.lower(), f"manifest hash matches: {relative}")
    installed = (ROOT / ".venv").exists() or (ROOT / "Data").exists()
    files = {p.relative_to(ROOT).as_posix().casefold() for p in ROOT.rglob("*") if p.is_file() and p.name != manifest.name and "__pycache__" not in p.parts and p.suffix != ".pyc"}
    if not installed:
        require(files == set(entries), "every release payload file is manifested and no unlisted file is present")
    else:
        require(set(entries).issubset(files), "all manifested release payloads exist in the installed runtime")

    for key, relative in relative_paths.items():
        if not key.endswith(".ps1"):
            continue
        path = ROOT / relative
        raw = path.read_bytes()
        require(raw.startswith(b"\xef\xbb\xbf"), f"PowerShell 5.1 UTF-8 BOM present: {relative}")
        raw.decode("utf-8-sig")
    check = (ROOT / "CHECK-LOCALAI.ps1").read_text(encoding="utf-8-sig")
    verify_model = (ROOT / "VERIFY-MODEL.ps1").read_text(encoding="utf-8-sig")
    require("Add-Check" in check and "Desktop shortcut" in check and "Application icon" in check, "diagnostic checks desktop shortcut and icon")
    require("content = 'Reply in one short sentence" in verify_model and "messages = @(" in verify_model, "inference diagnostic uses parser-safe ASCII prompt")

    repair = (ROOT / "REPAIR-AND-RESUME.ps1").read_text(encoding="utf-8-sig")
    require(re.search(r"if\s*\(\s*\$state\.Installed\s*\)", repair) is not None, "repair path does not require optional audio dependencies")
    installer = (ROOT / "INSTALL-PLATFORM.ps1").read_text(encoding="utf-8-sig")
    require("faster-whisper==1.2.1" not in installer and "Install FFmpeg (Gyan.FFmpeg)" not in installer, "text-chat installer does not force optional audio/FFmpeg installs")
    model_manager = (ROOT / "ENSURE-MODELS.ps1").read_text(encoding="utf-8-sig")
    require("Find-OllamaManifestByTag" in model_manager and "SHA-256 verification" in model_manager, "existing Qwen tags verify local manifest blobs when available")
    start_script = (ROOT / "START-CHAT.ps1").read_text(encoding="utf-8-sig")
    require("Start-Process $WebUrl" not in start_script, "service startup leaves app-window opening to the desktop launcher")
    verifier = (ROOT / "VERIFY-PACKAGE.ps1").read_text(encoding="utf-8-sig")
    require("[switch]$InstalledPlatform" in verifier, "package verifier distinguishes extracted ZIP from installed runtime")
    launcher = (ROOT / "LAUNCH-LOCALAI-APP.ps1").read_text(encoding="utf-8-sig")
    require("--app=' + $WebUrl" in launcher and "LocalAI Studio.lnk" in launcher, "desktop launcher creates branded shortcut and opens app-mode browser")
    setup = (ROOT / "SETUP-LOCALAI.ps1").read_text(encoding="utf-8-sig")
    require("MANIFEST-SHA256.txt" in setup and "LAUNCH-LOCALAI-APP.ps1" in setup, "one-click setup verifies, deploys and launches installed package")
    models = json.loads((ROOT / "MODELS.json").read_text(encoding="utf-8"))
    require(models["ollama"]["auto_download_when_missing"] is False, "Qwen automatic download remains disabled")
    require(models["whisper"]["required_for_text_chat"] is False, "Whisper remains optional for text chat")
    icon = ROOT / "Assets" / "LocalAI-Studio.ico"
    require(icon.is_file(), "Windows application icon is included")
    icon_bytes = icon.read_bytes()
    require(len(icon_bytes) >= 64 and icon_bytes[:4] == b"\x00\x00\x01\x00" and struct.unpack_from("<H", icon_bytes, 4)[0] >= 6, "ICO header declares multiple Windows icon sizes")
    setup_bat = (ROOT / "SETUP-LOCALAI.bat").read_text(encoding="ascii")
    maintenance_bat = (ROOT / "LocalAI-Studio.bat").read_text(encoding="ascii")
    require("SETUP-LOCALAI.ps1" in setup_bat and "powershell.exe" in setup_bat.lower(), "single setup BAT invokes the PowerShell deployment script")
    require("SETUP-LOCALAI.bat" in maintenance_bat and "LAUNCH-LOCALAI-APP.ps1" in maintenance_bat, "legacy BAT routes extracted start to setup and installed start to desktop launcher")
    print("RELEASE_CONTRACT_TESTS: SUCCESS")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
