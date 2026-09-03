# ADR — NTFS Read/Write Strategy for EDP Drive

Date: 2026-09-03
Status: **ACCEPTED**

## 1. Decision

EDP Drive adopts an **A + C** strategy:

1. **A — Existing NTFS remains Apple-native read-only compatibility.**
   - Detect NTFS.
   - Mount through the Apple native filesystem path.
   - Report the actual `readOnly` capability from the mounted filesystem.
   - Never attempt hidden/unsupported NTFS write enablement.

2. **C — Writable EDP data volumes should use an Apple-native writable format, with ExFAT as the cross-platform default.**
   - Type 2 / type 4 that must support normal file create/edit/delete should be provisioned or explicitly migrated to ExFAT.
   - Migration/formatting is destructive and must never happen automatically inside ordinary Drive mount/recovery flows.
   - Existing NTFS media remains readable without forcing migration.

3. **B — An independent NTFS RW provider is not part of the current release architecture.**
   - Do not restore `ntfs-3g`.
   - Do not enable undocumented Apple NTFS write paths.
   - Do not add an NTFS filesystem implementation to the current stabilization/release branch.
   - Reopen option B only if preserving NTFS-on-disk while writing becomes a hard product requirement that cannot be satisfied by ExFAT provisioning.

## 2. Product requirement being solved

The user-facing requirement is **reliable writable data storage** for exchange/secure data, including operations such as:

- create files;
- edit/save files;
- atomic replace/rename patterns;
- delete multiple files;
- large sequential I/O;
- remount persistence.

That requirement does not inherently require the on-disk filesystem to remain NTFS.

The current storage E2E already verifies these writable semantics on Apple-native writable filesystems through the existing EDP block-translation -> macFUSE Local -> DiskImages2 -> Apple filesystem architecture.

If a future deployment specifically requires writing an existing NTFS filesystem without reformatting, that is a different hard requirement and must reopen this ADR.

## 3. Current evidence

### 3.1 Real EDP media

Current real-device acceptance on the standard encrypted SanDisk EDP device established:

```text
type 1 -> FAT16 read-only
type 2 -> Apple native NTFS read-only
type 4 -> Apple native NTFS read-only
```

The product already reports these capabilities rather than pretending the volumes are writable.

### 3.2 Apple formatting guidance

Apple's current Disk Utility documentation lists APFS, MS-DOS (FAT), and ExFAT as the supported formatting choices; for Windows-compatible external storage it specifically recommends FAT for smaller volumes and ExFAT for larger volumes.

NTFS is not presented as a normal writable formatting target in Disk Utility.

Public reference:

- Apple Disk Utility User Guide — “File system formats available in Disk Utility on Mac”
- Apple Disk Utility User Guide — “Format a disk for Windows computers in Disk Utility on Mac”

### 3.3 FSKit capability and cost

Apple FSKit can implement user-space filesystem modules. Apple's current documentation states that FSKit modules are app extensions and the current supported design flow is `FSUnaryFileSystem`. Apple's sample project also requires a filesystem-extension entitlement (`com.apple.developer.fskit.fsmodule`).

Therefore “implement NTFS ourselves in FSKit” is technically possible in the abstract but is not a small mount-provider change. It creates an independent filesystem product with a new extension/distribution/security surface.

Public reference:

- Apple Developer Documentation — FSKit
- Apple Developer Documentation — Building a passthrough file system

### 3.4 macFUSE boundary

macFUSE 5.x provides the signed FSKit transport used by EDP Drive and has improved FSKit-channel performance on macOS 26. That solves the block/file-transport integration problem; it does not supply NTFS filesystem semantics by itself.

The current product intentionally uses macFUSE only as the Local block transport for `volume.raw` and delegates actual FAT/ExFAT/NTFS interpretation to macOS.

## 4. Options considered

## Option A — Apple native NTFS read-only

### Advantages

- already implemented and validated;
- no new filesystem code;
- no new third-party write dependency;
- no data-corruption risk from an unproven NTFS writer;
- preserves access to existing NTFS data;
- fits the current Apple-native filesystem architecture;
- fits current self-signed distribution constraints.

### Disadvantages

- existing NTFS media cannot satisfy normal write/edit/delete requirements;
- users may perceive mounted data volumes as limited until they are provisioned in a writable format.

### Decision

**Accepted as the compatibility mode for existing NTFS media.**

It is not the preferred format for writable EDP data volumes.

## Option B — Independent NTFS RW provider

Possible implementations would include:

1. a new NTFS filesystem implementation using FSKit;
2. a new NTFS implementation behind macFUSE Local/FUSE semantics;
3. a separately licensed/signed third-party provider or SDK.

### Required scope

A production-quality NTFS writer must correctly handle far more than basic read/write calls, including at minimum:

