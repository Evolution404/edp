#!/usr/bin/env python3
import argparse
import hashlib
import os
import random
from pathlib import Path


def fsync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write_and_sync(path: Path, data: bytes) -> None:
    with path.open("wb", buffering=0) as handle:
        handle.write(data)
        os.fsync(handle.fileno())


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def deterministic_block(block_index: int, size: int = 4096) -> bytes:
    return bytes(((block_index * 23 + offset * 41 + 7) & 0xFF) for offset in range(size))


def run_core(root: Path) -> None:
    root.mkdir(parents=True, exist_ok=True)

    # M02: create -> write -> fsync -> read -> hash. Full remount verification is
    # performed by the shell harness after the transport and DiskImages2 device
    # are both recreated.
    proof = root / "m02-exchange-proof.bin"
    expected = b"".join(deterministic_block(block) for block in range(1024))
    write_and_sync(proof, expected)
    fsync_dir(root)
    if proof.read_bytes() != expected:
        raise RuntimeError("M02 immediate readback mismatch")
    proof_hash = sha256_file(proof)
    print(f"M02_SHA256={proof_hash}")
    print("SCENARIO=M02_STAGE1_OK exchange_create_write_fsync_read_hash")

    # M04: Finder/TextEdit-style atomic save over an existing target.
    atomic_target = root / "m04-atomic.txt"
    write_and_sync(atomic_target, b"old-content")
    atomic_temp = root / ".m04-atomic.txt.tmp"
    write_and_sync(atomic_temp, "new-content-原子保存".encode("utf-8"))
    os.replace(atomic_temp, atomic_target)
    fsync_dir(root)
    if atomic_target.read_text(encoding="utf-8") != "new-content-原子保存":
        raise RuntimeError("M04 atomic replacement mismatch")
    print("SCENARIO=M04_OK finder_atomic_save_pattern")

    # M05: batch create/delete equivalent to Finder multi-selection delete.
    batch = root / "m05-batch"
    batch.mkdir(exist_ok=True)
    intended = [batch / f"item-{index:02d}.dat" for index in range(32)]
    for index, path in enumerate(intended):
        write_and_sync(path, deterministic_block(index, 1024))
    for path in intended:
        path.unlink()
    fsync_dir(batch)
    if any(path.exists() for path in intended):
        raise RuntimeError("M05 batch delete left requested files behind")
    for metadata in list(batch.iterdir()):
        metadata.unlink(missing_ok=True)
    batch.rmdir()
    print("SCENARIO=M05_OK multiple_file_delete")

    # M06: file rename, directory rename and overwrite semantics.
    rename_root = root / "m06-source-dir"
    rename_root.mkdir(exist_ok=True)
    source = rename_root / "source.txt"
    destination = rename_root / "destination.txt"
    write_and_sync(source, b"source-value")
    write_and_sync(destination, b"destination-old")
    os.replace(source, destination)
    if destination.read_bytes() != b"source-value":
        raise RuntimeError("M06 overwrite rename mismatch")
    renamed_root = root / "m06-renamed-dir"
    os.replace(rename_root, renamed_root)
    fsync_dir(root)
    if not (renamed_root / "destination.txt").is_file():
        raise RuntimeError("M06 directory rename mismatch")
    print("SCENARIO=M06_OK rename_file_directory_overwrite")

    # M07: Unicode, spaces and emoji.
    unicode_path = root / "M07 中文 文件 🚀.txt"
    unicode_payload = "南京 EDP 存储回归 ✅".encode("utf-8")
    write_and_sync(unicode_path, unicode_payload)
    if unicode_path.read_bytes() != unicode_payload:
        raise RuntimeError("M07 Unicode filename readback mismatch")
    print("SCENARIO=M07_OK unicode_filename")

    # M08: 128 MiB sequential write + hash readback.
    large_path = root / "m08-large-sequential.bin"
    expected_hash = hashlib.sha256()
    with large_path.open("wb", buffering=0) as handle:
        for block in range((128 * 1024 * 1024) // (1024 * 1024)):
            seed = hashlib.sha256(f"edp-m08-{block}".encode()).digest()
            chunk = (seed * ((1024 * 1024 + len(seed) - 1) // len(seed)))[: 1024 * 1024]
            handle.write(chunk)
            expected_hash.update(chunk)
        os.fsync(handle.fileno())
    if sha256_file(large_path) != expected_hash.hexdigest():
        raise RuntimeError("M08 large sequential hash mismatch")
    print("SCENARIO=M08_OK large_sequential_128MiB")

    # M09: fixed-seed random block-range writes and reads.
    random_path = root / "m09-random-io.bin"
    size = 16 * 1024 * 1024
    expected_random = bytearray(size)
    write_and_sync(random_path, expected_random)
    rng = random.Random(0xED20260830)
    fd = os.open(random_path, os.O_RDWR)
    try:
        for operation in range(2500):
            length = rng.choice((16, 64, 512, 4096, 16384))
            offset = rng.randrange(0, size - length + 1)
            payload = bytes(rng.randrange(0, 256) for _ in range(length))
            written = os.pwrite(fd, payload, offset)
            if written != length:
                raise RuntimeError(f"M09 short pwrite at operation {operation}")
            expected_random[offset : offset + length] = payload
            if operation % 17 == 0:
                probe_length = rng.choice((16, 512, 4096))
                probe_offset = rng.randrange(0, size - probe_length + 1)
                actual = os.pread(fd, probe_length, probe_offset)
                if actual != bytes(expected_random[probe_offset : probe_offset + probe_length]):
                    raise RuntimeError(f"M09 random read mismatch at operation {operation}")
        os.fsync(fd)
    finally:
        os.close(fd)
    if random_path.read_bytes() != bytes(expected_random):
        raise RuntimeError("M09 final random I/O image mismatch")
    print("SCENARIO=M09_OK fixed_seed_random_io_2500")


def run_secure(root: Path) -> None:
    proof = root / "m03-secure-proof.bin"
    payload = b"".join(deterministic_block(block + 2048) for block in range(512))
    write_and_sync(proof, payload)
    fsync_dir(root)
    if proof.read_bytes() != payload:
        raise RuntimeError("M03 immediate secure readback mismatch")
    proof_hash = sha256_file(proof)
    print(f"M03_SHA256={proof_hash}")
    print("SCENARIO=M03_STAGE1_OK secure_create_write_fsync_read_hash")


def verify_secure_remount(root: Path, expected_hash: str) -> None:
    proof = root / "m03-secure-proof.bin"
    actual = sha256_file(proof)
    if actual != expected_hash:
        raise RuntimeError(f"M03 remount hash mismatch: expected={expected_hash} actual={actual}")
    print("SCENARIO=M03_OK secure_full_remount_hash")


def verify_remount(root: Path, expected_hash: str) -> None:
    proof = root / "m02-exchange-proof.bin"
    actual = sha256_file(proof)
    if actual != expected_hash:
        raise RuntimeError(f"M02 remount hash mismatch: expected={expected_hash} actual={actual}")
    if (root / "m04-atomic.txt").read_text(encoding="utf-8") != "new-content-原子保存":
        raise RuntimeError("M04 content did not survive remount")
    if not (root / "M07 中文 文件 🚀.txt").is_file():
        raise RuntimeError("M07 Unicode file did not survive remount")
    print("SCENARIO=M02_OK exchange_full_remount_hash")
    print("RESULT=STORAGE_REMOUNT_PERSISTENCE_OK")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("core", "secure", "verify-remount", "verify-secure-remount"))
    parser.add_argument("mountpoint")
    parser.add_argument("expected_hash", nargs="?")
    args = parser.parse_args()
    root = Path(args.mountpoint)
    if args.mode == "core":
        run_core(root)
    elif args.mode == "secure":
        run_secure(root)
    elif args.mode == "verify-remount":
        if not args.expected_hash:
            parser.error("verify-remount requires expected_hash")
        verify_remount(root, args.expected_hash)
    else:
        if not args.expected_hash:
            parser.error("verify-secure-remount requires expected_hash")
        verify_secure_remount(root, args.expected_hash)


if __name__ == "__main__":
    main()
