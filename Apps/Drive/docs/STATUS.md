# EDP Drive — Current Status

Updated: 2026-09-03
Current validated branch: `codex/ui-macos26-liquid-glass`
Current validated release-candidate baseline: `b3de7619fee84f4787953269a681aa0a99149263`
Current fixed-head CI: GitHub Actions run `33701172126` — **PASS**

> This file is the current product-status source of truth. Historical plans, handoffs, diagnostics and experiment trackers are evidence only. They must not override this file, `ARCHITECTURE.md`, `TESTING.md`, or `RELEASE-CHECKLIST.md`.

## 1. Product scope

EDP Drive is a native macOS 26+ menu-bar application. The production product is:

- Swift / SwiftUI / AppKit;
- one foreground App: `com.edp.drive`;
- one embedded privileged service: `com.edp.drive.service`;
- XPC + Disk Arbitration + IOKit + Security framework;
- `Packages/EDPCore` for EDP metadata / identity / crypto;
- official macFUSE Local FSKit runtime as the only transport backend;
- Private DiskImages2 publication to Apple native filesystem stacks;
- no Tauri/WebView, FUSE-T, ntfs-3g, authopen, DriverKit block workaround, or custom filesystem implementation.

Installed topology:

```text
/Applications/EDP Drive.app                         com.edp.drive
└── Contents/Library/LaunchServices/edp-drive-service

LaunchDaemon / Mach service                         com.edp.drive.service
Runtime root                                         /Library/Application Support/EDP Drive
Persistent service state                            /var/db/com.edp.drive
```

The background service is not a second App and must not receive a separate Full Disk Access grant.

## 2. USB classification and ownership

Drive performs a read-only passive classification from the whole USB metadata shape. The canonical media classes are:

```text
standardEncrypted
legacyNoPassword
currentNoPassword
unrecognizedEDP
ordinaryUSB
```

Only `standardEncrypted` may enter the managed raw/password/mount lifecycle.

The other four classes must remain owned by macOS / Disk Arbitration / Finder. Drive must not create a retained raw lease, establish an EDP mount session, or unmount their physical volumes.

A managed physical device uses the V3 five-factor identity:

1. USB VID;
2. USB PID;
3. LBA4 numeric `onlyId`;
4. whole-device capacity;
5. LBA11 deviceId.

All five factors must match. `diskN` is never a durable device identity and may be reused by macOS.

## 3. Partition model and defaults

A standard encrypted EDP device exposes three logical partition types:

- type 1 — boot/start partition, no password;
- type 2 — exchange partition, independent password;
- type 4 — secure partition, independent password.

Current policy defaults are fail-safe:

```text
autoMount = false
autoProbePassword = false
```

for all partition types unless explicitly changed by user policy.

Saved per-device policies are not silently changed when global defaults later change. Type 2 and type 4 credentials are isolated from each other.

## 4. Production data path

Canonical managed path:

```text
standard EDP physical USB
  -> foreground-App FDA broker opens exact validated whole raw device
  -> SCM_RIGHTS passes fd to privileged service
  -> exact identity / metadata revalidation
  -> EDPCore block translation
  -> type 1 plaintext slice OR type 2/4 SM4 transparent block view
  -> macFUSE Local FSKit transport
  -> hidden volume.raw
  -> Private DiskImages2 publication
  -> synthetic /dev/diskN IOMedia
  -> Disk Arbitration
  -> Apple native filesystem stack
  -> Finder
```

The service never treats a persisted BSD name as authority. Teardown and eject decisions revalidate current generation / backing identity immediately before destructive operations.

## 5. Filesystem policy

EDP Drive does not implement FAT, ExFAT, APFS or NTFS filesystem semantics.

- FAT / ExFAT capability comes from Apple native filesystem stacks.
- Existing NTFS is supported as Apple-native read-only compatibility when macOS mounts it read-only.
- Writable cross-platform EDP data volumes use ExFAT as the preferred filesystem policy.
- The product does not restore `ntfs-3g`, use undocumented NTFS write switches, or add an in-product NTFS writer.
- The product does not silently format or migrate NTFS as part of normal mount/recovery lifecycle management.

The accepted decision is `ADR-2026-09-03-ntfs-rw.md`: A + C — native NTFS RO compatibility plus ExFAT for writable cross-platform data. A separate NTFS RW provider is out of scope unless preserving NTFS-on-disk while writing becomes a hard product requirement.

## 6. Raw access and FDA model

The permanent permission model is single-App FDA:

```text
FDA identity: com.edp.drive
FDA subject:  /Applications/EDP Drive.app
```

The embedded service itself is not an FDA subject.