- allocation and bitmap consistency;
- MFT records and attributes;
- directories and indexes;
- rename/replace semantics;
- file size / allocation size updates;
- timestamps and attributes;
- sparse files;
- crash consistency;
- dirty-volume handling and recovery expectations;
- Windows interoperability;
- unknown/unsupported feature fail-closed behavior.

Depending on the selected provider, additional concerns include:

- filesystem-extension entitlement/provisioning;
- signing/distribution compatibility with the current self-signed EDP model;
- extension enablement UX;
- dependency licensing;
- vendor compatibility with macOS 26 updates;
- new performance and corruption regression matrices.

### Why not `ntfs-3g`

`ntfs-3g` and the old NTFS-3G write fallback are explicitly retired from the EDP architecture. Reintroducing them would restore a dependency/lifecycle path that the current monorepo deliberately removed.

### Why not undocumented Apple NTFS write mode

A hidden or unsupported write switch is not an acceptable release architecture for EDP data. The product requires deterministic failure handling and data-integrity confidence; undocumented behavior cannot be treated as a stable storage contract.

### Decision

**Rejected for the current release and current stabilization plan.**

Option B may only be reopened as a separate project after a hard NTFS-preservation requirement is documented.

## Option C — Standardize writable data volumes on ExFAT

### Advantages

- Apple-native read/write on macOS;
- Windows-compatible;
- no additional filesystem runtime/provider;
- works with the already validated EDP block translation and DiskImages2 path;
- avoids adding a second filesystem implementation lifecycle;
- writable behavior can be covered by the existing M02/M04-M09/M03/M10/M14 storage tests;
- aligns with Apple's own cross-platform external-storage formatting guidance.

### Disadvantages

- converting an existing NTFS filesystem is destructive;
- data must be backed up and restored during migration;
- ExFAT has different resilience/metadata characteristics than NTFS;
- automatic conversion would be unacceptable.

### Decision

**Accepted as the preferred writable cross-platform data-volume policy.**

Drive itself must not silently format or migrate a volume.

## 5. Final product behavior

### Existing NTFS data volume

```text
probe NTFS
  -> publish block device
  -> Apple native mount
  -> inspect real mount flags
  -> expose as read-only when macOS mounted it read-only
  -> UI shows read-only capability
  -> no write marker / no write probe
```

### Writable ExFAT data volume

```text
probe ExFAT
  -> publish block device
  -> Apple native mount
  -> require readOnly == false
  -> normal create/edit/delete/persistence operations allowed
```

### Unsupported/unformatted volume

Remain capability-aware and fail closed. Do not guess a writable filesystem.

## 6. Migration policy

If an operator needs to convert an existing NTFS EDP data partition to writable ExFAT:

1. explicitly back up all required data;
2. verify the backup independently;
3. perform an intentional filesystem reformat/migration outside ordinary Drive automatic lifecycle;
4. restore data;
5. verify hashes/content as appropriate;
6. run writable persistence acceptance.

This must be a deliberate maintenance action, never an automatic response to seeing NTFS.

No current release code is required to implement an in-App “convert NTFS to ExFAT” button.

## 7. Safety consequences

The following become hard product rules:

- never write to an Apple-native read-only NTFS mount;
- never use a write marker to “test” NTFS capability;
- never silently format NTFS because the user requested a mount;
- never restore `ntfs-3g` fallback;
- never use an undocumented native NTFS write switch;
- keep filesystem capability visible in XPC/UI state;
- writable acceptance must follow the actual mounted `readOnly` flag.

## 8. Testing consequences

Existing tests remain authoritative:

- capability-aware physical acceptance accepts native NTFS RO;
- read-only volumes receive remount/read-only verification only;
- writable volumes receive create/fsync/hash/remount/delete tests;
- system ratchets must continue to reject `ntfs-3g` product payload/runtime.

New documentation/system ratchets should assert the chosen ADR remains referenced by current product docs.

## 9. Release consequence

NTFS RW is **not a blocker** for the current EDP Drive release candidate.

The release may proceed with:

```text
existing NTFS -> supported read-only compatibility
writable cross-platform target -> ExFAT
```

provided the UI accurately reports read-only state and no destructive migration is automatic.

## 10. Reopen criteria

Reopen this ADR only if at least one of the following becomes a confirmed requirement:

1. existing NTFS media must remain NTFS and must be writable on macOS;
2. Windows interoperability requires NTFS-specific semantics that ExFAT cannot satisfy;
3. an approved, signed, supportable NTFS RW provider becomes available and meets EDP distribution/security constraints;
4. an internally developed NTFS provider is explicitly funded as an independent filesystem project.

If reopened, create a separate implementation plan and do not modify the current stable mount architecture opportunistically.
