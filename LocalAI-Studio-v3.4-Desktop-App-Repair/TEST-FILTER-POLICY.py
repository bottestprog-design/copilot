#!/usr/bin/env python3
"""Offline guardrail tests for expensive model behavior and download policy."""
from __future__ import annotations
import json, re
from pathlib import Path
ROOT=Path(__file__).resolve().parent

def read(path: Path) -> str:
    if not path.is_file(): raise AssertionError(f"Missing required file: {path}")
    text=path.read_text(encoding="utf-8-sig")
    compile(text,str(path),"exec")
    return text

def main() -> int:
    thinking=read(ROOT/"Filters"/"02-Accuracy-Thinking.py")
    review=read(ROOT/"Filters"/"03-Selective-Self-Review.py")
    if not re.search(r"enable_qwen_thinking\s*:\s*bool\s*=\s*Field\(\s*default\s*=\s*False",thinking):
        raise AssertionError("Qwen thinking must be opt-in (default False).")
    if not re.search(r"enabled\s*:\s*bool\s*=\s*Field\(\s*default\s*=\s*False",review):
        raise AssertionError("Selective self-review must be opt-in (default False).")
    timeout=re.search(r"timeout_seconds\s*:\s*int\s*=\s*Field\(\s*default\s*=\s*(\d+).*?ge\s*=\s*(\d+).*?le\s*=\s*(\d+)",review)
    if not timeout: raise AssertionError("Self-review timeout must have explicit lower/upper bounds.")
    default,lower,upper=map(int,timeout.groups())
    if not (5<=lower<=default<=upper<=120): raise AssertionError(f"Unsafe self-review timeout values: {default}, {lower}, {upper}")
    config=json.loads(read(ROOT/"MODELS.json"))
    if config["ollama"].get("auto_download_when_missing") is not False:
        raise AssertionError("Qwen auto-download must be disabled by default.")
    if config["whisper"].get("required_for_text_chat") is not False:
        raise AssertionError("Whisper must remain optional for text chat.")
    if config["whisper"].get("auto_download_when_missing") is not True:
        raise AssertionError("Whisper download policy should remain an explicit opt-in action, not a text-start dependency.")
    print("[PASS] Qwen deep thinking is opt-in")
    print("[PASS] Second-pass self-review is opt-in")
    print(f"[PASS] Self-review timeout is {default}s and bounded to {lower}-{upper}s")
    print("[PASS] Qwen auto-download is disabled by default")
    print("[PASS] Whisper is not required for text chat")
    print("MODEL_POLICY_TESTS: SUCCESS")
    return 0

if __name__=="__main__": raise SystemExit(main())
