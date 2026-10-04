#!/usr/bin/env python3
"""
Deterministic ZIP writer for WordPress plugin packages (WP-SOURCE-05).

Members are stored uncompressed (ZIP_STORED), sorted lexicographically by archive path,
with fixed DOS timestamp and stable Unix external attributes derived from git modes.
"""

from __future__ import annotations

import argparse
import binascii
import json
import struct
import sys
import zlib
from pathlib import Path

# Fixed metadata (1980-01-01 00:00:00 MS-DOS) — common reproducible-build convention.
FIXED_DOS_TIME = 0
FIXED_DOS_DATE = 33  # 1980-01-01
CREATE_VERSION = 20  # Unix zip format 2.0
EXTRACT_VERSION = 20
CREATE_SYSTEM_UNIX = 3
VERSION_MADE_BY = (CREATE_SYSTEM_UNIX << 8) | CREATE_VERSION
GENERAL_PURPOSE_FLAG = 0
COMPRESSION_STORED = 0


def git_mode_to_unix(mode: str) -> int:
    if mode == "100755":
        return 0o755
    if mode == "100644":
        return 0o644
    raise ValueError(f"unsupported git mode for zip: {mode}")


def unix_mode_to_external_attr(unix_mode: int) -> int:
    return (unix_mode & 0xFFFF) << 16


def crc32(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF


def write_deterministic_zip(members: list[dict], output_path: Path) -> None:
    """
    members: list of {"path": "slug/file.php", "mode": "100644", "data": bytes}
    paths must use forward slashes and be sorted lexicographically by path.
    """
    sorted_members = sorted(members, key=lambda m: m["path"])
    paths = [m["path"] for m in sorted_members]
    if paths != sorted(paths):
        raise ValueError("member paths must be sorted lexicographically")

    local_records: list[bytes] = []
    central_records: list[bytes] = []
    offset = 0

    for member in sorted_members:
        path_str = member["path"]
        path_bytes = path_str.encode("utf-8")
        if b"\0" in path_bytes:
            raise ValueError(f"NUL in zip path: {path_str}")
        data = member["data"]
        if not isinstance(data, (bytes, bytearray)):
            raise TypeError("member data must be bytes")
        unix_mode = git_mode_to_unix(str(member["mode"]))
        external_attr = unix_mode_to_external_attr(unix_mode)
        comp_size = len(data)
        uncomp_size = comp_size
        crc = crc32(data)

        local_header = struct.pack(
            "<IHHHHHIIIHH",
            0x04034B50,
            EXTRACT_VERSION,
            GENERAL_PURPOSE_FLAG,
            COMPRESSION_STORED,
            FIXED_DOS_TIME,
            FIXED_DOS_DATE,
            crc,
            comp_size,
            uncomp_size,
            len(path_bytes),
            0,
        )
        local_record = local_header + path_bytes + data
        local_records.append(local_record)

        central_header = struct.pack(
            "<IHHHHHHIIIHHHHHII",
            0x02014B50,
            VERSION_MADE_BY,
            EXTRACT_VERSION,
            GENERAL_PURPOSE_FLAG,
            COMPRESSION_STORED,
            FIXED_DOS_TIME,
            FIXED_DOS_DATE,
            crc,
            comp_size,
            uncomp_size,
            len(path_bytes),
            0,
            0,
            0,
            0,
            external_attr,
            offset,
        )
        central_records.append(central_header + path_bytes)
        offset += len(local_record)

    central_dir = b"".join(central_records)
    local_data = b"".join(local_records)
    end_record = struct.pack(
        "<IHHHHIIH",
        0x06054B50,
        0,
        0,
        len(sorted_members),
        len(sorted_members),
        len(central_dir),
        len(local_data),
        0,
    )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(local_data + central_dir + end_record)


def load_members_manifest(manifest_path: Path) -> list[dict]:
    raw = manifest_path.read_text(encoding="utf-8")
    entries = json.loads(raw)
    members: list[dict] = []
    for entry in entries:
        rel = entry["path"]
        mode = entry["mode"]
        file_path = Path(entry["file"])
        data = file_path.read_bytes()
        members.append({"path": rel, "mode": mode, "data": data})
    return members


def main() -> int:
    parser = argparse.ArgumentParser(description="Build deterministic WordPress plugin ZIP")
    parser.add_argument("--output", required=True, help="Output .zip path")
    parser.add_argument(
        "--members-json",
        required=True,
        help="JSON list of {path, mode, file} where path is archive member path",
    )
    args = parser.parse_args()
    members = load_members_manifest(Path(args.members_json))
    write_deterministic_zip(members, Path(args.output))
    return 0


if __name__ == "__main__":
    sys.exit(main())
