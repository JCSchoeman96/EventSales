#!/usr/bin/env python3
"""Probe one of the locked, loopback-only workstation Redis endpoints."""

from __future__ import annotations

import os
import socket
import sys
from urllib.parse import unquote, urlsplit


ALLOWED_PORTS = {56379, 56380}


class RedisProtocolError(Exception):
    pass


def encode_command(*parts: str) -> bytes:
    encoded = [part.encode() for part in parts]
    result = [f"*{len(encoded)}\r\n".encode()]
    for part in encoded:
        result.extend((f"${len(part)}\r\n".encode(), part, b"\r\n"))
    return b"".join(result)


def read_response(stream):
    prefix = stream.read(1)
    line = stream.readline()
    if not prefix or not line.endswith(b"\r\n"):
        raise RedisProtocolError

    value = line[:-2]
    if prefix == b"+":
        return value.decode()
    if prefix == b"-":
        raise RedisProtocolError
    if prefix == b":":
        return int(value)
    if prefix == b"$":
        length = int(value)
        if length == -1:
            return None
        payload = stream.read(length + 2)
        if len(payload) != length + 2 or not payload.endswith(b"\r\n"):
            raise RedisProtocolError
        return payload[:-2]
    if prefix == b"*":
        length = int(value)
        if length == -1:
            return None
        return [read_response(stream) for _ in range(length)]
    raise RedisProtocolError


def command(sock: socket.socket, stream, *parts: str):
    sock.sendall(encode_command(*parts))
    return read_response(stream)


def probe(expected_port: int, check: str) -> str:
    if expected_port not in ALLOWED_PORTS or check not in {"ping", "version"}:
        raise ValueError

    parsed = urlsplit(os.environ["EVENTSALES_REDIS_PROBE_URL"])
    if (
        parsed.scheme != "redis"
        or parsed.hostname != "127.0.0.1"
        or parsed.port != expected_port
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError

    database = parsed.path.removeprefix("/")
    if not database.isdigit():
        raise ValueError

    with socket.create_connection(("127.0.0.1", expected_port), timeout=3) as sock:
        sock.settimeout(3)
        with sock.makefile("rb") as stream:
            username = unquote(parsed.username) if parsed.username is not None else None
            password = unquote(parsed.password) if parsed.password is not None else None

            if password is not None:
                if username:
                    auth_reply = command(sock, stream, "AUTH", username, password)
                else:
                    auth_reply = command(sock, stream, "AUTH", password)
                if auth_reply != "OK":
                    raise RedisProtocolError

            if database != "0":
                select_reply = command(sock, stream, "SELECT", database)
                if select_reply != "OK":
                    raise RedisProtocolError

            if check == "ping":
                reply = command(sock, stream, "PING")
                if reply != "PONG":
                    raise RedisProtocolError
                return "PONG"

            info = command(sock, stream, "INFO", "server")
            if not isinstance(info, bytes):
                raise RedisProtocolError
            for line in info.decode().splitlines():
                if line.startswith("redis_version:"):
                    return line.partition(":")[2].split(".", 1)[0]
            raise RedisProtocolError


def main() -> int:
    try:
        if len(sys.argv) != 3:
            raise ValueError
        result = probe(int(sys.argv[1]), sys.argv[2])
    except (KeyError, OSError, ValueError, RedisProtocolError, UnicodeError):
        print("Redis probe failed", file=sys.stderr)
        return 1

    print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
