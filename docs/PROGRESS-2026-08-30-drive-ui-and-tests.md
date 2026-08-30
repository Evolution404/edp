# EDP Drive UI + Regression Suite Progress（2026-08-30）

> 本文件是下一阶段实时进度追踪。每完成一个可验证小阶段，立即更新状态、测试结果、commit SHA 和下一步，再 push。

## Baseline

Repository:

```text
Evolution404/edp
```

Branch:

```text
codex/ui-macos26-liquid-glass
```

Implementation baseline before these planning docs:

```text
fd10092 fix(drive): require five-factor physical device identity
```

Current important prior commits:

```text
7361252 fix(drive): use native split view for smooth sidebar
d537675 refactor(drive): remove obsolete ui shell and update ratchet
fd10092 fix(drive): require five-factor physical device identity
```

## Global invariants

- [x] Native `NSSplitViewController` sidebar accepted at 900px.
- [x] Sidebar toolbar `»` regression removed in native split implementation.
- [x] Sidebar spring/overshoot regression removed.
- [x] Sidebar button focus ring removed via `focusEffectDisabled()`.
- [x] Five-factor physical identity implemented.
- [x] LBA4 numeric onlyId required for standard encrypted Drive claim.
- [x] Old physical-ID auto migration removed.
- [x] Real disk4/disk5 metadata fixtures still classify as standard encrypted.
- [x] Swift 6 strict identity build passed at `fd10092`.
- [ ] Full redesigned UI implemented.
- [ ] Virtual physical USB regression suite implemented.
- [ ] Sparse-image full storage E2E integrated into normal regression.
- [ ] New UI automation integrated.
- [ ] Final exact-head CI green.

---

# Task A — UI Redesign

Plan:

```text
docs/PLAN-2026-08-30-drive-ui-redesign.md
```

## UI-A — Information architecture

Status: `DONE`

- [x] Sidebar = 总览 / 设备 / 活动 / 设置.
- [x] Default page = 总览.
- [x] Device subnavigation = 概览 / 分区 / 安全.
- [x] Keep native split controller unchanged.
- [x] Swift 6 warnings-as-errors.

Validation at implementation HEAD:

```text
git diff --check = PASS
make drive-check = PASS
NSSplitViewController geometry ratchet preserved
.menuBarExtraStyle(.window) preserved
```

The new overview is intentionally a first-pass shell in UI-A; detailed hero/status/partition/quick-action composition is completed in UI-B. Device subnavigation is functional now, while the denser layout refinement remains UI-C.

Commit: `072381e feat(drive): establish redesigned information architecture`

## UI-B — Overview

Status: `DONE`

- [x] Device hero.
- [x] Service/FDA/macFUSE/auto-mount status strip.
- [x] Partition overview without fabricated per-partition capacity.
- [x] Quick actions including Finder, serial mount-all, and whole-device eject.
- [x] Recent activity.

Validation at implementation HEAD:

```text
git diff --check = PASS
make drive-check = PASS
EDP_UI_PREVIEW Swift 6 warnings-as-errors typecheck = PASS
RESULT=DRIVE_UI_PREVIEW_COMPILE_OK
```

`mountAllAvailablePartitions` sequences the existing per-partition XPC operation and stops on the first surfaced failure; no mount-service protocol or raw-device semantics changed.

Commit: `3973068 feat(drive): build liquid glass overview workspace`

## UI-C — Device workspace

Status: `DONE`

### Overview

- [x] VID/PID.
- [x] LBA4 onlyId.
- [x] LBA11 metadataDeviceID.
- [x] Capacity.
- [x] BSD name with explicit dynamic-name wording.
- [x] Stable internal deviceID and five-factor identity explanation.
- [x] Eject/delete record.

### Partitions

- [x] Compact type 1/2/4 rows.
- [x] Auto mount.
- [x] Mount/unmount plus serial mount-all/unmount-all.
- [x] Finder.
- [x] filesystem/readOnly/error.
- [x] credential actions preserved in the secondary action menu.

### Security

- [x] Exchange credential.
- [x] Secure credential.
- [x] Update/delete.
- [x] Integration status and settings/recheck actions.

Validation at implementation HEAD:

```text
git diff --check = PASS
make drive-check = PASS
EDP_UI_PREVIEW Swift 6 warnings-as-errors typecheck = PASS
RESULT=DRIVE_UI_C_FINAL_OK
```

The device overview now exposes the five-factor identity evidence without treating `diskN` as stable identity. Partition bulk operations sequence the existing per-partition XPC APIs and surface the first failure; no XPC protocol, raw-device, credential, or mount-service semantics changed.

Commit: `27ac58e feat(drive): redesign device partition and security views`

