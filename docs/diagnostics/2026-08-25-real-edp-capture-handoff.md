# Real EDP USB capture / mount handoff — 2026-08-25

Branch: `feat/macos26-native-fskit`

This document is the handoff point for the next session that has working Mac access. Read `docs/STATUS.md` first for the authoritative architecture and evidence, then continue from here. Do not repeat already-completed macFUSE/DiskImages2 feasibility research.

## Current product direction

The accepted macOS 26+ product data path is:

```text
physical EDP USB
  -> raw device
  -> LBA11/LBA12 + password validation + file-key derivation
  -> Swift SM4 transparent block translation
  -> EDPBlockReadable (later writable)
  -> macFUSE 5.x backend=fskit
  -> hidden FUSE mount exposing volume.raw
  -> Private DiskImages2
  -> AppleDiskImages / IOMedia / /dev/diskN
  -> Disk Arbitration
  -> Apple native filesystem
  -> Finder
```

Do not reintroduce a custom exFAT/FAT/APFS/NTFS implementation. EDP code owns only metadata, password/key handling, crypto, and offset/length block translation.

## What is already proven

### Structural bridge

GitHub Actions run `32848875297` proved:

```text
macFUSE 5.3.3 backend=fskit
-> volume.raw
-> Private DiskImages2
-> /dev/disk8
-> Apple native ExFAT
-> real read/write
```

Final marker:

```text
RESULT=MACFUSE_FSKIT_DISKIMAGES2_NATIVE_FS_E2E_OK
```

### Swift crypto read path

GitHub Actions run `32851503960` proved:

```text
cipher image
-> EDPFileRawDevice
-> EDPEncryptedPartitionReader
-> EDPEncryptedReadOnlyBlockDevice
-> macFUSE backend=fskit
-> Private DiskImages2 --readonly
-> Apple native filesystem
```

The native filesystem successfully read the expected files and a 4 MiB payload with matching SHA-256. Final marker:

```text
RESULT=EDP_CRYPTO_MACFUSE_DISKIMAGES2_NATIVE_FS_READ_E2E_OK
```

This proves the crypto path and block bridge, but the encrypted filesystem image was synthetic. It does **not** yet prove a physical EDP USB mounts in Finder.

## Latest repository state

At handoff creation, the branch already contains commit:

```text
ad951e44d89cbaea48af657246cc016fb12a9740
feat: add one-command real EDP capture
```

New entry point:

```text
scripts/capture-real-edp.sh
```

The script is designed to:

- discover an external physical whole disk, or accept `diskN` explicitly;
- obtain device size from `diskutil`;
- resolve USB VID/PID from IORegistry;
- use `/dev/rdiskN` for raw reads;
- build `CaptureEDPDataFixture`;
- ask for the EDP password locally without echo;
- capture LBA11/LBA12 and the first 1 MiB of the selected encrypted partition;
- write results under `.edp-captures/<timestamp>-diskN/`;
- never format, mount, unmount, or write the physical USB disk.

Typical invocation from repository root:

```bash
./scripts/capture-real-edp.sh
```

If more than one external physical disk is connected:

```bash
./scripts/capture-real-edp.sh diskN
```

Expected final marker:

```text
RESULT=EDP_ONE_COMMAND_REAL_CAPTURE_OK
```

The password and derived file key must never be committed, copied into chat, or written into fixture metadata.

## Mac state at handoff

The user has already inserted the real EDP USB into the Mac. Another ChatGPT session has working Mac access. Continue there rather than troubleshooting this conversation's Mac connector.

Repository path on the Mac:

```text
/Users/zhangyuxi/Desktop/edp-usb-vault
```

## Immediate next task — do this first

Use the Mac-connected session to perform a **read-only real-device capture**.

1. Open `/Users/zhangyuxi/Desktop/edp-usb-vault`.
2. Confirm branch is `feat/macos26-native-fskit` and pull latest changes if necessary.
3. Inspect `diskutil list` / `diskutil info` and identify the inserted physical EDP USB. Do not guess the disk number.
4. Run the one-command capture script against that disk.
5. Let the user type the EDP password locally when prompted. Do not ask the user to paste the password into chat.
6. Verify the capture ends with `RESULT=EDP_ONE_COMMAND_REAL_CAPTURE_OK`.
7. Inspect the generated `manifest.json` and fixture files. Do not expose secrets.
8. Validate that the decrypted data head looks structurally like the start of the expected native disk/filesystem image and that bounds/partition offsets are plausible.

Do **not** write to the real EDP disk during this phase.

## After successful capture

The next engineering milestone is the full real-device read-only path:

```text
real /dev/rdiskN
+ actual VID/PID/device size
+ actual password
-> actual LBA11/LBA12 unlock
-> actual derived file key
-> actual encrypted partition descriptor
-> EDPEncryptedPartitionReader
-> EDPEncryptedReadOnlyBlockDevice
-> macFUSE FSKit volume.raw
-> DiskImages2 explicit read-only attach
-> /dev/diskM
-> Apple native filesystem
-> Finder
```

Success criteria:

- DiskImages2 publishes a BSD disk with `Media Read-Only: Yes`;
- Apple native filesystem recognizes the decrypted disk/partition;
- Finder can list directories and open several known files;
- byte/hash checks on known files are correct;
- random reads remain correct;
- unmount/eject/FUSE teardown is clean;
- no write callback is enabled for the physical real-device test.

Only after this passes should write support be implemented.

## Code work still expected

Before or while integrating the real raw device, keep these implementation points in scope:

1. `EDPFileRawDevice` must not rely on `st_size` for `/dev/rdiskN`; support a trusted declared device size supplied from disk discovery.
2. Centralize the product unlock sequence into one Swift factory/session instead of duplicating LBA11/LBA12/password/key logic in test tools.
3. Keep the C/libfuse layer as ABI glue only; crypto stays in Swift.
4. Keep Private DiskImages2 selectors isolated in the single bridge module and runtime-probed/fail-closed.
5. Keep the current manual-key/synthetic E2E as a lower-level regression gate even after the product-style unlock path is added.

Suggested Swift product boundary:

```text
EDPReadOnlyUnlockRequest
  vidHex
  pidHex
  deviceSizeBytes
  password
  partitionType

EDPReadOnlyUnlock.unlock(raw:request:)
  -> EDPUnlockedReadOnlyVolume
  -> EDPEncryptedReadOnlyBlockDevice
```

Do not expose the derived file key in the public result.

## Evidence discipline

Maintain these distinctions in status reports:

- structural macFUSE -> DiskImages2 -> native filesystem: proven;
- Swift EDP crypto path through the same bridge using a synthetic encrypted disk image: proven;
- real LBA11/LBA12-derived key in the physical USB data path: capture/validation is the current task;
- physical real EDP USB mounted in Finder: **not yet proven until the next milestone succeeds**;
- physical write support: intentionally deferred until read-only real-device validation passes.

## Do not regress

Do not spend time on:

- macOS 15 compatibility;
- macFUSE kernel backend;
- `/sbin/mount -F` workaround work;
- DriverKit / `IOUserBlockStorageDevice` entitlement work;
- custom filesystem implementations;
- hdiutil runtime bridge;
- old custom FSKit filesystem skeleton as the product path.

The highest-value action now is to collect and validate the real EDP device evidence, then immediately wire the real raw device into the already-proven read-only macFUSE + DiskImages2 pipeline.
