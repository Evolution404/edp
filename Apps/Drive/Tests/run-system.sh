#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="${ROOT}/Apps/Drive/Tests"
STORAGE_RUNNER="${TEST_ROOT}/run-storage.sh"
UI_RUNNER="${TEST_ROOT}/run-ui.sh"
APP_SERVICE_SUPPORT_RUNNER="${TEST_ROOT}/run-app-service-support.sh"
INSTALLER_MEDIA_PROBE_RUNNER="${TEST_ROOT}/run-installer-media-probe.sh"
APP_SOURCE="${ROOT}/Apps/Drive/product/App/EDPUSBVaultApp.swift"
APP_SERVICE_SUPPORT_SOURCE="${ROOT}/Apps/Drive/product/App/Service/EDPAppServiceSupport.swift"
APP_SMOKE_SUPPORT_SOURCE="${ROOT}/Apps/Drive/product/App/Service/EDPXPCSmokeSupport.swift"
APP_VIEW_MODEL_SOURCE="${ROOT}/Apps/Drive/product/App/Model/EDPVaultViewModel.swift"
APP_SIDEBAR_SOURCE="${ROOT}/Apps/Drive/product/App/Sidebar/EDPSidebarView.swift"
APP_SHELL_SOURCE="${ROOT}/Apps/Drive/product/App/Shell/EDPMainWindow.swift"
APP_OVERVIEW_SOURCE="${ROOT}/Apps/Drive/product/App/Pages/EDPOverviewView.swift"
APP_DEVICES_SOURCE="${ROOT}/Apps/Drive/product/App/Pages/EDPDevicesView.swift"
APP_ACTIVITY_SOURCE="${ROOT}/Apps/Drive/product/App/Pages/EDPActivityView.swift"
APP_SETTINGS_SOURCE="${ROOT}/Apps/Drive/product/App/Pages/EDPSettingsView.swift"
APP_MENU_BAR_SOURCE="${ROOT}/Apps/Drive/product/App/MenuBar/EDPMenuBarView.swift"
RUNTIME_SOURCE="${ROOT}/Apps/Drive/product/EDPVaultRuntime.swift"
RUNTIME_SUPPORT_SOURCE="${ROOT}/Apps/Drive/product/EDPRuntimeSupport.swift"
RUNTIME_STATE_SOURCE="${ROOT}/Apps/Drive/product/EDPRuntimeState.swift"
DEVICE_OPERATIONS_SOURCE="${ROOT}/Apps/Drive/product/EDPDeviceOperations.swift"
DEVICE_DISCOVERY_CONTROLLER_SOURCE="${ROOT}/Apps/Drive/product/EDPDeviceDiscoveryController.swift"
RAW_ACCESS_SOURCE="${ROOT}/Apps/Drive/product/EDPRawAccess.swift"
RAW_ACCESS_COORDINATOR_SOURCE="${ROOT}/Apps/Drive/product/EDPRawAccessCoordinator.swift"
AUTOMATION_STATE_SOURCE="${ROOT}/Apps/Drive/product/EDPAutomationState.swift"
ACTIVITY_STORE_SOURCE="${ROOT}/Apps/Drive/product/EDPActivityStore.swift"
EJECT_COORDINATOR_SOURCE="${ROOT}/Apps/Drive/product/EDPEjectCoordinator.swift"
SERVICE_LIFECYCLE_STATE_SOURCE="${ROOT}/Apps/Drive/product/EDPServiceLifecycleState.swift"
RECOVERY_COORDINATOR_SOURCE="${ROOT}/Apps/Drive/product/EDPRecoveryCoordinator.swift"
XPC_PROTOCOL_SOURCE="${ROOT}/Apps/Drive/product/EDPXPCProtocol.swift"
XPC_SERVICE_SOURCE="${ROOT}/Apps/Drive/product/EDPXPCService.swift"
SERVICE_MAIN_SOURCE="${ROOT}/Apps/Drive/product/EDPServiceMain.swift"
MOUNT_LIFECYCLE_SOURCE="${ROOT}/Apps/Drive/product/EDPMountLifecycle.swift"
MOUNT_SUPPORT_SOURCE="${ROOT}/Apps/Drive/product/EDPMountSupport.swift"
SCHEDULER_SOURCE="${ROOT}/Apps/Drive/product/EDPLifecycleScheduler.swift"
JOURNAL_SOURCE="${ROOT}/Apps/Drive/product/EDPLifecycleJournal.swift"
RUNTIME_METRICS_SOURCE="${ROOT}/Apps/Drive/product/EDPRuntimeMetrics.swift"
NATIVE_SYSTEM_SOURCE="${ROOT}/Apps/Drive/product/EDPNativeSystem.swift"
IOKIT_LIFECYCLE_SOURCE="${ROOT}/Apps/Drive/product/EDPIOKitLifecycle.swift"
MACFUSE_POLICY_SOURCE="${ROOT}/Apps/Drive/product/EDPMacFUSERuntimePolicy.swift"
PUBLISHER_SOURCE="${ROOT}/Apps/Drive/product/EDPBlockDevicePublisher.swift"
POLICY_SOURCE="${ROOT}/Apps/Drive/product/EDPDevicePolicyStore.swift"
CREDENTIAL_SOURCE="${ROOT}/Apps/Drive/product/EDPCredentialStore.swift"
MODEL_PROPERTY_SOURCE="${ROOT}/Apps/Drive/Tests/VirtualUSB/ValidateLifecycleModelProperties.swift"
EMBEDDED_SERVICE_PLIST="${ROOT}/Apps/Drive/product/App/com.edp.drive.service.plist"
LEGACY_SERVICE_PLIST="${ROOT}/Apps/Drive/installer/com.edp.drive.service.plist"
CLEAN_INSTALLER_SOURCE="${ROOT}/Apps/Drive/installer/build-clean-installer.sh"
SELF_SIGNED_INSTALLER_SOURCE="${ROOT}/Apps/Drive/installer/build-self-signed-installer.sh"
INSTALLER_VERIFY_SOURCE="${ROOT}/Apps/Drive/scripts/verify-clean-installer.sh"
MAKEFILE_SOURCE="${ROOT}/Makefile"
RAW_VALIDATION_SOURCE="${ROOT}/Apps/Drive/product/EDPRawValidation.c"
RAW_VALIDATION_HEADER="${ROOT}/Apps/Drive/product/EDPRawValidation.h"
RAW_BROKER_SOURCE="${ROOT}/Apps/Drive/product/EDPRawFDBroker.c"

# The default regression suite must never gain an interactive elevation path.
if /usr/bin/grep -RInE '(^|[[:space:]])sudo([[:space:]]|$)|/usr/bin/sudo' "${TEST_ROOT}" \
  --exclude='README.md' --exclude='run-system.sh' --exclude-dir='CI'; then
  echo 'forbidden sudo dependency in Drive regression suite' >&2
  exit 1
fi

# Virtual fixtures may carry synthetic rdisk-looking strings as identity data,
# but tests must never open a literal physical raw node.
if /usr/bin/grep -RInE 'open\([^\n]*\/dev\/rdisk|fopen\([^\n]*\/dev\/rdisk|FileHandle\([^\n]*\/dev\/rdisk' \
  "${TEST_ROOT}" --exclude='run-system.sh'; then
  echo 'forbidden literal physical raw-device open in Drive regression suite' >&2
  exit 1
fi

# Destructive filesystem preparation is allowed only through the storage
# runner's synthetic-device proof. Whole-disk erase is never permitted.
! /usr/bin/grep -RInF 'diskutil eraseDisk' "${TEST_ROOT}" --exclude='run-system.sh'
/usr/bin/grep -Fq 'assert_fixture_device "$bsd" "$path"' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'assert_synthetic_device "$attached_bsd" "$backing"' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'diskutil eraseVolume "$filesystem" "$label" "$bsd"' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'fixture backing escaped test root' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'synthetic backing escaped test root' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'image.get("diskimages2") is False' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'image.get("owner-uid") == os.getuid()' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'Teardown is metadata-only.' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'bounded 15 /usr/bin/hdiutil detach "/dev/$bsd" -force' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'wait_for_fixture_publication_gone "$path" 100' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'successful detach call is not enough' "${STORAGE_RUNNER}"
! /usr/bin/grep -Fq '[[ -e "/dev/$bsd" ]] || return 0' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'capture_hdiutil_info() {' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'bounded 3 /usr/bin/hdiutil info -plist' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'hdiutil info snapshot did not stabilize' "${STORAGE_RUNNER}"
[[ "$(/usr/bin/grep -Fc '/usr/bin/hdiutil info -plist' "${STORAGE_RUNNER}")" -eq 1 ]]
/usr/bin/grep -Fq 'capture_hdiutil_info "$WORK_DIR/hdiutil-artifact-check.plist" 20' "${STORAGE_RUNNER}"
DA_MOUNT_SOURCE="${ROOT}/Apps/Drive/Tests/Storage/DiskArbitrationMountHelper.c"
EJECT_IMAGE_SECTION="$(/usr/bin/awk '/^eject_image\(\)/,/^filesystem_format_completed\(\)/' "${STORAGE_RUNNER}")"
/usr/bin/grep -Fq 'bounded 25 "$DA_MOUNT_BIN" --eject "$bsd"' <<<"${EJECT_IMAGE_SECTION}"
/usr/bin/grep -Fq 'recover_synthetic_publication "$bsd" "$backing"' <<<"${EJECT_IMAGE_SECTION}"
! /usr/bin/grep -Fq '/usr/bin/hdiutil detach' <<<"${EJECT_IMAGE_SECTION}"
! /usr/bin/grep -Fq '/usr/sbin/diskutil eject' <<<"${EJECT_IMAGE_SECTION}"
! /usr/bin/grep -Fq 'diskutil unmountDisk' <<<"${EJECT_IMAGE_SECTION}"
/usr/bin/grep -Fq 'image.get("diskimages2") is True' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'image.get("owner-uid") == os.getuid()' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'synthetic_publication_owner_snapshot() {' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 're.fullmatch(r"/dev/disk' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq '[[ "$revalidated_snapshot" == "$owner_snapshot" ]]' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq -- '--assert-process-path "$pid" /usr/libexec/diskimagesiod' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'STORAGE_DISKIMAGES_OWNER_POSTKILL_PROCESS=' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'STORAGE_DISKIMAGES_OWNER_POSTKILL_SNAPSHOT=' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'STORAGE_DISKIMAGES_OWNER_POSTKILL_GENERATION=' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'STORAGE_DISKIMAGES_STALE_OWNER_RETIRED=stable-dead-owner' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq '[[ -z "$devices" && "$final_snapshot" == "$owner_snapshot" ]]' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq '! /bin/kill -0 "$pid"' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'proc_pidpath(' "${DA_MOUNT_SOURCE}"
! /usr/bin/grep -Fq 'REMOUNT_QUIESCENCE_SECONDS' "${STORAGE_RUNNER}"
! /usr/bin/grep -Fq 'wait_for_native_filesystem_quiescence' "${STORAGE_RUNNER}"
! /usr/bin/grep -Fq 'wait_for_remount_quiescence' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'DADiskEject(disk, kDADiskEjectOptionDefault' "${DA_MOUNT_SOURCE}"
M12_SECTION="$(/usr/bin/awk '/^run_m12\(\)/,/^run_m14\(\)/' "${STORAGE_RUNNER}")"
/usr/bin/grep -Fq 'unmount_path "$mountpoint"' <<<"${M12_SECTION}"
/usr/bin/grep -Fq 'cleanup_crashed_local_mount "$bridge"' <<<"${M12_SECTION}"
/usr/bin/grep -Fq 'eject_image "$bsd" "$bridge/volume.raw"' <<<"${M12_SECTION}"
/usr/bin/grep -Fq 'Product code therefore fails closed before entering that syscall' <<<"${M12_SECTION}"
! /usr/bin/grep -Fq 'force_unmount_synthetic_path' "${STORAGE_RUNNER}"
echo 'RESULT=DRIVE_SYSTEM_STORAGE_PUBLICATION_TEARDOWN_OK'
echo 'RESULT=DRIVE_SYSTEM_STORAGE_HDIUTIL_SNAPSHOT_BOUNDED_OK'
echo 'RESULT=DRIVE_SYSTEM_STORAGE_DA_EJECT_OWNER_RECOVERY_OK'

