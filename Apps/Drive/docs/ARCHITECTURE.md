# EDP Drive — Architecture

Updated: 2026-09-03
Applies to: macOS 26+ native EDP Drive

> This document describes the current production architecture. Historical implementation plans are not architectural authority.

## 1. Topology

```text
Foreground App
/Applications/EDP Drive.app
bundle id: com.edp.drive
        │
        │ NSXPC / Mach service
        ▼
Embedded privileged service
Contents/Library/LaunchServices/edp-drive-service
service id: com.edp.drive.service
        │
        ├── IOKit / Disk Arbitration
        ├── raw-FD broker through foreground App identity
        ├── Packages/EDPCore
        ├── macFUSE Local FSKit transport
        └── DiskImages2 publication
```

The product deliberately keeps one visible App plus one embedded service. There is no second Raw Access App.

## 2. Foreground App responsibilities

The App owns:

- menu-bar and main-window UI;
- service start/stop/restart controls;
- XPC client state and snapshots;
- user credential/policy commands;
- foreground macFUSE FSKit registration/enablement;
- the hidden raw-FD broker mode required to preserve single-App FDA identity.

UI implementation is separated into shell, sidebar, pages, menu bar, view model and service support modules.

The App does **not** own:

- physical USB discovery;
- long-lived raw leases;
- mount sessions;
- DiskImages2 lifecycle;
- physical eject orchestration.

Those belong to the service.

## 3. Privileged service responsibilities

The service owns the managed-device lifecycle:

- USB enumeration and classification;
- physical generation tracking;
- retained raw FD lifecycle;
- exact raw identity revalidation;
- credential validation against EDP metadata;
- mount/unmount sessions;
- automatic-mount policy execution;
- DiskImages2 publication lifecycle;
- physical safe eject;
- startup recovery and graceful shutdown;
- structured activity/journal/metrics snapshots.

Normal user-requested service stop is graceful. It is not implemented as an ordinary `kill -9` path.

## 4. Device classification boundary

The system distinguishes five media classes:

```text
standardEncrypted
legacyNoPassword
currentNoPassword
unrecognizedEDP
ordinaryUSB
```

Classification and ownership are separate decisions.

Only `standardEncrypted` can be owned by Drive. All other classes remain with macOS.

For a managed device, durable identity is:

```text
VID
+ PID
+ LBA4 onlyId
+ whole-device capacity
+ LBA11 deviceId
```

A BSD name such as `disk7` is transient state, never durable identity.

## 5. Raw access architecture

### 5.1 Why the foreground App participates

FDA must belong only to `com.edp.drive`. The embedded service must not become a second FDA subject.

When the service needs a writable raw whole-device FD, it launches the foreground App executable in a hidden broker mode. TCC therefore evaluates the already-approved App identity.

### 5.2 Broker contract

The broker:

1. receives a narrowly scoped raw-device request;
2. validates the target is the expected whole raw character device;
3. validates EDP metadata constraints;
4. opens the device;
5. sends the FD through Unix `SCM_RIGHTS`;
6. exits.

It does not expose a general-purpose “open arbitrary raw path” facility.

### 5.3 Service revalidation

Receiving an FD is not sufficient authority. The service revalidates:

- whole-USB registry generation;
- VID/PID;
- onlyId;
- capacity;
- LBA11 deviceId;
- required standard-encrypted metadata shape.

If current state no longer matches discovery state, the lease is refused.

## 6. Block and filesystem path

### Type 1

Type 1 is passwordless and exposed as a constrained plaintext slice.

### Type 2 / Type 4

Encrypted partitions use `Packages/EDPCore` for transparent block translation and SM4.

### Common publication path

```text
EDP logical block view
  -> macFUSE Local FSKit transport
  -> hidden volume.raw
  -> fixed diskimages2-attach helper
  -> DiskImages2 synthetic media
  -> Disk Arbitration
  -> Apple filesystem stack
  -> Finder
```

EDP Drive does not implement filesystem semantics.

## 7. macFUSE Local boundary

Only the Local FSKit transport is supported. There is no runtime backend selector and no fallback to:

- macFUSE kernel backend;
- FUSE-T;
- libfuse-based legacy product path.

Transport children receive only the fixed raw FD needed for their EDP session and run in the console-user context after privilege setup.

