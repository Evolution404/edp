# EDP Drive / Studio identity and service migration plan (2026-08-29)

This document is the Phase A audit and implementation contract for migrating the
monorepo from the historical `EDP USB Vault` / `EDPOpen` identities to EDP Drive
and EDP Studio.  The audited baseline is `56ed5fa0c42dc3a3a0924db487c1a73f2c1c8fbf`.

## Current progress

As of 2026-08-29:

- Phase A: complete — architecture, FDA, XPC, installer and persisted-state audit recorded here;
- Phase B: complete — Drive is one `/Applications/EDP Drive.app` plus one embedded `edp-drive-service`, with no Raw Access second App;
- Phase C: complete — Drive runtime identities are `com.edp.drive` / `com.edp.drive.service`, data and Keychain migration are implemented and regression-tested;
- Phase D: complete — UI Start / graceful Stop / Restart is implemented; `KeepAlive` / `RunAtLoad` are removed and XPC disconnect races are hardened;
- Phase E: complete — Studio is `EDP Studio.app`, `com.edp.studio`, `com.edp.studio.rawbroker`; native directory/project/target/scheme names are also migrated to `EDPStudioNative` / `EDPStudio`;
- Phase F: partially complete — build, installer expansion, signing and synthetic/golden gates pass; remaining work requires local administrator authorization, one FDA grant and real-USB lifecycle/performance acceptance;
- Phase G: partially complete — every old branch/tag commit is now represented in monorepo history and legacy USB Vault tags were copied; old repositories must not be deleted until Phase F real-machine acceptance passes and a final exact-head CI run is green.

## Non-negotiable production topology

Drive has one user-visible application and one embedded, signed service
executable:

```text
/Applications/EDP Drive.app
├── Contents/MacOS/EDP Drive
├── Contents/Library/LaunchServices/edp-drive-service
└── Contents/Library/LaunchDaemons/com.edp.drive.service.plist
```

The fixed identities are:

```text
App bundle/code identifier  com.edp.drive
Service code identifier     com.edp.drive.service
LaunchDaemon label          com.edp.drive.service
Mach service                com.edp.drive.service
```

There must be no second Drive `.app`.  In particular, the migration must remove
`EDP USB Vault Raw Access.app` and must not introduce `EDP Drive Service.app` or
`EDP Drive Raw Access.app`.

The filesystem path remains:

```text
physical EDP USB
  -> retained validated raw fd
  -> EDPCore transparent block crypto
  -> macFUSE Local transport
  -> volume.raw
  -> DiskImages2
  -> Apple native filesystem stack
  -> Finder
```

NTFS recognition remains in the filesystem probe.  No NTFS implementation is
bundled; mounting is delegated to Disk Arbitration and the native macOS stack.

## Phase A audit findings

### Raw access and retained descriptor ownership

`EDPVaultRuntime.swift` already contains the production raw-device authority:

- discovery only considers IOKit whole USB media;
- the candidate is tied to VID, PID, capacity, registry entry identities and a
  stable EDP device ID derived from LBA11;
- the path is constructed from the enumerated BSD name, not accepted from XPC;
- `lstat` before open, `fstat` after open and a second `lstat` require the same
  character-device `st_rdev`;
- LBA4, LBA7 and LBA11 are revalidated on the opened descriptor;
- the retained descriptor is closed by `EDPRawAccessLease.invalidate`/`deinit`;
- only the fixed EDP transport launcher receives a duplicated descriptor as fd
  3 after the console-user launcher validates its executable and privilege
  boundary.

The current Raw Access App contains no separate broker implementation.  The
installer copies the same `edp-vaultctl` executable into that App, and the
legacy LaunchDaemon starts that copy.  Moving that exact service role to
`EDP Drive.app/Contents/Library/LaunchServices/edp-drive-service` therefore
removes packaging duplication without widening the raw-device authority.

### XPC peer validation

The daemon accepts only a peer whose live code:

- passes `SecCodeCheckValidity`;
- has the fixed App code identifier;
- resolves to the fixed `/Applications` executable path;
- is root-owned and not group/other writable; and
- has the same Team ID, or for the self-signed distribution, the exact same leaf
  certificate as the service.

The migration will change only the fixed identifier/path constants.  It will
retain exact-leaf validation for the permanent `EDP Project Code Signing`
certificate and retain the rejection of ad-hoc or alternate self-signed peers.

### Service registration and Full Disk Access

The repository has working macOS 26 evidence for a certificate-backed,
installer-managed system LaunchDaemon plus privileged Mach XPC.  The current
self-signed build explicitly selects that path because the SMAppService path is
not the proven self-signed distribution mechanism.  The target implementation
will therefore use the allowed installer-managed LaunchDaemon, whose program is
the service executable inside the one installed App bundle.

FDA is intentionally re-granted once for the new service identity/path.  The
permanent signing certificate is unchanged:

```text
SHA-256  D9142CE44ABCB5DD662DF9621D48A88C88EDBCB0392D3C74EBACBB1292B7B5A7
root SHA-1 040B5488FB2B6C02B0786E76B674CB4460658CA2
```

