# EDP Drive — Release Checklist

Updated: 2026-09-03

> Use this checklist for an actual release candidate. A prior green commit does not substitute for exact-head verification of the package being released.

## 1. Candidate identity

Record before release testing:

```text
Branch:
Exact HEAD:
Version:
Clean.pkg path:
Clean.pkg SHA-256:
GitHub Actions run:
Date:
Tester:
```

The Git worktree must be clean and the package must be built from the exact recorded HEAD.

## 2. Code / architecture gate

- [ ] `git status` is clean.
- [ ] exact HEAD matches the intended remote branch.
- [ ] no uncommitted installer/runtime/UI changes.
- [ ] no old `MountManager` / `EDPDaemonController` path has returned.
- [ ] no Tauri/WebView/FUSE-T/ntfs-3g/authopen fallback has returned.
- [ ] no separate FDA subject for `edp-drive-service` has been introduced.
- [ ] no cached `diskN` is used as durable identity.

## 3. Automated local non-UI gate

Local machine may run deterministic/non-UI validation:

```bash
make drive-test-fast
make drive-test-system
make drive-test-virtual-usb
```

Expected:

- [ ] `RESULT=DRIVE_FAST_OK`
- [ ] `RESULT=DRIVE_SYSTEM_OK`
- [ ] `RESULT=DRIVE_VIRTUAL_USB_OK`
- [ ] S01–S35 present and PASS.
- [ ] lifecycle model executes 10,000 sequences / 320,000 steps.
- [ ] `git diff --check` PASS.

Do **not** use local xctrace timing as release UI evidence.

## 4. Production package build

Build the exact-head clean combined package using the repository-supported installer path.

- [ ] package build succeeds.
- [ ] package verification script succeeds.
- [ ] package contains one `EDP Drive.app` and embedded service, not a second Raw Access App.
- [ ] App and embedded service share the required stable self-signed certificate root.
- [ ] package includes the expected official macFUSE runtime/component.
- [ ] package does not contain ntfs-3g or FUSE-T product payloads.
- [ ] SHA-256 recorded above.

Never reuse an old package hash for a new exact HEAD.

## 5. Fixed-head GitHub Actions gate

Trigger `.github/workflows/drive.yml` on the exact candidate HEAD.

Required jobs:

- [ ] `native` PASS.
- [ ] `regression-fast` PASS.
- [ ] `regression-virtual-usb` PASS.
- [ ] `regression-storage` PASS.
- [ ] `regression-ui-system` PASS.

### Storage acceptance

Release storage log must include successful coverage of:

- [ ] M01;
- [ ] M02 and M04–M09;
- [ ] M03;
- [ ] M10 with at least 5 cycles;
- [ ] M12;
- [ ] M14;
- [ ] failure contracts;
- [ ] production Swift6/C17 strict build;
- [ ] `RESULT=DRIVE_STORAGE_E2E_OK`.

### UI acceptance

The UI gate is CI-only.

Required unchanged workload:

```text
20 sidebar toggles
8-second Animation Hitches trace
33,000,000 ns threshold
```

Required results:

- [ ] preview/page rendering PASS.
- [ ] 900×680 sidebar geometry contract PASS.
- [ ] accessibility structure PASS.
- [ ] `UI_HITCH_COUNT_GT33MS=0`.
- [ ] `RESULT=DRIVE_UI_ANIMATION_HITCHES_ZERO`.
- [ ] `RESULT=DRIVE_UI_OK`.

Do not increase the threshold, reduce toggles, shorten workload, or close unrelated user apps to create a pass.

## 6. Factory-clean baseline

Use the repository acceptance procedure:

```text
Apps/Drive/docs/FIRST-INSTALL-ACCEPTANCE.md
Apps/Drive/scripts/first-install-acceptance.sh
```

For a true first-install gate:

