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

The following logic is now implemented in Swift and covered by executable regressions:

- exact byte-oriented `EDPRawReadable` storage boundary;
- sector-aligned `FSBlockRawAccessor` for `FSBlockDeviceResource`;
- one shared aligned-window implementation used by production I/O and CI;
- one shared `EDPAlignedRead.readFully` implementation for the exact production aligned short-read loop and executable CI regressions;
- safe continuation of sector-aligned partial reads instead of treating every short read as immediate `EIO`;
- LBA4 serial-marker recognition;
- legacy LBA7 rolling-XOR decode and conservative EDP recognition;
- LBA11 device identity derivation;
- LBA12 volume descriptor parsing;
- CRC32 parity;
- native SM4 encrypt/decrypt parity;
- real captured file-key derivation parity;
- unaligned reads through the encrypted-partition reader.

The fast native regression job now exercises both golden vectors and deterministic property/boundary paths:

- 1,280 aligned-window property cases across multiple transfer alignments;
- 384 aligned short-read continuation property cases;
- 512 randomized segmented-progress cases against the exact production `EDPAlignedRead.readFully` loop, verifying request offsets, remaining lengths, destination placement, and final bytes;
- malformed/overflowing aligned windows and device-end expansion;
- zero, oversized, unaligned-progress, invalid-offset, and `off_t` overflow read-loop failures;
- malformed LBA4 serial markers and malformed LBA7 inputs;
- invalid SM4 keys/lengths and A6B0 inputs;
- short/invalid LBA11/LBA12 metadata and unsupported algorithms;
- wrong-password LBA12 entry skipping;
- zero-length, final-byte, out-of-bounds, overflowing, missing-key, and passthrough encrypted-partition reads;
- 1,024 deterministic randomized encrypted-reader windows using file keys derived from captured `disk4` and `disk5` LBA12 metadata;
- full production Extension/Host Swift source-graph typechecking plus compile-checking the top-level `InspectFSKit.swift` diagnostic tool.

The randomized real-key tests intentionally use deterministic synthetic plaintext/ciphertext. The repository does not contain a captured full encrypted data partition, so these tests prove reader correctness with the real derived keys but do **not** claim byte-for-byte parity against real-disk data-area ciphertext.

There are currently 3,200 deterministic property/random cases in the fast path before counting the fixed golden and negative-control cases:

```text
1280 aligned-window properties
 384 continuation properties
 512 production aligned-read progression properties
1024 real-derived-key encrypted-reader windows
----
3200 total
```

Current successful CI markers include:

