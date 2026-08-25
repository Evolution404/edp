# EDP Native FSKit PoC

Minimal macOS 26+ proof of concept for replacing the macFUSE backend with an EDP-owned FSKit extension.

## Current gate

The extension already builds, embeds in `Contents/Extensions`, registers as `com.apple.fskit.fsmodule`, declares block-resource support, and is associated with `edpvault` by Disk Arbitration on GitHub-hosted macOS 26 runners.

A fresh hosted runner stops at the expected macOS user-approval boundary:

```text
Module com.edp.usbvault.fskit-poc.extension is disabled!
```

Do not treat that as an FSKit implementation failure. Hosted runners cannot interactively approve third-party File System Extensions.

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

The verifier:

- requires macOS 26+;
- verifies the installed app signature structure;
- requires `FSClient` to find the EDP module with `isEnabled == true`;
- creates a temporary 16 MiB raw disk image and attaches a real `/dev/diskN`;
- invokes `mount -t edpvault` to drive FSKit probing;
- captures EDP/fskitd diagnostics;
- cleans up the temporary block device;
- succeeds only if EDP's own extension logs the exact marker:

```text
PROBE_BLOCK_DEVICE=diskN
```

Expected final result:

```text
RESULT=NATIVE_FSKIT_BLOCK_RESOURCE_DELIVERED:diskN
```

Set `EDP_RUNTIME_DIAG_DIR=/path` to choose where evidence is retained. Set `EDP_FSKIT_APP=/path/to/app` only when testing an app outside `/Applications/EDPFSKitPoC.app`.

The manual GitHub workflow `Native FSKit Approved Runtime Gate` runs this same verifier on a self-hosted, already-approved macOS runner.

## Block I/O architecture

`FSBlockDeviceResource` direct I/O has device transfer-alignment requirements, while `edp-core::volume::RawIo` intentionally supports arbitrary byte ranges and `EncryptedPartitionIO` commonly operates at 16-byte SM4 boundaries.

`Extension/FSBlockRawAccessor.swift` is therefore the first adapter layer. Its read path expands an arbitrary range to `max(blockSize, physicalBlockSize)`, performs one exact aligned FSKit direct read, then returns only the requested bytes. It is currently unused by `probeResource` so the runtime gate remains minimal and unambiguous.

Do not connect EDP discovery/decryption until the approved runtime verifier proves delivery of a real `FSBlockDeviceResource`.

After that gate passes, the intended order is:

1. read a small aligned metadata range through `FSBlockRawAccessor`;
2. expose a narrow C ABI/callback bridge into `edp-core::RawIo` rather than duplicating crypto in Swift;
3. run existing `discover_volume()` / `probe_boot_sector()` logic;
4. implement the smallest read-only FSKit volume exposing `/volume.raw`;
5. route `/volume.raw` reads through the existing `EncryptedPartitionIO`;
6. add write support only after read-only mount/unmount correctness is proven.
