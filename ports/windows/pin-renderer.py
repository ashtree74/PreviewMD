#!/usr/bin/env python3

import hashlib
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RENDERER = ROOT / "Sources" / "PreviewMD" / "Resources" / "Renderer"
MANIFEST = Path(__file__).resolve().parent / "renderer.sha256"


def git_blob(repo_relative: str) -> bytes:
    try:
        return subprocess.check_output(
            ["git", "cat-file", "blob", f"HEAD:{repo_relative}"],
            cwd=ROOT,
            stderr=subprocess.PIPE,
        )
    except subprocess.CalledProcessError as error:
        message = error.stderr.decode("utf-8", errors="replace").strip()
        raise SystemExit(f"missing Git blob for {repo_relative}: {message}") from error


def manifest_text() -> str:
    if not RENDERER.is_dir():
        raise SystemExit(f"renderer directory is missing: {RENDERER}")

    files = [path for path in RENDERER.rglob("*") if path.is_file()]
    lines = []
    for path in files:
        relative = path.relative_to(RENDERER).as_posix()
        repo_relative = path.relative_to(ROOT).as_posix()
        working = path.read_bytes()
        blob = git_blob(repo_relative)
        if working != blob:
            raise SystemExit(
                f"refusing to pin {relative}: work tree bytes differ from the HEAD blob"
            )
        digest = hashlib.sha256(blob).hexdigest()
        lines.append((relative, f"{digest}  {relative}"))

    lines.sort(key=lambda item: item[0])
    return "\n".join(line for _, line in lines) + "\n"


def main() -> int:
    text = manifest_text()
    MANIFEST.write_bytes(text.encode("utf-8"))
    print(f"wrote {len(text.splitlines())} pins to {MANIFEST.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