```text
ALIGNED_READ_SEGMENTED_PROGRESS=OK
ALIGNED_READ_SEGMENTED_PROPERTIES=OK:cases=512
ALIGNED_READ_INVALID_RESULTS=OK
ALIGNED_READ_OFFSET_OVERFLOW=OK
RESULT=ALIGNED_READ_LOOP_OK
ALIGNMENT_512=OK
ALIGNMENT_4096=OK
ALIGNED_WINDOW_PROPERTIES=OK:cases=1280
ALIGNED_WINDOW_NEGATIVE_CONTROLS=OK
ALIGNED_SHORT_READ_CONTINUATION=OK
ALIGNED_CONTINUATION_PROPERTIES=OK:cases=384
LBA4_SERIAL_NEGATIVE_CONTROLS=OK
LBA7_SHAPE_GUARDS=OK
RESERVED_PROBE_NEGATIVE_CONTROLS=OK
NATIVE_CRYPTO_NEGATIVE_PATHS=OK
NATIVE_ENCRYPTED_READER_BOUNDARIES=OK
NATIVE_METADATA_NEGATIVE_PATHS=OK
NATIVE_REAL_KEY_RANDOM_READS=OK:disk4_real_lexar:cases=512
NATIVE_REAL_KEY_RANDOM_READS=OK:disk5_real_sandisk:cases=512
NATIVE_REAL_KEY_RANDOM_READS=OK:disks=2:cases=1024
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

The block-device runtime gate is part of `Native FSKit Hosted Contract` rather than a second workflow that rebuilds the same app. It seeds captured EDP `disk4` LBA4/LBA7 metadata into the raw image before attaching it as `/dev/diskN`.

If Apple ever changes hosted-runner approval behavior and the EDP extension starts executing, CI will only report runtime success when the full native recognition chain is observed:

```text
PROBE_BLOCK_DEVICE=diskN
PROBE_BUILD_VERSION=<expected build>
PROBE_RESERVED_SECTORS_READ=true
PROBE_CORE=swift-native
PROBE_EDP_RESERVED_SIGNATURE=true
PROBE_MATCH=recognized
RESULT=NATIVE_FSKIT_SWIFT_CORE_RECOGNIZED:diskN:build=<expected build>
```

A mere callback invocation is not sufficient for success.

## FSClient behavior on GitHub-hosted macOS

`FSClient.fetchInstalledExtensions` exposes only Apple's built-in FSKit modules on a fresh hosted runner. An A/B test with signed macFUSE and the EDP module showed:

- PluginKit indexed both third-party modules;
- FSClient exposed neither third-party module;
- FSClient exposed Apple's built-in modules.

Therefore hosted Actions cannot prove user-approved third-party FSKit visibility or normal distribution behavior. They remain useful for build, bundle contract, signing structure, PluginKit, Disk Arbitration, raw-block creation, metadata translation, crypto parity, and approval-boundary classification.

Because this hosted FSClient result is a stable environment diagnostic rather than a changing product invariant, executing `FSClient.fetchInstalledExtensions` is now restricted to manual `workflow_dispatch` runs. The diagnostic source still compiles on every relevant Fast Checks run, while automatic Hosted Contract runs avoid paying the roughly 9-second runtime wait.

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
   - compiles the aligned-read, metadata, and crypto/native-core regression binaries in parallel;
   - executes the production aligned-read loop regression, LBA4/LBA7/alignment tests, and LBA11/LBA12/CRC32/SM4/encrypted-reader tests;
   - compiles/typechecks Extension, Host, and `InspectFSKit.swift` in parallel;
   - the aligned-read property harness alone is built with `-O` to remove test-loop overhead; production sources still receive the normal independent source-graph typecheck;
   - runs for ordinary Swift core changes and matching pull requests.

2. `Native FSKit Hosted Contract`
   - automatic triggers are limited to project/bundle metadata, host entrypoint, extension entrypoint/entitlements, and the hosted-contract workflow itself;
   - changes to `InspectFSKit.swift` do not trigger the heavy Xcode build; they are compile-checked on the Fast Checks path;
   - performs one XcodeGen + one arm64 Debug `xcodebuild`, with code signing/indexing/previews/debug-dylib/localization-emission overhead disabled where safe for this contract build;
   - validates bundle structure, build-version consistency, and native-only linkage;
   - signs, installs, and registers the same build once;
   - validates PluginKit indexing;
   - seeds captured disk4 LBA4/LBA7 into a real raw block device and classifies either the known approval boundary or a complete native EDP recognition result;
   - runs the hosted FSClient visibility diagnostic only when manually dispatched;
   - uploads one consolidated diagnostics artifact.

The former standalone `Native FSKit Block Probe` remains retired because it duplicated XcodeGen/build/sign/register work already performed by the hosted contract.

Measured on GitHub-hosted `macos-26-arm64` after the current split:

- `Native Swift Fast Checks`: representative runs are about **20–22 seconds** from runner start through cleanup; hosted-runner variance can move this somewhat;
- all 3,200 deterministic property/random cases plus fixed golden/negative controls remain enabled at that speed;
- automatic `Native FSKit Hosted Contract`: about **58 seconds** on the measured optimized run;
- inside that hosted build path, XcodeGen installation was about 4 seconds, project generation under 1 second, and `xcodebuild` about 41 seconds;
- the previous successful PoC + Block Probe pair consumed roughly two 76-second macOS jobs for an equivalent full hosted validation path.

This reduces heavy hosted macOS runner consumption from roughly 152 seconds to about 58 seconds for that path (about **62% less**). This is runner consumption, not a claim of identical wall-clock improvement, because the old jobs could run concurrently. Ordinary Swift core edits avoid the heavyweight Xcode build entirely.

The remaining obvious CI bottleneck is the approximately 41-second clean `xcodebuild`; XcodeGen generation itself is no longer material. Further CI work should only target that compile cost if it can preserve the same bundle/registration contract.

Manual diagnostics remain available for signing A/B, enablement negative control, hosted FSClient behavior, and the approved runtime gate.

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
