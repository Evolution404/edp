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

The fast native regression job now also exercises negative and boundary paths that were previously uncovered:

- invalid/overflowing aligned windows and device-end expansion;
- invalid aligned short-read continuation;
- malformed LBA4 serial markers and malformed LBA7 inputs;
- invalid SM4 keys/lengths and A6B0 inputs;
- short/invalid LBA11/LBA12 metadata and unsupported algorithms;
- wrong-password LBA12 entry skipping;
- zero-length, final-byte, out-of-bounds, overflowing, missing-key, and passthrough encrypted-partition reads;
- full production Swift source-graph typechecking for the host and extension.

Current successful CI markers include:

```text
ALIGNMENT_512=OK
ALIGNMENT_4096=OK
ALIGNED_WINDOW_NEGATIVE_CONTROLS=OK
ALIGNED_SHORT_READ_CONTINUATION=OK
LBA4_SERIAL_NEGATIVE_CONTROLS=OK
LBA7_SHAPE_GUARDS=OK
RESERVED_PROBE_NEGATIVE_CONTROLS=OK
NATIVE_CRYPTO_NEGATIVE_PATHS=OK
NATIVE_ENCRYPTED_READER_BOUNDARIES=OK
NATIVE_METADATA_NEGATIVE_PATHS=OK
RESULT=SWIFT_EDP_RESERVED_PROBE_GOLDEN_OK
RESULT=SWIFT_NATIVE_CRYPTO_CORE_OK
RESULT=SWIFT_NATIVE_LBA11_LBA12_OK
RESULT=SWIFT_NATIVE_ENCRYPTED_READER_OK
RESULT=NATIVE_SWIFT_SOURCE_GRAPH_TYPECHECKED
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

## Strengthened hosted block gate

The block-device runtime gate is now part of `Native FSKit Hosted Contract` rather than a second workflow that rebuilds the same app. It seeds captured EDP `disk4` LBA4/LBA7 metadata into the raw image before attaching it as `/dev/diskN`.

If Apple ever changes hosted-runner approval behavior and the EDP extension starts executing, CI will only report runtime success when the full native recognition chain is observed:

```text
PROBE_BLOCK_DEVICE=diskN
PROBE_RESERVED_SECTORS_READ=true
PROBE_CORE=swift-native
PROBE_EDP_RESERVED_SIGNATURE=true
PROBE_MATCH=recognized
RESULT=NATIVE_FSKIT_SWIFT_CORE_RECOGNIZED:diskN
```

A mere callback invocation is not sufficient for success.

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

## CI layout and measured speed

Automatic branch validation is split by cost and responsibility:

1. `Native Swift Fast Checks`
   - no XcodeGen and no `xcodebuild`;
   - validates the runtime verifier shell syntax;
   - compiles/runs LBA4/LBA7/alignment golden and negative tests;
   - compiles/runs LBA11/LBA12/CRC32/SM4/encrypted-reader golden and negative tests;
   - typechecks the complete production Swift source graph;
   - runs for ordinary Swift core changes.

2. `Native FSKit Hosted Contract`
   - triggers only for bundle/project/entrypoint/entitlement/hosted-contract changes;
   - performs one XcodeGen + one Debug `xcodebuild` with the index store disabled;
   - validates bundle structure and native-only linkage;
   - signs, installs, and registers the same build once;
   - validates PluginKit indexing and classifies hosted FSClient visibility;
   - seeds captured disk4 LBA4/LBA7 into a real raw block device and classifies either the known approval boundary or a complete native EDP recognition result;
   - uploads one consolidated diagnostics artifact.

The former standalone `Native FSKit Block Probe` was retired because it duplicated XcodeGen/build/sign/register work already performed by the hosted contract.

Measured on GitHub-hosted `macos-26-arm64` after this split:

- `Native Swift Fast Checks`: about 23 seconds from runner start through cleanup;
- combined `Native FSKit Hosted Contract`: about 70 seconds;
- the previous successful PoC + Block Probe pair consumed roughly two 76-second macOS jobs for an equivalent full hosted validation path.

This reduces heavy hosted macOS runner consumption from roughly 152 seconds to about 70 seconds for that path (about 54% less), while ordinary Swift core edits now avoid the heavyweight Xcode build entirely.

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
