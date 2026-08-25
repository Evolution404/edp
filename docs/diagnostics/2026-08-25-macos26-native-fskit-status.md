# macOS 26 Native FSKit — current runtime boundary

Date: 2026-08-25
Branch: `feat/macos26-native-fskit`

## Product direction

The macOS 26+ path is a native Swift/Apple-framework implementation:

```text
FSKit
  -> FSBlockDeviceResource
  -> FSBlockRawAccessor
  -> EDPRawReadable
  -> EDP metadata / key / crypto translation in Swift
  -> native FSVolume (not implemented yet)
```

The native target does not depend on macFUSE, Rust, a C ABI bridge, or an external daemon. Legacy code remains only as a behavior reference during migration.

The custom Swift exFAT-reader experiment has been retired. The current work is intentionally focused on proving the EDP block-translation boundary before committing to filesystem semantics.

## Confirmed working on GitHub-hosted macOS 26

Validated on GitHub Actions `macos-26` with macOS 26.5.2 / Xcode 26.6 / Apple Silicon:

### FSKit bundle contract

- SwiftUI host builds.
- ExtensionKit FSKit extension builds and links with `_NSExtensionMain`.
- Deployment target is macOS 26.0.
- Extension is embedded in `Contents/Extensions`.
- Extension point is `com.apple.fskit.fsmodule`.
- `FSShortName` is `edpvault`.
- `FSSupportsBlockResources = true`.
- Requested extension entitlements are:
  - `com.apple.developer.fskit.fsmodule = true`
  - `com.apple.security.app-sandbox = true`
- Ad-hoc signing is structurally valid for hosted CI inspection.
- PluginKit indexes `com.edp.usbvault.fskit-poc.extension` as an FSKit module.
- Disk Arbitration associates the raw block path with EDP's FSKit metadata.

### Native block translation core

The following logic is now implemented in Swift and covered by golden regressions:

- exact byte-oriented `EDPRawReadable` storage boundary;
- sector-aligned `FSBlockRawAccessor` for `FSBlockDeviceResource`;
- one shared aligned-window implementation used by production I/O and CI;
- safe continuation of sector-aligned partial reads instead of treating every short read as immediate `EIO`;
- LBA4 serial-marker recognition;
- legacy LBA7 rolling-XOR decode and conservative EDP recognition;
- LBA11 device identity derivation;
- LBA12 volume descriptor parsing;
- CRC32 parity;
- native SM4 encrypt/decrypt parity;
- real captured file-key derivation parity;
- unaligned reads through the encrypted-partition reader.

Current successful CI markers include:

```text
ALIGNMENT_512=OK
ALIGNMENT_4096=OK
ALIGNED_SHORT_READ_CONTINUATION=OK
RESERVED_PROBE_NEGATIVE_CONTROLS=OK
RESULT=SWIFT_EDP_RESERVED_PROBE_GOLDEN_OK
RESULT=SWIFT_NATIVE_CRYPTO_CORE_OK
RESULT=SWIFT_NATIVE_LBA11_LBA12_OK
RESULT=SWIFT_NATIVE_ENCRYPTED_READER_OK
RESULT=PURE_SWIFT_EDP_CORE_PROBE_OK
```

## Current FSKit probe behavior

`EDPFileSystem.probeResource` now does real EDP work when it receives an `FSBlockDeviceResource`:

1. emits the exact BSD-device marker;
2. reads LBA4 and LBA7 through `FSBlockRawAccessor`;
3. runs the native Swift recognizer;
4. returns `.notRecognized` unless both conservative EDP signals match;
5. returns `.recognized(name: "EDP USB Vault", ...)` when the captured EDP metadata shape matches.

Expected successful runtime markers are:

```text
PROBE_BLOCK_DEVICE=diskN
PROBE_RESERVED_SECTORS_READ=true
PROBE_CORE=swift-native
PROBE_EDP_RESERVED_SIGNATURE=true
PROBE_MATCH=recognized
```

## Exact remaining runtime boundary

A fresh GitHub-hosted runner still stops before the EDP extension launches:

```text
Module com.edp.usbvault.fskit-poc.extension is disabled!
```

This is the macOS user-authorization gate for third-party File System Extensions. On hosted Actions there is no interactive approval flow, so `probeResource` cannot be reached there.

This is not currently an FSKit implementation failure. The same hosted run confirms all of the following immediately before the denial:

- the app and extension compile successfully;
- PluginKit indexes the EDP FSKit module;
- a real raw block device is attached;
- Disk Arbitration discovers the EDP FSKit module metadata;
- `fskitd` is involved in the mount path;
- the request is rejected specifically because the EDP module is disabled.

## Strengthened hosted block probe