- [ ] user-context cleanup completed first where required.
- [ ] installed EDP Drive state removed.
- [ ] old EDP runtime/service state removed.
- [ ] old credentials/state removed as specified by the acceptance procedure.
- [ ] macFUSE baseline handled according to the factory-clean procedure.
- [ ] only the EDP Drive App FDA entry is reset for the factory-first-install scenario.
- [ ] `verify-clean` PASS.
- [ ] reboot.
- [ ] `verify-clean` PASS again after reboot.

Do not delete user source repositories or unrelated files as part of cleanup.

## 7. Install and signature gate

- [ ] install the exact recorded Clean.pkg.
- [ ] installer requires only the expected installation authorization.
- [ ] `/Applications/EDP Drive.app` exists.
- [ ] embedded `edp-drive-service` exists in the App bundle.
- [ ] service registration / Mach service is valid.
- [ ] strict code-sign verification PASS.
- [ ] App/service signing roots match the project signing identity.
- [ ] macFUSE Local runtime is installed/available.

## 8. FDA gate

Required policy:

```text
Grant Full Disk Access to EDP Drive only.
Do not grant separate FDA to edp-drive-service.
```

- [ ] FDA settings opened for EDP Drive App.
- [ ] user grants FDA once.
- [ ] no second service FDA item is required.
- [ ] App restart does not request another authorization.
- [ ] service restart does not request another authorization.

## 9. Standard encrypted physical EDP gate

Before insertion, enumerate all current physical external disks and note unrelated devices.

Safety:

- [ ] no unrelated external storage is touched.
- [ ] re-enumerate before every destructive/lifecycle action.
- [ ] never rely on a remembered `diskN`.
- [ ] never format/repartition/raw-write the physical EDP USB as a test.

On insertion:

- [ ] exactly expected standard encrypted device is classified as `standardEncrypted`.
- [ ] five-factor identity is stable: VID/PID/onlyId/capacity/LBA11 deviceId.
- [ ] retained raw access becomes ready without a second FDA/admin prompt.
- [ ] type 1 capability is reported correctly.
- [ ] type 2 credential can be verified/saved.
- [ ] type 4 credential can be verified/saved.
- [ ] mount policy matches saved policy rather than an implicit default.

Do not claim physical raw-EBUSY recovery unless a real physical EBUSY event actually occurred. Deterministic S31–S35 are contract evidence only.

## 10. Partition capability / persistence gate

Depending on the candidate’s configured policy:

- [ ] type 1 expected read/write/read-only capability verified.
- [ ] type 2 expected filesystem capability verified.
- [ ] type 4 expected filesystem capability verified.
- [ ] type 2 and type 4 credentials remain isolated.
- [ ] credential checkpoint PASS.
- [ ] policy round-trip PASS.
- [ ] no hidden transport/session residue after explicit unmount.

NTFS must be reported according to Apple native capability. Do not silently substitute a third-party write path.

## 11. Service lifecycle gate

- [ ] service health PASS.
- [ ] graceful Stop PASS.
- [ ] on-demand Start PASS.
- [ ] graceful Restart PASS.
- [ ] repeated start/stop cycles do not progressively slow materially.
- [ ] stopping the UI only leaves the intended service behavior.
- [ ] complete quit preserves the defined full-exit semantics.

Normal service stop must not use kill -9 as the normal product path.

## 12. Safe-eject gate

With the exact physical generation revalidated immediately before eject:

- [ ] XPC safe eject succeeds.
- [ ] all managed user filesystems are gone.
- [ ] DiskImages2 publication is gone or satisfies only the exact safe retired-tombstone contract.
- [ ] hidden macFUSE bridge is gone.
- [ ] transport process is gone.
- [ ] retained raw lease is released.
- [ ] snapshot reflects offline/saved state.
- [ ] automount/raw reacquisition remains suppressed after logical safe eject.
- [ ] residue = 0.
- [ ] U-state = 0.

After safe eject, merely restarting the App must not cause re-acquisition of the logically ejected still-inserted device.

## 13. Physical remove / reinsert gate

After actual removal and reinsertion:

- [ ] Drive rediscovers the device.
- [ ] stable five-factor device identity remains the same.
- [ ] current BSD name is re-enumerated; do not assume it matches the prior `diskN`.
- [ ] retained raw access returns without a new FDA/admin prompt.
- [ ] saved credential/policy state is available.
- [ ] configured auto-mount behavior is restored.

