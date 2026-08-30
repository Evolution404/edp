#!/usr/bin/env python3
import argparse
import os
from pathlib import Path

SECTOR_SIZE = 512
BOOT_START_SECTOR = 63


def write_at(handle, offset: int, data: bytes) -> None:
    handle.seek(offset)
    handle.write(data)


def make_mbr(start_sector: int, sector_count: int) -> bytes:
    if not (0 < start_sector <= 0xFFFFFFFF and 0 < sector_count <= 0xFFFFFFFF):
        raise ValueError("boot MBR geometry exceeds 32-bit fields")
    mbr = bytearray(SECTOR_SIZE)
    entry = 0x1BE
    mbr[entry + 4] = 0x06  # FAT16
    mbr[entry + 8 : entry + 12] = start_sector.to_bytes(4, "little")
    mbr[entry + 12 : entry + 16] = sector_count.to_bytes(4, "little")
    mbr[510:512] = b"\x55\xaa"
    return bytes(mbr)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture-dir", required=True)
    parser.add_argument("--boot-volume", required=True)
    parser.add_argument("--device-size", required=True, type=int)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    fixture = Path(args.fixture_dir)
    boot_volume = Path(args.boot_volume)
    output = Path(args.output)
    boot_size = boot_volume.stat().st_size
    if boot_size <= 0 or boot_size % SECTOR_SIZE:
        raise SystemExit("boot volume must be positive and sector aligned")
    boot_sectors = boot_size // SECTOR_SIZE
    boot_offset = BOOT_START_SECTOR * SECTOR_SIZE
    if boot_offset + boot_size > args.device_size:
        raise SystemExit("boot volume exceeds declared EDP device")

    metadata = {
        4: (fixture / "LBA4.bin").read_bytes(),
        7: (fixture / "LBA7.bin").read_bytes(),
        11: (fixture / "LBA11.bin").read_bytes(),
        12: (fixture / "LBA12.bin").read_bytes(),
    }
    if any(len(value) != SECTOR_SIZE for value in metadata.values()):
        raise SystemExit("LBA4/LBA7/LBA11/LBA12 must all be 512 bytes")

    output.unlink(missing_ok=True)
    with output.open("wb+") as handle:
        handle.truncate(args.device_size)
        write_at(handle, 0, make_mbr(BOOT_START_SECTOR, boot_sectors))
        for lba, data in metadata.items():
            write_at(handle, lba * SECTOR_SIZE, data)
        with boot_volume.open("rb") as source:
            handle.seek(boot_offset)
            while True:
                chunk = source.read(1024 * 1024)
                if not chunk:
                    break
                handle.write(chunk)
        handle.flush()
        os.fsync(handle.fileno())

    print(f"PREPARED_BOOT_START_SECTOR={BOOT_START_SECTOR}")
    print(f"PREPARED_BOOT_SIZE_BYTES={boot_size}")
    print(f"PREPARED_DEVICE_SIZE_BYTES={args.device_size}")
    print("RESULT=EDP_BOOT_FILESYSTEM_FIXTURE_READY")


if __name__ == "__main__":
    main()