`Native FSKit Block Probe` no longer attaches an all-zero image. It now seeds captured EDP `disk4` LBA4/LBA7 metadata into the raw image before attaching it as `/dev/diskN`.

If Apple ever changes hosted-runner approval behavior and the EDP extension starts executing, CI will only report runtime success when the full native recognition chain is observed:

```text
PROBE_BLOCK_DEVICE=diskN
PROBE_RESERVED_SECTORS_READ=true
PROBE_CORE=swift-native
PROBE_EDP_RESERVED_SIGNATURE=true
PROBE_MATCH=recognized
RESULT=NATIVE_FSKIT_SWIFT_CORE_RECOGNIZED:diskN
```

A mere callback invocation is no longer sufficient for success.

## FSClient behavior on GitHub-hosted macOS

`FSClient.fetchInstalledExtensions` exposes only Apple's built-in FSKit modules on a fresh hosted runner. An A/B test with signed macFUSE and the EDP module showed:

- PluginKit indexed both third-party modules;
- FSClient exposed neither third-party module;
- FSClient exposed Apple's built-in modules.

Therefore hosted Actions cannot prove user-approved third-party FSKit visibility or normal distribution behavior. They remain useful for build, bundle contract, signing structure, PluginKit, Disk Arbitration, raw-block creation, metadata translation, crypto parity, and approval-boundary classification.

## Enablement / onboarding

Manually writing the FSKit settings plist does not bypass approval and is retained only as a negative-control result.

The host app uses the public macOS onboarding path:

- query `FSClient.shared.fetchInstalledExtensions`;
- distinguish missing/awaiting approval, disabled, enabled, and query failure states;
- open **Login Items & Extensions** with `SMAppService.openSystemSettingsLoginItems()`;
- refresh FSKit state when the app becomes active again.

No private enablement API is part of the product path.

## Signing / provisioning conclusion

`com.apple.developer.fskit.fsmodule` is an FSKit provisioning capability. Injecting the entitlement into an ad-hoc signature is sufficient for structural CI experiments, but not a normal distribution strategy.

For a standard Mac with Gatekeeper/SIP/AMFI intact, the product path must use an Apple Developer Program signing identity and provisioning that authorizes the FSKit Module capability. Current evidence does not establish a separate special Apple approval process beyond normal capability provisioning; do not assume one unless later evidence demonstrates it.

Disabling SIP or globally weakening AMFI remains research-only and is not part of the product design.

## CI layout

Automatic branch workflows now cover:

1. `Native FSKit PoC`
   - host/extension build
   - bundle contract
   - signing/entitlement structure
   - PluginKit indexing
   - hosted FSClient classification

2. `Native Swift EDP Core Probe`
   - shared alignment math
   - aligned-short-read continuation
   - LBA4/LBA7 recognition
   - LBA11/LBA12 translation
   - CRC32 / SM4 / key derivation
   - encrypted-partition reader parity

3. `Native FSKit Block Probe`
   - build/register extension
   - seed captured EDP LBA4/LBA7 into a raw image
   - attach it as a real `/dev/diskN`
   - attempt the native FSKit mount path
   - accept either the known hosted approval boundary or a complete native EDP recognition result

Manual diagnostics remain available for signing A/B, enablement negative control, and the approved runtime gate.

## Next required gate

Do **not** implement a full filesystem yet.

The next evidence must come from a normal macOS 26 machine where the user has enabled the EDP File System Extension:

```text
FSKIT_MODULE_FOUND=com.edp.usbvault.fskit-poc.extension
FSKIT_MODULE_ENABLED=true
PROBE_BLOCK_DEVICE=diskN
PROBE_RESERVED_SECTORS_READ=true
PROBE_CORE=swift-native
PROBE_EDP_RESERVED_SIGNATURE=true
PROBE_MATCH=recognized
RESULT=NATIVE_FSKIT_SWIFT_CORE_RECOGNIZED:diskN
```

The repository already contains the self-hosted `Native FSKit Approved Runtime Gate` and `native/EDPFSKitPoC/Tools/verify-approved-runtime.sh` for this proof.

## Implementation order after the approved runtime gate

1. Keep `FSBlockRawAccessor` as the only FSKit-specific raw-device adapter.
2. Feed the existing native LBA11/LBA12 + crypto translation through the live block resource.
3. Prove decrypted bytes from a captured/real EDP partition through the live FSKit resource.
4. Define the smallest read-only `FSVolume` surface needed for the product architecture.
5. Validate mount, read, teardown, and unmount behavior before adding writes.
6. Add write support only after read-only correctness is stable.

Do not reintroduce macFUSE, the Rust bridge, a helper daemon, or the retired custom exFAT implementation into the native macOS 26 target.