The installer and tests must never change the user's default keychain or
keychain search list, generate another certificate, or use an Apple Developer
identity.

### Service lifecycle

`KeepAlive=true` and `RunAtLoad=true` conflict with a user-controlled Stop
operation.  The new plist will use neither.  The registered Mach service can be
launched on demand when the App intentionally opens XPC.

The App owns an explicit desired-running state:

- Start marks the service desired, verifies registration/enabled state and
  opens XPC, which may activate the service on demand.
- Stop first sends a privileged-XPC graceful-shutdown request.  The service
  stops device monitoring, unmounts every session, releases DiskImages2,
  stops each macFUSE transport, closes retained raw descriptors, invalidates
  XPC and exits normally.  The App then suppresses reconnect, so launchd does
  not immediately reactivate the job.
- Restart performs graceful Stop, waits with a bounded timeout for XPC
  invalidation/service exit, then performs Start and requires a fresh XPC
  round trip.

Service status in the UI must be based on a successful live XPC health check,
not merely on an installed or enabled launchd definition.  Registration,
running, stopping, stopped and failure/timeout states remain distinguishable.

### State and Keychain migration

New writes use only:

```text
/Library/Application Support/EDP Drive
/var/db/com.edp.drive
com.edp.drive.partition-password.v1
```

Upgrade migration is root-service-owned, serialized and idempotent:

1. create and permission-check the new state root;
2. copy/merge policy, credential index and recoverable session state through
   decoded model objects and atomic writes (never copy plaintext passwords to a
   file);
3. for every indexed partition, read the old System Keychain item, upsert the
   new item, read it back and compare bytes, then delete that old item;
4. retain old data/items when verification fails so the next launch can retry;
5. mark completion only after every record verifies; and
6. make all subsequent runtime writes target only the new namespace.

The migration reader covers the current partition service and older device
services (`com.edp.usbvault.partition-password.v4`,
`com.edp.usbvault.device-password.v3`, and
`com.edp.usbvault.device-password`) plus the existing encrypted-file migration.
Secrets are zeroed after use and are never printed.

The installer removes obsolete Apps/runtime/plists only after the service has
had an opportunity to migrate state; state cleanup is a post-verification step,
not a blind preinstall deletion.

### Studio audit

Studio is already a native SwiftUI/AppKit app using EDPCore and one privileged
raw broker.  Phase E is an identity/path migration, not an architecture change:

```text
App                    com.edp.studio
App path               /Applications/EDP Studio.app
Raw broker/Mach label  com.edp.studio.rawbroker
Broker path            /Library/PrivilegedHelperTools/com.edp.studio.rawbroker
```

The fixed executable path, exact identifier, permanent-certificate authority,
secure owner/mode, and bidirectional XPC signing requirements remain fail
closed.  No Rust/Tauri or `authopen` path may return to the production tree.

## Implementation phases and gates

### Phase B -- one Drive App and one embedded service

- rename the installed App/executable and embed the service at the fixed target
  path;
- point the installer-managed plist at that executable;
- remove Raw Access App build, payload, relocation and acceptance assumptions;
- retain the raw-fd and mount pipeline unchanged;
- add package assertions that exactly one Drive `.app` exists and the embedded
  service is a plain Mach-O executable.

### Phase C -- Drive identity and persisted-data migration

- switch App, service, launchd and Mach identities atomically;
- move runtime paths to the new product namespace;
- implement verified, retry-safe policy/state and Keychain migration;
- update peer-validation and installer upgrade cleanup contracts.

### Phase D -- Start, Stop and Restart

- add XPC health and graceful-shutdown methods;
- add deterministic controller/monitor/session/lease teardown;
- add bounded UI operations and accurate live state;
- cover success, rejection and timeout behavior without `kill -9`.

### Phase E -- Studio identity

- rename App/product/broker identifiers and fixed paths;
- update project, scripts, plist, documentation and signing-contract tests;
- verify the native Release build and alternate-signer rejection.

### Phase F -- installation, upgrade and real-device acceptance

- build and expand the installer and verify the one-App/FDA/service contract;
- exercise clean installation and old-namespace upgrade migration;
- after the one allowed FDA grant, exercise type 1/2/4, UI Stop/Start/Restart,
  App restart, USB replug/diskN change and reboot without another admin prompt;
- use only filesystem-level marker read/write/delete on the real USB;
- run a read/write performance sanity check without raw-sector writes.

### Phase G -- exact-head CI and repository retirement

- require exact-head Core, Drive and Studio CI success on monorepo `main`;
- confirm the monorepo is clean/equal locally and remotely;
- prove every old HEAD, branch and tag is represented in monorepo history;
- only after all functional and release gates pass, delete the three old GitHub
  repositories and verify `Evolution404/edp` is the sole EDP development repo.

The production gates include EDPCore tests, Swift 6 warnings-as-errors, existing
LBA11/LBA12 and encrypted reader/writer goldens, installer build/expansion,
absence of ntfs-3g, exact code/Mach identities, XPC peer-security tests,
graceful lifecycle tests, and Studio Release/peer-signing verification.
