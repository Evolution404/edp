# EDP USB Vault — First-Install Full Acceptance

This document defines the repeatable clean-machine acceptance process for the macOS 26+ product. The executable harness is:

```bash
./scripts/first-install-acceptance.sh
```

The purpose is to reproduce the conditions of a real first install, verify every user-facing storage path, and preserve enough evidence to compare future release candidates.

## Product architecture under test

The accepted product path is macFUSE-only:

```text
physical EDP USB
  -> persistent Full Disk Access Raw Access daemon
  -> retained whole-device O_RDWR fd
  -> partition 1: plaintext MBR FAT slice
  -> partition 2/4: SM4 read/write block translation
  -> macFUSE Local FSKit transport
  -> hidden volume.raw
  -> DiskImages2
  -> Apple filesystem stack / NTFS-3G where applicable
  -> Finder
```

The product does not depend on physical `/dev/diskNs1` being present after the daemon obtains the retained whole-disk descriptor. Startup, exchange, and secret partitions are all published from the same retained raw descriptor.

## Safety invariants

The cleanup harness is intentionally fail-closed.

- Cleanup refuses to run while `diskutil list external physical` contains any physical external disk.
- It never calls disk formatting, partitioning, erase, zeroing, or raw-sector write commands.
- Real exchange/secret passwords are never accepted as script arguments, environment variables, files, or log content. Password validation and storage occur only in the App UI and System Keychain.
- `factory-first-install` resets only the Raw Access helper Full Disk Access entry with Apple's `tccutil`; it does not modify the TCC database directly.
- The user's DefaultKeychain must remain `login.keychain`; temporary EDP signing keychains are treated as a hard failure.
- Acceptance result storage rejects symlinked report roots/session pointers and is mode `0700`.
- Test files are ordinary filesystem files with unique names. They are removed after hash/persistence verification.
- Safe eject is performed through the production XPC path, not `diskutil eject` as a substitute for product behavior.

## Two cleanup modes

### Factory first install

Use this for a true "never installed before" acceptance run:

```bash
./scripts/first-install-acceptance.sh preflight
sudo ./scripts/first-install-acceptance.sh factory-first-install
./scripts/first-install-acceptance.sh verify-clean
```

This removes EDP App/helper/runtime/state/credentials/receipts, uninstalls macFUSE, removes its per-user FSKit enablement state, and resets the Raw Access helper FDA entry.

Reboot after `verify-clean`, then run `verify-clean` again before installing the release candidate.

### Clean reinstall with FDA preserved

Use this to test reinstall/upgrade FDA continuity:

```bash
./scripts/first-install-acceptance.sh preflight
sudo ./scripts/first-install-acceptance.sh clean-install
./scripts/first-install-acceptance.sh verify-clean
```

This removes installed state but deliberately preserves the Raw Access FDA grant.

## Canonical first-install sequence

Run the following sequence for each release candidate.

```text
1.  preflight
2.  sudo factory-first-install
3.  verify-clean
4.  reboot Mac
5.  verify-clean
6.  sudo install <candidate.pkg>
7.  verify-installed
8.  open-fda
9.  user grants FDA once to EDP USB Vault Raw Access
10. insert one real EDP USB
11. verify-fda-device [VID:PID]
12. save/validate exchange and secret passwords in the App UI
13. credential-checkpoint
14. policy-smoke
15. functional-all
16. safe-eject
17. physically unplug the USB
18. physically reinsert the USB
19. verify-fda-device [VID:PID]
20. restart-app
21. verify-fda-device [VID:PID]
22. sudo restart-daemon
23. if the device was already open before daemon restart and raw lease cannot be reacquired, physically reinsert once
24. verify-fda-device [VID:PID]
25. reboot Mac
26. verify-fda-device [VID:PID]
27. credential-checkpoint
28. policy-smoke
29. functional-all
30. final-check
```

## What each stage proves

### `verify-installed`

Confirms App/helper/macFUSE/runtime presence, code signatures, App/helper version agreement, LaunchDaemon state, privileged XPC round trip, and a clean keychain configuration with no USB attached.

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

For type 1, 2, and 4, in order:

```text
mount
  -> create one unique ordinary test file
  -> sync
  -> SHA-256
  -> production XPC unmount
  -> production XPC remount
  -> verify file exists
  -> verify SHA-256 unchanged
  -> remove test file
  -> sync
  -> production XPC unmount
```

This validates startup plaintext slicing and encrypted read/write paths through the same retained-fd/macFUSE Local publication architecture.

### `safe-eject`

Uses the same XPC `eject()` operation as the UI. It verifies all three user volumes disappear and retained raw access is not reacquired while the physically connected USB remains logically ejected.

### App/daemon/reboot gates

- `restart-app` proves foreground App lifecycle does not disturb a live service or FSKit configuration.
- `restart-daemon` proves the privileged service can restart without requiring new authorization. A USB that has already entered a busy media-stack state may need one physical reinsertion to establish a fresh retained descriptor; this must not cause a new FDA/admin prompt.
- The Mac reboot gate proves FDA, LaunchDaemon startup, macFUSE FSKit enablement, device discovery, credential access, policy state, and full three-partition mounting survive an actual system restart.

## Evidence

Each run creates a session directory under:

```text
/Users/Shared/EDP USB Vault Acceptance/<UTC-session-id>/
```

The directory is owned by the console user and mode `0700`. `results.log` records only stage results, IDs, hashes, and package metadata. Passwords are never recorded.

The current session pointer is:

```text
/Users/Shared/EDP USB Vault Acceptance/current-session
```

The harness validates the pointer format and refuses symlinks before privileged stages consume it.

## Release gate

A candidate is not considered first-install accepted until all of the following are true on a real macOS 26 machine:

- factory cleanup and post-reboot clean verification pass;
- clean package verification and installation pass;
- only one explicit FDA grant is required;
- no per-device admin/fingerprint authorization occurs;
- startup/exchange/secret all pass write/remount/hash persistence;
- device/policy/credential state behaves correctly;
- safe eject remains suppressed until physical removal;
- physical reinsertion reacquires retained raw access without authorization;
- App restart passes;
- daemon restart passes;
- Mac reboot passes;
- the user's login keychain remains the DefaultKeychain throughout;
- the repository's macFUSE-only and installer CI contracts are green at the exact tested HEAD.
