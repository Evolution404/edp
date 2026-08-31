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

`drive-test-fast` runs the EDPCore package tests, strict Swift 6 UI typecheck, native golden core validation, media-classification validation, transport lifecycle validation, and the product policy-model contract. The policy-model gate locks all three partition types to safe opt-in defaults and verifies that later default changes never mutate existing device records. It is deliberately hardware-free.

`drive-test-virtual-usb` extends that baseline through TEST-C/TEST-D/TEST-E. It drives production discovery and daemon state through injected virtual whole-USB media, virtual metadata/raw devices, temporary Keychain/policy stores, and fake mount/Disk Arbitration dependencies. It covers P01–P30, C01–C08, D01–D13, and S01–S22 without opening a physical raw disk. D01–D13 cover safe new-device defaults, independent auto-mount/password-probe policy, built-in/custom default passwords, once-per-insertion wrong-password suppression, reconnect retry, XPC round-trips, Keychain-only default-password storage, manual-mount persistence, and stale synthetic `diskN` reuse protection. S13–S22 lock the asynchronous lifecycle itself: bounded one-shot FSKit host recovery/retry, cancellation priority, terminal-state idempotence, duplicate-mount single-flight fanout, mount→unmount cancellation, mount→eject serialization, coalesced shutdown while a mount is in flight, once-only Disk Arbitration completion when timeout/late/duplicate callbacks race, bounded asynchronous publisher process completion under normal/timeout/cancellation paths, preservation of typed raw-access/bridge/publication/filesystem/teardown failure categories, and deterministic virtual-clock same-tick ordering/cancellation terminality. `Tests/run-service-lifecycle.sh` is the focused credential/default-policy/service runner used by that target.

`drive-test-virtual-usb` includes the production discovery dependency seam plus
the complete P16–P30 lifecycle/fault matrix. Its focused service runner also
executes a fixed-seed lifecycle model/property gate with 10,000 generated
sequences (320,000 events at the default 32 steps each), checking terminal
stickiness, once-only Disk Arbitration completion, one-shot recovery/retry,
cancellation priority, and publication ownership. Any failure reports the fixed
seed, per-sequence seed, sequence index, and event trace for exact replay. It
reads only immutable fixture files and never opens `/dev/rdisk*`.

`drive-test-storage-smoke` and `drive-test-storage` both cover M01–M14. Both canonical profiles run 5 complete mount/attach/filesystem/unmount/eject/transport-remount cycles; same-partition remounts preserve real filesystem access but wait through the product-equivalent 3-second generation quiescence after exact teardown. The internal macFUSE Local bridge remains `local,nobrowse`; deadlock prevention comes from exact publication teardown, unique mount generations, and bounded quiescence rather than changing the bridge's established VFS semantics. The release profile keeps the stricter production-build/contract checks while accepting an explicit `EDP_STORAGE_LOOP_COUNT` override from 5–100 for optional soak runs. It verifies boot FAT16 at both
the native read-only mount and transport `EROFS` layers, encrypted persistence,
Finder-style operations, large/random I/O, unmount failure propagation,
transport crash recovery, durability failure propagation, and concurrent
type 1/2/4 session isolation. No sudo, physical USB, real raw node, or real EDP
credential is used.

`drive-test-ui` is an independent macOS UI gate. It builds the preview scenario
factory, renders main/device/menu-bar surfaces in Light/Dark mode (including a
credential-missing menu-bar state with direct password entry), executes 20
900×680 native sidebar toggles, checks accessibility structure, and parses an
Instruments `Animation Hitches` trace. Frames above 33 ms fail the gate.

`drive-test-system` is the release safety ratchet. It rejects sudo dependencies,
literal physical `/dev/rdisk*` opens, unguarded destructive disk operations,
legacy device-ID migration, synchronous mount/unmount/eject/shutdown fallbacks,
and regressions away from the native `NSSplitViewController`/window-style menu
bar architecture. It also locks normal runtime control to native APIs: macFUSE
signature validation uses Security.framework rather than `codesign`, daemon
liveness uses SMAppService/XPC rather than `launchctl`, and VFS teardown uses
`unmount(2)` rather than `/sbin/umount`.

The phase targets are intentionally independent so CI can isolate failures.
`drive-test-all` is the only aggregate target and runs every hardware-free gate.
Normal storage validation uses 5 cycles. Longer soak runs may explicitly raise `EDP_STORAGE_LOOP_COUNT` up to 100 when a lifecycle change specifically warrants it; they are not a release-blocking default.

Canonical targets:

```text
drive-test-identity
drive-test-virtual-usb
drive-test-storage-smoke
drive-test-storage
drive-test-ui
drive-test-system
drive-test-all
```