# Storage-only FSKit host recovery mirrors the production failure boundary. It
# must use real MNT_EXT_FSKIT mount detection and is reserved for teardown/stuck
# host recovery; extension registration/approval failures must never restart the
# user agent or grow into a retry loop.
FSKIT_GUARD_SOURCE="${ROOT}/Apps/Drive/native/EDPFSKitPoC/Tools/MacFUSEMinimal/DirectMFMountUnmountHelper.c"
/usr/bin/grep -Fq 'MNT_EXT_FSKIT' "${FSKIT_GUARD_SOURCE}"
! /usr/bin/grep -Fq 'MNT_FORCE' "${FSKIT_GUARD_SOURCE}"
! /usr/bin/grep -Fq 'DIRECT_MFMOUNT_PRIVILEGED_UNMOUNT_CALL' "${FSKIT_GUARD_SOURCE}"
/usr/bin/grep -Fq -- '--assert-no-fskit-mounts' "${FSKIT_GUARD_SOURCE}" "${STORAGE_RUNNER}"
! /usr/bin/grep -Fq 'for attempt in 1 2; do' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'command" == "/usr/libexec/fskit_agent"' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'wait_for_child_exit_bounded()' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'STORAGE_CHILD_EXIT_TIMEOUT=' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'STORAGE_ADAPTER_BRIDGE_RECOVERY=' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'STORAGE_ADAPTER_HOST_RECOVERY=' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'wait_for_child_exit_bounded "$pid" 50 "adapter-term-$tag"' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'wait_for_child_exit_bounded "$pid" 10 "adapter-kill-$tag"' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'wait_for_child_exit_bounded "$pid" 20 "adapter-post-host-recovery-$tag"' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'wait_for_child_exit_bounded "$pid" 30 "m12-crash-kill"' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq -- '--mountpoint-for-source' "${FSKIT_GUARD_SOURCE}" "${STORAGE_RUNNER}"
/usr/bin/grep -Fq -- '--assert-readonly' "${FSKIT_GUARD_SOURCE}" "${STORAGE_RUNNER}"
/usr/bin/grep -Fq -- '--assert-writable' "${FSKIT_GUARD_SOURCE}" "${STORAGE_RUNNER}"
/usr/bin/grep -Fq -- '--assert-no-mount-prefix' "${FSKIT_GUARD_SOURCE}" "${STORAGE_RUNNER}"
! /usr/bin/grep -Fq '/usr/sbin/diskutil info' "${STORAGE_RUNNER}"
! /usr/bin/grep -Eq '/sbin/mount([[:space:]]|$)' "${STORAGE_RUNNER}"
! /usr/bin/grep -Fq 'adapter_log_is_transient_fskit_failure' "${STORAGE_RUNNER}"
! /usr/bin/grep -Fq 'STORAGE_FSKIT_HOST_RETRY=' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'candidate="$(/usr/bin/mktemp "${output}.tmp.XXXXXX")"' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq '/bin/mv -f "$candidate" "$output"' "${STORAGE_RUNNER}"
! /usr/bin/grep -Fq ': >"$output"' "${STORAGE_RUNNER}"
echo 'RESULT=DRIVE_SYSTEM_STORAGE_FSKIT_BOUNDED_RECOVERY_OK'
echo 'RESULT=DRIVE_SYSTEM_STORAGE_ATOMIC_HDIUTIL_SNAPSHOT_OK'

# The macFUSE Local FSKit block bridge keeps its established local,nobrowse VFS
# semantics. Repeated-remount safety is enforced by exact publication teardown,
# unique generations, and real framework completion events; do not change the
# bridge's read/write VFS behavior as a substitute for lifecycle isolation.
TRANSPORT_BUILD="${ROOT}/Apps/Drive/installer/build-transport-backends.sh"
TRANSPORT_PROVIDER="${ROOT}/Apps/Drive/product/EDPTransportProvider.swift"
RAW_TRANSPORT="${ROOT}/Apps/Drive/native/EDPFSKitPoC/Tools/MacFUSEMinimal/DirectMFMountRawTransport.c"
ASYNC_SHIM="${ROOT}/Apps/Drive/native/EDPFSKitPoC/Tools/MacFUSEMinimal/DirectMFMountAsyncShim.c"
/usr/bin/grep -Fq '"nobrowse,volname=%s"' "${RAW_TRANSPORT}"
/usr/bin/grep -Fq 'localVolume: true' "${TRANSPORT_PROVIDER}"
/usr/bin/grep -Fq 'EDP_MFMOUNT_OPTIONS": "local,nobrowse"' "${TRANSPORT_PROVIDER}"
/usr/bin/grep -Fq 'EDP_MFMOUNT_QUIET": "0"' "${TRANSPORT_PROVIDER}"
/usr/bin/grep -Fq 'bool quiet = true;' "${RAW_TRANSPORT}"
/usr/bin/grep -Fq 'getenv("EDP_MFMOUNT_QUIET")' "${RAW_TRANSPORT}"
/usr/bin/grep -Fq 'MFMount(channel, mountpoint, options, quiet)' "${RAW_TRANSPORT}"
/usr/bin/grep -Fq 'local,nobrowse,volname=%s' "${TRANSPORT_BUILD}" "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'RUNTIME_FRAMEWORKS="${MACFUSE_RUNTIME_FRAMEWORKS:-/Library/Filesystems/macfuse.fs/Contents/Frameworks}"' "${TRANSPORT_BUILD}"
/usr/bin/grep -Fq -- '-Xlinker -rpath -Xlinker "${RUNTIME_FRAMEWORKS}"' "${TRANSPORT_BUILD}"
echo 'RESULT=DRIVE_SYSTEM_TRANSPORT_BRIDGE_LOCAL_OK'

# A factory-clean host has no installed macFUSE framework. The clean installer
# must compile against the verified framework extracted from the signed DMG,
# never depend on /Library/Filesystems/macfuse.fs already being installed.
/usr/bin/grep -Fq 'MACFUSE_BUILD_FRAMEWORKS="${MACFUSE_BUILD_PAYLOAD}/Library/Filesystems/macfuse.fs/Contents/Frameworks"' "${CLEAN_INSTALLER_SOURCE}"
/usr/bin/grep -Fq 'RESULT=MACFUSE_BUILD_FRAMEWORK_EXTRACTED_FROM_SIGNED_DMG' "${CLEAN_INSTALLER_SOURCE}"
/usr/bin/grep -Fq 'MACFUSE_FRAMEWORKS="${MACFUSE_BUILD_FRAMEWORKS}"' "${CLEAN_INSTALLER_SOURCE}"
! /usr/bin/grep -Fq 'MACFUSE_FRAMEWORKS="/Library/Filesystems/macfuse.fs/Contents/Frameworks"' "${CLEAN_INSTALLER_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_FACTORY_CLEAN_INSTALLER_BUILD_OK'

# Physical release candidates must use the pinned certificate-backed wrapper,
# never the ad-hoc-capable lower-level clean builder. The release verifier has
# an explicit strict mode that rejects cdhash-only signatures and requires the
# proven installer-managed service mode for the self-signed distribution.
/usr/bin/grep -Fq 'UNIFIED_IDENTITY="EDP Project Code Signing"' "${SELF_SIGNED_INSTALLER_SOURCE}"
/usr/bin/grep -Fq 'EXPECTED_CERT_ROOT_SHA1="040b5488fb2b6c02b0786e76b674cb4460658ca2"' "${SELF_SIGNED_INSTALLER_SOURCE}"
/usr/bin/grep -Fq 'export EDP_SELF_SIGNED_DISTRIBUTION=1' "${SELF_SIGNED_INSTALLER_SOURCE}"
/usr/bin/grep -Fq 'export EDP_SERVICE_MODE=legacy' "${SELF_SIGNED_INSTALLER_SOURCE}"
/usr/bin/grep -Fq 'drive-release-installer:' "${MAKEFILE_SOURCE}"
/usr/bin/grep -Fq './installer/build-self-signed-installer.sh "$(ARTIFACTS)"' "${MAKEFILE_SOURCE}"
/usr/bin/grep -Fq 'EDP_REQUIRE_RELEASE_SIGNING=1' "${MAKEFILE_SOURCE}"
/usr/bin/grep -Fq 'EXPECTED_RELEASE_CERT_ROOT_SHA1="040b5488fb2b6c02b0786e76b674cb4460658ca2"' "${INSTALLER_VERIFY_SOURCE}"
/usr/bin/grep -Fq 'RESULT=STABLE_SELF_SIGNED_RELEASE_IDENTITY' "${INSTALLER_VERIFY_SOURCE}"
/usr/bin/grep -Fq 'RESULT=SELF_SIGNED_RELEASE_SERVICE_MODE_OK' "${INSTALLER_VERIFY_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_RELEASE_SIGNING_GATE_OK'

# The console launcher must allow both transport modes.  A missing read-only
# target breaks the boot FAT16 path while leaving encrypted partitions healthy,
# which is easy to miss in ordinary smoke testing.
/usr/bin/grep -Fq 'edp-mfmount-local-readwrite' "${ROOT}/Apps/Drive/product/EDPConsoleExec.c"
/usr/bin/grep -Fq 'edp-mfmount-local-readonly' "${ROOT}/Apps/Drive/product/EDPConsoleExec.c"
/usr/bin/grep -Fq '"/Library/Application Support/EDP Drive/bin/diskimages2-attach"' "${ROOT}/Apps/Drive/product/EDPConsoleExec.c"
[[ "$(/usr/bin/grep -Fc 'diskimages2-attach' "${ROOT}/Apps/Drive/product/EDPConsoleExec.c")" -eq 1 ]]
echo 'RESULT=DRIVE_SYSTEM_CONSOLE_TRANSPORT_ALLOWLIST_OK'
echo 'RESULT=DRIVE_SYSTEM_DISKIMAGES_HELPER_ALLOWLIST_OK'

# The Animation Hitches performance gate is compositor-sensitive and therefore
# release-authoritative only on the GitHub Actions runner. Local runs may still
# execute deterministic UI structure checks, but must skip xctrace performance.
/usr/bin/grep -Fq 'GITHUB_ACTIONS:-false' "${UI_RUNNER}"
/usr/bin/grep -Fq 'RESULT=DRIVE_UI_PERF_CI_ONLY_SKIPPED_LOCALLY' "${UI_RUNNER}"
/usr/bin/grep -Fq 'RESULT=DRIVE_UI_PERF_CI_ENVIRONMENT' "${UI_RUNNER}"
/usr/bin/grep -Fq 'UI_XCTRACE_RECORD_TIMEOUT_SECONDS=120' "${UI_RUNNER}"
/usr/bin/grep -Fq 'UI_XCTRACE_EXPORT_TIMEOUT_SECONDS=30' "${UI_RUNNER}"
[[ "$(/usr/bin/grep -Fc 'python3 "${UI_BOUNDED}" --timeout "${UI_XCTRACE_RECORD_TIMEOUT_SECONDS}"' "${UI_RUNNER}")" -eq 1 ]]
[[ "$(/usr/bin/grep -Fc 'python3 "${UI_BOUNDED}" --timeout "${UI_XCTRACE_EXPORT_TIMEOUT_SECONDS}"' "${UI_RUNNER}")" -eq 4 ]]
for marker in LIST RECORD TOC_EXPORT FRAME_EXPORT EVENT_EXPORT; do
  /usr/bin/grep -Fq "UI_XCTRACE_${marker}_BEGIN" "${UI_RUNNER}"
  /usr/bin/grep -Fq "UI_XCTRACE_${marker}_END" "${UI_RUNNER}"
done
/usr/bin/grep -Fq -- '--launch -- "${BIN}" --hitch-only' "${UI_RUNNER}"
/usr/bin/grep -Fq 'table[@schema="hitches-frame-lifetimes"]' "${UI_RUNNER}"
/usr/bin/grep -Fq 'table[@schema="hitches"]' "${UI_RUNNER}"
/usr/bin/grep -Fq 'UI_HITCH_SAMPLE_SOURCE=' "${ROOT}/Apps/Drive/Tests/UI/ParseAnimationHitches.py"
/usr/bin/grep -Fq 'source = "hitch-events"' "${ROOT}/Apps/Drive/Tests/UI/ParseAnimationHitches.py"
/usr/bin/grep -Fq 'THRESHOLD_NS = 33_000_000' "${ROOT}/Apps/Drive/Tests/UI/ParseAnimationHitches.py"
echo 'RESULT=DRIVE_SYSTEM_UI_PERF_CI_ONLY_OK'

# Identity and architecture invariants that must not regress during release
# hardening.
/usr/bin/grep -Fq 'EDP-PHYSICAL-ID-V3' "${ROOT}/Apps/Drive/native/EDPFSKitPoC/Extension/EDPVolumeMetadata.swift"
! /usr/bin/grep -Fq 'migrateDeviceID' "${RUNTIME_SOURCE}" \
  "${ROOT}/Apps/Drive/product/EDPDevicePolicyStore.swift" \
  "${ROOT}/Apps/Drive/product/EDPCredentialStore.swift"
