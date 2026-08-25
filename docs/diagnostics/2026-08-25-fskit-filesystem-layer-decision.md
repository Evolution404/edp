# FSKit filesystem-layer decision for native EDP USB Vault

Date: 2026-08-25
Status: accepted for the current macOS 26 native branch

## Decision

Do not make the native product architecture depend on chaining the EDP decryption layer into Apple's built-in exFAT FSKit module.

The supported architecture remains:

```text
FSKit / fskitd
  -> real FSBlockDeviceResource
  -> FSBlockRawAccessor
  -> EDPRawReadable
  -> EDP metadata + key derivation + block translation
  -> native read-only filesystem semantics
  -> FSVolume
```

The filesystem-semantics layer must stay behind a narrow decrypted byte/block interface so it can be developed and tested independently from the FSKit resource adapter.

## Why

Apple's public `FSBlockDeviceResource` model represents a block-device resource associated with real media. The real resource handed to a file-system extension is created through the FSKit/fskitd resource path; the public API does not expose a supported constructor that turns arbitrary transformed/decrypted bytes into a new real `FSBlockDeviceResource` that can then be handed to another FSKit module.

No public supported API was found for either of these operations:

1. wrapping an EDP-translated byte stream as a second real FSKit block resource; or
2. invoking/chaining Apple's built-in exFAT FSKit module as a child filesystem of a third-party FSKit module.

Therefore module stacking may be investigated as an experiment if Apple later exposes such an API, but it is not a valid dependency for the product plan today.

References:

- Apple FSKit `FSBlockDeviceResource`: https://developer.apple.com/documentation/fskit/fsblockdeviceresource
- Apple FSKit framework documentation: https://developer.apple.com/documentation/fskit

## Stable SDK contract versus web documentation

The current GitHub-hosted toolchain used by this branch is macOS 26.5.2 with Xcode 26.6 / MacOSX26.5 SDK.

Compiler probes against that installed Swift SDK currently report:

```text
FSKIT_SDK_VOLUME_OPERATIONS=true
FSKIT_SDK_READ_WRITE_OPERATIONS=true
FSKIT_SDK_VOLUME_HANDLER=false
FSKIT_SDK_READ_WRITE_HANDLER=false
FSKIT_SDK_CLIENT_DIRECT_SETTINGS=false
```

Apple's web documentation already describes newer handler-style `FSVolume` APIs and a direct File System Extensions settings entry point, but those symbols are not yet present in this installed stable SDK. Production source must compile against the installed SDK rather than assuming the web documentation and runner SDK are synchronized.

The repository therefore has a separate `Native FSKit SDK Surface` workflow. It probes the actual compiler-visible SDK surface on a low-frequency schedule and manually, without adding compiler startup cost to every fast regression run.

## Current FSVolume work

`EDPReadOnlyVolumeContract.swift` is a compile-only contract built against the current stable SDK:

- `FSVolume.PathConfOperations`
- `FSVolume.Operations`
- `FSVolume.ReadWriteOperations`
- root directory activation
- empty directory enumeration
- read-only mutation policy (`EROFS`)
- no real filesystem parsing

It is intentionally **not** returned from `EDPFileSystem.loadResource` yet. This preserves the existing evidence gate: the project must first demonstrate that an approved third-party FSKit extension receives and recognizes the real EDP block resource on a normal macOS 26 installation.

## Consequence

Work that does not require the approved macOS 26 runtime can proceed in parallel:

1. prove real EDP cipher/plain translation using captures from the existing macOS 15.7.9 machine;
2. keep filesystem semantics isolated from FSKit-specific raw I/O;
3. define and test the smallest read-only namespace/file abstraction;
4. keep the FSVolume API contract compiler-checked;
5. only connect the real volume implementation to `loadResource` after the approved-runtime gate is crossed.

This keeps the native path reversible and avoids committing the project to either a private API or a full custom filesystem implementation before the runtime and real-data boundaries are proven.
