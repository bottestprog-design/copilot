from __future__ import annotations

import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "MANIFEST-SHA256.txt"
EXCLUDED_DIRS = {
    ".git", ".venv", ".venv.next", "__pycache__", ".pytest_cache",
    ".mypy_cache", ".ruff_cache", "node_modules", ".idea", ".vscode",
}
EXCLUDED_SUFFIXES = {
    ".pyc", ".pyo", ".sqlite", ".sqlite3", ".db", ".log", ".tmp", ".bak",
    ".sqlite-wal", ".sqlite-shm", ".sqlite3-wal", ".sqlite3-shm",
    ".sqlite-journal", ".sqlite3-journal", ".db-wal", ".db-shm", ".db-journal",
}
EXCLUDED_NAMES = {".DS_Store", "Thumbs.db", "desktop.ini", ".localai-creative-studio-owner.json"}


def included(path: Path) -> bool:
    rel = path.relative_to(ROOT)
    if path == MANIFEST or any(part in EXCLUDED_DIRS or part.startswith(".venv.previous-") or part.startswith(".venv.failed-") or part.startswith(".venv.next.incomplete-") for part in rel.parts):
        return False
    # Never follow or package symlinks/reparse-like aliases. A release must be
    # self-contained and must not hash files outside the selected project root.
    if path.is_symlink():
        return False
    is_junction = getattr(path, "is_junction", None)
    if is_junction is not None and is_junction():
        return False
    if path.suffix.lower() in EXCLUDED_SUFFIXES or path.name in EXCLUDED_NAMES:
        return False
    return path.is_file()


def main() -> None:
    files = sorted((p for p in ROOT.rglob("*") if included(p)), key=lambda p: p.relative_to(ROOT).as_posix().lower())
    lines = [f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(ROOT).as_posix()}" for path in files]
    MANIFEST.write_text("\n".join(lines) + "\n", encoding="ascii")
    print(f"Wrote {len(lines)} SHA-256 entries to {MANIFEST.name}")


if __name__ == "__main__":
    main()