/usr/bin/grep -Fq 'EDPNativeSplitViewController: NSSplitViewController' "${APP_SHELL_SOURCE}"
! /usr/bin/grep -Fq 'NavigationSplitView {' "${APP_SOURCE}" "${APP_SHELL_SOURCE}"
/usr/bin/grep -Fq 'struct EDPMainView: View' "${APP_SHELL_SOURCE}"
! /usr/bin/grep -Fq 'struct EDPMainView: View' "${APP_SOURCE}"
! /usr/bin/grep -Fq 'EDPNativeSplitViewController: NSSplitViewController' "${APP_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_UI_SHELL_SPLIT_OK'
/usr/bin/grep -Fq 'struct EDPOverviewView: View' "${APP_OVERVIEW_SOURCE}"
/usr/bin/grep -Fq 'struct EDPDevicesView: View' "${APP_DEVICES_SOURCE}"
/usr/bin/grep -Fq 'struct EDPDeviceDetailView: View' "${APP_DEVICES_SOURCE}"
/usr/bin/grep -Fq 'struct EDPActivityView: View' "${APP_ACTIVITY_SOURCE}"
/usr/bin/grep -Fq 'struct EDPSettingsView: View' "${APP_SETTINGS_SOURCE}"
/usr/bin/grep -Fq 'struct EDPMenuBarView: View' "${APP_MENU_BAR_SOURCE}"
! /usr/bin/grep -Fq 'struct EDPOverviewView: View' "${APP_SOURCE}"
! /usr/bin/grep -Fq 'struct EDPMenuBarView: View' "${APP_SOURCE}"
! /usr/bin/grep -Fq 'struct EDPDevicesView: View' "${APP_SOURCE}"
! /usr/bin/grep -Fq 'struct EDPDeviceDetailView: View' "${APP_SOURCE}"
! /usr/bin/grep -Fq 'struct EDPActivityView: View' "${APP_SOURCE}"
! /usr/bin/grep -Fq 'struct EDPSettingsView: View' "${APP_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_UI_PAGE_SPLIT_OK'
/usr/bin/grep -Fq 'edpMacFUSEInstallerPath' "${APP_SERVICE_SUPPORT_SOURCE}"
/usr/bin/grep -Fq 'func macFUSELocalRuntimeReady() -> Bool' "${APP_SERVICE_SUPPORT_SOURCE}"
! /usr/bin/grep -Fq 'func ensureMacFUSELocalEnablement() async throws -> Bool' "${APP_SERVICE_SUPPORT_SOURCE}" "${APP_SOURCE}" "${APP_VIEW_MODEL_SOURCE}"
! /usr/bin/grep -Fq '"install", "--components", "file-system-extensions"' "${APP_SERVICE_SUPPORT_SOURCE}" "${APP_VIEW_MODEL_SOURCE}"
/usr/bin/grep -Fq 'let edpDriveServicePath = edpDriveAppPath' "${APP_SERVICE_SUPPORT_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_UI_SERVICE_SUPPORT_SPLIT_OK'
/usr/bin/grep -Fq 'final class EDPVaultViewModel: ObservableObject' "${APP_VIEW_MODEL_SOURCE}"
! /usr/bin/grep -Fq 'final class EDPVaultViewModel: ObservableObject' "${APP_SOURCE}"
/usr/bin/grep -Fq 'final class EDPXPCSmokeResult: @unchecked Sendable' "${APP_SMOKE_SUPPORT_SOURCE}"
/usr/bin/grep -Fq 'enum EDPXPCPolicySmokeRunner' "${APP_SMOKE_SUPPORT_SOURCE}"
! /usr/bin/grep -Fq 'final class EDPXPCSmokeResult: @unchecked Sendable' "${APP_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_UI_VIEW_MODEL_SPLIT_OK'
/usr/bin/grep -Fq 'enum EDPMainSection: String, CaseIterable, Identifiable' "${APP_SIDEBAR_SOURCE}"
/usr/bin/grep -Fq 'struct EDPNativeSidebarView: View' "${APP_SIDEBAR_SOURCE}"
! /usr/bin/grep -Fq 'struct EDPNativeSidebarView: View' "${APP_SHELL_SOURCE}"
! /usr/bin/grep -Fq 'enum EDPMainSection: String, CaseIterable, Identifiable' "${APP_SHELL_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_UI_SIDEBAR_SPLIT_OK'
/usr/bin/grep -Fq '.menuBarExtraStyle(.window)' "${APP_SOURCE}"

# New-device policy is explicitly opt-in. Password probing and mounting are
# independent controls, and menu-bar users must be able to enter credentials
# without navigating into the main window.
/usr/bin/grep -Fq 'safePartitionDefaults()' "${POLICY_SOURCE}"
/usr/bin/grep -Fq 'autoMount: false' "${POLICY_SOURCE}"
/usr/bin/grep -Fq 'autoProbePassword: false' "${POLICY_SOURCE}"
/usr/bin/grep -Fq 'builtInDefaultProbePassword = Array("0000aaaa".utf8)' "${CREDENTIAL_SOURCE}"
/usr/bin/grep -Fq 'default-probe-password.v1' "${CREDENTIAL_SOURCE}"
/usr/bin/grep -Fq '点击钥匙设置密码' "${APP_MENU_BAR_SOURCE}"
! /usr/bin/grep -Fq '请先在主界面保存密码' "${APP_MENU_BAR_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_DEFAULT_POLICY_RATCHETS_OK'

# Full in-place upgrades must terminate the old foreground UI before replacing
# the signed App bundle. Otherwise that stale process correctly fails the XPC
# peer signature check against the newly installed bundle and cannot control the
# privileged service.
PREINSTALL_SOURCE="${ROOT}/Apps/Drive/installer/scripts/native-preinstall"
POSTINSTALL_SOURCE="${ROOT}/Apps/Drive/installer/scripts/native-postinstall"
CLEAN_INSTALLER_SOURCE="${ROOT}/Apps/Drive/installer/build-clean-installer.sh"
NATIVE_INSTALLER_SOURCE="${ROOT}/Apps/Drive/installer/build-native-installer.sh"
INSTALLER_PROBE_TEST_OUTPUT="$("${INSTALLER_MEDIA_PROBE_RUNNER}")"
echo "${INSTALLER_PROBE_TEST_OUTPUT}"
/usr/bin/grep -Fq 'RESULT=DRIVE_INSTALLER_MEDIA_PROBE_OK' <<<"${INSTALLER_PROBE_TEST_OUTPUT}"
/usr/bin/grep -Fq 'stop_running_drive_ui' "${PREINSTALL_SOURCE}"
/usr/bin/grep -Fq 'refuse_install_with_standard_edp_media' "${PREINSTALL_SOURCE}"
/usr/bin/grep -Fq 'INSTALLER_MEDIA_PROBE="${SCRIPT_DIR}/edp-installer-media-probe"' "${PREINSTALL_SOURCE}"
/usr/bin/grep -Fq 'exit(42)' "${ROOT}/Apps/Drive/installer/EDPInstallerMediaProbe.swift"
/usr/bin/grep -Fq 'SCENARIO=INSTALLER_MEDIA_PROBE_STANDARD_EDP_OK' <<<"${INSTALLER_PROBE_TEST_OUTPUT}"
/usr/bin/grep -Fq 'SCENARIO=INSTALLER_MEDIA_PROBE_ORDINARY_USB_OK' <<<"${INSTALLER_PROBE_TEST_OUTPUT}"
for installer_source in "${CLEAN_INSTALLER_SOURCE}" "${NATIVE_INSTALLER_SOURCE}"; do
  /usr/bin/grep -Fq 'edp-installer-media-probe' "${installer_source}"
  /usr/bin/grep -Fq 'com.edp.drive.installer-media-probe' "${installer_source}"
done
INSTALL_GUARD_LINE="$(/usr/bin/grep -nFx 'refuse_install_with_standard_edp_media' "${PREINSTALL_SOURCE}" | /usr/bin/cut -d: -f1)"
STOP_UI_LINE="$(/usr/bin/grep -nFx 'stop_running_drive_ui' "${PREINSTALL_SOURCE}" | /usr/bin/tail -1 | /usr/bin/cut -d: -f1)"
SERVICE_BOOTOUT_LINE="$(/usr/bin/grep -nF '/bin/launchctl bootout "system/${SERVICE_LABEL}"' "${PREINSTALL_SOURCE}" | /usr/bin/head -1 | /usr/bin/cut -d: -f1)"
[[ "${INSTALL_GUARD_LINE}" =~ ^[0-9]+$ && "${STOP_UI_LINE}" =~ ^[0-9]+$ && "${SERVICE_BOOTOUT_LINE}" =~ ^[0-9]+$ ]]
[[ "${INSTALL_GUARD_LINE}" -lt "${STOP_UI_LINE}" && "${STOP_UI_LINE}" -lt "${SERVICE_BOOTOUT_LINE}" ]]
/usr/bin/grep -Fq 'DRIVE_UI_EXECUTABLE="/Applications/EDP Drive.app/Contents/MacOS/EDP Drive"' "${PREINSTALL_SOURCE}"
/usr/bin/grep -Fq 'EDP Drive upgrade stopping the currently running foreground UI before bundle replacement.' "${PREINSTALL_SOURCE}"
/usr/bin/grep -Fq 'recover_edp_storage_test_diskimages2_orphans' "${PREINSTALL_SOURCE}"
/usr/bin/grep -Fq 'is_edp_storage_test_backing_path' "${PREINSTALL_SOURCE}"
/usr/bin/grep -Fq 'Refresh immediately before signalling so a recycled PID/backing tuple' "${PREINSTALL_SOURCE}"
/usr/bin/grep -Fq 'macfuse_scratch_pid_for_identity' "${PREINSTALL_SOURCE}"
/usr/bin/grep -Fq 'exact backing + device identity' "${PREINSTALL_SOURCE}"
/usr/bin/grep -Fq 'found macFUSE scratch ${device} with stale helper record' "${PREINSTALL_SOURCE}"
/usr/bin/grep -Fq 'A live, exact diskimages-helper scratch can be detached independently of' "${PREINSTALL_SOURCE}"
/usr/bin/grep -Fq 'The only operation that can disturb unrelated FSKit volumes is recycling' "${PREINSTALL_SOURCE}"
/usr/bin/grep -Fq 'Never act on the recorded PID by itself.' "${PREINSTALL_SOURCE}"
/usr/bin/grep -Fq 'recover_stale_console_fskit_agent' "${PREINSTALL_SOURCE}"
# Global FSKit mount refusal belongs only inside fskit_agent recovery. A live
# exact 4 KiB scratch helper must remain directly detachable even while an
# unrelated ExFAT/FSKit volume is mounted.
[[ "$(/usr/bin/grep -Fc "/sbin/mount | /usr/bin/grep -Fq 'fskit'" "${PREINSTALL_SOURCE}")" -eq 1 ]]
DIRECT_DETACH_LINE="$(/usr/bin/grep -nF '/usr/bin/hdiutil detach "${device}" -force' "${PREINSTALL_SOURCE}" | /usr/bin/cut -d: -f1)"
STALE_RECOVERY_LINE="$(/usr/bin/grep -nF 'if recover_stale_console_fskit_agent; then' "${PREINSTALL_SOURCE}" | /usr/bin/cut -d: -f1 | /usr/bin/tail -1)"
[[ "${DIRECT_DETACH_LINE}" =~ ^[0-9]+$ && "${STALE_RECOVERY_LINE}" =~ ^[0-9]+$ && "${DIRECT_DETACH_LINE}" -lt "${STALE_RECOVERY_LINE}" ]]
! /usr/bin/grep -Fq 'refused to recover macFUSE scratch while an FSKit filesystem is mounted' "${PREINSTALL_SOURCE}"
! /usr/bin/grep -Fq 'refreshed_pid="$(hdi_value "${info}" "${image_index}" hdid-pid)"' "${PREINSTALL_SOURCE}"
/usr/bin/grep -Fq 'run_bounded() {' "${PREINSTALL_SOURCE}"
/usr/bin/grep -Fq 'run_bounded 8 /usr/bin/hdiutil info -plist' "${PREINSTALL_SOURCE}"
/usr/bin/grep -Fq 'run_bounded 12 /usr/bin/hdiutil detach "${device}" -force' "${PREINSTALL_SOURCE}"
if /usr/bin/grep -Eq '^[[:space:]]*/usr/bin/hdiutil[[:space:]]' "${PREINSTALL_SOURCE}"; then
  echo 'unbounded hdiutil call in production preinstall' >&2
  exit 1
fi
echo 'RESULT=DRIVE_SYSTEM_INSTALLER_HDIUTIL_BOUNDED_OK'