## 8. DiskImages2 boundary

### 8.1 Normal publish

Normal publish uses the fixed helper:

```text
/Library/Application Support/EDP Drive/bin/diskimages2-attach
```

The helper is invoked only through an exact console-exec allowlist. Arbitrary executables are rejected.

### 8.2 hdiutil use

`hdiutil` is not the normal attach mechanism.

Allowed bounded uses are limited to:

- publication metadata discovery via `hdiutil info -plist`;
- narrowly scoped scratch-orphan detach during recovery/installer cleanup.

Normal block publication remains the private DiskImages2 helper path.

## 9. Runtime ownership components

### `EDPDeviceDiscoveryController`

Owns discovery calls, metadata reading, scan diagnostics, timestamps and discovery seams.

### `EDPRawAccessCoordinator`

Owns:

- retained raw lease state;
- single-flight raw acquisition;
- raw worker queue;
- exact-generation EBUSY recovery;
- raw-ready/error state.

### `EDPAutomationState`

Owns:

- manual-unmount suppression;
- failed-auto-mount suppression;
- password-probe suppression;
- retry eligibility state.

### `EDPMountCoordinator`

Owns logical partition sessions and mount/unmount orchestration.

### `EDPEjectCoordinator`

Owns:

- duplicate eject fanout;
- generation-aware physical eject;
- automount suppression during eject;
- already-absent idempotent success.

### `EDPRecoveryCoordinator`

Owns failed-eject recovery, generation revalidation, raw reacquisition and policy restoration.

### `EDPServiceLifecycleState`

Owns startup/shutdown intent, shutdown single-flight and completion fanout.

### `EDPActivityStore`

Owns bounded activity retention.

### `EDPXPCService`

Maps trusted XPC calls onto service-controller operations.

### `EDPServiceController`

Top-level service orchestration. It coordinates components but should not absorb their internal state machines again.

### `EDPServiceMain`

Owns daemon/CLI/process entrypoint behavior.

## 10. Queue and lifecycle rules

Lifecycle state is asynchronous and single-path.

Required properties:

- duplicate mount/eject operations fan out to one in-flight operation;
- cancellation is terminal and late callbacks are idempotent;
- shutdown waits for active eject before final teardown;
- failed teardown retains enough session state to fail closed rather than pretending resources are gone;
- replacement physical generation never inherits authority from a stale operation.

The property model exercises these invariants over fixed-seed 320,000 lifecycle steps.

## 11. Raw EBUSY recovery

Exact contract:

```text
raw open returns EBUSY
        │
        ▼
revalidate exact original USB generation
        │ mismatch -> FAIL CLOSED
        ▼
forced whole-device DA unmount
        │ failure -> FAIL CLOSED
        ▼
exactly one raw-open retry
        │
        ├── success -> continue
        └── any failure -> stop, no second recovery
```

Non-EBUSY raw errors never trigger this recovery.

## 12. Teardown ordering

A healthy session tears down from upper layers toward lower ownership:

```text
user filesystem
  -> DiskImages2 publication
  -> hidden macFUSE Local bridge
  -> transport process
  -> raw lease when no session still needs it
```

Errors are propagated. Session state is not cleared merely to make cleanup look successful.

## 13. Dead transport fail-closed rule

The dangerous state is:

```text
upper filesystem still mounted
lower transport already dead
```

Real macOS 26 evidence showed synchronous unmount/force-unmount can block indefinitely in this state.

Therefore production refuses synchronous VFS teardown when it detects this combination. It journals a teardown failure and retains the failed session state for explicit recovery/reboot rather than risking a permanently blocked lifecycle queue.

## 14. DiskImages2 tombstone retirement

A stale metadata-only record can remain after `diskimagesiod` has exited.

The record is retired only if:

```text
exact backing path matches
AND no system entities remain
AND original owner snapshot is unchanged
AND recorded PID is absent
AND second bounded sample is still same dead-owner snapshot
```

A changed PID, owner, device entity or generation is never treated as the same publication.

## 15. Safe eject

Safe eject sequence is generation-aware:

1. suppress automatic remount for that physical generation;
2. drain managed partition sessions;
3. release lower resources only after upper teardown is proven;
4. revalidate the original whole-USB generation;
5. arm and atomically persist a logical-eject tombstone for the stable device ID + current USB registry generation;
6. request exact physical DA eject;
7. retain suppression until actual removal/reinsertion.

The tombstone lives under `/var/db/com.edp.drive/logical-eject-suppressions.json`. Reconcile reloads/reapplies it after privileged-service restart, so neither a foreground App restart nor a service restart may reacquire raw access for the same still-inserted USB generation. Discovery is not authoritative for tombstone retirement: a temporary metadata/discovery omission does not clear suppression, and a replacement generation observed while the persisted original `usbRegistryEntryID` still exists is also suppressed fail-closed. Only IOKit-confirmed disappearance of the exact persisted USB registry generation clears the tombstone and admits a new generation. A failed physical eject rolls the tombstone back before raw-access recovery. If persistence cannot be made coherent, the path fails closed.

If the original device has already disappeared, eject can finish idempotently and retire its tombstone. If the BSD name was reused by a replacement device, the replacement must not be touched.

## 16. Credentials and policy

Credentials and policy are separate concerns.

- type 2 and type 4 credentials are isolated;
- credentials are stored in Keychain, not plaintext files;
- policy state is persisted separately;
- global defaults do not mutate existing devices;
- safe defaults are `autoMount=false`, `autoProbePassword=false`.

## 17. XPC trust boundary

The service validates its XPC peer against the fixed EDP Drive App identity/signing requirement. A stale or unrelated process must not receive privileged operations.

The XPC API exposes product operations, not arbitrary raw filesystem/device primitives.

## 18. External-process policy

All production external-process use must be one of:

1. a normal-path exact allowlisted helper with bounded execution; or
2. a narrow recovery/configuration path with bounded execution and fail-closed identity guards.

Foreground App external tools are async, typed, bounded and Task-cancellable.

Installer `hdiutil` use is also bounded and escalates TERM -> KILL only inside the wrapper.

## 19. FSKit agent reset policy

No component may recycle user FSKit agents while an FSKit volume is active.

Foreground App:

- checks global `MNT_EXT_FSKIT` state;
- skips reset if any FSKit mount exists.

Daemon recovery:

- requires root;
- identifies the exact console user;
- refuses if any FSKit mount exists;
- only then restarts the exact console-user `fskit_agent`.

Installer recovery follows the same fail-closed principle.

## 20. Observability

The service maintains:

- typed lifecycle errors;
- bounded lifecycle journal;
- bounded activity store;
- seven non-sensitive recovery counters.

Observability cannot change lifecycle decisions and cannot contain credentials, secret key material or device-path identifiers in the metrics schema.

## 21. Filesystem write policy

`ADR-2026-09-03-ntfs-rw.md` is accepted and is part of the current architecture contract.

The decision is A + C:

- existing NTFS media remains Apple-native read-only compatibility when macOS reports it read-only;
- writable cross-platform EDP data volumes use ExFAT as the preferred filesystem policy;
- Drive never silently reformats or migrates NTFS in ordinary mount/recovery flows;
- Drive does not restore `ntfs-3g`, use undocumented native NTFS write switches, or embed an NTFS filesystem writer;
- a separate NTFS RW provider may only be reopened as an independent project if preserving NTFS-on-disk while writing becomes a hard product requirement.

This keeps filesystem semantics owned by the Apple-native filesystem layer and prevents an unrelated NTFS implementation lifecycle from entering the current release architecture.

## 22. Deliberately unsupported architectures

Do not reintroduce:

```text
Tauri / WebView
FUSE-T
ntfs-3g
macFUSE kernel backend
authopen
AuthorizationDB raw-open workarounds
DriverKit block-device workaround
custom FAT/ExFAT/NTFS filesystem implementation
separate FDA grant for edp-drive-service
cached diskN as durable identity
sync force-unmount after lower transport death
```

## 23. Related current documents

- `STATUS.md` — current product status and evidence;
- `TESTING.md` — test layers and authority;
- `RELEASE-CHECKLIST.md` — release-candidate gate;
- `ADR-2026-09-03-ntfs-rw.md` — accepted filesystem write policy;
- `FIRST-INSTALL-ACCEPTANCE.md` — detailed machine acceptance procedure.