## UI-D — Activity + Settings

Status: `DONE`

- [x] Timeline activity UI.
- [x] Filter controls for 全部 / 设备 / 挂载 / 安全 / 错误.
- [x] No bounce animation.
- [x] Settings grouped as 常规 / 系统集成 / 后台服务 / 高级 without the old generic `Form` shell.
- [x] Diagnostics preserved with copy support.
- [x] Permission recheck, component reveal, service controls, and login-item controls preserved.

Validation at implementation HEAD:

```text
git diff --check = PASS
make drive-check = PASS
EDP_UI_PREVIEW Swift 6 warnings-as-errors typecheck = PASS
no .symbolEffect(.bounce) in Drive UI
no top-level Form shell in settings
RESULT=DRIVE_UI_D_COMPILE_OK
RESULT=DRIVE_UI_D_STRUCTURE_OK
```

Activity filtering is a presentation-only projection over the existing 200-entry runtime activity feed; persistence and XPC activity semantics are unchanged.

Commit: `250b9d8 feat(drive): redesign activity and settings surfaces`

## UI-E — Menu Bar Mini Control Center

Status: `DONE`

- [x] Keep `.menuBarExtraStyle(.window)`.
- [x] Header with service status and direct 打开主窗口 action.
- [x] Device compact card(s) with capacity and connected state.
- [x] Partition quick controls with filesystem/mount status and credential-missing guidance.
- [x] Global auto-mount toggle.
- [x] Service start/stop/restart.
- [x] Footer: 刷新 / 仅退出界面 / 完全退出.
- [x] Full exit still requests graceful service shutdown before terminating the UI.

Validation at implementation HEAD:

```text
git diff --check = PASS
make drive-check = PASS
EDP_UI_PREVIEW Swift 6 warnings-as-errors typecheck = PASS
.menuBarExtraStyle(.window) preserved
RESULT=DRIVE_UI_E_COMPILE_OK
RESULT=DRIVE_UI_E_STRUCTURE_OK
```

The menu bar is now the approved compact control center instead of a navigation-heavy menu surface. Existing XPC partition/service actions are reused without changing lifecycle semantics.

Commit: `d0937ce feat(drive): redesign menu bar control center`

## UI-F — Accessibility / Dark / Performance

Status: `TODO`

- [ ] 900×680 sidebar 20-toggle automation.
- [ ] No `»`.
- [ ] No overshoot.
- [ ] No focus ring.
- [ ] Light mode.
- [ ] Dark mode.
- [ ] Reduce Motion.
- [ ] Reduce Transparency.
- [ ] Increased Contrast.
- [ ] Accessibility labels.
- [ ] Instruments Animation Hitches = 0 for sidebar test.

Commit: `TBD`

## UI-G — Final UI acceptance

Status: `TODO`

- [ ] Full function mapping checklist.
- [ ] Preview scenarios.
- [ ] CI ratchet updated.
- [ ] User visual approval.

Commit: `TBD`

---

# Task B — Regression Test Overhaul

Plan:

```text
docs/PLAN-2026-08-30-drive-regression-suite.md
```

## TEST-A — Unified test runner

Status: `DONE`

- [x] Create canonical `Apps/Drive/Tests/` structure.
- [x] Inventory existing validators.
- [x] `make drive-test-fast`.
- [x] Existing tests still green.

Validation at implementation HEAD:

```text
git diff --check = PASS
make drive-test-fast = PASS
RESULT=DRIVE_CORE_OK
RESULT=DRIVE_FAST_OK
```

The fast runner is hardware-free and reuses the existing production validators rather than cloning parser/crypto logic. Stable Makefile entry points for later phases are reserved now and will be replaced by dedicated harnesses as TEST-B through TEST-H land.

Commit: `4a5c48d test(drive): unify regression suite entrypoints`

## TEST-B — Identity / Classification matrix

Status: `DONE`

- [x] P01–P15.
- [x] Real disk4/disk5 anchors.
- [x] Deterministic generated/mutated metadata cases without duplicate binary fixtures.
- [x] Five-factor one-at-a-time mutation.
- [x] onlyId missing / non-numeric / UInt64 overflow cases.

Validation at implementation HEAD:

```text
git diff --check = PASS
make drive-test-identity = PASS
SCENARIO=P01_OK ... SCENARIO=P15_OK
RESULT=DRIVE_IDENTITY_OK
```

P01/P02 are pinned to captured disk4/disk5 truth. P03–P09 exercise production `EDPMetadataProbe` classification and LBA4 parsing. P10–P15 exercise production `EDPVolumeMetadata.stablePhysicalDeviceID`, including per-factor mutation and VID/PID case normalization.

