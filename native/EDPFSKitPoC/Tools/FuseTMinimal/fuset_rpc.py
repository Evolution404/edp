#!/usr/bin/env python3
"""Minimal, dependency-free helpers for the FUSE-T FSKit RPC experiment.

This is PoC-only code.  It deliberately does not mount anything and does not
encode guessed filesystem-operation response schemas.  Its job is to make the
parts already proven on macOS reproducible in CI:

* 8-byte big-endian frame header (metadata length, payload length)
* JSON metadata + optional binary payload
* request_id/method validation
* handshake response contract
* fixed-size backing reads with strict EOF semantics

The operation-specific schema is added only after it has been extracted from
FUSE-T 1.2.7 and/or captured from a real FskitSrvModule request.
"""

from __future__ import annotations

import argparse
import io
import json
import os
import struct
import tempfile
import unittest
from dataclasses import dataclass
from typing import BinaryIO, Any

MAX_COMPONENT_BYTES = 16 * 1024 * 1024
_HEADER = struct.Struct(">II")


class ProtocolError(RuntimeError):
    pass


@dataclass(frozen=True)
class RPCFrame:
    metadata: dict[str, Any]
    payload: bytes = b""


def _read_exact(stream: BinaryIO, length: int) -> bytes:
    if length < 0:
        raise ProtocolError("negative frame length")
    chunks: list[bytes] = []
    remaining = length
    while remaining:
        chunk = stream.read(remaining)
        if not chunk:
            raise EOFError(f"unexpected EOF with {remaining} bytes remaining")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def encode_frame(frame: RPCFrame) -> bytes:
    metadata_bytes = json.dumps(
        frame.metadata,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    payload = bytes(frame.payload)
    _validate_lengths(len(metadata_bytes), len(payload))
    return _HEADER.pack(len(metadata_bytes), len(payload)) + metadata_bytes + payload


def read_frame(stream: BinaryIO) -> RPCFrame:
    header = _read_exact(stream, _HEADER.size)
    metadata_length, payload_length = _HEADER.unpack(header)
    _validate_lengths(metadata_length, payload_length)
    metadata_bytes = _read_exact(stream, metadata_length)
    payload = _read_exact(stream, payload_length)
    try:
        metadata = json.loads(metadata_bytes.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProtocolError(f"invalid JSON metadata: {exc}") from exc
    if not isinstance(metadata, dict):
        raise ProtocolError("metadata must be a JSON object")
    return RPCFrame(metadata=metadata, payload=payload)


def write_frame(stream: BinaryIO, frame: RPCFrame) -> None:
    encoded = encode_frame(frame)
    view = memoryview(encoded)
    while view:
        written = stream.write(view)
        if written is None:
            # Buffered streams are allowed to return None while accepting all
            # data.  This matches BinaryIO.write's documented contract.
            break
        if written <= 0:
            raise ProtocolError("frame write made no progress")
        view = view[written:]
    if hasattr(stream, "flush"):
        stream.flush()


def _validate_lengths(metadata_length: int, payload_length: int) -> None:
    if metadata_length > MAX_COMPONENT_BYTES:
        raise ProtocolError("metadata exceeds 16 MiB contract limit")
    if payload_length > MAX_COMPONENT_BYTES:
        raise ProtocolError("payload exceeds 16 MiB contract limit")
    if metadata_length + payload_length > MAX_COMPONENT_BYTES:
        raise ProtocolError("combined frame exceeds 16 MiB contract limit")


def validate_request(frame: RPCFrame) -> tuple[int, str]:
    request_id = frame.metadata.get("request_id")
    method = frame.metadata.get("method")
    if not isinstance(request_id, int) or isinstance(request_id, bool) or request_id < 0:
        raise ProtocolError("request_id must be a non-negative integer")
    if not isinstance(method, str) or not method:
        raise ProtocolError("method must be a non-empty string")
    return request_id, method


def handshake_response(request: RPCFrame, *, session_id: str, auth_token: str) -> RPCFrame:
    request_id, method = validate_request(request)
    if method != "handshake":
        raise ProtocolError(f"expected handshake, got {method!r}")
    supplied_token = request.metadata.get("auth_token")
    if supplied_token != auth_token:
        return error_response(request_id, errno_value=13, message="authentication failed")
    return RPCFrame(
        metadata={
            "request_id": request_id,
            "ok": True,
            "session_id": session_id,
        }
    )


def ok_response(request_id: int, **fields: Any) -> RPCFrame:
    metadata: dict[str, Any] = {"request_id": request_id, "ok": True}
    metadata.update(fields)
    return RPCFrame(metadata=metadata)


def error_response(request_id: int, *, errno_value: int, message: str) -> RPCFrame:
    return RPCFrame(
        metadata={
            "request_id": request_id,
            "ok": False,
            "errno": int(errno_value),
            "message": message,
        }
    )


class FixedBacking:
    """Read-only backing used by the future /volume.raw node.

    It guarantees the Phase-D invariant: offset < size never produces an
    artificial zero-byte read.  EOF is represented only by offset >= size.
    """

    def __init__(self, path: str):
        self.path = path
        self.size = os.stat(path).st_size

    def pread(self, offset: int, length: int) -> bytes:
        if offset < 0 or length < 0:
            raise ValueError("offset and length must be non-negative")
        if offset >= self.size or length == 0:
            return b""
        wanted = min(length, self.size - offset)
        fd = os.open(self.path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
        try:
            data = os.pread(fd, wanted, offset)
        finally:
            os.close(fd)
        if len(data) != wanted:
            raise OSError(
                f"short backing read at offset={offset}: expected {wanted}, got {len(data)}"
            )
        return data


class ContractTests(unittest.TestCase):
    def test_frame_round_trip_with_binary_payload(self) -> None:
        original = RPCFrame(
            metadata={"request_id": 7, "method": "read_file", "offset": 4096},
            payload=b"\x00\x01\xffpayload",
        )
        decoded = read_frame(io.BytesIO(encode_frame(original)))
        self.assertEqual(decoded, original)

    def test_header_is_big_endian_lengths(self) -> None:
        encoded = encode_frame(RPCFrame(metadata={"x": 1}, payload=b"abc"))
        metadata_length, payload_length = _HEADER.unpack(encoded[:8])
        self.assertEqual(payload_length, 3)
        self.assertEqual(metadata_length, len(b'{"x":1}'))

    def test_combined_size_limit_is_fail_closed(self) -> None:
        with self.assertRaises(ProtocolError):
            encode_frame(
                RPCFrame(
                    metadata={"x": "a" * (MAX_COMPONENT_BYTES - 32)},
                    payload=b"b" * 64,
                )
            )

    def test_handshake_requires_matching_token_and_returns_session(self) -> None:
        request = RPCFrame(
            metadata={"request_id": 1, "method": "handshake", "auth_token": "secret"}
        )
        response = handshake_response(request, session_id="session-1", auth_token="secret")
        self.assertEqual(
            response.metadata,
            {"request_id": 1, "ok": True, "session_id": "session-1"},
        )

    def test_handshake_rejects_wrong_token(self) -> None:
        request = RPCFrame(
            metadata={"request_id": 1, "method": "handshake", "auth_token": "wrong"}
        )
        response = handshake_response(request, session_id="session-1", auth_token="secret")
        self.assertFalse(response.metadata["ok"])
        self.assertEqual(response.metadata["errno"], 13)

    def test_fixed_backing_random_reads_and_eof(self) -> None:
        content = bytes((i * 17 + 3) % 256 for i in range(8193))
        with tempfile.NamedTemporaryFile() as fixture:
            fixture.write(content)
            fixture.flush()
            backing = FixedBacking(fixture.name)
            self.assertEqual(backing.size, len(content))
            for offset, length in ((0, 1), (1, 31), (4095, 4097), (8192, 64)):
                self.assertEqual(backing.pread(offset, length), content[offset : offset + length])
            self.assertEqual(backing.pread(len(content), 1), b"")
            self.assertEqual(backing.pread(len(content) + 100, 1024), b"")


def _main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true", help="run contract tests")
    args = parser.parse_args()
    if args.self_test:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(ContractTests)
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        return 0 if result.wasSuccessful() else 1
    parser.print_help()
    return 2


if __name__ == "__main__":
    raise SystemExit(_main())
