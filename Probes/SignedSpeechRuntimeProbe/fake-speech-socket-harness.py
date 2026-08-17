#!/usr/bin/env python3
"""Serve one deterministic protocol-v2 selftest response on a temporary socket."""

import argparse
import json
import os
import socket
import struct
import sys

EXPECTED_VALUE = "wilted-swift"


def progress(message: str) -> None:
    print(f"stage=fake-harness.{message}", file=sys.stderr, flush=True)


def read_exact(connection: socket.socket, count: int) -> bytes:
    chunks = []
    remaining = count
    while remaining:
        chunk = connection.recv(remaining)
        if not chunk:
            raise RuntimeError("client closed before the complete frame arrived")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def frame(frame_type: int, payload: bytes) -> bytes:
    body = bytes([frame_type]) + payload
    return struct.pack(">I", len(body)) + body


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--ready-file", required=True)
    args = parser.parse_args()

    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        listener.bind(args.socket)
        os.chmod(args.socket, 0o600)
        listener.listen(1)
        with open(args.ready_file, "w", encoding="utf-8") as ready:
            ready.write("ready\n")
        progress("ready")
        listener.settimeout(10.0)
        connection, _ = listener.accept()
        with connection:
            progress("request")
            body_length = struct.unpack(">I", read_exact(connection, 4))[0]
            if body_length < 1 or body_length > 64 * 1024 * 1024:
                raise RuntimeError("invalid frame length")
            body = read_exact(connection, body_length)
            if body[0] != 1:
                raise RuntimeError("expected a request frame")
            request = json.loads(body[1:].decode("utf-8"))
            if (
                request.get("protocol_version") != 2
                or request.get("kind") != "selftest"
                or request.get("params") != {"action": "echo", "value": EXPECTED_VALUE}
            ):
                raise RuntimeError("request was not the exact protocol-v2 selftest")
            response = json.dumps(
                {"result": {"value": EXPECTED_VALUE}},
                separators=(",", ":"),
            ).encode("utf-8")
            connection.sendall(frame(2, response))
            progress("response")
        return 0
    except Exception as error:  # pragma: no cover - exercised through the shell probe
        print(f"fake socket harness failed: {error}", file=sys.stderr, flush=True)
        return 1
    finally:
        listener.close()
        try:
            os.unlink(args.socket)
        except FileNotFoundError:
            pass
        try:
            os.unlink(args.ready_file)
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
