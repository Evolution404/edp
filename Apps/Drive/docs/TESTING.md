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

Authoritative for hardware-free lifecycle semantics. The suite now also invokes the full software-only Virtual USB Lab, so routine insert/mount/eject/remove/reinsert regression requires no real USB hardware.

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
- safe-eject logical suppression S36–S40: App reconcile does not reacquire, service restart preserves the tombstone, discovery omission cannot retire a live generation, replacement generation overlap fails closed, and only exact original USB-registry disappearance releases the new generation;
- S41 early Disk Arbitration claim classification: verified `standardEncrypted` media is eligible for the pre-FSKit whole-disk claim, while metadata failure/nonstandard media fails open to macOS;
- S42 claim-continuous runtime pause/resume: pause releases managed raw state without process shutdown, and resume reacquires the same physical generation;
- S43 in-process runtime restart: teardown/reconcile reuses the same service/DA owner rather than creating a claim gap;
- fixed-seed lifecycle property model;
- full software-only USB integration flow V01–V07: simulated OS automount before Drive start, Drive takeover, active-service mount-approval denial + claim, partition 1/2/4 mount/unmount, runtime pause/resume/restart, safe eject, physical-generation removal/reinsert with a different `diskN`, abrupt unplug while mounted, and non-EDP fail-open behavior.

### Full software-only Virtual USB Lab

Direct command:

```bash
make drive-test-virtual-usb-lab
```

The lab uses the captured EDP metadata fixture plus in-memory `EDPVirtualUSBState`, a virtual Disk Arbitration owner/mount table and a virtual mount manager. It executes the real `EDPServiceController`; only hardware/OS edges are injected. It does **not** enumerate `/dev/diskN`, does not invoke `diskutil`, does not use `IOUSBHost`, and does not require any external storage device.

A small production-default testability seam injects the `hasMountedBSDPrefix` check. Production still defaults to `EDPNativeMountTable.hasMountedBSDPrefix`; the lab injects its own in-memory mount table. This allows the same raw-access takeover path to exercise “macOS had already mounted the boot child before Drive started” without creating a real mount.

Expected markers:

```text
SCENARIO=V01_OK boot_system_automount_then_edp_takeover_without_physical_usb
SCENARIO=V02_OK fresh_insert_mount_approval_dissent_claim_raw_ready
SCENARIO=V03_OK virtual_partition_1_2_4_mount_unmount
SCENARIO=V04_OK virtual_pause_resume_restart_same_generation
SCENARIO=V05_OK virtual_safe_eject_remove_reinsert_new_generation
SCENARIO=V06_OK abrupt_virtual_unplug_while_mounted_cleans_session_and_recovers
SCENARIO=V07_OK non_edp_virtual_usb_fail_open_to_system
RESULT=DRIVE_FULLY_SOFTWARE_VIRTUAL_USB_OK
```

Important distinction:

S31–S35 prove the **contract** of raw EBUSY recovery. They do not prove a physical EBUSY event occurred on a real USB device. S36–S40 are deterministic lifecycle evidence for safe-eject suppression and exact-generation retirement. S41 proves the standard-only/fail-open classification contract for the early Disk Arbitration claim; fresh `54c048f` physical reinsert proved the claim can win the macOS 26 FSKit probe race, and installed `9b5a859` completed the lifecycle proof: physical Pause/Resume/Restart kept one service PID and continuous `DA_CLAIMED=true`, raw access reconverged without EBUSY, safe eject remained valid under the active claim, App/runtime restart while logically ejected did not reacquire, exact physical removal retired the original generation, reinsertion regained early claim/raw readiness, and root `lsof` showed no `fskitd` child-partition holder. Complete-Quit end state was also physically exercised. The remaining release gate is the exact-head reboot/post-reboot audit for the installed `9b5a859` package.

Expected high-level markers include:

```text
SCENARIO=S01_OK ... SCENARIO=S47_OK
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

On an interactive local desktop, `run-storage.sh` refuses to run by default because synthetic FSKit/DiskImages2 teardown can stall Finder. Storage E2E is CI-authoritative. An isolated local test environment may opt in explicitly with `EDP_ALLOW_LOCAL_STORAGE_E2E=1`; do not use that override on the user's normal desktop session.

The smoke profile uses `EDP_STORAGE_LOOP_COUNT=3` for ordinary PR/development CI. The release profile remains `EDP_STORAGE_LOOP_COUNT=5`, and the scheduled stress job remains 100 cycles. Final release candidates must explicitly select the release profile; the faster smoke profile does not satisfy the release checklist.

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

The hitch target is started by the test runner itself and `xctrace` attaches to its PID. `xctrace --notify-tracing-started` opens an explicit gate before sidebar toggles begin. The target then stays alive past the 8-second trace limit so Instruments owns recording termination instead of racing an early target exit during trace finalization. The parser still scopes performance strictly to the toggle begin/end timestamps, so the post-toggle hold is excluded from hitch scoring. This avoids the macOS 26 runner's observed `xctrace --launch`/teardown stalls while preserving the same trace window and 33ms threshold.

A performance PASS requires:

```text
UI_HITCH_COUNT_GT33MS=0
RESULT=DRIVE_UI_ANIMATION_HITCHES_ZERO
RESULT=DRIVE_UI_OK
```

## 10. GitHub Actions responsibility split

Workflow: `.github/workflows/drive.yml`

### `native`

Builds EDPCore and compiles the production daemon / SwiftUI App under strict `-O`, Swift 6 and `-warnings-as-errors` settings. Golden/media/transport validators are not duplicated here; those contracts belong to `regression-fast`.

### `regression-fast`

Runs:

```bash
make drive-test-fast
```

Native-core golden, metadata/media classification, transport lifecycle, bounded-VFS and product-model validators are linked into one `-Onone` test executable. The regression still runs EDPCore tests, strict App typecheck and block-publisher contracts, but avoids recompiling the same validator source set several times.

### `regression-virtual-usb`

Runs:

```bash
make drive-test-virtual-usb
```

Discovery, P16–P30, C/D, S01–S47, the 320,000-step property model and V01–V07 are linked into one `-Onone` regression executable. The production/runtime sources are therefore compiled once per job instead of once per validator; coverage and Swift 6 `-warnings-as-errors` remain unchanged.

### `regression-storage`

On macOS 26:

1. installs official macFUSE Local FSKit runtime;
2. ordinary push/PR/manual runs default to `make drive-test-storage-smoke` (3 M10 cycles);
3. a final manual release run selects workflow input `storage_profile=release`, which runs `make drive-test-storage` (5 M10 cycles);
4. uploads storage logs.

Timeout: 30 minutes. The smoke result is development evidence only; release acceptance requires the explicit 5-cycle release profile.

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

Generic combined clean-installer builder (CI/development only):

```bash
Apps/Drive/installer/build-clean-installer.sh <output-dir>
```

**Do not use that raw builder as the final self-signed release-candidate entry.** It supports ad-hoc/CI configurations by design.

Canonical physical-release entry from the repository root:

```bash
make drive-release-installer ARTIFACTS="$PWD/Apps/Drive/artifacts"
```

Equivalent Drive-local entry:

```bash
Apps/Drive/installer/build-self-signed-installer.sh Apps/Drive/artifacts
EDP_REQUIRE_RELEASE_SIGNING=1 Apps/Drive/scripts/verify-clean-installer.sh Apps/Drive/artifacts/EDP-Drive-0.6.0-arm64-Clean.pkg
```

The release entry pins `EDP Project Code Signing`, certificate root `040b5488fb2b6c02b0786e76b674cb4460658ca2`, and the proven self-signed installer-managed service mode. The release-signing verifier rejects ad-hoc App/service signatures even when ordinary `codesign --verify` succeeds.

The combined installer includes the pinned official macFUSE package/runtime material required by the product.

Before physical release acceptance, verify the exact generated package using the release-signing verifier rather than relying only on filename or prior hashes.

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
