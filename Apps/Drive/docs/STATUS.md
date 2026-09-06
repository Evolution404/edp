# EDP Drive — Current Status

Updated: 2026-09-06
Current validated branch: `codex/ui-macos26-liquid-glass`
Current release code/package HEAD: `a7667d003279e31c1fd932b9180f32bd427c0bc0`
Current exact-head CI: GitHub Actions run `34031734671` — **PASS 5/5** core paths (native, fast+VirtualUSB, deterministic UI, storage core and storage lifecycle M10–M14), with the separate 33 ms UI release performance gate also PASS. `4ed0325` also added side-effect-free `--help` / `-h` early exit before App/UI model initialization; the native CI dynamically verifies that CLI path. `a7667d0` adds one bounded ordinary-unmount retry only for healthy exact-generation transport teardown after the first nonzero helper exit leaves the hidden bridge mounted; force paths and system-host recovery remain prohibited.
Current signed package: `artifacts/EDP-Drive-0.6.0-arm64-Clean.pkg`, SHA-256 `e1abc47aa69a463e37a2046cfe06bdd2729ae3072141dfbe0daf52d578c230f8` — strict release verifier PASS and installed on the acceptance Mac. Installed `--help` / `-h`, service health, XPC snapshot and macFUSE FSKit enablement all PASS.
Current candidate status: **RELEASE GATES PASS / CLEAN-INSTALL VERIFIED / STANDARD-EDP THREE-PARTITION PHYSICAL ACCEPTANCE PASS / EXACT-HEAD REBOOT ACCEPTANCE PASS.** Fresh Lexar insertion on the installed `a7667d0` package preserved the exact five-factor identity (`21c4:0cd1`, onlyID `3164177653`, capacity `124736503808`, metadata deviceID `disk&ven_lexar&prod_usb_flash_drive`, stable ID `disk&ven_lexar&prod_usb_flash_drive#59e8f8ae5883447c198104e7`) with `privilegedAccessReady=true`, no `fskitd` child raw holder and zero raw EBUSY/forced-whole recovery. The previously reproducible new-bridge immediate-unmount sequence (`FAIL/PASS/FAIL/PASS/FAIL`) became **8/8 mount PASS + 8/8 immediate ordinary-unmount PASS** after `a7667d0`; all eight recent lifecycle entries ended in `transportTeardownComplete`, with no hidden mount or transport residue. Product safe eject PASSed, App restart and routine runtime restart preserved suppression, exact physical removal retired the suppression entry (`manualUnmountSuppressions=[]`) and removed the old `/dev/disk26` / IOKit generation, and a fresh physical reinsert automatically restored the same five-factor identity and `privilegedAccessReady=true` with no child raw holder or recovery. After the user revalidated and saved the real type2/type4 credentials in the App UI, credential checkpoint and policy round-trip PASSed; type1 FAT16 read-only remount PASSed; type2 exchange and type4 secret partitions both completed production-path RW write → unmount → remount → SHA-256 persistence verification → cleanup, ending in `RESULT=ALL_THREE_PARTITIONS_CAPABILITY_PERSISTENCE_OK`. Exact-head reboot completed at `2026-09-06 21:00:57`; the still-inserted logically safe-ejected Lexar remained suppressed after reboot (`privilegedAccessReady=false`), service/XPC health and macFUSE FSKit enablement persisted, saved credentials remained present, and all recovery counters stayed zero. Physical removal then retired the old `disk6`/IOKit generation; fresh reinsert restored the same stable five-factor identity and `privilegedAccessReady=true`; post-reboot credential checkpoint, policy round-trip and full type1/type2/type4 `functional-all` all PASSed. Final safe eject again left `privilegedAccessReady=false`, zero EDP mounts/transport/raw holders, `rawBusyRecoveryCount=0`, `forcedWholeUnmountCount=0`, and `fskitTransientRetryCount=0`.

> This file is the current product-status source of truth. Historical plans, handoffs, diagnostics and experiment trackers are evidence only. They must not override this file, `ARCHITECTURE.md`, `TESTING.md`, or `RELEASE-CHECKLIST.md`.

## 1. Product scope

EDP Drive is a native macOS 26+ menu-bar application. The production product is:

- Swift / SwiftUI / AppKit;
- one foreground App: `com.edp.drive`;
- one embedded privileged service: `com.edp.drive.service`;
- XPC + Disk Arbitration + IOKit + Security framework;
- `Packages/EDPCore` for EDP metadata / identity / crypto;
- official macFUSE Local FSKit runtime as the only transport backend;
- Apple public `hdiutil` raw-image publication to native filesystem stacks;
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
  -> /usr/sbin/diskutil image attach --plist --noMount
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

