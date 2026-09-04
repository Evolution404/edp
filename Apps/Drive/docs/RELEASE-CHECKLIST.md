# EDP Drive — Release Checklist

Updated: 2026-09-04

> Use this checklist for an actual release candidate. A prior green commit does not substitute for exact-head verification of the package being released.

## 1. Candidate identity

Record before release testing:

```text
Status: PHYSICAL GATES PASS — exact-head reboot/post-reboot audit pending
Branch: codex/ui-macos26-liquid-glass
Release code/package HEAD: 9b5a8595203cf88ff726f9aa08bc62b8c25a8d29
Version: 0.6.0
Clean.pkg path: artifacts/EDP-Drive-0.6.0-arm64-Clean.pkg
Clean.pkg SHA-256: 43659c5fd37cc3cdb5546ab14b71782ea339bd6899209a59570bd119e0e9e264
Exact-head GitHub Actions run: 33748594918 — PASS 5/5
Physical acceptance: PASS for early claim, Pause/Resume/Restart continuity, safe eject, exact removal/reinsert, and Complete-Quit end state
Remaining mandatory gate: exact-head reboot + post-reboot health/identity/raw/safe-eject audit
Date: 2026-09-04
Tester: automated local + GitHub Actions + macOS first-install + physical Lexar acceptance
```

Earlier candidates remain historical invalidations: `51a6c9c` reacquired a logically safe-ejected still-inserted USB after App restart; `f7d7dde` closed that tombstone bug but a fresh replug exposed `fskitd` child-partition EBUSY; `54c048f` physically proved early standard-EDP `DADiskClaim` prevents that insertion race, but a true privileged-process stop/start destroyed the claim session and recreated the EBUSY window. `9b5a859` closes that lifecycle gap by keeping routine Stop/Start/Restart inside the same privileged process/DA owner and reserving true process shutdown for Complete Quit after safe-ejecting connected EDP devices. The installed `9b5a859` package has now passed those physical gates; only its exact-head reboot audit remains.

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
- [x] release-signing verifier succeeds with `EDP_REQUIRE_RELEASE_SIGNING=1`.
- [x] `RESULT=STABLE_SELF_SIGNED_RELEASE_IDENTITY`.
- [x] `RESULT=SELF_SIGNED_RELEASE_SERVICE_MODE_OK`.
- [x] package contains one `EDP Drive.app` and embedded service, not a second Raw Access App.
- [x] App and embedded service both resolve to pinned certificate root `040b5488fb2b6c02b0786e76b674cb4460658ca2`.
- [x] package includes the expected official macFUSE 5.3.3 runtime/component.
- [x] package does not contain ntfs-3g or FUSE-T product payloads.
- [x] SHA-256 for the signed exact-head package recorded above.

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

- [x] non-destructive `preflight` PASS on 2026-09-03: no external physical disk, no EDP/macFUSE transport mount, login.keychain remains DefaultKeychain; acceptance session created.
- [x] user-context cleanup completed first where required.
- [x] installed EDP Drive state removed.
- [x] old EDP runtime/service state removed.
- [x] old credentials/state removed as specified by the acceptance procedure.
- [x] macFUSE baseline handled according to the factory-clean procedure.
- [x] only the EDP Drive App FDA entry was reset for the factory-first-install scenario.
- [x] `verify-clean` PASS.
- [x] reboot completed and boot time revalidated.
- [x] `verify-clean` PASS again after reboot before signed install.

Do not delete user source repositories or unrelated files as part of cleanup.

## 7. Install and signature gate

- [x] install the exact recorded Clean.pkg.
- [x] installer requires only the expected installation authorization.
- [x] `/Applications/EDP Drive.app` exists.
- [x] embedded `edp-drive-service` exists in the App bundle.
- [x] installer-managed LaunchDaemon / Mach service is valid and running.
- [x] `verify-installed` + privileged XPC smoke/snapshot PASS.
- [x] strict code-sign verification PASS.
- [x] App/service signing roots both equal the pinned project certificate root.
- [x] macFUSE Local runtime is installed/available.

## 8. FDA gate

Required policy:

```text
Grant Full Disk Access to EDP Drive only.
Do not grant separate FDA to edp-drive-service.
```

- [x] FDA settings opened for EDP Drive App.
- [x] user grants FDA once to EDP Drive only.
- [x] no second service FDA item is required; service raw access is brokered through the signed App identity.
- [x] App restart retains `privilegedAccessReady=true` without another authorization.
- [!] true privileged-process stop/start on installed `54c048f` reproduced a DA-claim gap: the old claim disappeared, `fskitd` took `/dev/rdisk6s1`, and raw access returned to EBUSY. Routine product Stop/Start/Restart has therefore been redesigned as claim-continuous runtime pause/resume/restart; the replacement package must physically prove those controls retain/recover `privilegedAccessReady` without another authorization.

