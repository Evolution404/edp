# ADR: Host block-publication provider boundary

Date: 2026-09-06
Status: Accepted

## Context

EDP Drive needs to turn the authenticated logical `volume.raw` block view into a host `/dev/diskN` / IOMedia so Apple filesystem stacks and Disk Arbitration can operate on it.

The historical implementation directly loaded `PrivateFrameworks/DiskImages2.framework` and invoked private Objective-C classes/selectors. That is not an acceptable production dependency and has been removed.

Apple currently documents `hdiutil attach -nomount`, `-readwrite`, `-plist`, and `hdiutil detach`. macOS 27 introduces DiskImageKit, but the documented API currently does not establish a public host-IOMedia attachment contract suitable for EDP.

## Decision

Host block publication is always accessed through `EDPBlockDevicePublisher` and selected through `EDPBlockDevicePublisherFactory`.

Current backend policy:

- macOS 26: `hdiutil-compatibility`.
- macOS 27+: continue `hdiutil-compatibility` unless a documented DiskImageKit host-attachment capability is implemented and positively validated.
- `diskimagekit-host-attachment` is a reserved future backend identifier only; framework presence or OS version alone must never select it.
- Private DiskImages2 APIs are permanently prohibited and are not a fallback.

The current compatibility provider publishes with:

```text
/usr/bin/hdiutil attach -nomount -readwrite -plist <volume.raw>
```

It immediately resolves the returned whole BSD device to an exact IOKit registry generation. Teardown uses generation-aware Disk Arbitration first and bounded public `hdiutil detach <exact device> -force` only after exact-generation revalidation.

EDP must never signal or kill Apple `diskimagesiod`, disk-image helper, `fskit_agent`, or ExtensionKit host processes as a recovery mechanism.

## Migration trigger

A DiskImageKit provider may be implemented only when all of the following are true:

1. Apple documents an API that attaches an EDP-compatible random-access image to the host as IOMedia / `/dev/diskN`.
2. The API does not require a private entitlement incompatible with the product distribution model.
3. It supports the required writable random-access semantics.
4. GitHub macOS runner E2E proves FAT16/ExFAT publication, mount, unmount, safe eject, crash recovery, and repeated lifecycle coverage.
5. Existing exact-generation and fail-closed teardown contracts remain intact.

After the minimum supported macOS version no longer needs the compatibility provider and the replacement passes the release gate, `hdiutil-compatibility` may be removed.

## Consequences

The mount/session architecture is no longer coupled to one disk-image mechanism. The current `hdiutil` dependency is explicitly temporary and replaceable, while private DiskImages2 cannot re-enter the codebase under compatibility pressure.
