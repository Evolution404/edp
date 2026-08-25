# Real EDP data fixture capture on macOS 15.x

Date: 2026-08-25

## Purpose

`CaptureEDPDataFixture.swift` turns an existing macOS 15.x machine into a read-only evidence collector for the native Swift EDP core. It does **not** use FSKit, macFUSE, a helper daemon, or any write operation against the USB device.

The goal is to obtain a small paired sample from a real EDP data partition:

```text
real raw EDP disk
  -> LBA11 / LBA12 metadata
  -> native Swift key derivation
  -> real encrypted partition bytes
  -> native Swift SM4 translation
  -> matching plaintext bytes
```

This closes the gap between the existing real-key/synthetic-ciphertext CI tests and true data-area ciphertext captured from a physical EDP disk.

## Safety boundary

- The source device is opened `O_RDONLY` and only `pread` is used.
- The tool never writes to the source disk.
- The EDP password and derived file key are not written to the capture directory.
- When `EDP_PASSWORD` is absent, the password is requested interactively without terminal echo.
- The default capture size is 64 KiB and the maximum accepted size is 8 MiB.
- Local capture output should go under `.edp-captures/`, which is ignored by Git.
- **Do not commit a real plaintext capture to this public repository until its contents have been reviewed.** Use a test EDP disk containing no sensitive files whenever possible.

## Build on the macOS 15.7.9 machine

From the repository root:

```bash
bash native/EDPFSKitPoC/Tools/build-capture-tool.sh
```

The builder targets macOS 15.0 by default and writes:

```text
artifacts/native/CaptureEDPDataFixture
```

CI also compiles this exact tool graph with an `arm64-apple-macosx15.0` deployment target, so accidental use of macOS 26-only APIs is caught before the tool is used on the physical 15.7.9 Mac.

## Collect the required disk parameters

Identify the whole EDP USB disk first:

```bash
diskutil list external physical
```

Assume the result is `disk4`. Save its metadata without changing the disk:

```bash
diskutil info -plist /dev/disk4 > /tmp/edp-disk-info.plist
/usr/libexec/PlistBuddy -c 'Print :TotalSize' /tmp/edp-disk-info.plist
```

Record the USB vendor ID and product ID from System Information or `ioreg`. They must correspond to the physical EDP device because LBA11 device identity derivation includes VID, PID, and disk size.

Prefer the raw character device for the capture:

```text
/dev/rdisk4
```

Raw-device access normally requires administrator privileges on macOS.

## Capture

Create a local ignored output directory:

```bash
mkdir -p .edp-captures/disk4-data-head
```

Then run the tool. Replace the example VID, PID, disk size, and BSD disk number with the values for the attached device:

```bash
sudo artifacts/native/CaptureEDPDataFixture \
  /dev/rdisk4 \
  21c4 \
  0cd1 \
  124736503808 \
  .edp-captures/disk4-data-head \
  2 \
  65536
```

The tool asks for the EDP password without echo. For non-interactive automation only, `EDP_PASSWORD` may be supplied in the environment instead.

Partition type defaults to `2`; type `4` can be selected explicitly. Capture length defaults to 65536 bytes and must be a multiple of 16.

## Output

A successful capture produces:

```text
LBA11.bin
LBA12.bin
LBA12.plain.bin
data-head.cipher.bin
data-head.plain.bin
manifest.json
```

The manifest records disk identity inputs, selected partition geometry, algorithm, and capture length. It explicitly records that password/file-key secrets were not written.

Expected terminal markers include:

```text
CAPTURE_PARTITION_TYPE=2
CAPTURE_BYTES=65536
CAPTURE_SECRETS_WRITTEN=false
RESULT=EDP_REAL_DATA_FIXTURE_CAPTURED
```

## What to return for analysis

The best evidence set is the entire capture directory **after reviewing `data-head.plain.bin` for sensitive content**. If the plaintext cannot be shared, keep it local and provide at minimum `manifest.json`, LBA11/LBA12, and a local hash comparison result. A dedicated non-sensitive test EDP disk is strongly preferred because it lets the real cipher/plain pair become a permanent regression fixture.
