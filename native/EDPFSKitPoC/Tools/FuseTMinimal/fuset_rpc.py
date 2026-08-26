#!/usr/bin/env python3
"""Minimal, dependency-free helpers for the FUSE-T FSKit bridge experiment.

This PoC intentionally contains only protocol pieces that have been observed on
FUSE-T 1.2.7 or are local fail-closed invariants.  It does not guess directory,
lookup-item, xattr, or statfs response shapes that have not yet been captured.

Observed contract currently encoded here:

* 8-byte big-endian frame header (metadata length, payload length)
* JSON metadata + optional raw binary payload
* request_id/method validation
* handshake response requires ok=true + matching session_id
* open {node_id, open_modes} -> handle_id
* read {node_id, offset, length} -> ok metadata + raw frame payload
* close {node_id, keeping_modes} -> ok metadata
* fixed-size backing reads with strict EOF semantics
* known mutation methods fail closed with EROFS
"""

from __future__ import annotations

import argparse
import errno
import hashlib
import io
import json
import os
import struct
import tempfile
import unittest
from dataclasses import dataclass
from typing import Any, BinaryIO

MAX_COMPONENT_BYTES = 16 * 1024 * 1024
_HEADER = struct.Struct(">II")
VOLUME_RAW_NODE_ID = 2
VOLUME_RAW_HANDLE_ID = 1

# Method spellings are taken from FUSE-T 1.2.7 binary strings.  This list is a
# fail-closed guard, not a claim that every method has already been exercised by
# FskitSrvModule in the EDP PoC.
READ_ONLY_MUTATION_METHODS = frozenset(
    {
        "create",
        "create_directory",
        "create_symlink",
        "remove",
        "remove_directory",
        "remove_xattr",
        "rename",
        "set_attributes",
        "set_xattr",
        "truncate",
        "write",
    }
)


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
        return error_response(request_id, errno_value=errno.EACCES, message="authentication failed")
    return RPCFrame(
        metadata={
            "request_id": request_id,
            "ok": True,
            "session_id": session_id,
        }
    )


def ok_response(request_id: int, *, payload: bytes = b"", **fields: Any) -> RPCFrame:
    metadata: dict[str, Any] = {"request_id": request_id, "ok": True}
    metadata.update(fields)
    return RPCFrame(metadata=metadata, payload=payload)


def error_response(request_id: int, *, errno_value: int, message: str) -> RPCFrame:
    return RPCFrame(
        metadata={
            "request_id": request_id,
            "ok": False,
            "errno": int(errno_value),
            "message": message,
        }
    )


def _required_nonnegative_int(metadata: dict[str, Any], key: str) -> int:
    value = metadata.get(key)
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise ProtocolError(f"{key} must be a non-negative integer")
    return value


class FixedBacking:
    """Read-only backing for the hidden /volume.raw node."""

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


class VolumeRawBackend:
    """Observed single-file open/read/close contract plus fail-closed mutations.

    lookup/getattr/directory response schemas intentionally remain outside this
    class until their complete metadata shapes are captured and checked in.
    """

    def __init__(self, backing: FixedBacking):
        self.backing = backing

    def handle(self, request: RPCFrame) -> RPCFrame:
        request_id, method = validate_request(request)

        if method == "ping":
            return ok_response(request_id)
        if method in READ_ONLY_MUTATION_METHODS:
            return error_response(request_id, errno_value=errno.EROFS, message="read-only filesystem")
        if method == "open":
            return self._open(request_id, request.metadata)
        if method == "read":
            return self._read(request_id, request.metadata)
        if method == "close":
            return self._close(request_id, request.metadata)
        return error_response(request_id, errno_value=errno.ENOSYS, message=f"unsupported method: {method}")

    def _open(self, request_id: int, metadata: dict[str, Any]) -> RPCFrame:
        node_id = _required_nonnegative_int(metadata, "node_id")
        _required_nonnegative_int(metadata, "open_modes")
        if node_id != VOLUME_RAW_NODE_ID:
            return error_response(request_id, errno_value=errno.ENOENT, message="unknown node")
        return ok_response(request_id, handle_id=VOLUME_RAW_HANDLE_ID)

    def _read(self, request_id: int, metadata: dict[str, Any]) -> RPCFrame:
        node_id = _required_nonnegative_int(metadata, "node_id")
        offset = _required_nonnegative_int(metadata, "offset")
        length = _required_nonnegative_int(metadata, "length")
        if node_id != VOLUME_RAW_NODE_ID:
            return error_response(request_id, errno_value=errno.ENOENT, message="unknown node")
        return ok_response(request_id, payload=self.backing.pread(offset, length))

    def _close(self, request_id: int, metadata: dict[str, Any]) -> RPCFrame:
        node_id = _required_nonnegative_int(metadata, "node_id")
        _required_nonnegative_int(metadata, "keeping_modes")
        if node_id != VOLUME_RAW_NODE_ID:
            return error_response(request_id, errno_value=errno.ENOENT, message="unknown node")
        return ok_response(request_id)