## 9. Standard encrypted physical EDP gate

Before insertion, enumerate all current physical external disks and note unrelated devices.

Safety:

- [x] no unrelated external storage was present/touched during this first-install physical gate.
- [x] physical storage was re-enumerated before lifecycle operations; stale `diskN` was not used as identity.
- [x] the stable device ID / five-factor identity, not BSD name, drove acceptance.
- [x] the physical EDP USB was never formatted or repartitioned; type1 was never filesystem-written and only capability-aware temporary data markers were used on writable type2/type4.

On insertion:

- [x] Lexar `21c4:0cd1` standard encrypted EDP entered the managed pipeline; non-managed media rules remain separately fixture-gated.
- [x] five-factor identity is stable: VID/PID `21c4:0cd1`, onlyID `3164177653`, capacity `124736503808`, metadata deviceID `disk&ven_lexar&prod_usb_flash_drive`, stable ID `disk&ven_lexar&prod_usb_flash_drive#59e8f8ae5883447c198104e7`.
- [x] retained raw access becomes ready without a second FDA/admin prompt.
- [x] type 1 capability is FAT16 read-only.
- [x] type 2 credential verified/saved in App UI without password entering logs/CLI.
- [x] type 4 credential verified/saved in App UI without password entering logs/CLI.
- [x] saved policy remains `autoMount=false` for type1/type2/type4 and survives policy round-trip restore.

Do not claim physical raw-EBUSY recovery unless a real physical EBUSY event actually occurred. Deterministic S31–S35 are contract evidence only.

## 10. Partition capability / persistence gate

Depending on the candidate’s configured policy:

- [x] type 1 read-only capability verified across mount/unmount/remount; no marker write performed.
- [x] type 2 writable capability verified with temporary marker persistence across remount and marker deletion afterward.
- [x] type 4 writable capability verified with temporary marker persistence across remount and marker deletion afterward.
- [x] type 2 and type 4 credentials remain isolated/saved.
- [x] credential checkpoint PASS before and after physical reinsert.
- [x] policy round-trip/restore PASS before and after physical reinsert.
- [x] all three partitions were explicitly unmounted after capability tests.

NTFS follows the accepted `ADR-2026-09-03-ntfs-rw.md` policy: Apple-native read-only compatibility is supported; writable cross-platform data should use ExFAT; do not silently substitute a third-party write path or automatically reformat NTFS.

## 11. Service lifecycle gate

Historical process-level lifecycle evidence remains useful for launchd/on-demand health, but it is no longer the product meaning of the routine UI Stop/Start/Restart controls while an EDP device is claimed.

- [x] service health PASS.
- [x] historical 8-cycle process-level gate PASS: warmup 74ms; steady starts 1049–1072ms; first steady avg 1064.0ms, last avg 1060.3ms, slope -0.2ms/cycle; one daemon each cycle.
- [x] S42 deterministic contract PASS: runtime pause releases raw state and resume reacquires the same generation without service shutdown.
- [x] S43 deterministic contract PASS: runtime restart reuses the same service / Disk Arbitration owner.
- [x] physical runtime Pause PASS on installed `9b5a859`: raw lease released, `runtimePaused=true`, service PID stayed `34883`, `DA_CLAIMED=true`, and no EBUSY recovery occurred.
- [x] physical runtime Start/Resume PASS: same service PID/claim owner retained control and `privilegedAccessReady=true` reconverged automatically within about 2 seconds, with `rawBusyRecoveryCount=0` and no new FDA prompt.
- [x] physical runtime Restart PASS: service PID remained `34883`, `DA_CLAIMED=true` throughout, raw access reconverged automatically, and no `fskitd` child holder appeared.
- [x] Complete Quit end-state PASS: after safe eject, graceful service shutdown plus foreground App termination left both processes absent; reopening EDP Drive restored the service while the still-inserted logically-ejected Lexar remained suppressed (`privilegedAccessReady=false`).

Routine lifecycle control must not use `kill -9` and must not terminate the privileged process merely to implement Stop/Start/Restart. True process shutdown is reserved for Complete Quit.

## 12. Safe-eject gate

With the exact physical generation revalidated immediately before eject:

- [x] XPC safe eject succeeds.
- [x] all managed user filesystems are gone after eject.
- [x] final DiskImages2 publication/residue audit after mandatory reboot found no EDP publication/mount/process residue.
- [x] final hidden macFUSE bridge/transport audit after mandatory reboot found no `.edp-*` mount/volume or `edp-mfmount`/`diskimages2-attach` process residue.
- [x] retained raw lease is released (`privilegedAccessReady=false`) while the logically ejected device remains physically inserted.
- [x] snapshot reflects unavailable partitions with saved credential state.
- [x] automount/raw reacquisition remains suppressed after logical safe eject.
- [x] final residue = 0 immediately after final safe eject.
- [x] final U-state = 0 immediately after final safe eject (`privilegedAccessReady=false`, all partitions unavailable).
- [x] `f7d7dde` focused physical retest closed the original App/service restart blocker: safe eject kept `privilegedAccessReady=false` across foreground App restart and a complete privileged-service stop/start while the same USB generation remained physically inserted; type2/type4 saved credential state remained intact.
- [x] installed `54c048f` then proved the S41 prevention path on a fresh physical replug: `DA_CLAIMED=true`, root `lsof` showed `edp-drive-service` as the only raw holder on `/dev/rdisk6`, no `fskitd` child-partition holder existed, `privilegedAccessReady=true`, and both `rawBusyRecoveryCount` / `forcedWholeUnmountCount` remained zero.
- [x] installed `9b5a859` closed the former claim-gap blocker: foreground App restart kept raw readiness/claim; routine runtime Pause/Resume/Restart kept one privileged service PID and continuous DA ownership; safe eject still succeeded under the active early claim; App/runtime restart while logically ejected did not reacquire.

After safe eject, merely restarting the App or service must not cause re-acquisition of the logically ejected still-inserted device. Transient discovery/metadata omission must not clear suppression. If a replacement generation is observed while the persisted original USB registry generation still exists, both remain fail-closed; only confirmed disappearance of the original registry generation may admit the replacement. On the subsequent fresh insertion, raw access must return automatically without FDA/admin prompting and without a persistent `fskitd` holder on the physical child partition.

## 13. Physical remove / reinsert gate

After actual removal and reinsertion:

- [x] Drive rediscovers the device after physical removal/reinsert.
- [x] stable five-factor device identity remains the same.
- [x] latest `9b5a859` focused retest re-enumerated the Lexar as `disk27`; BSD-name value is evidence only and is not durable identity.
- [x] `9b5a859` fresh replug restored retained raw access directly under early claim: `DA_CLAIMED=true`, root `lsof` showed only `edp-drive-service` on `/dev/rdisk27`, no `/dev/rdisk27s1` `fskitd` holder appeared, and no EBUSY recovery was needed.
- [x] saved credential/policy state remained available across removal/reinsert.
- [x] configured auto-mount behavior (`false` on all three partitions) remained restored.

If `diskN` happens not to change during the test, do not report “physical diskN change verified.”

## 14. Exact-head reboot gate

This is mandatory for a release candidate even if earlier commits already passed reboot acceptance.

With the candidate installed and credentials/policy saved:

- [x] reboot macOS completed; boot time revalidated as 2026-09-03 14:51:53.
- [x] no manual service FDA was added before or after reboot.
- [x] App/service opened and XPC health remained normal after reboot.
- [x] service health PASS.
- [x] macFUSE Local path was operational, proven by post-reboot type1/type2/type4 mount/remount tests.
- [x] standard Lexar EDP device was discovered after reboot.
- [x] retained App-FDA raw access worked after reboot.
- [x] no repeat admin/Touch ID/FDA authorization was required.
- [x] credential persistence PASS.
- [x] policy persistence PASS.
- [x] configured partition behavior/capability PASS, including type1 RO and type2/type4 RW persistence.
- [x] historical reboot gate for the earlier baseline passed, but it does not substitute for the mandatory `9b5a859` exact-head reboot.
- [ ] reboot the currently installed `9b5a859` package and repeat service health, five-factor identity, retained raw access, credential/policy persistence and final safe-eject audit.

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

As of 2026-09-04:

```text
ordinaryUSB physical negative      BLOCKED_BY_FIXTURE
legacyNoPassword physical negative BLOCKED_BY_FIXTURE
currentNoPassword physical negative BLOCKED_BY_FIXTURE
unrecognizedEDP physical negative  BLOCKED_BY_FIXTURE
9b5a859 physical release gates      PASS; exact-head reboot/post-reboot audit PENDING
NTFS RW ADR                         ACCEPTED A+C (native NTFS RO + writable ExFAT)
```
