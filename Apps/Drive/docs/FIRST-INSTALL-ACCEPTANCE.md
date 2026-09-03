# EDP Drive — First-Install Full Acceptance

> Current product facts and release criteria are defined by `STATUS.md`, `ARCHITECTURE.md`, `TESTING.md`, and `RELEASE-CHECKLIST.md`. This file is the detailed machine-execution procedure and must remain consistent with those four current sources of truth.

This document defines the repeatable clean-machine acceptance process for the macOS 26+ product. The executable harness is:

```bash
./scripts/first-install-acceptance.sh
```

The purpose is to reproduce the conditions of a real first install, verify every user-facing storage path, and preserve enough evidence to compare future release candidates.

## Product architecture under test

The accepted product path is macFUSE-only:

```text
physical standardEncrypted EDP USB
  -> EDP Drive App Full Disk Access identity
  -> hidden root broker mode of the same EDP Drive executable
  -> retained whole-device O_RDWR fd in the privileged service
  -> partition 1: plaintext MBR FAT slice
  -> partition 2/4: SM4 read/write block translation
  -> macFUSE Local FSKit transport
  -> hidden volume.raw
  -> DiskImages2
  -> Apple native filesystem stack
  -> Finder
```

The product does not depend on physical `/dev/diskNs1` being present after the daemon obtains the retained whole-disk descriptor. Startup, exchange, and secret partitions are all published from the same retained raw descriptor.

## Safety invariants

The cleanup harness is intentionally fail-closed.

- Cleanup refuses to run while `diskutil list external physical` contains any physical external disk.
- It never calls disk formatting, partitioning, erase, zeroing, or raw-sector write commands.
- Real exchange/secret passwords are never accepted as script arguments, environment variables, files, or log content. Password validation and storage occur only in the App UI and System Keychain.
- `user-cleanup` runs without `sudo` so macOS TCC permits the logged-in user to remove their own macFUSE/EDP Containers, Group Containers, preferences, caches, saved state, and FSKit enablement state. Privileged cleanup must not try to bypass these user-domain TCC boundaries.
- `factory-first-install` resets only the visible EDP Drive App Full Disk Access entry (`com.edp.drive`) with Apple's `tccutil`; it does not modify the TCC database directly.
- The user's DefaultKeychain must remain `login.keychain`; temporary EDP signing keychains are treated as a hard failure.
- Acceptance result storage rejects symlinked report roots/session pointers and is mode `0700`.
- Test files are ordinary filesystem files with unique names. They are removed after hash/persistence verification.
- Safe eject is performed through the production XPC path, not `diskutil eject` as a substitute for product behavior.

## Two cleanup modes

### Factory first install

Use this for a true "never installed before" acceptance run:

```bash
./scripts/first-install-acceptance.sh preflight
./scripts/first-install-acceptance.sh user-cleanup
sudo ./scripts/first-install-acceptance.sh factory-first-install
./scripts/first-install-acceptance.sh verify-clean
```

`user-cleanup` must run in the logged-in user's normal TCC context. The sudo stage requires its session marker, then removes EDP App/embedded-service/runtime/system state/credentials/receipts, uninstalls the system macFUSE runtime, and resets the EDP Drive App FDA entry. This split is required on macOS 26 because a root shell launched through an authorization context is not automatically allowed to traverse the logged-in user's protected Containers/Group Containers.

Reboot after `verify-clean`, then run `verify-clean` again before installing the release candidate.

### Clean reinstall with FDA preserved

Use this to test reinstall/upgrade FDA continuity:

```bash
./scripts/first-install-acceptance.sh preflight
./scripts/first-install-acceptance.sh user-cleanup
sudo ./scripts/first-install-acceptance.sh clean-install
./scripts/first-install-acceptance.sh verify-clean
```

This removes installed state but deliberately preserves the single EDP Drive App FDA grant. The same non-root `user-cleanup` gate is required before the privileged stage.

## Canonical first-install sequence

Run the following sequence for each release candidate.

```text
1.  preflight
2.  user-cleanup
3.  sudo factory-first-install
4.  verify-clean
5.  reboot Mac
6.  verify-clean
7.  sudo install <candidate.pkg>
8.  verify-installed
9.  open-fda
10. user grants FDA once to EDP Drive only
11. insert one real EDP USB
12. verify-fda-device [VID:PID]
13. save/validate exchange and secret passwords in the App UI
14. credential-checkpoint
15. policy-smoke
16. functional-all
17. safe-eject
18. physically unplug the USB
19. physically reinsert the USB
20. verify-fda-device [VID:PID]
21. restart-app
22. verify-fda-device [VID:PID]
23. service-stop
24. confirm the service remains stopped and is not relaunched by launchd
25. service-start
26. verify-fda-device [VID:PID]
27. service-restart
28. verify-fda-device [VID:PID]
29. reboot Mac
30. verify-fda-device [VID:PID]
31. credential-checkpoint
32. policy-smoke
33. functional-all
34. final-check
```