### Legacy hdiutil metadata tombstone

Old persisted sessions may encounter an `hdiutil info -plist` record after its IOMedia has already disappeared. This compatibility path never signals the recorded system helper. A record is treated as retired only when the exact expected backing path has no device entities, the owner snapshot remains identical on immediate revalidation, and the recorded PID no longer resolves to an executable process. Any PID / UID / entity change remains fail-closed.

### Safe eject

Whole-device eject is single-flight and generation-aware. After successful safe eject, automatic reacquisition remains suppressed until actual physical removal/reinsertion.

## 9. External and private dependency boundaries

### Disk image publication

Production must not load `PrivateFrameworks/DiskImages2.framework` or call private DiskImages2 Objective-C classes/selectors. Host publication is behind `EDPBlockDevicePublisherFactory`; the currently implemented backend is explicitly named `diskutil-image-compatibility`, not the long-term architecture.

Current compatibility command:

```text
diskutil image attach --plist --noMount <volume.raw>
```

The resulting whole IOMedia registry generation is captured immediately and becomes the teardown authority. Normal teardown uses Disk Arbitration eject first. If that bounded operation fails while the exact generation is still present, EDP may run bounded `diskutil eject <diskN>` only after exact-generation revalidation. `hdiutil info -plist` remains only for legacy persisted-session and narrowly scoped scratch metadata reconciliation; it is not part of the normal mount/unmount path.

macOS 27+ introduces DiskImageKit as the future provider candidate. EDP must not select that backend merely because the framework exists: provider selection stays on `diskutil-image-compatibility` until a documented host-IOMedia attachment capability is implemented and positively tested. Private DiskImages2 is permanently excluded as a fallback. GitHub Actions run `34012596455` proves the diskutil-image path across M01–M14 on macOS 26.

### pluginkit / user FSKit registration

`pluginkit` is restricted to foreground-App macFUSE enablement/support. It is not allowed in daemon mount, block-publication, or runtime hot paths.

Foreground external-tool calls are async, typed, 8-second bounded, and Task-cancellable.

### FSKit host ownership

`fskit_agent`, `fskitd` and ExtensionKit host lifecycles are system-owned. EDP does not restart, signal or kill them. Bridge timeout/extension-unavailable failures are recorded as typed transient failures; a later explicit/reconnect retry starts a new formal mount attempt and lets macOS manage the FSKit host lifecycle.

## 10. Recovery diagnostics

Runtime diagnostics expose seven non-sensitive UInt64 counters:

- `rawBusyRecoveryCount`;
- `forcedWholeUnmountCount`;
- `fskitTransientRetryCount`;
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

Current UI contract keeps the native split view / Liquid Glass design and the existing “仅退出界面 / 完全退出” distinction. Routine background Stop/Start/Restart now controls the in-process runtime so the DA claim stays continuous; Complete Quit first safe-ejects connected managed EDP devices and only then terminates the privileged process.

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
HEAD  f734f43899e174c5965f32917f6164ccb2994305
Run   33711677562
```

All core jobs passed:

- native / Swift 6 build — PASS;
- fast / identity regression — PASS;
- virtual USB / service lifecycle — PASS;
- UI + system ratchets — PASS;
- sparse-image storage M01–M14 — PASS.

The same fixed-head run recorded the unchanged UI performance gate as:

```text
UI_HITCH_MAX_MS=0.000
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

DONE for release code/package HEAD `9b5a8595203cf88ff726f9aa08bc62b8c25a8d29`.

- exact-head Clean.pkg verifier PASS and installed;
- reboot completed at `2026-09-04 13:30:00`;
- service health PASS without a second service FDA subject;
- logically-ejected same generation remained suppressed across reboot;
- exact physical removal cleared the persisted generation;
- fresh reinsert enumerated as `disk4` with unchanged five-factor identity;
- `DA_CLAIMED=true`, `privilegedAccessReady=true`, zero raw errors/busy recovery;
- root holder audit showed only `edp-drive-service` on the whole raw disk and no `fskitd` child holder;
- credential/policy persistence PASS;
- final safe eject PASS with residue/U-state = 0.

### Phase E

DONE. Current source-of-truth documentation is consolidated into:

- `STATUS.md`;
- `ARCHITECTURE.md`;
- `TESTING.md`;
- `RELEASE-CHECKLIST.md`;
- `HISTORICAL.md` for superseded-plan indexing.

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