When writable raw access is required, the root service launches the already-signed foreground App executable in hidden raw-broker mode. That broker:

- validates whole-USB / raw character-device shape;
- validates EDP metadata constraints;
- opens the raw whole device;
- transfers the fd only through Unix `SCM_RIGHTS`;
- does not expose an arbitrary raw-path API.

The service then revalidates registry generation plus the physical five-factor identity before retaining the lease.

No TCC database modification, AuthorizationDB modification, `/dev` permission weakening, or per-insert administrator authorization is part of the production design.

## 7. Runtime lifecycle architecture

The former monolithic runtime has been split into explicit responsibilities. Important production boundaries include:

- `EDPDeviceDiscoveryController` — physical discovery and scan diagnostics;
- `EDPRawAccessCoordinator` — retained raw lease and exact-generation EBUSY recovery;
- `EDPAutomationState` — auto-mount / probe suppression state;
- `EDPMountCoordinator` — partition session mount/unmount orchestration;
- `EDPEjectCoordinator` — physical generation quiesce / eject single-flight;
- `EDPRecoveryCoordinator` — failed-eject recovery orchestration;
- `EDPServiceLifecycleState` — startup/shutdown state and completion fanout;
- `EDPActivityStore` — bounded activity retention;
- `EDPXPCService` — XPC adapter;
- `EDPServiceController` — top-level XPC-facing service orchestration;
- `EDPServiceMain` — process/CLI entrypoint.

System ratchets prohibit the old `MountManager` / `EDPDaemonController` architecture from returning.

## 8. Critical teardown and recovery rules

### Raw EBUSY

The only accepted raw-open EBUSY recovery is:

```text
exact current registry generation
+ EBUSY only
+ forced whole-device Disk Arbitration unmount
+ exactly one raw-open retry
```

No recovery is attempted for non-EBUSY errors, metadata mismatch, replacement generation, or DA failure.

### Dead transport with live upper filesystem

macOS 26 testing proved this state cannot safely use synchronous forced teardown:

- ordinary DA unmount may time out;
- `unmount(2, MNT_FORCE)` may enter an uninterruptible wait.

Production therefore fails closed when the lower transport has exited while the upper user filesystem remains mounted. It does not enter a synchronous VFS unmount syscall in that state.

### DiskImages2 stale owner tombstone

macOS 26 may retain an `hdiutil` owner record after the exact `diskimagesiod` process has exited. It is treated as retired only when all of the following hold:

- exact expected backing path;
- owner-only publication (`devicePaths.isEmpty`);
- exact owner snapshot remains identical across bounded stabilization;
- recorded owner PID has no executable process;
- no PID / UID / entity generation change appears.

Any identity or generation change remains fail-closed.

### Safe eject

Whole-device eject is single-flight and generation-aware. After successful safe eject, automatic reacquisition remains suppressed until actual physical removal/reinsertion.

## 9. External and private dependency boundaries

### DiskImages2

Formal attach uses only the fixed private helper:

```text
/Library/Application Support/EDP Drive/bin/diskimages2-attach
```

through exact `EDPConsoleExec` allowlisting.

### hdiutil

Production does **not** use `hdiutil` as the normal DiskImages2 attach path.

Allowed production uses are bounded:

- `hdiutil info -plist` for publication identity/recovery metadata;
- `hdiutil detach -force` only for the narrowly scoped macFUSE scratch-orphan recovery path in installer cleanup.

The preinstall script routes these calls through bounded TERM/KILL control; system ratchets reject direct unbounded production `hdiutil` calls.

### pluginkit / user FSKit registration

`pluginkit` is restricted to foreground-App macFUSE enablement/support. It is not allowed in daemon mount, block-publication, or runtime hot paths.

Foreground external-tool calls are async, typed, 8-second bounded, and Task-cancellable.

### fskit_agent / extensionkitservice reset

Agent reset is recovery/configuration-only and fail-closed:

- foreground App refuses reset while **any** FSKit mount is active;
- daemon recovery requires root, exact console user, and no active FSKit mount;
- installer stale-agent recovery also requires exact process identity and no active FSKit filesystem.

## 10. Recovery diagnostics

Runtime diagnostics expose seven non-sensitive UInt64 counters:

- `rawBusyRecoveryCount`;
- `forcedWholeUnmountCount`;
- `fskitAgentRecoveryCount`;
- `diskImagesAttachRecoveryCount`;
- `diskImagesDetachRecoveryCount`;
- `mountRetryCount`;
- `ejectAlreadyAbsentSuccessCount`.

The metrics schema must not contain passwords, credentials, secret/key material, device IDs, raw paths, or mount paths.

## 11. UI state

