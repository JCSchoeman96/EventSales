#!/usr/bin/env python3
"""Prove deterministic ZIP output is independent of member list order."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
WRITER = ROOT / "scripts/lib/build_deterministic_wordpress_zip.py"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    members = [
        {"path": "demo/a.php", "mode": "100644", "data": b"<?php\n// a\n"},
        {"path": "demo/b.php", "mode": "100755", "data": b"<?php\n// b\n"},
        {"path": "demo/README.md", "mode": "100644", "data": b"# demo\n"},
    ]
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        files = []
        manifest_a = []
        manifest_b = []
        for member in members:
            rel = member["path"].split("/", 1)[1]
            file_path = tmp_path / rel
            file_path.parent.mkdir(parents=True, exist_ok=True)
            file_path.write_bytes(member["data"])
            entry = {
                "path": member["path"],
                "mode": member["mode"],
                "file": str(file_path),
            }
            manifest_a.append(entry)
        manifest_b = list(reversed(manifest_a))

        zip_a = tmp_path / "a.zip"
        zip_b = tmp_path / "b.zip"
        manifest_a_path = tmp_path / "a.json"
        manifest_b_path = tmp_path / "b.json"
        manifest_a_path.write_text(json.dumps(manifest_a), encoding="utf-8")
        manifest_b_path.write_text(json.dumps(manifest_b), encoding="utf-8")

        for manifest, out in ((manifest_a_path, zip_a), (manifest_b_path, zip_b)):
            subprocess.check_call(
                [sys.executable, str(WRITER), "--output", str(out), "--members-json", str(manifest)]
            )

        if sha256(zip_a) != sha256(zip_b):
            print("ZIP order perturbation changed archive SHA256", file=sys.stderr)
            return 1

    print("plugin-deterministic-zip-order-test: passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
