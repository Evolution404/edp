# EDP Drive — Release Checklist

Updated: 2026-09-03

> Use this checklist for an actual release candidate. A prior green commit does not substitute for exact-head verification of the package being released.

## 1. Candidate identity

Record before release testing:

```text
Status: INVALIDATED — the package below was ad-hoc signed and is not a release candidate
Branch: codex/ui-macos26-liquid-glass
Previous runtime HEAD: f734f43899e174c5965f32917f6164ccb2994305
Version: 0.6.0
Invalidated Clean.pkg SHA-256: 62f685f3fe69006f165cf649e49acb8d2bb9dc7e31e85033e01bf5416e7dedda
Previous automated GitHub Actions run: 33711677562
Replacement signed candidate: PENDING after release-signing gate commit
Date: 2026-09-03
Tester: automated local + GitHub Actions + macOS first-install acceptance
```

The invalidated package passed ordinary `codesign --verify` but had a cdhash-only designated requirement. It was rejected by the privileged XPC signer boundary on the clean machine and must never be installed for further physical/FDA acceptance.

The Git worktree must be clean and the package must be built from the exact recorded HEAD.

## 2. Code / architecture gate

- [x] `git status` is clean at the recorded candidate build/CI point.
- [x] exact HEAD matches the intended remote branch.
- [x] no uncommitted installer/runtime/UI changes at candidate build time.
- [x] no old `MountManager` / `EDPDaemonController` path has returned.
- [x] no Tauri/WebView/FUSE-T/ntfs-3g/authopen fallback has returned.
- [x] no separate FDA subject for `edp-drive-service` has been introduced.
- [x] no cached `diskN` is used as durable identity.

## 3. Automated local non-UI gate

Local machine may run deterministic/non-UI validation:

```bash
make drive-test-fast
make drive-test-system
make drive-test-virtual-usb
```

Expected:

- [x] `RESULT=DRIVE_FAST_OK`
- [x] `RESULT=DRIVE_SYSTEM_OK`
- [x] `RESULT=DRIVE_VIRTUAL_USB_OK`
- [x] S01–S35 present and PASS.
- [x] lifecycle model executes 10,000 sequences / 320,000 steps.
- [x] `git diff --check` PASS.

Do **not** use local xctrace timing as release UI evidence.

## 4. Production package build

Build the exact-head clean combined release package using the certificate-backed release entry only:

```bash
make drive-release-installer ARTIFACTS="$PWD/Apps/Drive/artifacts"
```

Do **not** use `build-clean-installer.sh` directly as a physical release-candidate entry. That lower-level builder intentionally supports ad-hoc/CI configurations.

Required release-signing evidence:

- [x] package build succeeds.
- [x] package verification script succeeds (`RESULT=EDP_CLEAN_INSTALLER_VERIFIED`).
- [ ] release-signing verifier succeeds with `EDP_REQUIRE_RELEASE_SIGNING=1`.
- [ ] `RESULT=STABLE_SELF_SIGNED_RELEASE_IDENTITY`.
- [ ] `RESULT=SELF_SIGNED_RELEASE_SERVICE_MODE_OK`.
- [x] package contains one `EDP Drive.app` and embedded service, not a second Raw Access App.
- [ ] App and embedded service both resolve to pinned certificate root `040b5488fb2b6c02b0786e76b674cb4460658ca2`.
- [x] package includes the expected official macFUSE 5.3.3 runtime/component.
- [x] package does not contain ntfs-3g or FUSE-T product payloads.
- [ ] SHA-256 for the newly rebuilt signed package recorded above.

An ad-hoc designated requirement of the form `cdhash H"..."` is a release failure even if ordinary `codesign --verify` succeeds. Never reuse an old package hash for a new exact HEAD.

## 5. Fixed-head GitHub Actions gate

Trigger `.github/workflows/drive.yml` on the exact candidate HEAD.

Required jobs:

- [x] `native` PASS.
- [x] `regression-fast` PASS.
- [x] `regression-virtual-usb` PASS.
- [x] `regression-storage` PASS.
- [x] `regression-ui-system` PASS.