The App is fully split into maintainable native modules:

```text
App/EDPUSBVaultApp.swift                App/CLI entrypoint
App/Model/EDPVaultViewModel.swift
App/Shell/EDPMainWindow.swift
App/Sidebar/EDPSidebarView.swift
App/Pages/EDPOverviewView.swift
App/Pages/EDPDevicesView.swift
App/Pages/EDPActivityView.swift
App/Pages/EDPSettingsView.swift
App/MenuBar/EDPMenuBarView.swift
App/Service/EDPAppServiceSupport.swift
App/Service/EDPXPCSmokeSupport.swift
```

`EDPUSBVaultApp.swift` is approximately 476 lines rather than the previous ~3810-line monolith.

Current UI contract keeps the native split view / Liquid Glass design and the existing “仅退出界面 / 完全退出” semantics.

UI performance evidence is **GitHub Actions only**. Local desktop load is not an authoritative benchmark.

Release UI gate remains:

```text
20 sidebar toggles
8 s Animation Hitches trace
THRESHOLD_NS = 33_000_000
```

The threshold/workload/window must not be weakened to manufacture a pass.

## 12. Current automated validation baseline

Latest fixed-head run:

```text
HEAD  b3de7619fee84f4787953269a681aa0a99149263
Run   33701172126
```

All core jobs passed:

- native / Swift 6 build — PASS;
- fast / identity regression — PASS;
- virtual USB / service lifecycle — PASS;
- UI + system ratchets — PASS;
- sparse-image storage M01–M14 — PASS.

The immediately preceding UI-specific all-green baseline `dded9d4` / run `33684536121` recorded:

```text
UI_HITCH_COUNT_GT33MS=0
RESULT=DRIVE_UI_ANIMATION_HITCHES_ZERO
RESULT=DRIVE_UI_OK
```

Storage coverage includes M01, M02/M04–M09, M03, M10 5-cycle teardown, M12 transport-crash recovery boundary, M14 concurrent partition sessions, failure contracts, and production Swift6/C17 strict compilation.

## 13. Physical-device evidence

Completed on a standard encrypted SanDisk EDP device:

- standard encrypted classification;
- five-factor identity;
- retained single-App FDA raw access across reinsert;
- type 1 / 2 / 4 capability checks;
- saved type 2/type 4 credentials;
- safe eject and suppression;
- two reinsert cycles;
- no separate service FDA;
- unrelated external SN750 storage left untouched.

Important limitation: physical raw EBUSY recovery did not naturally trigger. S31–S35 deterministic tests cover that contract; it must not be reported as a physical EBUSY PASS.

Still `BLOCKED_BY_FIXTURE` for physical negative evidence:

- ordinary USB;
- legacyNoPassword;
- currentNoPassword;
- unrecognizedEDP.

Synthetic/virtual results must not be presented as those physical proofs.

## 14. Remaining release work

### D3 — physical negative matrix

Blocked only by missing physical fixtures listed above.

### D4 — exact-head reboot gate

Still required for the eventual release candidate:

1. build and verify exact-head Clean.pkg;
2. install it;
3. reboot macOS;
4. verify only `com.edp.drive` FDA is used;
5. verify retained raw access after reboot;
6. verify credential/policy persistence;
7. verify standard EDP mount/capability path;
8. safe eject and prove residue/U-state = 0.

### Phase E

Current source-of-truth documentation is being consolidated into:

- `STATUS.md`;
- `ARCHITECTURE.md`;
- `TESTING.md`;
- `RELEASE-CHECKLIST.md`.

### Phase F

DONE. `ADR-2026-09-03-ntfs-rw.md` accepts A + C: Apple-native NTFS read-only compatibility plus ExFAT as the preferred writable cross-platform data format. Option B, an independent NTFS RW provider, is not part of the current release architecture and may only be reopened as a separate project for a hard NTFS-preservation requirement.

## 15. Current entry points

For current product facts, read in this order:

1. `Apps/Drive/docs/STATUS.md`;
2. `Apps/Drive/docs/ARCHITECTURE.md`;
3. `Apps/Drive/docs/TESTING.md`;
4. `Apps/Drive/docs/RELEASE-CHECKLIST.md`;
5. `Apps/Drive/docs/ADR-2026-09-03-ntfs-rw.md` for the accepted filesystem write policy;
6. `docs/PROGRESS-2026-09-01-drive-stabilization-and-release.md` for active execution history.

`Apps/Drive/docs/FIRST-INSTALL-ACCEPTANCE.md` remains the detailed machine acceptance procedure.

All 2026-08 plan/tracker files and old handoffs are historical evidence unless explicitly referenced by one of the current source-of-truth documents above.
