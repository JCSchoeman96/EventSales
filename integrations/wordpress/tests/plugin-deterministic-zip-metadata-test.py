#!/usr/bin/env python3
"""Verify deterministic ZIP encodes Unix version-made-by and permission bits."""

from __future__ import annotations

import struct
import subprocess
import sys
import tempfile
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
WRITER = ROOT / "scripts/lib/build_deterministic_wordpress_zip.py"

VERSION_MADE_BY_UNIX = (3 << 8) | 20


def parse_central_directory(zip_bytes: bytes) -> list[dict]:
    eocd_sig = b"\x50\x4b\x05\x06"
    idx = zip_bytes.rfind(eocd_sig)
    if idx < 0:
        raise ValueError("EOCD not found")
    cd_size, cd_offset = struct.unpack_from("<II", zip_bytes, idx + 12)
    pos = cd_offset
    end = cd_offset + cd_size
    entries = []
    while pos < end:
        if zip_bytes[pos : pos + 4] != b"\x50\x4b\x01\x02":
            raise ValueError("Expected central directory header")
        (
            _sig,
            version_made_by,
            _version_needed,
            _flag,
            _method,
            _mtime,
            _mdate,
            _crc,
            _comp_size,
            _uncomp_size,
            name_len,
            extra_len,
            comment_len,
            _disk_start,
            _internal,
            external_attr,
            _offset,
        ) = struct.unpack_from("<IHHHHHHIIIHHHHHII", zip_bytes, pos)
        name_start = pos + 46
        name = zip_bytes[name_start : name_start + name_len].decode("utf-8")
        entries.append(
            {
                "name": name,
                "version_made_by": version_made_by,
                "external_attr": external_attr,
            }
        )
        pos = name_start + name_len + extra_len + comment_len
    return entries


def unix_mode_from_external_attr(external_attr: int) -> int:
    return (external_attr >> 16) & 0xFFFF


def main() -> int:
    members = [
        {"path": "demo/exec.php", "mode": "100755", "data": b"#!/usr/bin/env php\n"},
        {"path": "demo/plain.php", "mode": "100644", "data": b"<?php\n"},
    ]
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        manifest = []
        for member in members:
            rel = member["path"].split("/", 1)[1]
            file_path = tmp_path / rel
            file_path.parent.mkdir(parents=True, exist_ok=True)
            file_path.write_bytes(member["data"])
            manifest.append(
                {"path": member["path"], "mode": member["mode"], "file": str(file_path)}
            )
        manifest_path = tmp_path / "members.json"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        zip_path = tmp_path / "meta.zip"
        subprocess.check_call(
            [sys.executable, str(WRITER), "--output", str(zip_path), "--members-json", str(manifest_path)]
        )
        entries = parse_central_directory(zip_path.read_bytes())
        by_name = {entry["name"]: entry for entry in entries}
        exec_entry = by_name["demo/exec.php"]
        plain_entry = by_name["demo/plain.php"]
        if exec_entry["version_made_by"] != VERSION_MADE_BY_UNIX:
            print(
                f"exec.php version_made_by expected {VERSION_MADE_BY_UNIX}, got {exec_entry['version_made_by']}",
                file=sys.stderr,
            )
            return 1
        if plain_entry["version_made_by"] != VERSION_MADE_BY_UNIX:
            print("plain.php version_made_by not Unix-encoded", file=sys.stderr)
            return 1
        if unix_mode_from_external_attr(exec_entry["external_attr"]) != 0o755:
            print("exec.php external Unix mode not 0755", file=sys.stderr)
            return 1
        if unix_mode_from_external_attr(plain_entry["external_attr"]) != 0o644:
            print("plain.php external Unix mode not 0644", file=sys.stderr)
            return 1

    print("plugin-deterministic-zip-metadata-test: passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
