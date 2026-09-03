# EDP Drive — Testing Matrix

Updated: 2026-09-03

> This document defines which test layer is authoritative for which claim. Do not promote synthetic evidence into physical-device evidence, and do not use local desktop UI timing as release performance evidence.

## 1. Canonical developer targets

```bash
make drive-test-fast
make drive-test-virtual-usb
make drive-test-storage-smoke
make drive-test-storage
make drive-test-ui
make drive-test-system
make drive-test-all
```

`drive-test-all` currently expands to:

```text
drive-test-fast
+ drive-test-virtual-usb
+ drive-test-storage
+ drive-test-ui
+ drive-test-system
```

## 2. Test layers and authority

| Layer | Hardware | Purpose | Can prove physical-device behavior? |
|---|---|---|---|
| Fast / unit / golden | none | crypto, identity, publisher contracts, model invariants | No |
| Virtual USB | none | lifecycle, classifier, policy, generation races | No |
| Storage sparse-image E2E | no physical EDP USB | macFUSE Local + DiskImages2 + Apple FS behavior | No |
| System ratchets | none | architecture/security/static contracts | No |
| UI deterministic | none | page rendering, accessibility, toggle contract | No |
| UI xctrace on GitHub Actions | no physical EDP USB | compositor-sensitive 33ms performance gate | No |
| Installed-machine acceptance | Mac install | packaging/FDA/service/reboot integration | Partly |
| Physical-device acceptance | actual media | actual USB ownership/raw/eject/replug behavior | Yes |

## 3. Fast regression

Command:

```bash
make drive-test-fast
```

Includes core compile/test plus Drive fast suites such as:

- EDPCore crypto and metadata golden vectors;
- five-factor identity behavior;
- model contracts;
- runtime metrics contract;
- DiskImages2 dead-owner tombstone deterministic contract;
- macFUSE scratch cleanup contract;
- block publisher contract.

Expected terminal marker:

```text
RESULT=DRIVE_FAST_OK
```

## 4. Virtual USB / lifecycle regression

Command:

```bash
make drive-test-virtual-usb
```

Authoritative for hardware-free lifecycle semantics such as:

- stale `diskN` reuse refusal;
- replacement generation refusal;
- reconnect of same identity;
- two same-model devices remain independent;
- broken device isolation;
- detach races;
- credential/policy rules;
- service start/stop/restart state;
- mount/eject single-flight;
- shutdown/eject serialization;
- raw EBUSY exact-generation recovery S31–S35;
- fixed-seed lifecycle property model.

Important distinction:

S31–S35 prove the **contract** of raw EBUSY recovery. They do not prove a physical EBUSY event occurred on a real USB device.

Expected high-level markers include:

```text
SCENARIO=S01_OK ... SCENARIO=S35_OK
MODEL_SEQUENCES=10000
MODEL_STEPS=320000
RESULT=DRIVE_LIFECYCLE_MODEL_PROPERTIES_OK
RESULT=DRIVE_VIRTUAL_USB_OK
```

## 5. Storage sparse-image E2E

Smoke:

```bash
make drive-test-storage-smoke
```

Release profile:

```bash
make drive-test-storage
```

Both require the macFUSE Local FSKit runtime. GitHub Actions installs the official runtime before running the suite.

Current release profile uses `EDP_STORAGE_LOOP_COUNT=5`.

### Covered scenarios

The release suite currently covers:

- M01 — boot FAT16 native readonly behavior;
- M02 — exchange write/fsync/read/hash + full remount persistence;
- M04 — Finder/TextEdit-style atomic save pattern;
- M05 — multiple file delete;
- M06 — rename/overwrite patterns;
- M07 — Unicode filenames;
- M08 — large sequential I/O;
- M09 — fixed-seed random I/O;
- M03 — secure partition persistence;
- M10 — five mount/unmount cycles with leak checks;
- M12 — transport-crash recoverable boundary + remount;
- M14 — concurrent partition sessions;
- failure contracts;
- production Swift6/C17 strict compile.

Expected release marker:

```text
RESULT=DRIVE_STORAGE_E2E_OK
```

### What storage E2E does not prove

It does not prove:

- physical USB classification;
- retained FDA against a real `/dev/rdiskN`;
- real USB disconnect/reinsert behavior;
- real physical eject;
- physical negative media classes.

## 6. Storage teardown safety rules

The storage harness must mirror production ownership semantics. It must not reintroduce old experiments such as:

- unbounded `wait` after a child can enter kernel wait;
- direct dangerous `MNT_FORCE` test teardown after lower transport death;
- stale `diskN` authority;
- unvalidated `diskimagesiod` PID signalling;
- `hdiutil detach -> diskutil eject` as the production publication contract.

All helper/process teardown paths must be bounded or fail closed.

## 7. System ratchets

Command:

```bash
make drive-test-system
```

System ratchets lock architecture and safety constraints, including:

- no interactive `sudo` dependency in ordinary regression tests;
- no separate service FDA model;
- no product raw-path open fallback;
- no sync lifecycle fallback;
- raw EBUSY exact-generation semantics;
- async Disk Arbitration and publisher contracts;
- split runtime/UI ownership boundaries;
- no return of old `MountManager` / `EDPDaemonController` structure;
- runtime metrics schema remains non-sensitive;
- PluginKit remains foreground-App-only;
- App/daemon/installer FSKit-agent reset remains fail-closed;
- production preinstall `hdiutil` is bounded;
- UI performance remains CI-only and threshold stays 33ms.

Expected marker:

```text
RESULT=DRIVE_SYSTEM_OK
```

## 8. App external-tool deterministic test

Command:

```bash
Apps/Drive/Tests/run-app-service-support.sh
```