Commit: `b18a3dd test(drive): add strict physical identity matrix`

## TEST-C — Production dependency seam

Status: `DONE`

- [x] `EDPWholeUSBMedia` value model.
- [x] `EDPWholeUSBMediaProviding` media/registry provider protocol.
- [x] `EDPRawMetadataReading` protocol and shared raw metadata snapshot.
- [x] Central `EDPPhysicalIdentity` used by discovery and retained raw-FD revalidation.
- [x] Production `EDPIOKitWholeUSBMediaProvider` + `EDPPrivilegedRawMetadataReader` preserve the default service path.
- [x] `EDPDaemonController` receives production dependencies by initializer injection.
- [x] No production environment-variable selector or hidden provider backdoor.
- [x] Virtual provider/reader validator calls production `EDPPhysicalDiskDiscovery` directly.

Validation at implementation HEAD:

```text
make drive-test-virtual-usb = PASS
SCENARIO=TEST_C_INJECTED_DISCOVERY_OK
SCENARIO=TEST_C_METADATA_READER_FAILURE_ISOLATED
RESULT=DRIVE_DISCOVERY_SEAM_OK
RESULT=DRIVE_VIRTUAL_USB_OK
full native daemon Swift 6 warnings-as-errors compile = PASS
RESULT=DRIVE_TEST_C_PRODUCTION_BUILD_OK
git diff --check = PASS
```

The old duplicate runtime classifier/identity assembly has been removed. IOKit inventory, privileged metadata reads, injected virtual media, and retained raw-FD validation now converge on the same production identity/classification logic.

Commit: `223ac06 refactor(drive): inject physical media discovery dependencies`

## TEST-D — Virtual Physical USB Harness

Status: `DONE`

- [x] Insert/remove/reinsert.
- [x] diskN change with stable five-factor identity.
- [x] diskN reuse by a different device.
- [x] replacement race between discovery and retained raw access.
- [x] registry mutation rejection.
- [x] onlyId/LBA11 mutation rejection through production revalidation.
- [x] short read/EIO fault injection.
- [x] detach during metadata read and after discovery.
- [x] detach propagated through the production plaintext block boundary.
- [x] multiple same-model devices remain independent.
- [x] one broken device does not poison discovery of another device.
- [x] P16–P30 automated.
- [x] 4K physical-transfer alignment and invalid-capacity guards retained.

Validation at implementation HEAD:

```text
make drive-test-virtual-usb = PASS
SCENARIO=P16_OK ... SCENARIO=P30_OK
RESULT=DRIVE_VIRTUAL_PHYSICAL_USB_OK
RESULT=DRIVE_VIRTUAL_USB_OK
full native daemon Swift 6 warnings-as-errors compile = PASS
RESULT=DRIVE_TEST_D_PRODUCTION_BUILD_OK
git diff --check = PASS
```

The lifecycle harness operates entirely on injected IOKit-equivalent inventory, captured immutable metadata, mutable virtual device state, and an in-memory raw block backend. It does not open `/dev/rdisk*`. P24 proves detach/error propagation at the production plaintext block boundary; full macFUSE/DiskImages2 detach cleanup remains a storage-lifecycle responsibility for TEST-F rather than being overclaimed here.

Commit: `4e38088 test(drive): simulate physical usb lifecycle failures`

## TEST-E — Credential / Policy / Service lifecycle

Status: `DONE`

- [x] C01–C08 credential and policy matrix.
- [x] S01–S10 daemon/service lifecycle matrix.
- [x] Wrong password fails before Keychain persistence.
- [x] Partition 2/4 credentials remain independently removable.
- [x] New five-factor physical identity never inherits display name, auto-mount policy, or credential state.
- [x] Policy/credential state persists across service reconstruction for the same identity.
- [x] Startup with no device and startup with an already-present virtual EDP device.
- [x] Service stop with zero mounts and with active mounts.
- [x] Service restart preserves stable identity; foreground/XPC client reconstruction does not stop the daemon.
- [x] Explicit macFUSE transient retry clears the retained failure and succeeds on the second production reconcile.
- [x] One broken virtual device does not poison another good device.
- [x] Stale-session recovery runs at controller initialization.
- [x] XPC graceful full-exit tears down sessions before requesting process shutdown.
- [x] Production controller dependencies are initializer-injected; production defaults remain real IOKit/raw lease/Keychain/policy/mount/Disk Arbitration implementations.
- [x] Test-only synchronous queue helpers compile only under `EDP_REGRESSION_TESTS`; no environment selector/backdoor was added.

Validation at implementation HEAD:

```text
make drive-test-virtual-usb = PASS
SCENARIO=C01_OK ... SCENARIO=C08_OK
SCENARIO=S01_OK ... SCENARIO=S10_OK
RESULT=DRIVE_CREDENTIAL_POLICY_SERVICE_OK
RESULT=DRIVE_SERVICE_LIFECYCLE_OK
RESULT=DRIVE_VIRTUAL_USB_OK
shipping native daemon Swift 6 warnings-as-errors compile = PASS
RESULT=DRIVE_TEST_E_PRODUCTION_BUILD_OK
git diff --check = PASS
```

TEST-E instantiates the production `EDPDaemonController` with explicit test dependencies rather than duplicating its state machine. The normal executable still constructs the controller with the original real dependencies, and the regression harness uses only temporary Keychain/policy paths plus virtual media/raw state.

Commit: `a78e417 test(drive): cover credential policy and service lifecycle`

## TEST-F — Sparse-image Storage E2E

Status: `DONE`

- [x] Reuse `PrepareEDPFilesystemFixture.swift` with combined sparse type 1/2/4 media.
- [x] Reuse `DirectMFMountEDPFixtureAdapter.c` and production `edp_rw_open_device()`.
- [x] Reuse macFUSE Local + writable DiskImages2 publication + Apple native filesystems.
- [x] M01–M14.
- [x] Boot FAT16 native read-only mount plus transport-level `EROFS` fail-closed write.
- [x] Atomic-save pattern.
- [x] Random I/O.
- [x] 50 mount/unmount/remount loops by default (configurable only within 50–100).
- [x] XPC unmount/eject failure propagation with retained session state.
- [x] Transport crash bounded cleanup and successful remount.
- [x] `synchronize()` and final durability failure propagation.
- [x] Concurrent type 1/2/4 sessions remain independent.
- [x] No leaked mount/process/synthetic device/fd.

Validation at implementation worktree:

```text
make drive-test-storage = PASS
make drive-test-virtual-usb = PASS
SCENARIO=M01_OK ... SCENARIO=M14_OK
M10 loops = 50/50
M10 fd baseline/max = 9/9
RESULT=DRIVE_STORAGE_FAILURE_CONTRACTS_OK
RESULT=DRIVE_STORAGE_PRODUCTION_SWIFT6_C17_STRICT_OK
RESULT=DRIVE_STORAGE_E2E_OK
RESULT=MACFUSE_SCRATCH_CLEANUP_CONTRACT_OK
post-test synthetic images = []
git diff --check = PASS
```

The boot product path keeps `volume.raw` metadata writable enough for macFUSE
Local activation, rejects every transport WRITE with `EROFS`, publishes the
slice through writable Private DiskImages2, and uses Apple `mount_msdos -o
rdonly` for the final system-level FAT16 mount. Crash recovery only matches an
exact persisted mount source to the narrow root-owned 4 KiB macFUSE UUID
scratch signature before cleanup; unrelated devices and images are rejected.

Commit: `pending commit`

## TEST-G — UI automation

Status: `TODO`

- [ ] Preview scenario factory.
- [ ] Main navigation automation.
- [ ] Device subpages.
- [ ] Menu bar.
- [ ] 900px geometry.
- [ ] Light/Dark.
- [ ] Accessibility.
- [ ] Instruments trace parsing.

Commit: `TBD`

## TEST-H — CI and release gate

Status: `TODO`

- [ ] `make drive-test-all`.
- [ ] No physical USB required.
- [ ] No sudo/password required for core suite.
- [ ] CI jobs split by responsibility.
- [ ] Nightly stress.
- [ ] Result artifacts.
- [ ] Safety ratchets against real raw writes.
- [ ] README/testing docs.

Commit: `TBD`

---

# Final Acceptance

## No-hardware automation

- [ ] `make drive-test-all` succeeds with zero external physical disks.
- [ ] No test opens `/dev/rdisk*` by default.
- [ ] No real password needed.
- [ ] No admin prompt for normal regression.

## Physical identity

- [ ] VID mismatch => different device.
- [ ] PID mismatch => different device.
- [ ] onlyId mismatch => different device.
- [ ] capacity mismatch => different device.
- [ ] LBA11 deviceId mismatch => different device.
- [ ] same five factors + different diskN => same device.
- [ ] same-model two disks + different onlyId => independent devices.

## Storage

- [ ] Boot/exchange/secure covered.
- [ ] Encrypted RW persistence.
- [ ] Rename/atomic save/delete.
- [ ] Mount/unmount/remount stress.
- [ ] Failure propagation.

## UI

- [ ] Approved four-module design.
- [ ] Menu bar control center.
- [ ] 900px native sidebar regression gate.
- [ ] User final visual approval.

## CI

- [ ] Exact final HEAD all required jobs green.