### Storage acceptance

Release storage log must include successful coverage of:

- [x] M01;
- [x] M02 and M04–M09;
- [x] M03;
- [x] M10 with 5 cycles;
- [x] M12;
- [x] M14;
- [x] failure contracts;
- [x] production Swift6/C17 strict build;
- [x] `RESULT=DRIVE_STORAGE_E2E_OK`.

### UI acceptance

The UI gate is CI-only.

Required unchanged workload:

```text
20 sidebar toggles
8-second Animation Hitches trace
33,000,000 ns threshold
```

Required results:

- [x] preview/page rendering PASS.
- [x] 900×680 sidebar geometry contract PASS (`UI_SIDEBAR_TOGGLE_1...20_OK`, `DRIVE_UI_900X680_SIDEBAR_OK`).
- [x] accessibility structure PASS.
- [x] `UI_HITCH_COUNT_GT33MS=0`.
- [x] `RESULT=DRIVE_UI_ANIMATION_HITCHES_ZERO`.
- [x] `RESULT=DRIVE_UI_OK`.

Do not increase the threshold, reduce toggles, shorten workload, or close unrelated user apps to create a pass.

## 6. Factory-clean baseline

Use the repository acceptance procedure:

```text
Apps/Drive/docs/FIRST-INSTALL-ACCEPTANCE.md
Apps/Drive/scripts/first-install-acceptance.sh
```

For a true first-install gate:

- [x] non-destructive `preflight` PASS on 2026-09-03: no external physical disk, no EDP/macFUSE transport mount, login.keychain remains DefaultKeychain; acceptance session `20260903T005258Z-22259` created.
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

NTFS follows the accepted `ADR-2026-09-03-ntfs-rw.md` policy: Apple-native read-only compatibility is supported; writable cross-platform data should use ExFAT; do not silently substitute a third-party write path or automatically reformat NTFS.

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

- [x] raw EBUSY recovery is exact-generation only and retries raw open exactly once.
- [x] non-EBUSY raw errors never force whole-device unmount.
- [x] replacement generation remains fail-closed.
- [x] dead lower transport + live upper filesystem does not enter sync force-unmount.
- [x] DiskImages2 tombstone retirement requires stable dead owner + zero entities.
- [x] any changed DiskImages2 generation remains failure.
- [x] agent reset is refused while any FSKit mount is active.
- [x] PluginKit remains out of daemon mount hot paths.
- [x] external recovery tools remain bounded.

## 17. Diagnostics gate

- [x] runtime metrics snapshot exports only the seven approved UInt64 counters.
- [x] no password/credential/secret/key/raw path/deviceID is added to the metrics schema.
- [x] lifecycle journal remains bounded/redacted.
- [x] failure states preserve useful typed teardown/recovery diagnostics.

## 18. Release decision

A candidate may be called **release-ready** only when:

- exact-head automated CI is all green;
- exact-head package verification passes;
- exact-head install + reboot gate passes;
- standard encrypted physical-device gate passes;
- no new critical fail-closed exception is unresolved;
- any missing negative physical fixture is explicitly documented as `BLOCKED_BY_FIXTURE`, not silently marked PASS.

NTFS RW is not a prerequisite for this release. The accepted NTFS ADR uses native NTFS read-only compatibility plus ExFAT for writable cross-platform data. A separate NTFS RW provider requires a future hard NTFS-preservation requirement and a separate implementation plan.

## 19. Current known blockers

As of 2026-09-03:

```text
ordinaryUSB physical negative      BLOCKED_BY_FIXTURE
legacyNoPassword physical negative BLOCKED_BY_FIXTURE
currentNoPassword physical negative BLOCKED_BY_FIXTURE
unrecognizedEDP physical negative  BLOCKED_BY_FIXTURE
factory-clean/install/reboot gate NOT YET RUN for release candidate f734f43
NTFS RW ADR                         ACCEPTED A+C (native NTFS RO + writable ExFAT)
```