class ContractTests(unittest.TestCase):
    def test_frame_round_trip_with_binary_payload(self) -> None:
        original = RPCFrame(
            metadata={"request_id": 7, "method": "read", "offset": 4096},
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
        self.assertEqual(response.metadata["errno"], errno.EACCES)

    def _make_backend(self, fixture: tempfile.NamedTemporaryFile) -> tuple[bytes, VolumeRawBackend]:
        content = bytes((i * 17 + 3) % 256 for i in range(65537))
        fixture.write(content)
        fixture.flush()
        return content, VolumeRawBackend(FixedBacking(fixture.name))

    def test_observed_open_read_close_schema(self) -> None:
        with tempfile.NamedTemporaryFile() as fixture:
            content, backend = self._make_backend(fixture)
            opened = backend.handle(
                RPCFrame(metadata={"request_id": 10, "method": "open", "node_id": 2, "open_modes": 1})
            )
            self.assertEqual(opened.metadata, {"request_id": 10, "ok": True, "handle_id": 1})

            read = backend.handle(
                RPCFrame(metadata={"request_id": 11, "method": "read", "node_id": 2, "offset": 4095, "length": 4097})
            )
            self.assertEqual(read.metadata, {"request_id": 11, "ok": True})
            self.assertEqual(read.payload, content[4095 : 4095 + 4097])

            closed = backend.handle(
                RPCFrame(metadata={"request_id": 12, "method": "close", "node_id": 2, "keeping_modes": 0})
            )
            self.assertEqual(closed.metadata, {"request_id": 12, "ok": True})

    def test_random_read_boundary_matrix_and_strict_eof(self) -> None:
        with tempfile.NamedTemporaryFile() as fixture:
            content, backend = self._make_backend(fixture)
            cases = (
                (0, 1),
                (1, 31),
                (511, 2),
                (4095, 4097),
                (32767, 8192),
                (len(content) - 1, 65536),
                (len(content), 1),
                (len(content) + 100, 1024),
            )
            for request_id, (offset, length) in enumerate(cases, start=20):
                response = backend.handle(
                    RPCFrame(
                        metadata={
                            "request_id": request_id,
                            "method": "read",
                            "node_id": 2,
                            "offset": offset,
                            "length": length,
                        }
                    )
                )
                self.assertTrue(response.metadata["ok"])
                self.assertEqual(response.payload, content[offset : offset + length])
                if offset < len(content) and length > 0:
                    self.assertGreater(len(response.payload), 0)
                if offset >= len(content):
                    self.assertEqual(response.payload, b"")

    def test_full_backing_hash_via_chunked_rpc_reads(self) -> None:
        with tempfile.NamedTemporaryFile() as fixture:
            content, backend = self._make_backend(fixture)
            reconstructed = bytearray()
            offset = 0
            request_id = 100
            while offset < len(content):
                response = backend.handle(
                    RPCFrame(
                        metadata={
                            "request_id": request_id,
                            "method": "read",
                            "node_id": 2,
                            "offset": offset,
                            "length": 7777,
                        }
                    )
                )
                self.assertTrue(response.payload)
                reconstructed.extend(response.payload)
                offset += len(response.payload)
                request_id += 1
            self.assertEqual(len(reconstructed), len(content))
            self.assertEqual(hashlib.sha256(reconstructed).digest(), hashlib.sha256(content).digest())

    def test_mutations_fail_closed_with_erofs(self) -> None:
        with tempfile.NamedTemporaryFile() as fixture:
            _, backend = self._make_backend(fixture)
            for request_id, method in enumerate(sorted(READ_ONLY_MUTATION_METHODS), start=200):
                response = backend.handle(RPCFrame(metadata={"request_id": request_id, "method": method}))
                self.assertFalse(response.metadata["ok"])
                self.assertEqual(response.metadata["errno"], errno.EROFS)
                self.assertEqual(response.payload, b"")


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