If `diskN` happens not to change during the test, do not report “physical diskN change verified.”

## 14. Exact-head reboot gate

This is mandatory for a release candidate even if earlier commits already passed reboot acceptance.

With the candidate installed and credentials/policy saved:

- [ ] reboot macOS.
- [ ] no manual service FDA is added before or after reboot.
- [ ] App starts/opens normally.
- [ ] service health PASS.
- [ ] macFUSE Local enablement is ready or converges through the bounded foreground enablement path.
- [ ] standard EDP device is discovered.
- [ ] retained App-FDA raw access works after reboot.
- [ ] no repeat admin/Touch ID/FDA authorization is required.
- [ ] credential persistence PASS.
- [ ] policy persistence PASS.
- [ ] configured partition mount behavior PASS.
- [ ] final safe eject PASS with residue/U-state = 0.

## 15. Physical negative-media matrix

These claims require the actual corresponding physical media.

### ordinary USB

- [ ] fixture available, otherwise `BLOCKED_BY_FIXTURE`.
- [ ] macOS owns it normally.
- [ ] Drive does not create retained raw lease.
- [ ] Drive does not create EDP mount session.
- [ ] Drive does not unmount/eject it as an EDP device.

### legacyNoPassword

- [ ] fixture available, otherwise `BLOCKED_BY_FIXTURE`.
- [ ] correctly classified.
- [ ] Drive does not enter password/raw/mount managed pipeline.

### currentNoPassword

- [ ] fixture available, otherwise `BLOCKED_BY_FIXTURE`.
- [ ] correctly classified.
- [ ] Drive does not enter password/raw/mount managed pipeline.

### unrecognizedEDP

- [ ] fixture available, otherwise `BLOCKED_BY_FIXTURE`.
- [ ] Drive does not create retained raw lease.
- [ ] Drive does not create mount session.

Virtual/synthetic evidence must not be used to check these physical boxes.

## 16. Recovery / fail-closed review

Before release, verify no change weakened these contracts:

- [ ] raw EBUSY recovery is exact-generation only and retries raw open exactly once.
- [ ] non-EBUSY raw errors never force whole-device unmount.
- [ ] replacement generation remains fail-closed.
- [ ] dead lower transport + live upper filesystem does not enter sync force-unmount.
- [ ] DiskImages2 tombstone retirement requires stable dead owner + zero entities.
- [ ] any changed DiskImages2 generation remains failure.
- [ ] agent reset is refused while any FSKit mount is active.
- [ ] PluginKit remains out of daemon mount hot paths.
- [ ] external recovery tools remain bounded.

## 17. Diagnostics gate

- [ ] runtime metrics snapshot exports only the seven approved UInt64 counters.
- [ ] no password/credential/secret/key/raw path/deviceID is added to the metrics schema.
- [ ] lifecycle journal remains bounded/redacted.
- [ ] failure states preserve useful typed teardown/recovery diagnostics.

## 18. Release decision

A candidate may be called **release-ready** only when:

- exact-head automated CI is all green;
- exact-head package verification passes;
- exact-head install + reboot gate passes;
- standard encrypted physical-device gate passes;
- no new critical fail-closed exception is unresolved;
- any missing negative physical fixture is explicitly documented as `BLOCKED_BY_FIXTURE`, not silently marked PASS.

NTFS RW is not a prerequisite unless the product decision explicitly changes in the NTFS ADR.

## 19. Current known blockers

As of 2026-09-03:

```text
ordinaryUSB physical negative      BLOCKED_BY_FIXTURE
legacyNoPassword physical negative BLOCKED_BY_FIXTURE
currentNoPassword physical negative BLOCKED_BY_FIXTURE
unrecognizedEDP physical negative  BLOCKED_BY_FIXTURE
exact-head reboot gate             NOT YET RUN for the next release candidate
NTFS RW ADR                         NOT YET DECIDED
```