# macFUSE's signed installer can reset the console user's FSKit enabledModules
# state. preinstall deliberately stops the old foreground App before bundle
# replacement, so postinstall must relaunch the new App in that same GUI user's
# bootstrap namespace. The App owns the TCC-safe user-domain enablement repair;
# the privileged installer must not edit the user's Group Container directly.
/usr/bin/grep -Fq 'DRIVE_UI_EXECUTABLE="${APP}/Contents/MacOS/EDP Drive"' "${POSTINSTALL_SOURCE}"
/usr/bin/grep -Fq 'relaunch_drive_ui_for_console_user()' "${POSTINSTALL_SOURCE}"
/usr/bin/grep -Fq 'console_uid="$(/usr/bin/stat -f '\''%u'\'' /dev/console 2>/dev/null || true)"' "${POSTINSTALL_SOURCE}"
/usr/bin/grep -Fq '/bin/launchctl asuser "${console_uid}" /usr/bin/open -g -a "${APP}"' "${POSTINSTALL_SOURCE}"
/usr/bin/grep -Fq 'drive_ui_running_for_uid "${console_uid}"' "${POSTINSTALL_SOURCE}"
/usr/bin/grep -Fq 'macFUSE package upgrades reset enabledModules.plist' "${POSTINSTALL_SOURCE}"
! /usr/bin/grep -Fq 'sudo ' "${POSTINSTALL_SOURCE}"
LAST_SERVICE_KICKSTART_LINE="$(/usr/bin/grep -nF '/bin/launchctl kickstart -k "system/${SERVICE_LABEL}"' "${POSTINSTALL_SOURCE}" | /usr/bin/tail -1 | /usr/bin/cut -d: -f1)"
RELAUNCH_CALL_LINE="$(/usr/bin/grep -nFx 'relaunch_drive_ui_for_console_user' "${POSTINSTALL_SOURCE}" | /usr/bin/tail -1 | /usr/bin/cut -d: -f1)"
[[ "${LAST_SERVICE_KICKSTART_LINE}" =~ ^[0-9]+$ && "${RELAUNCH_CALL_LINE}" =~ ^[0-9]+$ && "${LAST_SERVICE_KICKSTART_LINE}" -lt "${RELAUNCH_CALL_LINE}" ]]
echo 'RESULT=DRIVE_SYSTEM_INSTALLER_FOREGROUND_RELAUNCH_OK'
echo 'RESULT=DRIVE_SYSTEM_UPGRADE_UI_HANDOFF_OK'
echo 'RESULT=DRIVE_SYSTEM_INSTALLER_TEST_ORPHAN_REVALIDATION_OK'
echo 'RESULT=DRIVE_SYSTEM_INSTALLER_UNRELATED_FSKIT_MOUNT_OK'

# launchd defaults to a 10-second minimum runtime. The Drive daemon is explicitly
# user-stoppable and restartable, so both packaging modes must override that
# throttle without reintroducing KeepAlive/RunAtLoad semantics.
for plist in "${EMBEDDED_SERVICE_PLIST}" "${LEGACY_SERVICE_PLIST}"; do
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :ThrottleInterval' "${plist}")" == "1" ]]
  ! /usr/libexec/PlistBuddy -c 'Print :KeepAlive' "${plist}" >/dev/null 2>&1
  ! /usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "${plist}" >/dev/null 2>&1
done
echo 'RESULT=DRIVE_SYSTEM_SERVICE_RESTART_THROTTLE_OK'

# Installed service-cycle timing must be measured inside one monotonic clock
# process and must reject material progressive startup slowdown. Never regress
# to subtracting samples from separate helper processes, which can yield
# impossible negative durations on some hosts.
ACCEPTANCE_SOURCE="${ROOT}/Apps/Drive/scripts/first-install-acceptance.sh"
/usr/bin/grep -Fq 'completed = subprocess.run([sys.argv[1], "--xpc-health"]' "${ACCEPTANCE_SOURCE}"
/usr/bin/grep -Fq 'SERVICE_CYCLE_TREND=PASS' "${ACCEPTANCE_SOURCE}"
/usr/bin/grep -Fq 'steady = values[1:]' "${ACCEPTANCE_SOURCE}"
/usr/bin/grep -Fq 'WARMUP_MS={values[0]}' "${ACCEPTANCE_SOURCE}"
! /usr/bin/grep -Fq "start_ns=\"\$(/usr/bin/python3 -c 'import time; print(time.monotonic_ns())')\"" "${ACCEPTANCE_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_SERVICE_CYCLE_TIMING_OK'

# Real-device acceptance must follow the installed product's filesystem
# capabilities. Boot and Apple-native read-only NTFS volumes must never receive
# a marker write merely to satisfy an obsolete all-RW acceptance assumption.
/usr/bin/grep -Fq 'partition_snapshot_line()' "${ACCEPTANCE_SOURCE}"
/usr/bin/grep -Fq 'if [[ "${type}" == "1" && "${read_only}" != "true" ]]' "${ACCEPTANCE_SOURCE}"
/usr/bin/grep -Fq 'RESULT=PARTITION_${type}_READONLY_REMOUNT_OK' "${ACCEPTANCE_SOURCE}"
/usr/bin/grep -Fq 'RESULT=ALL_THREE_PARTITIONS_CAPABILITY_PERSISTENCE_OK' "${ACCEPTANCE_SOURCE}"
! /usr/bin/grep -Fq 'mountpoint_for_type()' "${ACCEPTANCE_SOURCE}"
! /usr/bin/grep -Fq 'RESULT=ALL_THREE_PARTITIONS_RW_PERSISTENCE_OK' "${ACCEPTANCE_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_REAL_DEVICE_CAPABILITY_ACCEPTANCE_OK'

