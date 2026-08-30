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

Status: `TODO`

- [ ] Sidebar = 总览 / 设备 / 活动 / 设置.
- [ ] Default page = 总览.
- [ ] Device subnavigation = 概览 / 分区 / 安全.
- [ ] Keep native split controller unchanged.
- [ ] Swift 6 warnings-as-errors.

Commit: `TBD`

## UI-B — Overview

Status: `TODO`

- [ ] Device hero.
- [ ] Service/FDA/macFUSE/auto-mount status strip.
- [ ] Partition overview.
- [ ] Quick actions.
- [ ] Recent activity.

Commit: `TBD`

## UI-C — Device workspace

Status: `TODO`

### Overview

- [ ] VID/PID.
- [ ] LBA4 onlyId.
- [ ] LBA11 metadataDeviceID.
- [ ] Capacity.
- [ ] BSD name.
- [ ] Stable internal deviceID.
- [ ] Eject/delete record.

### Partitions

- [ ] Compact type 1/2/4 rows.
- [ ] Auto mount.
- [ ] Mount/unmount.
- [ ] Finder.
- [ ] filesystem/readOnly/error.
- [ ] credential actions preserved.

### Security

- [ ] Exchange credential.
- [ ] Secure credential.
- [ ] Update/delete.
- [ ] Integration status links.

Commit: `TBD`

## UI-D — Activity + Settings

Status: `TODO`

- [ ] Timeline activity UI.
- [ ] Filter controls.
- [ ] No bounce animation.
- [ ] Settings grouped as 常规 / 系统集成 / 后台服务 / 高级.
- [ ] Diagnostics preserved.

Commit: `TBD`

## UI-E — Menu Bar Mini Control Center

Status: `TODO`

- [ ] Keep `.menuBarExtraStyle(.window)`.
- [ ] Header/service status.
- [ ] Device compact card(s).
- [ ] Partition quick controls.
- [ ] Global auto-mount.
- [ ] Service start/stop/restart.
- [ ] Footer: 刷新 / 仅退出界面 / 完全退出.

Commit: `TBD`

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

Commit: `pending commit`

## TEST-C — Production dependency seam

Status: `TODO`

- [ ] `EDPWholeUSBMedia` value model.
- [ ] Media provider protocol.
- [ ] Raw metadata reader protocol.
- [ ] Central `EDPPhysicalIdentity`.
- [ ] Production adapters preserve semantics.
- [ ] No production environment backdoor.

Commit: `TBD`

## TEST-D — Virtual Physical USB Harness

Status: `TODO`

- [ ] Insert/remove/reinsert.
- [ ] diskN change.
- [ ] diskN reuse.
- [ ] replacement race.
- [ ] registry mutation.
- [ ] onlyId/LBA11 mutation.
- [ ] short read/EIO.
- [ ] detach mid-operation.
- [ ] multiple devices.
- [ ] failure isolation.
- [ ] P16–P30 automated.

Commit: `TBD`

## TEST-E — Credential / Policy / Service lifecycle

Status: `TODO`

- [ ] C01–C08.
- [ ] S01–S10.
- [ ] New physical identity never inherits old state.
- [ ] Service stop/restart/recovery.

Commit: `TBD`

## TEST-F — Sparse-image Storage E2E

Status: `TODO`

- [ ] Reuse `PrepareEDPFilesystemFixture.swift`.
- [ ] Reuse `DirectMFMountEDPFixtureAdapter.c`.
- [ ] Reuse macFUSE Local + DiskImages2 path.
- [ ] M01–M14.
- [ ] Atomic-save pattern.
- [ ] Random I/O.
- [ ] 50–100 mount/unmount loop.
- [ ] Failure propagation.
- [ ] No leaked mount/process/fd.

Commit: `TBD`

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