## What each stage proves

### `verify-installed`

Confirms the single EDP Drive App, embedded service, macFUSE/runtime presence, code signatures, App/service version agreement, LaunchDaemon state, privileged XPC round trip, and a clean keychain configuration with no USB attached.

### `verify-fda-device`

Requires exactly one connected EDP device with `privilegedAccessReady=true`. An optional expected `VID:PID` prevents accidentally accepting a different USB device.

### `credential-checkpoint`

Requires:

```text
type 1 -> credential=notRequired
type 2 -> credential=saved
type 4 -> credential=saved
```

If type 2/4 are not saved, the harness stops before any filesystem write test. The user must return to the App UI and save the actual password there.

### `policy-smoke`

Saves current values, then verifies round-trip persistence for:

- device display name;
- global auto-mount;
- startup auto-mount;
- exchange auto-mount;
- secret auto-mount.

The harness disables global auto-mount while toggling per-partition values so the policy test itself does not trigger mounts. It restores the original values and verifies the restored snapshot before returning success.

### `functional-all`

For type 1, 2, and 4, the harness first reads the exact partition state from the production XPC snapshot after mounting. Validation follows the filesystem capability reported by the installed product rather than assuming every partition is writable.

```text
mount
  -> read exact filesystem / readOnly / mountPoint from XPC snapshot
  -> if readOnly=true:
       production XPC unmount
       -> production XPC remount
       -> require the same filesystem classification and readOnly=true
       -> production XPC unmount
  -> if readOnly=false:
       create one unique ordinary test file
       -> sync -> SHA-256
       -> production XPC unmount/remount
       -> verify file and SHA-256 persistence
       -> remove test file -> sync -> production XPC unmount
```

Type 1 is required to remain read-only. NTFS volumes mounted read-only by the current Apple-native policy are never written by acceptance. Writable ExFAT/FAT data volumes still receive the temporary marker persistence test. Mount/unmount completion and the exact mount point come from the XPC snapshot, not hard-coded `/Volumes/...` path polling.

### `safe-eject`

Uses the same XPC `eject()` operation as the UI. It verifies all three user volumes disappear and retained raw access is not reacquired while the physically connected USB remains logically ejected.

### App/service/reboot gates

- `restart-app` proves foreground App lifecycle does not disturb a live service or FSKit configuration.
- `service-stop` uses the product XPC graceful-shutdown contract. It must tear down every mount/transport/raw lease and the launchd job must remain stopped; `KeepAlive`/`RunAtLoad` may not silently revive it.
- `service-start` proves a new privileged service instance can be activated on demand through its Mach service without administrator authorization.
- `service-restart` is `service-stop -> service-start`; it validates the same lifecycle used by the UI Restart button and does not use `launchctl kickstart -k` as a substitute.
- The Mac reboot gate proves FDA, LaunchDaemon registration, macFUSE FSKit enablement, device discovery, credential access, policy state, and full three-partition mounting survive an actual system restart.

## Evidence

Each run creates a session directory under:

```text
/Users/Shared/EDP Drive Acceptance/<UTC-session-id>/
```

The directory is owned by the console user and mode `0700`. `results.log` records only stage results, IDs, hashes, and package metadata. Passwords are never recorded.

The current session pointer is:

```text
/Users/Shared/EDP Drive Acceptance/current-session
```

The harness validates the pointer format and refuses symlinks before privileged stages consume it.

## Release gate

A candidate is not considered first-install accepted until all of the following are true on a real macOS 26 machine:

- factory cleanup and post-reboot clean verification pass;
- clean package verification and installation pass;
- only one explicit FDA grant is required;
- no per-device admin/fingerprint authorization occurs;
- startup/exchange/secret all pass capability-aware remount persistence; read-only volumes remain read-only and only writable volumes receive the temporary write/hash test;
- device/policy/credential state behaves correctly;
- safe eject remains suppressed until physical removal;
- physical reinsertion reacquires retained raw access without authorization;
- App restart passes;
- daemon restart passes;
- Mac reboot passes;
- the user's login keychain remains the DefaultKeychain throughout;
- the repository's macFUSE-only and installer CI contracts are green at the exact tested HEAD.