# DiskImages2 teardown identity must be proven from the bounded hdiutil owner
# snapshot only. Never stat the macFUSE backing path or synthetic /dev/diskN
# from parsePublication(): either can be in a transient FSKit/LIFS generation
# and turn the privileged service itself into an uninterruptible waiter.
PUBLISH_PARSE_SECTION="$(/usr/bin/awk '
  /private func parsePublication\(/ { capture=1 }
  /private func isEDPTransportBackingPath\(/ { capture=0 }
  capture { print }
' "${PUBLISHER_SOURCE}")"
/usr/bin/printf '%s\n' "${PUBLISH_PARSE_SECTION}" | /usr/bin/grep -Fq 'Self.isSyntheticBSDDevicePath'
! /usr/bin/printf '%s\n' "${PUBLISH_PARSE_SECTION}" | /usr/bin/grep -Fq 'stat(expected'
! /usr/bin/printf '%s\n' "${PUBLISH_PARSE_SECTION}" | /usr/bin/grep -Fq 'return stat(path'
/usr/bin/grep -Fq 'isStableDeadOwnerOnlyRetirement' "${PUBLISHER_SOURCE}"
/usr/bin/grep -Fq 'original.devicePaths.isEmpty' "${PUBLISHER_SOURCE}"
/usr/bin/grep -Fq 'revalidated == original' "${PUBLISHER_SOURCE}"
/usr/bin/grep -Fq 'revalidatedOwnerExecutablePath == nil' "${PUBLISHER_SOURCE}"
/usr/bin/grep -Fq 'confirmDeadOwnerOnlyRetirementAsync' "${PUBLISHER_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_PUBLICATION_METADATA_ONLY_TEARDOWN_OK'

# The storage regression harness must obey the same teardown rule as product
# code. Comparing DiskImages2 image-path values is lexical/metadata-only; never
# resolve the macFUSE volume.raw path or stat a transient synthetic /dev/diskN.
/usr/bin/grep -Fq 'Teardown is metadata-only.' "${STORAGE_RUNNER}"
! /usr/bin/grep -Fq 'os.path.realpath(' "${STORAGE_RUNNER}"
! /usr/bin/grep -Eq '\[\[[^]]*(-e|! -e)[[:space:]]+"/dev/\$bsd"' "${STORAGE_RUNNER}"
echo 'RESULT=DRIVE_SYSTEM_STORAGE_METADATA_ONLY_TEARDOWN_OK'
/usr/bin/grep -Fq 'STORAGE_LAST_PUBLICATION_RECOVERY_MODE="stable-dead-owner"' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'STORAGE_ADAPTER_DEAD_OWNER_RECOVERY_BEGIN=' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'adapter-dead-owner-kill-' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'cleanup_crashed_local_mount "$bridge"' "${STORAGE_RUNNER}"
echo 'RESULT=DRIVE_SYSTEM_STORAGE_DEAD_OWNER_ADAPTER_RECOVERY_OK'

# Mount/unmount/eject/shutdown lifecycle is intentionally single-path and
# asynchronous. Never reintroduce polling sleeps or synchronous manager
# fallbacks into the production daemon; regression-only wait adapters stay
# isolated behind EDP_REGRESSION_TESTS.
TRANSPORT_SOURCE="${ROOT}/Apps/Drive/product/EDPTransportProvider.swift"
! /usr/bin/grep -Fq 'private func waitUntil(' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'usleep(' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'com.edp.drive.transport-stop-sync' "${TRANSPORT_SOURCE}"
! /usr/bin/grep -Fq 'func stop(' "${TRANSPORT_SOURCE}"
/usr/bin/grep -Fq 'transport process already exited while VFS mount remains active' "${TRANSPORT_SOURCE}"
/usr/bin/grep -Fq 'transport exited while user filesystem remains mounted; refusing synchronous VFS unmount' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'transportUnavailableWithMountedFilesystem' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'manager.mount(' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'manager.unmount(' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'manager.eject(' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'manager.unmountAll(' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'private final class EDPMountCoordinator: EDPDaemonMountManaging' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'private final class MountManager' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'func mountAsync(' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'func unmountAsync(' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'func ejectAsync(' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'func unmountAllAsync(' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'func shutdownGracefullyAsync(' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq '#if EDP_REGRESSION_TESTS' "${RUNTIME_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_ASYNC_LIFECYCLE_RATCHET_OK'

# Disk Arbitration is a callback-driven subsystem. Production code must not
# turn DA callbacks back into synchronous waits, and all runtime callers must
# consume the async API. Regression-only adapters may wait behind the test flag.
/usr/bin/grep -Fq 'func unmountWholeAsync(' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'func unmountAsync(' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'func mountAsync(' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'func mountNobrowseAsync(' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'func mountReadOnlyAsync(' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'let readOnly = "rdonly" as CFString' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'diskArbitration.mountReadOnlyAsync(bsd, at: mountpoint)' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'DA_MOUNT_BIN="$BUILD_DIR/edp-da-mount"' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq '"$DA_MOUNT_BIN" --mount-readonly-at "$bsd" "$mountpoint"' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq '"$DA_MOUNT_BIN" --mount "$bsd"' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq '"$DA_MOUNT_BIN" --unmount "$bsd"' "${STORAGE_RUNNER}"
! /usr/bin/grep -Eq '/usr/sbin/diskutil[[:space:]]+mount([[:space:]]|$)' "${STORAGE_RUNNER}"
! /usr/bin/grep -Eq '^[[:space:]]*bounded .* /sbin/umount' "${STORAGE_RUNNER}"
! /usr/bin/grep -Fq 'executable: "/sbin/mount_msdos"' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Eq '^[[:space:]]*bounded .* /sbin/mount_msdos' "${STORAGE_RUNNER}"
echo 'RESULT=DRIVE_SYSTEM_FAT16_FSKIT_READONLY_OK'
echo 'RESULT=DRIVE_SYSTEM_STORAGE_DIRECT_DA_MOUNT_OK'
/usr/bin/grep -Fq 'func ejectAsync(' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'EDPDiskArbitrationCompletionGate' "${NATIVE_SYSTEM_SOURCE}"
! /usr/bin/grep -Fq 'box.semaphore.wait' "${NATIVE_SYSTEM_SOURCE}"
! /usr/bin/grep -Fq 'diskArbitration.unmountWhole(' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'diskArbitration.eject(' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'diskArbitration.mount(' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'diskArbitration.mountNobrowse(' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'func unpublish(' "${ROOT}/Apps/Drive/product/EDPBlockDevicePublisher.swift"
/usr/bin/grep -Fq 'func unpublishAsync(' "${ROOT}/Apps/Drive/product/EDPBlockDevicePublisher.swift"
echo 'RESULT=DRIVE_SYSTEM_ASYNC_DISK_ARBITRATION_OK'

# Physical USB DA operations are authorized by the exact IOMedia generation,
# never by a reusable diskN alone. A generation that disappears while safe
# eject is tearing down synthetic publications is an idempotent success; a
# live generation DA failure remains fail-closed. Duplicate eject joins the
# existing single-flight request, and graceful shutdown waits for eject terminal.
/usr/bin/grep -Fq 'DADiskCopyIOMedia(disk)' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'actualRegistryEntryID == expectedRegistryEntryID' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'expectedRegistryEntryID: disk.registryEntryID' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'final class EDPEjectCoordinator' "${EJECT_COORDINATOR_SOURCE}"
/usr/bin/grep -Fq 'mediaProvider.registryEntryExists(disk.usbRegistryEntryID)' "${EJECT_COORDINATOR_SOURCE}"
/usr/bin/grep -Fq 'private var completionWaiters = [String: [EDPDaemonMountCompletion]]()' "${EJECT_COORDINATOR_SOURCE}"
/usr/bin/grep -Fq 'expectedRegistryEntryID: disk.registryEntryID' "${EJECT_COORDINATOR_SOURCE}"
/usr/bin/grep -Fq 'eject.performPhysicalEjectAsync(disk: disk)' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'beginShutdownTeardownIfReadyLocked()' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'private var ejectCompletionWaiters' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'private var ejectingUSBRegistryIDs' "${RUNTIME_SOURCE}"
for marker in \
  'SCENARIO=S24_OK physical_disappears_during_teardown_is_idempotent_success' \
  'SCENARIO=S25_OK diskn_reuse_never_ejects_replacement_generation' \
  'SCENARIO=S26_OK live_generation_da_error_remains_failure' \
  'SCENARIO=S27_OK late_da_error_after_generation_removal_is_success' \
  'SCENARIO=S28_OK duplicate_eject_single_flight_fanout' \
  'SCENARIO=S29_OK shutdown_waits_for_inflight_eject' \
  'SCENARIO=S30_OK duplicate_eject_failure_fanout'; do
  /usr/bin/grep -Fq "${marker}" "${ROOT}/Apps/Drive/Tests/VirtualUSB/ValidateCredentialPolicyServiceLifecycle.swift"
done
echo 'RESULT=DRIVE_SYSTEM_PHYSICAL_EJECT_GENERATION_RATCHET_OK'

# DiskImages2 publication teardown is event-driven on exact synthetic IOMedia
# generations. hdiutil is allowed only as a one-shot abnormal recovery inspector;
# neither normal teardown nor owner recovery may poll it on a timer. Recovery
# also binds diskimagesiod to PID + process start time before TERM/KILL so PID
# reuse can never become a signal target.
! /usr/bin/grep -Fq 'Thread.sleep' "${PUBLISHER_SOURCE}"
! /usr/bin/grep -Fq 'waitUntilExit()' "${PUBLISHER_SOURCE}"
! /usr/bin/grep -Fq 'waitForPublicationToDisappearAsync' "${PUBLISHER_SOURCE}"
! /usr/bin/grep -Fq '@Sendable func poll()' "${PUBLISHER_SOURCE}"
! /usr/bin/grep -Fq 'func publishWritableImage(' "${PUBLISHER_SOURCE}"
/usr/bin/grep -Fq 'func publishWritableImageAsync(' "${PUBLISHER_SOURCE}"
/usr/bin/grep -Fq 'private final class EDPPublicationTerminationOperation' "${PUBLISHER_SOURCE}"
/usr/bin/grep -Fq 'private struct EDPProcessGeneration' "${PUBLISHER_SOURCE}"
/usr/bin/grep -Fq 'info.pbi_start_tvsec' "${PUBLISHER_SOURCE}"
/usr/bin/grep -Fq 'DispatchSource.makeProcessSource' "${PUBLISHER_SOURCE}"
/usr/bin/grep -Fq 'private final class EDPExactResourceTerminationWaiter' "${PUBLISHER_SOURCE}"
/usr/bin/grep -Fq 'registryEntryID: generation.registryEntryID' "${PUBLISHER_SOURCE}"
/usr/bin/grep -Fq 'EDPIOMediaTerminationMonitor' "${PUBLISHER_SOURCE}"
/usr/bin/grep -Fq 'EDPIOKitMediaLifecycle.registryEntryExists' "${PUBLISHER_SOURCE}"
/usr/bin/grep -Fq 'func cleanupNewOrphansAsync(' "${PUBLISHER_SOURCE}"
/usr/bin/grep -Fq 'func cleanupOrphanAsync(' "${PUBLISHER_SOURCE}"
/usr/bin/grep -Fq 'runBoundedProcessAsync(' "${PUBLISHER_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_EVENT_DRIVEN_BLOCK_PUBLISHER_OK'

# Generation handoff must be based on actual teardown events, never a fixed
# remount delay. Native filesystem DA completion, exact DiskImages2 IOMedia
# termination, exact hidden-source IOMedia termination and transport child exit
# together define terminal teardown. A completed teardown can remount
# immediately; time does not participate in generation ownership.
! /usr/bin/grep -Fq 'EDPRemountQuiescenceGate' "${SCHEDULER_SOURCE}"
! /usr/bin/grep -Fq 'remountQuiescenceSeconds' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'remountQuiescenceWait' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'remountQuiescenceStarted' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'remountQuiescenceComplete' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'event: "nativeFilesystemDAUnmountStarted"' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'diskArbitration.unmountAsync(session.exposedBSD)' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'event: "nativeFilesystemDAUnmountComplete"' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'continueUnmountAfterNativeFilesystemDeactivation' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'requireSourceTermination: true' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'exposedRegistryEntryID' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'func observeExit(on queue:' "${TRANSPORT_SOURCE}"
/usr/bin/grep -Fq 'operation.journalContext.id.uuidString.lowercased().prefix(8)' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'RESULT=TRANSPORT_EVENT_DRIVEN_GENERATION_TEARDOWN_OK' \
  "${ROOT}/Apps/Drive/native/EDPFSKitPoC/Tools/ValidateTransportLifecycle.swift"
echo 'RESULT=DRIVE_SYSTEM_EVENT_DRIVEN_GENERATION_HANDOFF_OK'

# User-visible success paths are event-driven end to end. MFMount readiness is
# delivered through an inherited READY pipe, mount cancellation drains through
# terminal observers, whole-USB DA events reconcile immediately, and graceful
# process exit is released only after the client ACKs receipt of the reply.
! /usr/bin/grep -Fq 'pollBridgeActivation' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'scheduler.schedule(on: lifecycleQueue, after: 0.1)' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'func observeReady(on queue:' "${TRANSPORT_SOURCE}"
/usr/bin/grep -Fq 'EDP_MFMOUNT_READY_FD' "${MOUNT_SUPPORT_SOURCE}"
/usr/bin/grep -Fq 'void EDPDirectMFMountSignalReady(void)' "${RAW_TRANSPORT}"
MOUNT_WORKER_SECTION="$(/usr/bin/awk '/static void \*mount_worker\(/,/MFMountResult EDPAsyncMFMount\(/' "${ASYNC_SHIM}")"
/usr/bin/grep -Fq 'only the real framework MFMount completion here is authoritative' <<<"${MOUNT_WORKER_SECTION}"
/usr/bin/grep -Fq 'EDPDirectMFMountSignalReady();' <<<"${MOUNT_WORKER_SECTION}"
[[ "$(/usr/bin/grep -Fc 'EDPDirectMFMountSignalReady();' "${ASYNC_SHIM}")" -eq 1 ]]
! /usr/bin/grep -Fq 'EDPDirectMFMountSignalReady();' "${RAW_TRANSPORT}"
/usr/bin/grep -Fq 'export EDP_MFMOUNT_READY_FD=9' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'macFUSE Local READY arrived before volume.raw became usable' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'terminalObservers.append' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq '.milliseconds(250)' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'fileprivate func handleDiskEvent()' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'onChange?()' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'func acknowledgeGracefulShutdownReply()' "${XPC_PROTOCOL_SOURCE}"
/usr/bin/grep -Fq 'acknowledgementProxy.acknowledgeGracefulShutdownReply()' "${APP_VIEW_MODEL_SOURCE}"
/usr/bin/grep -Fq 'proxy.acknowledgeGracefulShutdownReply()' "${APP_SOURCE}"
! /usr/bin/grep -Fq '.milliseconds(100)' "${SERVICE_MAIN_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_ZERO_FIXED_WAIT_SUCCESS_PATH_OK'

# Generic runtime utilities live outside the orchestration file so controller
# responsibilities do not grow back through local process/error/file helpers.
/usr/bin/grep -Fq 'enum RuntimeError' "${RUNTIME_SUPPORT_SOURCE}"
/usr/bin/grep -Fq 'func atomicWrite(' "${RUNTIME_SUPPORT_SOURCE}"
! /usr/bin/grep -Fq 'private enum RuntimeError' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'private func atomicWrite(' "${RUNTIME_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_RUNTIME_SUPPORT_SPLIT_OK'

# Persistent runtime paths and legacy-state migration are infrastructure, not
# daemon orchestration. Keep their ownership in the dedicated runtime-state unit.
/usr/bin/grep -Fq 'let dataRoot = "/var/db/com.edp.drive"' "${RUNTIME_STATE_SOURCE}"
/usr/bin/grep -Fq 'func migrateLegacyRuntimeState() throws' "${RUNTIME_STATE_SOURCE}"
/usr/bin/grep -Fq 'func makeCredentialStore() throws' "${RUNTIME_STATE_SOURCE}"
! /usr/bin/grep -Fq 'private let dataRoot' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'private func migrateLegacyRuntimeState()' "${RUNTIME_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_RUNTIME_STATE_SPLIT_OK'

# Transport spawn/session/mount-operation support belongs outside the daemon
# orchestration file; keep raw-fd inheritance and mount-operation ownership in
# the dedicated mount-support unit.
/usr/bin/grep -Fq 'final class EDPSpawnedProcess' "${MOUNT_SUPPORT_SOURCE}"
/usr/bin/grep -Fq 'func spawnConsoleTransport(' "${MOUNT_SUPPORT_SOURCE}"
/usr/bin/grep -Fq 'F_DUPFD_CLOEXEC' "${MOUNT_SUPPORT_SOURCE}"
/usr/bin/grep -Fq 'final class MountSession' "${MOUNT_SUPPORT_SOURCE}"
/usr/bin/grep -Fq 'final class EDPFSKitMountOperationBox' "${MOUNT_SUPPORT_SOURCE}"
! /usr/bin/grep -Fq 'private final class EDPSpawnedProcess' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'private final class MountSession' "${RUNTIME_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_MOUNT_SUPPORT_SPLIT_OK'

# Device discovery, filesystem probing, credential verification, and CLI
# authorization are reusable device operations, not daemon orchestration.
/usr/bin/grep -Fq 'func discoverEDPDisks(' "${DEVICE_OPERATIONS_SOURCE}"
/usr/bin/grep -Fq 'func filesystemMagic(' "${DEVICE_OPERATIONS_SOURCE}"
/usr/bin/grep -Fq 'func verifyPartitionType(' "${DEVICE_OPERATIONS_SOURCE}"
/usr/bin/grep -Fq 'func authorize(' "${DEVICE_OPERATIONS_SOURCE}"
! /usr/bin/grep -Fq 'private func filesystemMagic(' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'private func verifyPartitionType(' "${RUNTIME_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_DEVICE_OPERATIONS_SPLIT_OK'

# Discovery scan execution and scan diagnostics/count/timestamp belong to the
# dedicated discovery controller. The daemon controller retains only the current
# connected-device business snapshot.
/usr/bin/grep -Fq 'final class EDPDeviceDiscoveryController' "${DEVICE_DISCOVERY_CONTROLLER_SOURCE}"
/usr/bin/grep -Fq 'func scan() throws -> [PhysicalDisk]' "${DEVICE_DISCOVERY_CONTROLLER_SOURCE}"
/usr/bin/grep -Fq 'private(set) var scanCount: UInt64 = 0' "${DEVICE_DISCOVERY_CONTROLLER_SOURCE}"
/usr/bin/grep -Fq 'diagnostics = ["discovery_error:' "${DEVICE_DISCOVERY_CONTROLLER_SOURCE}"
/usr/bin/grep -Fq 'let disks = try discovery.scan()' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'private var lastDiscoveryDiagnostics' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'private var discoveryScanCount' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'private let metadataReader' "${RUNTIME_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_DEVICE_DISCOVERY_CONTROLLER_SPLIT_OK'

# Raw primitives and raw lifecycle orchestration both live outside the daemon
# controller. The coordinator owns retained leases, single-flight waiters,
# readiness/error state, raw worker scheduling, and the one-shot exact-generation
# EBUSY recovery; controller code only supplies its current generation predicate.
/usr/bin/grep -Fq 'final class EDPRawAccessLease' "${RAW_ACCESS_SOURCE}"
/usr/bin/grep -Fq 'func openPersistentRawAccess(' "${RAW_ACCESS_SOURCE}"
/usr/bin/grep -Fq 'struct EDPPrivilegedRawMetadataReader' "${RAW_ACCESS_SOURCE}"
/usr/bin/grep -Fq 'EDPPhysicalDeviceRevalidation.metadataStillMatches' "${RAW_ACCESS_SOURCE}"
/usr/bin/grep -Fq 'final class EDPRawAccessCoordinator' "${RAW_ACCESS_COORDINATOR_SOURCE}"
/usr/bin/grep -Fq 'private var leases = [String: EDPRawAccessLease]()' "${RAW_ACCESS_COORDINATOR_SOURCE}"
/usr/bin/grep -Fq 'private var probeWaiters = [String: [EDPRawAccessLeaseCompletion]]()' "${RAW_ACCESS_COORDINATOR_SOURCE}"
/usr/bin/grep -Fq 'func requireLeaseAsync(' "${RAW_ACCESS_COORDINATOR_SOURCE}"
! /usr/bin/grep -Fq 'final class EDPRawAccessLease' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'rawAccessLeases' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'rawAccessProbeWaiters' "${RUNTIME_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_RAW_ACCESS_SPLIT_OK'

# Insertion-scoped auto-mount failure memory and manual/default-probe
# suppressions are a single owner-queue-confined state object, not four mutable
# dictionaries spread across the daemon controller.
/usr/bin/grep -Fq 'final class EDPAutomationState' "${AUTOMATION_STATE_SOURCE}"
/usr/bin/grep -Fq 'func recordFailure(' "${AUTOMATION_STATE_SOURCE}"
/usr/bin/grep -Fq 'func suppressManualRemount(' "${AUTOMATION_STATE_SOURCE}"
/usr/bin/grep -Fq 'func suppressDefaultProbe(' "${AUTOMATION_STATE_SOURCE}"
/usr/bin/grep -Fq 'func prune(connectedDeviceIDs:' "${AUTOMATION_STATE_SOURCE}"
! /usr/bin/grep -Fq 'private var failedMounts =' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'private var failedMountCodes =' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'private var manualUnmountSuppressions =' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'private var defaultProbeSuppressions =' "${RUNTIME_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_AUTOMATION_STATE_SPLIT_OK'

# Activity retention is a bounded owner-queue ring buffer, not another mutable
# collection embedded in the daemon controller.
/usr/bin/grep -Fq 'final class EDPActivityStore' "${ACTIVITY_STORE_SOURCE}"
/usr/bin/grep -Fq 'private var activities = [EDPXPCActivity]()' "${ACTIVITY_STORE_SOURCE}"
/usr/bin/grep -Fq 'activities.removeLast(activities.count - capacity)' "${ACTIVITY_STORE_SOURCE}"
! /usr/bin/grep -Fq 'private var activities = [EDPXPCActivity]()' "${RUNTIME_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_ACTIVITY_STORE_SPLIT_OK'

# Startup-recovery and shutdown single-flight state belong to one owner-queue
# lifecycle state object. The controller owns actual teardown actions only.
/usr/bin/grep -Fq 'final class EDPServiceLifecycleState' "${SERVICE_LIFECYCLE_STATE_SOURCE}"
/usr/bin/grep -Fq 'func completeStartupRecovery(errorMessage:' "${SERVICE_LIFECYCLE_STATE_SOURCE}"
/usr/bin/grep -Fq 'func beginShutdown(completion:' "${SERVICE_LIFECYCLE_STATE_SOURCE}"
/usr/bin/grep -Fq 'func beginTeardownIfReady(hasActiveEjects:' "${SERVICE_LIFECYCLE_STATE_SOURCE}"
/usr/bin/grep -Fq 'func finishShutdown()' "${SERVICE_LIFECYCLE_STATE_SOURCE}"
! /usr/bin/grep -Fq 'private var shutdownCompletions' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'private var shutdownInProgress' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'private var shutdownTeardownStarted' "${RUNTIME_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_SERVICE_LIFECYCLE_STATE_SPLIT_OK'

# Failed-eject recovery is a separate orchestration boundary: it releases eject
# suppression, revalidates the original whole-USB generation, reacquires raw
# access once, restores boot policy, and then reports the original failure.
/usr/bin/grep -Fq 'final class EDPRecoveryCoordinator' "${RECOVERY_COORDINATOR_SOURCE}"
/usr/bin/grep -Fq 'func recoverFailedEject(' "${RECOVERY_COORDINATOR_SOURCE}"
/usr/bin/grep -Fq 'wholeUSBMediaStillMatches(' "${RECOVERY_COORDINATOR_SOURCE}"
/usr/bin/grep -Fq 'ejectCoordinator.releaseActive(deviceID:' "${RECOVERY_COORDINATOR_SOURCE}"
/usr/bin/grep -Fq 'recovery.recoverFailedEject(' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'wholeUSBMediaStillMatches(disk, mediaProvider: mediaProvider)' "${RUNTIME_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_RECOVERY_COORDINATOR_SPLIT_OK'

# The top-level owner-queue orchestration type is the service controller. It
# coordinates already-extracted discovery/raw/automation/eject/recovery state
# and must not drift back to the old catch-all daemon-controller identity.
/usr/bin/grep -Fq 'final class EDPServiceController' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'final class EDPDaemonController' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'let controller = try EDPServiceController()' "${SERVICE_MAIN_SOURCE}"
/usr/bin/grep -Fq 'private let controller: EDPServiceController' "${XPC_SERVICE_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_SERVICE_CONTROLLER_BOUNDARY_OK'

# XPC protocol adaptation and reply fanout belong in the service adapter, not
# in the daemon orchestration file. Regression tests instantiate this adapter
# directly, so keep it in every native/service compile source list.
/usr/bin/grep -Fq 'final class EDPXPCService' "${XPC_SERVICE_SOURCE}"
/usr/bin/grep -Fq 'private final class EDPSendableStringReply' "${XPC_SERVICE_SOURCE}"
/usr/bin/grep -Fq 'controller.shutdownGracefullyAsync' "${XPC_SERVICE_SOURCE}"
! /usr/bin/grep -Fq 'final class EDPXPCService' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'EDPSendableStringReply' "${RUNTIME_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_XPC_SERVICE_SPLIT_OK'

# Daemon listener wiring, doctor/CLI commands, and the service @main entrypoint
# are process bootstrap concerns, not mount/runtime orchestration.
/usr/bin/grep -Fq 'private func daemon() throws -> Never' "${SERVICE_MAIN_SOURCE}"
/usr/bin/grep -Fq 'private func doctor() -> Int32' "${SERVICE_MAIN_SOURCE}"
/usr/bin/grep -Fq 'private enum EDPVaultMain' "${SERVICE_MAIN_SOURCE}"
! /usr/bin/grep -Fq 'private func daemon() throws -> Never' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'private enum EDPVaultMain' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'recoverPersistedMountSessionsForServiceCleanup' "${SERVICE_MAIN_SOURCE}"
/usr/bin/grep -Fq 'func recoverPersistedMountSessionsForServiceCleanup(' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'MountManager()' "${SERVICE_MAIN_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_SERVICE_MAIN_SPLIT_OK'

# Lifecycle recovery decisions use typed failure categories. Stable helper/log
# strings may be parsed once at their adapter boundary, but controller/recovery
# policy code must never branch on user-facing error text.
/usr/bin/grep -Fq 'enum EDPLifecycleFailureCode' "${MOUNT_LIFECYCLE_SOURCE}"
/usr/bin/grep -Fq 'recognizedRawAccessFailure' "${MOUNT_LIFECYCLE_SOURCE}"
/usr/bin/grep -Fq 'struct EDPFSKitMountLifecycleMachine' "${MOUNT_LIFECYCLE_SOURCE}"
/usr/bin/grep -Fq 'enum EDPFSKitHostRecovery' "${MOUNT_LIFECYCLE_SOURCE}"
/usr/bin/grep -Fq 'restartConsoleAgentIfSafeAsync(' "${MOUNT_LIFECYCLE_SOURCE}"
/usr/bin/grep -Fq 'process.terminationHandler' "${MOUNT_LIFECYCLE_SOURCE}"
! /usr/bin/grep -Fq 'EDPNativeBoundedProcess.run' "${MOUNT_LIFECYCLE_SOURCE}"
! /usr/bin/grep -Fq 'enum EDPLifecycleFailureCode' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'enum EDPFSKitHostRecovery' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'func lastFailureCode(deviceID:' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'automation.failureCode(for: partitionKey) == .bridgeExtensionUnavailable' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'failure.contains("File system extension' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'errorMessage.contains("EDP_RAW_' "${RUNTIME_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_TYPED_LIFECYCLE_ERRORS_OK'

# Raw validation must preserve the true open(2) errno and use separate stable
# codes for target/path/generation/metadata revalidation. Otherwise a metadata
# or IOKit mismatch is indistinguishable from FDA EPERM and the UI gives the
# user a false privacy-permission diagnosis.
/usr/bin/grep -Fq 'EDP_RAW_VALIDATION_TARGET = 1001' "${RAW_VALIDATION_HEADER}"
/usr/bin/grep -Fq 'EDP_RAW_VALIDATION_METADATA = 1007' "${RAW_VALIDATION_HEADER}"
/usr/bin/grep -Fq 'edp_open_validated_raw_device_diagnostic' "${RAW_VALIDATION_SOURCE}" "${RAW_BROKER_SOURCE}"
/usr/bin/grep -Fq 'out_error_code = errno != 0 ? errno : EIO' "${RAW_VALIDATION_SOURCE}"
/usr/bin/grep -Fq 'EDP_RAW_BROKER_VALIDATION_FAILED code=%d errno=%d' "${RAW_BROKER_SOURCE}"
/usr/bin/grep -Fq 'EDP_RAW_LEASE_OPEN_FAILED:1007' "${ROOT}/Apps/Drive/Tests/VirtualUSB/ValidateCredentialPolicyServiceLifecycle.swift"
echo 'RESULT=DRIVE_SYSTEM_RAW_VALIDATION_DIAGNOSTICS_OK'

# A failed macOS filesystem probe can leave an otherwise-unmounted physical EDP
# whole media busy for O_RDWR. Recovery is exact-generation, EBUSY-only, bounded
# to one forced whole-disk unmount plus one raw-open retry, and never applies to
# EPERM/metadata failures or a replacement disk reusing the BSD name.
/usr/bin/grep -Fq 'func forceUnmountWholeAsync(' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'kDADiskUnmountOptionWhole | kDADiskUnmountOptionForce' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'EDPLifecycleFailure.isRawAccessBusy(failure)' "${RAW_ACCESS_COORDINATOR_SOURCE}"
/usr/bin/grep -Fq 'allowBusyRecovery: false' "${RAW_ACCESS_COORDINATOR_SOURCE}"
/usr/bin/grep -Fq 'expectedRegistryEntryID: disk.registryEntryID' "${RAW_ACCESS_COORDINATOR_SOURCE}"
/usr/bin/grep -Fq 'rawAccessGenerationMatchesLocked(candidate)' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'case rawAccessBusy' "${MOUNT_LIFECYCLE_SOURCE}"
/usr/bin/grep -Fq 'rawAccess.shouldAutoProbe(disk)' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'registryGenerationByDeviceID' "${RAW_ACCESS_COORDINATOR_SOURCE}"
/usr/bin/grep -Fq 'case .rawAccessBusy:' "${RAW_ACCESS_SOURCE}"
for scenario in S31 S32 S33 S34 S35 S44; do
  /usr/bin/grep -Fq "SCENARIO=${scenario}_OK" "${ROOT}/Apps/Drive/Tests/VirtualUSB/ValidateCredentialPolicyServiceLifecycle.swift"
done
echo 'RESULT=DRIVE_SYSTEM_RAW_EBUSY_RECOVERY_OK'

# A successful safe eject must remain logically suppressed while the exact
# persisted USB registry generation is still physically present. Discovery is
# not authoritative for retirement: transient metadata omission and a concurrent
# replacement generation both fail closed. Only IOKit-confirmed disappearance
# of the original registry generation releases the suppression.
/usr/bin/grep -Fq 'logicalEjectSuppressionPath' "${RUNTIME_STATE_SOURCE}"
/usr/bin/grep -Fq 'logicallyEjectedUSBRegistryIDs' "${EJECT_COORDINATOR_SOURCE}"
/usr/bin/grep -Fq 'func armLogicalSuppression(disk:' "${EJECT_COORDINATOR_SOURCE}"
/usr/bin/grep -Fq 'func reconcileSuppressedGenerations(disks:' "${EJECT_COORDINATOR_SOURCE}"
/usr/bin/grep -Fq 'if mediaProvider.registryEntryExists(suppressedUSBRegistryEntryID)' "${EJECT_COORDINATOR_SOURCE}"
/usr/bin/grep -Fq 'try eject.reconcileSuppressedGenerations(disks: disks)' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'try self.eject.armLogicalSuppression(disk: disk)' "${RUNTIME_SOURCE}"
for scenario in S36 S37 S38 S39 S40; do
  /usr/bin/grep -Fq "SCENARIO=${scenario}_OK" "${ROOT}/Apps/Drive/Tests/VirtualUSB/ValidateCredentialPolicyServiceLifecycle.swift"
done
echo 'RESULT=DRIVE_SYSTEM_SAFE_EJECT_SUPPRESSION_OK'

# Standard encrypted EDP media must be claimed during the Disk Arbitration peek
# phase, before macOS starts automatic FSKit probing. This closes the physical
# replug race where fskitd can retain /dev/rdiskNs1 and make the whole-disk RW
# raw lease fail with EBUSY. Classification remains standard-EDP-only; no daemon
# hot-path workaround may kill/reset fskitd globally.
/usr/bin/grep -Fq 'struct EDPEarlyDiskClaimClassifier: Sendable' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'resolved.mediaKind == .standardEncrypted && resolved.identity != nil' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'DARegisterDiskPeekCallback(' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'DADiskClaim(' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'DADiskIsClaimed(' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'DADiskUnclaim(' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'private var earlyClaimedDisks = [UInt64: DADisk]()' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'private var earlyClaimTerminationMonitors = [UInt64: EDPIOMediaTerminationMonitor]()' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'EDPIOMediaTerminationMonitor(' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'EDPIOKitMediaLifecycle.registryEntryExists(registryEntryID)' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'earlyClaimedDisks[registryEntryID] = disk' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'earlyClaimTerminationMonitors[registryEntryID] = monitor' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'earlyClaimedDisks.removeValue(forKey: registryEntryID)' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'earlyClaimTerminationMonitors.removeValue(forKey: registryEntryID)' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'func hasExclusiveClaim(_ bsdName: String, expectedRegistryEntryID: UInt64) -> Bool' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'EDP Drive owns this standard encrypted physical generation' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'SCENARIO=S41_OK' "${ROOT}/Apps/Drive/Tests/VirtualUSB/ValidateCredentialPolicyServiceLifecycle.swift"
! /usr/bin/grep -Ei 'killall.*fskitd|pkill.*fskitd|SIG(KILL|TERM).*fskitd' "${RUNTIME_SOURCE}" "${NATIVE_SYSTEM_SOURCE}" "${RAW_ACCESS_COORDINATOR_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_EARLY_EDP_DISK_CLAIM_OK'

# Routine UI stop/start/restart must not terminate the privileged process while a
# standard EDP generation is claimed. Pause/resume/restart quiesce mounts and raw
# leases in-process so the Disk Arbitration session/claim has no gap for fskitd.
# Only explicit full exit retains the process-level graceful shutdown path.
/usr/bin/grep -Fq 'func requestRuntimePause(withReply' "${XPC_PROTOCOL_SOURCE}"
/usr/bin/grep -Fq 'func requestRuntimeResume(withReply' "${XPC_PROTOCOL_SOURCE}"
/usr/bin/grep -Fq 'func requestRuntimeRestart(withReply' "${XPC_PROTOCOL_SOURCE}"
/usr/bin/grep -Fq 'func pauseRuntimeAsync(completion:' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'func resumeRuntimeAsync(completion:' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'func restartRuntimeAsync(completion:' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'private func continuousClaimFailureLocked() -> String?' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'diskArbitration.hasExclusiveClaim(' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'private func restoreRuntimeRawAccessLocked(completion:' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'refreshRawAccessNextLocked(' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'proxy.requestRuntimePause' "${APP_VIEW_MODEL_SOURCE}"
/usr/bin/grep -Fq 'proxy.requestRuntimeResume' "${APP_VIEW_MODEL_SOURCE}"
/usr/bin/grep -Fq 'proxy.requestRuntimeRestart' "${APP_VIEW_MODEL_SOURCE}"
/usr/bin/grep -Fq 'func shutdownService(completion:' "${APP_VIEW_MODEL_SOURCE}"
! /usr/bin/grep -Fq 'stopService(restart: true)' "${APP_VIEW_MODEL_SOURCE}"
for scenario in S42 S43 S45; do
  /usr/bin/grep -Fq "SCENARIO=${scenario}_OK" "${ROOT}/Apps/Drive/Tests/VirtualUSB/ValidateCredentialPolicyServiceLifecycle.swift"
done
FULL_EXIT_SECTION="$(/usr/bin/awk '/func shutdownService\(completion:/,/func openServiceSettings\(\)/' "${APP_VIEW_MODEL_SOURCE}")"
/usr/bin/grep -Fq 'proxy.requestRuntimeResume' <<<"${FULL_EXIT_SECTION}"
/usr/bin/grep -Fq 'proxy.snapshot' <<<"${FULL_EXIT_SECTION}"
/usr/bin/grep -Fq 'proxy.eject(deviceID:' <<<"${FULL_EXIT_SECTION}"
/usr/bin/grep -Fq 'proxy.requestGracefulShutdown' <<<"${FULL_EXIT_SECTION}"
FULL_EXIT_RESUME_LINE="$(/usr/bin/grep -nF 'proxy.requestRuntimeResume' <<<"${FULL_EXIT_SECTION}" | /usr/bin/head -n1 | /usr/bin/cut -d: -f1)"
FULL_EXIT_EJECT_LINE="$(/usr/bin/grep -nF 'proxy.eject(deviceID:' <<<"${FULL_EXIT_SECTION}" | /usr/bin/head -n1 | /usr/bin/cut -d: -f1)"
FULL_EXIT_SHUTDOWN_LINE="$(/usr/bin/grep -nF 'proxy.requestGracefulShutdown' <<<"${FULL_EXIT_SECTION}" | /usr/bin/head -n1 | /usr/bin/cut -d: -f1)"
[[ "${FULL_EXIT_RESUME_LINE}" -lt "${FULL_EXIT_EJECT_LINE}" && "${FULL_EXIT_EJECT_LINE}" -lt "${FULL_EXIT_SHUTDOWN_LINE}" ]]
echo 'RESULT=DRIVE_SYSTEM_FULL_EXIT_SAFE_EJECT_ORDER_OK'
echo 'RESULT=DRIVE_SYSTEM_CLAIM_CONTINUOUS_RUNTIME_CONTROL_OK'

# Lifecycle failure bounds are monotonic and scheduler-driven. Bridge readiness
# and mount-drain success are event-driven; only their timeout branches consume
# the virtual clock and must never regress to wall-clock Date()/asyncAfter logic.
/usr/bin/grep -Fq 'protocol EDPLifecycleScheduling' "${SCHEDULER_SOURCE}"
/usr/bin/grep -Fq 'DispatchTime.now().uptimeNanoseconds' "${SCHEDULER_SOURCE}"
/usr/bin/grep -Fq 'scheduler.schedule(on: lifecycleQueue, after: 8)' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'scheduler.schedule(on: lifecycleQueue, after: timeoutSeconds)' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'scheduler.schedule(on: operation.queue, after: max(0, gracefulExitSeconds))' "${TRANSPORT_SOURCE}"
! /usr/bin/grep -Eq 'Date\(\)\.addingTimeInterval\((8|15)\)' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Eq 'Date\(\) [<>]=? deadline' "${RUNTIME_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_VIRTUAL_CLOCK_LIFECYCLE_OK'

# Model/property regression is deterministic, reproducible, and must retain at
# least 10,000 generated lifecycle sequences plus a failure trace.
/usr/bin/grep -Fq 'static let fixedSeed: UInt64' "${MODEL_PROPERTY_SOURCE}"
/usr/bin/grep -Fq 'sequenceCount: Int = 10_000' "${MODEL_PROPERTY_SOURCE}"
/usr/bin/grep -Fq 'MODEL_PROPERTY_FAILURE invariant=' "${MODEL_PROPERTY_SOURCE}"
/usr/bin/grep -Fq 'TRACE:' "${MODEL_PROPERTY_SOURCE}"
/usr/bin/grep -Fq 'EDPDiskArbitrationCompletionGate()' "${MODEL_PROPERTY_SOURCE}"
/usr/bin/grep -Fq 'cancelled mount launched a new attempt' "${MODEL_PROPERTY_SOURCE}"
/usr/bin/grep -Fq 'failed terminal state retained publication ownership' "${MODEL_PROPERTY_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_MODEL_PROPERTIES_OK'

# Runtime lifecycle diagnostics are bounded, monotonic, machine-readable, and
# deliberately exclude credential/raw-data fields. The controller must export
# the journal as JSON without exposing helper stderr or filesystem/raw paths.
/usr/bin/grep -Fq 'static let defaultCapacity = 256' "${JOURNAL_SOURCE}"
/usr/bin/grep -Fq 'entries.removeFirst(entries.count - capacity)' "${JOURNAL_SOURCE}"
/usr/bin/grep -Fq 'let elapsedMs: UInt64' "${JOURNAL_SOURCE}"
/usr/bin/grep -Fq 'let diagnosticCode: String?' "${JOURNAL_SOURCE}"
/usr/bin/grep -Fq '"lifecycleJournal": manager.lifecycleJournalSnapshot().map(\.jsonObject)' "${RUNTIME_SOURCE}"
if /usr/bin/grep -Ei 'password|credential|plaintext|stderr|rawPath|secret|keyData|keyBytes' "${JOURNAL_SOURCE}"; then
  echo 'sensitive field leaked into lifecycle journal schema' >&2
  exit 1
fi
echo 'RESULT=DRIVE_SYSTEM_LIFECYCLE_JOURNAL_OK'

# Recovery observability is a fixed numeric schema. Counters record only event
# totals and must never grow device identity, paths, credentials, or secret data.
for key in \
  rawBusyRecoveryCount \
  forcedWholeUnmountCount \
  fskitAgentRecoveryCount \
  diskImagesAttachRecoveryCount \
  diskImagesDetachRecoveryCount \
  mountRetryCount \
  ejectAlreadyAbsentSuccessCount; do
  /usr/bin/grep -Fq "\"${key}\"" "${RUNTIME_METRICS_SOURCE}"
done
/usr/bin/grep -Fq '"runtimeMetrics": metrics.snapshot().jsonObject' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'metrics.increment(.rawBusyRecovery)' "${RAW_ACCESS_COORDINATOR_SOURCE}"
/usr/bin/grep -Fq 'metrics.increment(.forcedWholeUnmount)' "${RAW_ACCESS_COORDINATOR_SOURCE}"
/usr/bin/grep -Fq 'metrics.increment(.fskitAgentRecovery)' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'metrics.increment(.diskImagesAttachRecovery)' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'metrics.increment(.diskImagesDetachRecovery)' "${PUBLISHER_SOURCE}"
/usr/bin/grep -Fq 'metrics.increment(.mountRetry)' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'metrics.increment(.ejectAlreadyAbsentSuccess)' "${EJECT_COORDINATOR_SOURCE}"
if /usr/bin/grep -Ei 'deviceID|rawPath|mountPoint|password|credential|secret|keyData|keyBytes' "${RUNTIME_METRICS_SOURCE}"; then
  echo 'sensitive field leaked into runtime metrics schema' >&2
  exit 1
fi
echo 'RESULT=DRIVE_SYSTEM_RUNTIME_METRICS_OK'

# Explicitly reopening the foreground App must restore discovery-service intent.
# A prior Stop/Complete Quit may stop the daemon for that UI session, but must
# never make the next visible app launch silently unable to discover USB media.
/usr/bin/grep -Fq 'Explicitly opening EDP Drive always restores the discovery daemon.' "${APP_VIEW_MODEL_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_APP_REOPEN_RESTORES_SERVICE_OK'

# External/private production dependencies are explicit and bounded. The normal
# DiskImages2 publish path uses the exact signed helper; hdiutil detach belongs
# only to orphan scratch recovery. FSKit approval is owned by macOS/macFUSE and
# is never synthesized by PluginKit/plist writes during App launch. User tools
# remain typed, timeout-bounded, and Task-cancellable.
/usr/bin/grep -Fq 'enum EDPUserToolError: Error, LocalizedError, Sendable' "${APP_SERVICE_SUPPORT_SOURCE}"
/usr/bin/grep -Fq 'timeout: Duration = .seconds(8)' "${APP_SERVICE_SUPPORT_SOURCE}"
/usr/bin/grep -Fq 'withTaskCancellationHandler' "${APP_SERVICE_SUPPORT_SOURCE}"
/usr/bin/grep -Fq 'requestCancellation()' "${APP_SERVICE_SUPPORT_SOURCE}"
/usr/bin/grep -Fq 'Darwin.kill(self.process.processIdentifier, SIGKILL)' "${APP_SERVICE_SUPPORT_SOURCE}"
! /usr/bin/grep -Fq 'waitUntilExit()' "${APP_SERVICE_SUPPORT_SOURCE}"
! /usr/bin/grep -Fq 'while process.isRunning' "${APP_SERVICE_SUPPORT_SOURCE}"
! /usr/bin/grep -Fq 'Task.sleep(for: .milliseconds(50))' "${APP_SERVICE_SUPPORT_SOURCE}"
! /usr/bin/grep -Fq 'ensureMacFUSELocalEnablement' "${APP_VIEW_MODEL_SOURCE}" "${APP_SERVICE_SUPPORT_SOURCE}"
/usr/bin/grep -Fq 'macFUSELocalRuntimeReady()' "${APP_VIEW_MODEL_SOURCE}"
! /usr/bin/grep -Fq 'macFUSELocalEnablementReady()' "${APP_VIEW_MODEL_SOURCE}"
! /usr/bin/grep -Fq '/usr/bin/pluginkit' "${RUNTIME_SOURCE}" "${MOUNT_LIFECYCLE_SOURCE}" "${PUBLISHER_SOURCE}"
DISKIMAGES_PUBLISHER_SECTION="$(/usr/bin/awk '/^final class EDPDiskImages2Publisher/{found=1} found {print}' "${PUBLISHER_SOURCE}")"
/usr/bin/grep -Fq 'helperPath = binaryRoot + "/diskimages2-attach"' <<<"${DISKIMAGES_PUBLISHER_SECTION}"
/usr/bin/grep -Fq 'helperPath, "--writable-noautomount", path' <<<"${DISKIMAGES_PUBLISHER_SECTION}"
/usr/bin/grep -Fq 'arguments: ["info", "-plist"]' <<<"${DISKIMAGES_PUBLISHER_SECTION}"
! /usr/bin/grep -Fq 'hdiutil attach' <<<"${DISKIMAGES_PUBLISHER_SECTION}"
! /usr/bin/grep -Fq 'hdiutil detach' <<<"${DISKIMAGES_PUBLISHER_SECTION}"
/usr/bin/grep -Fq 'runHdiutilAsync(["detach", device, "-force"])' "${PUBLISHER_SOURCE}"
"${APP_SERVICE_SUPPORT_RUNNER}" | /usr/bin/grep -Fq 'RESULT=DRIVE_APP_USER_TOOL_BOUNDED_TYPED_CANCELLABLE_OK'
echo 'RESULT=DRIVE_SYSTEM_EXTERNAL_DEPENDENCY_BOUNDARIES_OK'

# Normal product lifecycle must never execute a potentially uninterruptible VFS
# unmount syscall inside the privileged service. The exact hidden IOMedia
# generation is monitored in IOKit and /sbin/umount is isolated in a helper
# process whose termination is event-driven. App-side helper execution is also
# Process.terminationHandler-driven; enablement does not use fixed retry sleeps.
! /usr/bin/grep -Fq '/bin/launchctl' "${APP_SOURCE}" "${APP_VIEW_MODEL_SOURCE}" "${APP_SERVICE_SUPPORT_SOURCE}"
! /usr/bin/grep -Fq '/usr/bin/codesign' "${MACFUSE_POLICY_SOURCE}"
/usr/bin/grep -Fq 'SecStaticCodeCheckValidity' "${MACFUSE_POLICY_SOURCE}"
/usr/bin/grep -Fq 'kSecCodeInfoTeamIdentifier' "${MACFUSE_POLICY_SOURCE}"
! /usr/bin/grep -Fq '/usr/bin/pluginkit' "${MACFUSE_POLICY_SOURCE}"
/usr/bin/grep -Fq 'executableURL = URL(fileURLWithPath: "/sbin/umount")' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'requireSourceTermination: true' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'Darwin.unmount(path, flags)' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'final class EDPIOMediaTerminationMonitor' "${IOKIT_LIFECYCLE_SOURCE}"
/usr/bin/grep -Fq 'process.terminationHandler' "${APP_SERVICE_SUPPORT_SOURCE}"
/usr/bin/grep -Fq 'withTaskCancellationHandler' "${APP_SERVICE_SUPPORT_SOURCE}"
! /usr/bin/grep -Fq 'edpMacFUSEEnablementMaxAttempts' "${APP_SERVICE_SUPPORT_SOURCE}" "${APP_VIEW_MODEL_SOURCE}"
! /usr/bin/grep -Fq 'for attempt in' "${APP_VIEW_MODEL_SOURCE}"
! /usr/bin/grep -Fq 'Require the user FSKit state to remain stable for one' "${APP_VIEW_MODEL_SOURCE}"
/usr/bin/grep -Fq 'func macFUSELocalRuntimeReady() -> Bool' "${APP_SERVICE_SUPPORT_SOURCE}"
/usr/bin/grep -Fq 'transportRuntimeReady = macFUSELocalRuntimeReady()' "${APP_VIEW_MODEL_SOURCE}"
! /usr/bin/grep -Fq 'enabledModules.plist' "${APP_SERVICE_SUPPORT_SOURCE}" "${APP_VIEW_MODEL_SOURCE}"
! /usr/bin/grep -Fq '/usr/bin/pluginkit' "${APP_SERVICE_SUPPORT_SOURCE}" "${APP_VIEW_MODEL_SOURCE}"
! /usr/bin/grep -Fq 'FSClient' "${APP_SERVICE_SUPPORT_SOURCE}" "${APP_VIEW_MODEL_SOURCE}"
! /usr/bin/grep -Fq 'noActiveFSKitMountsForAgentReset' "${APP_SERVICE_SUPPORT_SOURCE}" "${APP_VIEW_MODEL_SOURCE}"
! /usr/bin/grep -Fq '"install", "--components", "file-system-extensions"' "${APP_SERVICE_SUPPORT_SOURCE}" "${APP_VIEW_MODEL_SOURCE}"
/usr/bin/grep -Fq 'packageUpgradeAction == '\''clean'\''' "${CLEAN_INSTALLER_SOURCE}"
/usr/bin/grep -Fq 'packageUpgradeAction == '\''upgrade'\''' "${CLEAN_INSTALLER_SOURCE}"
/usr/bin/grep -Fq 'require-scripts="true"' "${CLEAN_INSTALLER_SOURCE}"
/usr/bin/grep -Fq 'case bridgeExtensionRequiresApproval' "${MOUNT_LIFECYCLE_SOURCE}"
/usr/bin/grep -Fq 'direct_mfmount_async_result=4' "${MOUNT_LIFECYCLE_SOURCE}"
/usr/bin/grep -Fq 'case .bridgeExtensionUnavailable, .bridgeExtensionRequiresApproval:' "${MOUNT_LIFECYCLE_SOURCE}"
/usr/bin/grep -Fq 'EDP_MFMOUNT_QUIET": "0"' "${TRANSPORT_PROVIDER}"
echo 'RESULT=DRIVE_SYSTEM_FSKIT_APPROVAL_OWNERSHIP_OK'
echo 'RESULT=DRIVE_SYSTEM_FSKIT_ENABLEMENT_EVENT_DRIVEN_OK'
echo 'RESULT=DRIVE_SYSTEM_NATIVE_RUNTIME_CONTROL_OK'

# Current Drive documentation must remain aligned with canonical Makefile/CI
# entry points and must not send maintainers back to superseded handoffs/plans.
STATUS_DOC="${ROOT}/Apps/Drive/docs/STATUS.md"
ARCHITECTURE_DOC="${ROOT}/Apps/Drive/docs/ARCHITECTURE.md"
TESTING_DOC="${ROOT}/Apps/Drive/docs/TESTING.md"
RELEASE_DOC="${ROOT}/Apps/Drive/docs/RELEASE-CHECKLIST.md"
NTFS_ADR_DOC="${ROOT}/Apps/Drive/docs/ADR-2026-09-03-ntfs-rw.md"
HISTORICAL_DOC="${ROOT}/Apps/Drive/docs/HISTORICAL.md"
for doc in "${STATUS_DOC}" "${ARCHITECTURE_DOC}" "${TESTING_DOC}" "${RELEASE_DOC}" "${NTFS_ADR_DOC}" "${HISTORICAL_DOC}"; do
  [[ -s "${doc}" ]]
done
/usr/bin/grep -Fq 'Current exact-head CI:' "${STATUS_DOC}"
/usr/bin/grep -Fq 'persisted original `usbRegistryEntryID`' "${ARCHITECTURE_DOC}"
/usr/bin/grep -Fq 'logically-ejected' "${STATUS_DOC}" "${RELEASE_DOC}"
/usr/bin/grep -Fq 'S36–S40' "${STATUS_DOC}" "${TESTING_DOC}" "${RELEASE_DOC}"
/usr/bin/grep -Fq '— **PASS 5/5**' "${STATUS_DOC}"
/usr/bin/grep -Fq 'autoMount = false' "${STATUS_DOC}"
/usr/bin/grep -Fq 'THRESHOLD_NS = 33_000_000' "${STATUS_DOC}" "${TESTING_DOC}"
/usr/bin/grep -Fq 'make drive-test-fast' "${TESTING_DOC}"
/usr/bin/grep -Fq 'make drive-test-virtual-usb' "${TESTING_DOC}"
/usr/bin/grep -Fq 'make drive-test-storage-smoke' "${TESTING_DOC}"
/usr/bin/grep -Fq 'make drive-test-storage' "${TESTING_DOC}"
/usr/bin/grep -Fq 'make drive-test-ui' "${TESTING_DOC}"
/usr/bin/grep -Fq 'make drive-test-system' "${TESTING_DOC}"
/usr/bin/grep -Fq 'make drive-test-all' "${TESTING_DOC}"
/usr/bin/grep -Fq '`regression-storage`' "${TESTING_DOC}"
/usr/bin/grep -Fq '`regression-ui-system`' "${TESTING_DOC}"
/usr/bin/grep -Fq '`nightly-storage-stress`' "${TESTING_DOC}"
/usr/bin/grep -Fq 'BLOCKED_BY_FIXTURE' "${RELEASE_DOC}"
/usr/bin/grep -Fq 'The accepted decision is `ADR-2026-09-03-ntfs-rw.md`: A + C' "${STATUS_DOC}"
/usr/bin/grep -Fq 'The decision is A + C:' "${ARCHITECTURE_DOC}"
/usr/bin/grep -Fq 'Filesystem policy / NTFS ADR test consequences' "${TESTING_DOC}"
/usr/bin/grep -Fq 'ACCEPTED A+C (native NTFS RO + writable ExFAT)' "${RELEASE_DOC}"
/usr/bin/grep -Fq 'Status: **ACCEPTED**' "${NTFS_ADR_DOC}"
/usr/bin/grep -Fq 'EDP Drive adopts an **A + C** strategy:' "${NTFS_ADR_DOC}"
/usr/bin/grep -Fq 'Do not restore `ntfs-3g`.' "${NTFS_ADR_DOC}"
/usr/bin/grep -Fq 'NTFS RW is **not a blocker** for the current EDP Drive release candidate.' "${NTFS_ADR_DOC}"
! /usr/bin/grep -Fq 'NTFS RW ADR                         NOT YET DECIDED' "${RELEASE_DOC}"
/usr/bin/grep -Fq 'Historical Document Index' "${HISTORICAL_DOC}"
echo 'RESULT=DRIVE_SYSTEM_CURRENT_DOCS_OK'
echo 'RESULT=DRIVE_SYSTEM_NTFS_ADR_OK'

# GitHub deprecated Node.js 20 for JavaScript actions. Drive workflow actions
# must stay on the official Node24-based major lines rather than relying on the
# runner to force-migrate an older JavaScript runtime at execution time.
DRIVE_WORKFLOW="${ROOT}/.github/workflows/drive.yml"
[[ "$(/usr/bin/grep -Fc 'actions/checkout@v7' "${DRIVE_WORKFLOW}")" -eq 6 ]]
[[ "$(/usr/bin/grep -Fc 'actions/upload-artifact@v7' "${DRIVE_WORKFLOW}")" -eq 5 ]]
! /usr/bin/grep -Fq 'actions/checkout@v6' "${DRIVE_WORKFLOW}"
! /usr/bin/grep -Fq 'actions/upload-artifact@v4' "${DRIVE_WORKFLOW}"
echo 'RESULT=DRIVE_SYSTEM_GITHUB_ACTIONS_NODE24_OK'

# Canonical top-level gates must remain wired and hardware-free by construction.
/usr/bin/grep -Fq 'drive-test-storage-smoke:' "${ROOT}/Makefile"
/usr/bin/grep -Fq 'EDP_STORAGE_PROFILE=smoke EDP_STORAGE_LOOP_COUNT=5' "${ROOT}/Makefile"
/usr/bin/grep -Fq 'EDP_STORAGE_PROFILE=release EDP_STORAGE_LOOP_COUNT=5' "${ROOT}/Makefile"
/usr/bin/grep -Fq 'LOOP_COUNT="${EDP_STORAGE_LOOP_COUNT:-5}"' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'MIN_LOOPS=5' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'drive-test-system:' "${ROOT}/Makefile"
/usr/bin/grep -Fq 'drive-test-all: drive-test-fast drive-test-virtual-usb drive-test-storage drive-test-ui drive-test-system' "${ROOT}/Makefile"

RAW_BROKER_SOURCE="${ROOT}/Apps/Drive/product/EDPRawFDBroker.c"
/usr/bin/grep -Fq 'EDP_RAW_BROKER_APP_PATH "/Applications/EDP Drive.app/Contents/MacOS/EDP Drive"' "${RAW_BROKER_SOURCE}"
/usr/bin/grep -Fq 'SCM_RIGHTS' "${RAW_BROKER_SOURCE}"
/usr/bin/grep -Fq 'geteuid() != 0' "${RAW_BROKER_SOURCE}"
/usr/bin/grep -Fq 'edpRawFDBrokerSpawn(appPath, rawPath, 5_000' "${RAW_ACCESS_SOURCE}"
/usr/bin/grep -Fq 'EDPPhysicalDeviceRevalidation.metadataStillMatches(metadata, disk: disk)' "${RAW_ACCESS_SOURCE}"
! /usr/bin/grep -Fq 'Darwin.open(disk.rawPath' "${RUNTIME_SOURCE}" "${RAW_ACCESS_SOURCE}"
/usr/bin/grep -Fq 'CommandLine.arguments.firstIndex(of: "--raw-fd-broker")' "${APP_SOURCE}"
/usr/bin/grep -Fq 'RAW_ACCESS_BUNDLE_ID="com.edp.drive"' "${ACCEPTANCE_SOURCE}"
! /usr/bin/grep -Fq 'RAW_ACCESS_BUNDLE_ID="com.edp.drive.service"' "${ACCEPTANCE_SOURCE}"
/usr/bin/grep -Fq 'open -R "${APP}"' "${ACCEPTANCE_SOURCE}"
! /usr/bin/grep -Fq 'open -R "${SERVICE_BIN}"' "${ACCEPTANCE_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_SINGLE_APP_FDA_RAW_BROKER_OK'

echo 'RESULT=DRIVE_SYSTEM_NO_SUDO_OK'
echo 'RESULT=DRIVE_SYSTEM_NO_PHYSICAL_RAW_OPEN_OK'
echo 'RESULT=DRIVE_SYSTEM_SYNTHETIC_WRITE_GUARD_OK'
echo 'RESULT=DRIVE_SYSTEM_ARCHITECTURE_RATCHETS_OK'
echo 'RESULT=DRIVE_SYSTEM_OK'
