# EDP Drive Regression Tests

This directory is the canonical entry point for Drive regression tests that do not require a physical USB device.

## Safety boundary

Normal regression commands in this directory must not:

- open `/dev/rdisk*` or write `/dev/disk*`;
- run destructive `diskutil erase*` commands;
- write raw data to physical devices;
- require a real EDP password, Full Disk Access, sudo, or administrator interaction.

Captured metadata under `Apps/Drive/fixtures/real_disks` is immutable truth input. Generated or mutated fixtures must live in memory or a temporary directory.

## Existing validator inventory

The initial unified runner intentionally reuses production validators instead of cloning their logic:

- `native/EDPFSKitPoC/Tools/ValidateEDPNativeCore.swift` — native crypto, LBA11/LBA12 and encrypted-reader golden coverage.
- `native/EDPFSKitPoC/Tools/ValidateEDPMetadataProbe.swift` — aligned reads, LBA4 onlyId, five media classes, real disk4/disk5 metadata.
- `native/EDPFSKitPoC/Tools/ValidateTransportLifecycle.swift` — transport process lifecycle hardening.
- `native/EDPFSKitPoC/Tools/ValidateBoundedVFS.swift` — bounded VFS unmount guard.
- `native/EDPFSKitPoC/Tools/ValidateCredentialStore.swift` — credential namespace behavior.
- `product/Tests/ValidateFinderNobrowseMount.swift` — Finder/nobrowse mount contract.
- `product/Tests/ValidateMacFUSEScratchCleanup.swift` — macFUSE scratch cleanup.
- `product/Tests/ValidateProductModels.swift` — product model contract.

`VirtualUSB/ValidateDiscoverySeam.swift` is the first executable consumer of the production dependency seam. It injects a virtual whole-USB inventory and metadata reader into `EDPPhysicalDiskDiscovery`, while the shipping daemon defaults to `EDPIOKitWholeUSBMediaProvider` + `EDPPrivilegedRawMetadataReader`. There is no environment-variable selector in the production App or service.

`Storage/run-storage.sh` is the TEST-F sparse-image harness. It builds one
combined virtual physical disk from captured disk4 LBA4/LBA7/LBA11/LBA12,
then exercises production boot/type 2/type 4 unlock through macFUSE Local,
DiskImages2, and Apple FAT16/ExFAT filesystems. Every DiskImages2 device is
matched back to its exact temporary backing file before any filesystem format
operation is allowed.

## Commands

From the repository root:

```bash
make drive-test-fast
```

`drive-test-fast` runs the EDPCore package tests, strict Swift 6 UI typecheck, native golden core validation, media-classification validation, and transport lifecycle validation. It is deliberately hardware-free.

`drive-test-virtual-usb` extends that baseline through TEST-C/TEST-D/TEST-E. It drives production discovery and daemon state through injected virtual whole-USB media, virtual metadata/raw devices, temporary Keychain/policy stores, and fake mount/Disk Arbitration dependencies. It covers P01–P30, C01–C08, and S01–S10 without opening a physical raw disk. `Tests/run-service-lifecycle.sh` is the focused C/S runner used by that target.

`drive-test-virtual-usb` includes the production discovery dependency seam plus
the complete P16–P30 lifecycle/fault matrix. It reads only immutable fixture
files and never opens `/dev/rdisk*`.

`drive-test-storage` covers M01–M14. Its default stress gate performs 50 full
mount/attach/filesystem/unmount/eject/transport-remount cycles and rejects a
loop count outside the accepted 50–100 range. It verifies boot FAT16 at both
the native read-only mount and transport `EROFS` layers, encrypted persistence,
Finder-style operations, large/random I/O, unmount failure propagation,
transport crash recovery, durability failure propagation, and concurrent
type 1/2/4 session isolation. No sudo, physical USB, real raw node, or real EDP
credential is used.

Canonical targets:

```text
drive-test-identity
drive-test-virtual-usb
drive-test-storage
drive-test-ui
drive-test-system
drive-test-all
```
