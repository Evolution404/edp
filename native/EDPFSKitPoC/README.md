# EDP Native FSKit PoC

Minimal macOS 26+ proof of concept for replacing the macFUSE backend with an EDP-owned FSKit extension.

## Architecture rule

The macOS 26 native product path is Swift/Apple-framework only. The FSKit host and extension do not build, link, or call Rust, C ABI bridge code, macFUSE, or an external helper daemon.

Legacy Rust crates remain in the repository temporarily as the previous implementation and as behavior references while functionality is migrated. They are not dependencies of `native/EDPFSKitPoC`.

Native layering:

```text
FSKit
  -> FSBlockDeviceResource
  -> FSBlockRawAccessor (alignment + exact byte reads)
  -> EDPRawReadable (Swift storage boundary)
  -> EDP metadata / key / crypto parsers in Swift
  -> native FSVolume implementation
```

Crypto, LBA11/LBA12 parsing, partition mapping, and filesystem semantics must be added on the Swift side. Do not reintroduce a Rust bridge into the native target.

## Current gate

The extension builds, embeds in `Contents/Extensions`, registers as `com.apple.fskit.fsmodule`, declares block-resource support, and is associated with `edpvault` by Disk Arbitration on GitHub-hosted macOS 26 runners.

A fresh hosted runner stops at the expected macOS user-approval boundary:

```text
Module com.edp.usbvault.fskit-poc.extension is disabled!
```

Do not treat that as an FSKit implementation failure. Hosted runners cannot interactively approve third-party File System Extensions.

The native probe already reads EDP LBA4/LBA7 through `FSBlockRawAccessor`, decodes the legacy rolling-XOR metadata in Swift, requires the serial marker plus partition types `[1, 2, 4]`, and returns `.recognized(...)` only when both signals match.

## First-run flow on a normal Mac

1. Install and launch `EDPFSKitPoC.app`.
2. The host checks `FSClient` automatically.
3. If approval is required, choose **Open Login Items & Extensions**.
4. In System Settings, open **File System Extensions** and enable the EDP extension once.
5. Return to the app. It refreshes automatically and should show **Native FSKit is enabled**.

No private enablement API and no manual `enabledModules.plist` modification are used.

## One-command approved runtime verification

After the extension is installed and enabled, run from the repository root:

```bash
bash native/EDPFSKitPoC/Tools/verify-approved-runtime.sh
```

The verifier seeds captured EDP LBA4/LBA7 metadata into a temporary raw block device, drives `mount -t edpvault`, and succeeds only when the EDP extension logs the native Swift recognition markers.

Expected final result:

```text
RESULT=NATIVE_FSKIT_SWIFT_CORE_RECOGNIZED:diskN
```

Set `EDP_RUNTIME_DIAG_DIR=/path` to choose where evidence is retained. Set `EDP_FSKIT_APP=/path/to/app` only when testing an app outside `/Applications/EDPFSKitPoC.app`.

## Next implementation order

1. port LBA11/LBA12 parsing and volume descriptors to Swift;
2. implement native SM4 plus key derivation with golden-vector parity tests;
3. add a Swift encrypted-partition reader on top of `EDPRawReadable`;
4. prove plaintext reads from captured media/fixtures;
5. implement the smallest read-only `FSVolume` and filesystem semantics;
6. add write support only after read-only mount/unmount correctness is proven.
