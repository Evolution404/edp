# macOS 26 Native FSKit — current runtime boundary

Date: 2026-08-25
Branch: `feat/macos26-native-fskit`

## Goal

Replace the macFUSE backend with a native macOS 26+ FSKit extension. The first gate is deliberately minimal: prove that a real block device reaches EDP's own `FSBlockDeviceResource` `probeResource` callback before adding EDP metadata parsing, decryption, or a `/volume.raw` filesystem.

## Confirmed working

On GitHub Actions `macos-26` (macOS 26.5.2 / Xcode 26.6):

- SwiftUI host app builds.
- ExtensionKit FSKit extension builds and links with `_NSExtensionMain`.
- Deployment target is macOS 26.0.
- Extension is embedded in `Contents/Extensions`.
- Extension point is `com.apple.fskit.fsmodule`.
- `FSShortName` is `edpvault`.
- `FSSupportsBlockResources = true`.
- Requested extension entitlements are:
  - `com.apple.developer.fskit.fsmodule = true`
  - `com.apple.security.app-sandbox = true`
- Ad-hoc signing is structurally valid for CI inspection.
- PluginKit indexes the EDP extension as an FSKit module.
- A real raw image can be attached as `/dev/diskN`.
- Disk Arbitration associates that block device probe path with EDP's FSKit metadata (`FSModule=edpvault`, EDP bundle ID, block-resource support).

## Exact current runtime boundary

A hosted runner reaches the native FSKit approval gate and then stops with:

```text
Module com.edp.usbvault.fskit-poc.extension is disabled!
```

The EDP extension is not launched and its `probeResource` is not called. This is expected on a fresh hosted runner with no interactive File System Extensions approval.

The only valid runtime success marker is emitted by EDP itself:

```text
PROBE_BLOCK_DEVICE=diskN
```

Do not treat another Apple filesystem module's `probeResource` log as success.

## FSClient behavior on GitHub-hosted macOS

`FSClient.fetchInstalledExtensions` returns only Apple's built-in FSKit modules on the hosted runner. An A/B test installed official signed macFUSE 5.3.3 and the EDP ad-hoc module on the same runner:

- PluginKit indexed both third-party modules.
- FSClient exposed neither third-party module.
- FSClient exposed only Apple's exFAT, FTP, and MSDOS modules.

Therefore GitHub-hosted Actions cannot be used to decide whether Developer ID/provisioned EDP signing is sufficient for runtime visibility. Hosted Actions remain useful for build, bundle-contract, signing-structure, PluginKit, Disk Arbitration, and raw-block tests.

## Enablement is a user authorization gate

Manually writing:

```text
~/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist
```

does not make the module visible to FSClient and does not bypass `fskitd` approval. That experiment is retained only as a manual negative control.

The host app now provides a macOS 26-native onboarding path using `SMAppService.openSystemSettingsLoginItems()` and refreshes FSKit state when the app becomes active again.

## Signing / provisioning conclusion

`com.apple.developer.fskit.fsmodule` is an FSKit provisioning capability. Merely inserting the entitlement into an ad-hoc signature is not a normal distribution mechanism: on a standard user machine AMFI must accept the entitlement as authorized by the signing/provisioning identity.

For normal distribution with Gatekeeper/SIP/AMFI intact, plan around an Apple Developer Program signing identity and a provisioning profile/App ID that authorizes the FSKit Module capability. Current public Apple documentation identifies the FSKit Module capability but does not state that it requires a separate special entitlement-request approval beyond enabling/provisioning the capability. Do not conflate Developer Program membership/signing with a separate Apple capability-request approval unless later evidence shows one is required.

Ad-hoc execution that relies on disabling SIP or `amfi_get_out_of_my_way=1` is suitable only for isolated research, not the product installation path.

## CI layout

Automatic on branch pushes:

1. `Native FSKit PoC`
   - build
   - bundle contract
   - entitlement/signature structure
   - PluginKit FSKit indexing
   - classify hosted FSClient visibility without treating it as a failure

2. `Native FSKit Block Probe`
   - build/register
   - attach a real raw `/dev/diskN`
   - attempt `mount -t edpvault`
   - pass only as either:
     - real EDP marker `PROBE_BLOCK_DEVICE=...`, or
     - the known hosted-runner approval boundary

Manual diagnostics:

- `Native FSKit Signing A-B`
- `Native FSKit Enablement Negative Control`
- `Native FSKit Approved Runtime Gate`

The approved runtime gate is self-hosted only. It intentionally does not overwrite the installed application. It requires an already installed and user-approved EDP FSKit module, then creates a real raw block device and requires EDP's exact `PROBE_BLOCK_DEVICE=diskN` marker.

## Next gate

Do **not** implement EDP decryption or `/volume.raw` yet.

Next required evidence on a normal approved macOS 26 machine:

```text
FSKIT_MODULE_FOUND=com.edp.usbvault.fskit-poc.extension
FSKIT_MODULE_ENABLED=true
PROBE_BLOCK_DEVICE=diskN
RESULT=NATIVE_FSKIT_BLOCK_RESOURCE_DELIVERED
```

Once that gate passes:

1. Read a small fixed range from `FSBlockDeviceResource` in `probeResource`.
2. Recognize only the EDP container signature/metadata.
3. Return the correct `FSProbeResult` without implementing a full volume yet.
4. Implement the smallest read-only volume exposing only `/volume.raw`.
5. Connect `EncryptedPartitionIO` behind that virtual file.
6. Add write support only after read-only correctness and teardown/unmount behavior are proven.