Covers foreground external-tool runner:

- normal success;
- typed non-zero exit;
- bounded timeout;
- Swift Task cancellation.

Expected marker:

```text
RESULT=DRIVE_APP_USER_TOOL_BOUNDED_TYPED_CANCELLABLE_OK
```

## 9. UI testing policy

### Local machine

Local execution may validate deterministic UI structure only.

Local desktop compositor timing is **not** release-authoritative because WindowServer load and unrelated local state are not controlled variables.

When run locally, the UI harness must skip the xctrace performance section and report:

```text
RESULT=DRIVE_UI_PERF_CI_ONLY_SKIPPED_LOCALLY
```

Do not close unrelated user apps, change product animation behavior, or adjust thresholds to manufacture a local pass.

### GitHub Actions

Release-authoritative UI performance runs only on GitHub macOS 26 runner.

Current gate is fixed:

```text
20 sidebar toggles
8-second Animation Hitches trace
THRESHOLD_NS = 33_000_000
```

Current process-level watchdogs:

```text
xctrace record = 120 s
xctrace list/export = 30 s
```

These watchdogs bound Instruments startup/export. They do not change the 33ms performance threshold or the workload.

A performance PASS requires:

```text
UI_HITCH_COUNT_GT33MS=0
RESULT=DRIVE_UI_ANIMATION_HITCHES_ZERO
RESULT=DRIVE_UI_OK
```

## 10. GitHub Actions responsibility split

Workflow: `.github/workflows/drive.yml`

### `native`

Builds core and compiles native daemon / SwiftUI App under strict settings.

### `regression-fast`

Runs:

```bash
make drive-test-fast
```

### `regression-virtual-usb`

Runs:

```bash
make drive-test-virtual-usb
```

### `regression-storage`

On macOS 26:

1. installs official macFUSE Local FSKit runtime;
2. runs `make drive-test-storage`;
3. uploads storage logs.

Timeout: 30 minutes.

### `regression-ui-system`

Runs:

```bash
make drive-test-ui
make drive-test-system
```

Timeout: 20 minutes.

### `nightly-storage-stress`

Scheduled-only job:

```text
EDP_STORAGE_LOOP_COUNT=100
make drive-test-storage
make drive-test-system
```

Timeout: 45 minutes.

## 11. Current fixed-head evidence

Current source-of-truth validation:

```text
HEAD: f734f43899e174c5965f32917f6164ccb2994305
Run:  33711677562
```

Results:

```text
native                 PASS
regression-fast        PASS
regression-virtual-usb PASS
regression-ui-system   PASS
regression-storage     PASS
```

The fixed-head `f734f43` UI/system job passed with the unchanged 33ms threshold; its UI evidence recorded `UI_HITCH_MAX_MS=0.000`, `UI_HITCH_COUNT_GT33MS=0` and `RESULT=DRIVE_UI_OK`.

## 12. Installer/build verification

Production native installer build entry:

```bash
Apps/Drive/installer/build-native-installer.sh <output-dir>
```

Combined clean installer entry:

```bash
Apps/Drive/installer/build-clean-installer.sh <output-dir>
```

The combined installer includes the pinned official macFUSE package/runtime material required by the product.

Before physical release acceptance, verify the exact generated package using the repository verification script rather than relying only on filename or prior hashes.

## 13. First-install / reinstall acceptance

Detailed procedure:

```text
Apps/Drive/docs/FIRST-INSTALL-ACCEPTANCE.md
Apps/Drive/scripts/first-install-acceptance.sh
```

This layer is authoritative for:

- clean baseline;
- package installation;
- App/service registration;
- single-App FDA grant;
- service lifecycle;
- reboot persistence;
- credential/policy persistence;
- physical safe eject when a real EDP USB is present.

## 14. Physical test evidence rules

A physical claim requires actual corresponding media.

### Already evidenced

A standard encrypted SanDisk EDP device has completed positive/capability/replug/safe-eject evidence.

### Still blocked by fixture

The following remain `BLOCKED_BY_FIXTURE` until the actual media exists:

```text
ordinaryUSB physical negative
legacyNoPassword physical negative
currentNoPassword physical negative
unrecognizedEDP physical negative
```

Do not substitute golden fixtures, virtual USB or sparse images for these physical negatives.

## 15. Real-device safety rules

Before every real-device action:

- re-enumerate current devices;
- match exact identity/current generation;
- do not trust a remembered `diskN`;
- do not touch unrelated external media;
- never format, repartition or raw-write the physical EDP device as a test shortcut.

Known unrelated external storage such as the user’s SN750 must remain untouched.

## 16. Release test order

For a candidate code change:

1. `drive-check` / strict compile;
2. `drive-test-fast`;
3. `drive-test-system`;
4. `drive-test-virtual-usb`;
5. production installer compile if production packaging/source lists changed;
6. commit/push;
7. fixed-head GitHub Actions;
8. only when preparing a physical release candidate, execute exact-head installed/reboot/physical gates.

Do not run local UI performance xctrace.

## 17. Filesystem policy / NTFS ADR test consequences

`ADR-2026-09-03-ntfs-rw.md` is accepted and test behavior must follow it:

- Apple-native read-only NTFS is a valid supported compatibility result, not a failed writable test;
- read-only NTFS receives capability/remount verification only and never a write marker;
- writable ExFAT/FAT receives the create/fsync/hash/remount/delete persistence path;
- no test may silently enable an undocumented NTFS write mode or restore `ntfs-3g`;
- no ordinary regression test may auto-format or migrate an NTFS volume;
- a future independent NTFS RW provider requires a separate test plan and cannot inherit the current storage PASS claims.
