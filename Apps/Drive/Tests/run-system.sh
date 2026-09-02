#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="${ROOT}/Apps/Drive/Tests"
STORAGE_RUNNER="${TEST_ROOT}/run-storage.sh"
UI_RUNNER="${TEST_ROOT}/run-ui.sh"
APP_SOURCE="${ROOT}/Apps/Drive/product/App/EDPUSBVaultApp.swift"
RUNTIME_SOURCE="${ROOT}/Apps/Drive/product/EDPVaultRuntime.swift"
RUNTIME_SUPPORT_SOURCE="${ROOT}/Apps/Drive/product/EDPRuntimeSupport.swift"
RUNTIME_STATE_SOURCE="${ROOT}/Apps/Drive/product/EDPRuntimeState.swift"
DEVICE_OPERATIONS_SOURCE="${ROOT}/Apps/Drive/product/EDPDeviceOperations.swift"
RAW_ACCESS_SOURCE="${ROOT}/Apps/Drive/product/EDPRawAccess.swift"
RAW_ACCESS_COORDINATOR_SOURCE="${ROOT}/Apps/Drive/product/EDPRawAccessCoordinator.swift"
MOUNT_LIFECYCLE_SOURCE="${ROOT}/Apps/Drive/product/EDPMountLifecycle.swift"
MOUNT_SUPPORT_SOURCE="${ROOT}/Apps/Drive/product/EDPMountSupport.swift"
SCHEDULER_SOURCE="${ROOT}/Apps/Drive/product/EDPLifecycleScheduler.swift"
JOURNAL_SOURCE="${ROOT}/Apps/Drive/product/EDPLifecycleJournal.swift"
NATIVE_SYSTEM_SOURCE="${ROOT}/Apps/Drive/product/EDPNativeSystem.swift"
MACFUSE_POLICY_SOURCE="${ROOT}/Apps/Drive/product/EDPMacFUSERuntimePolicy.swift"
PUBLISHER_SOURCE="${ROOT}/Apps/Drive/product/EDPBlockDevicePublisher.swift"
POLICY_SOURCE="${ROOT}/Apps/Drive/product/EDPDevicePolicyStore.swift"
CREDENTIAL_SOURCE="${ROOT}/Apps/Drive/product/EDPCredentialStore.swift"
MODEL_PROPERTY_SOURCE="${ROOT}/Apps/Drive/Tests/VirtualUSB/ValidateLifecycleModelProperties.swift"
EMBEDDED_SERVICE_PLIST="${ROOT}/Apps/Drive/product/App/com.edp.drive.service.plist"
LEGACY_SERVICE_PLIST="${ROOT}/Apps/Drive/installer/com.edp.drive.service.plist"
CLEAN_INSTALLER_SOURCE="${ROOT}/Apps/Drive/installer/build-clean-installer.sh"
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
/usr/bin/grep -Fq '(not devices or expected_device in devices)' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq -- '--assert-process-path "$pid" /usr/libexec/diskimagesiod' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'proc_pidpath(' "${DA_MOUNT_SOURCE}"
/usr/bin/grep -Fq 'REMOUNT_QUIESCENCE_SECONDS=3' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'wait_for_native_filesystem_quiescence' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'Keep the DiskImages2 IOMedia' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'wait_for_remount_quiescence' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'if (( iteration < LOOP_COUNT )); then' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'DADiskEject(disk, kDADiskEjectOptionDefault' "${DA_MOUNT_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_STORAGE_PUBLICATION_TEARDOWN_OK'
echo 'RESULT=DRIVE_SYSTEM_STORAGE_HDIUTIL_SNAPSHOT_BOUNDED_OK'
echo 'RESULT=DRIVE_SYSTEM_STORAGE_DA_EJECT_OWNER_RECOVERY_OK'

# Storage-only FSKit host recovery mirrors the production one-shot policy. It
# must use real MNT_EXT_FSKIT mount detection, never restart the user agent while
# any FSKit volume is active, and never grow into an unbounded retry loop.
FSKIT_GUARD_SOURCE="${ROOT}/Apps/Drive/native/EDPFSKitPoC/Tools/MacFUSEMinimal/DirectMFMountUnmountHelper.c"
/usr/bin/grep -Fq 'MNT_EXT_FSKIT' "${FSKIT_GUARD_SOURCE}"
/usr/bin/grep -Fq -- '--assert-no-fskit-mounts' "${FSKIT_GUARD_SOURCE}" "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'for attempt in 1 2; do' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'command" == "/usr/libexec/fskit_agent"' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'STORAGE_FSKIT_HOST_RETRY=' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq -- '--mountpoint-for-source' "${FSKIT_GUARD_SOURCE}" "${STORAGE_RUNNER}"
/usr/bin/grep -Fq -- '--assert-readonly' "${FSKIT_GUARD_SOURCE}" "${STORAGE_RUNNER}"
/usr/bin/grep -Fq -- '--assert-writable' "${FSKIT_GUARD_SOURCE}" "${STORAGE_RUNNER}"
/usr/bin/grep -Fq -- '--assert-no-mount-prefix' "${FSKIT_GUARD_SOURCE}" "${STORAGE_RUNNER}"
! /usr/bin/grep -Fq '/usr/sbin/diskutil info' "${STORAGE_RUNNER}"
! /usr/bin/grep -Eq '/sbin/mount([[:space:]]|$)' "${STORAGE_RUNNER}"
! /usr/bin/grep -Fq 'while adapter_log_is_transient_fskit_failure' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'candidate="$(/usr/bin/mktemp "${output}.tmp.XXXXXX")"' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq '/bin/mv -f "$candidate" "$output"' "${STORAGE_RUNNER}"
! /usr/bin/grep -Fq ': >"$output"' "${STORAGE_RUNNER}"
echo 'RESULT=DRIVE_SYSTEM_STORAGE_FSKIT_BOUNDED_RECOVERY_OK'
echo 'RESULT=DRIVE_SYSTEM_STORAGE_ATOMIC_HDIUTIL_SNAPSHOT_OK'

# The macFUSE Local FSKit block bridge keeps its established local,nobrowse VFS
# semantics. Repeated-remount safety is enforced by exact publication teardown,
# unique generations, and quiescence; do not change the bridge's read/write VFS
# behavior as a substitute for lifecycle isolation.
TRANSPORT_BUILD="${ROOT}/Apps/Drive/installer/build-transport-backends.sh"
TRANSPORT_PROVIDER="${ROOT}/Apps/Drive/product/EDPTransportProvider.swift"
RAW_TRANSPORT="${ROOT}/Apps/Drive/native/EDPFSKitPoC/Tools/MacFUSEMinimal/DirectMFMountRawTransport.c"
/usr/bin/grep -Fq '"nobrowse,volname=%s"' "${RAW_TRANSPORT}"
/usr/bin/grep -Fq 'localVolume: true' "${TRANSPORT_PROVIDER}"
/usr/bin/grep -Fq 'EDP_MFMOUNT_OPTIONS": "local,nobrowse"' "${TRANSPORT_PROVIDER}"
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

# The console launcher must allow both transport modes.  A missing read-only
# target breaks the boot FAT16 path while leaving encrypted partitions healthy,
# which is easy to miss in ordinary smoke testing.
/usr/bin/grep -Fq 'edp-mfmount-local-readwrite' "${ROOT}/Apps/Drive/product/EDPConsoleExec.c"
/usr/bin/grep -Fq 'edp-mfmount-local-readonly' "${ROOT}/Apps/Drive/product/EDPConsoleExec.c"
echo 'RESULT=DRIVE_SYSTEM_CONSOLE_TRANSPORT_ALLOWLIST_OK'

# The Animation Hitches performance gate is compositor-sensitive and therefore
# release-authoritative only on the GitHub Actions runner. Local runs may still
# execute deterministic UI structure checks, but must skip xctrace performance.
/usr/bin/grep -Fq 'GITHUB_ACTIONS:-false' "${UI_RUNNER}"
/usr/bin/grep -Fq 'RESULT=DRIVE_UI_PERF_CI_ONLY_SKIPPED_LOCALLY' "${UI_RUNNER}"
/usr/bin/grep -Fq 'RESULT=DRIVE_UI_PERF_CI_ENVIRONMENT' "${UI_RUNNER}"
/usr/bin/grep -Fq -- '--launch -- "${BIN}" --hitch-only' "${UI_RUNNER}"
/usr/bin/grep -Fq 'table[@schema="hitches-frame-lifetimes"]' "${UI_RUNNER}"
/usr/bin/grep -Fq 'children = list(row)' "${ROOT}/Apps/Drive/Tests/UI/ParseAnimationHitches.py"
/usr/bin/grep -Fq 'is_duration=False' "${ROOT}/Apps/Drive/Tests/UI/ParseAnimationHitches.py"
/usr/bin/grep -Fq 'is_duration=True' "${ROOT}/Apps/Drive/Tests/UI/ParseAnimationHitches.py"
/usr/bin/grep -Fq 'THRESHOLD_NS = 33_000_000' "${ROOT}/Apps/Drive/Tests/UI/ParseAnimationHitches.py"
echo 'RESULT=DRIVE_SYSTEM_UI_PERF_CI_ONLY_OK'

# Identity and architecture invariants that must not regress during release
# hardening.
/usr/bin/grep -Fq 'EDP-PHYSICAL-ID-V3' "${ROOT}/Apps/Drive/native/EDPFSKitPoC/Extension/EDPVolumeMetadata.swift"
! /usr/bin/grep -Fq 'migrateDeviceID' "${RUNTIME_SOURCE}" \
  "${ROOT}/Apps/Drive/product/EDPDevicePolicyStore.swift" \
  "${ROOT}/Apps/Drive/product/EDPCredentialStore.swift"
/usr/bin/grep -Fq 'EDPNativeSplitViewController: NSSplitViewController' "${APP_SOURCE}"
! /usr/bin/grep -Fq 'NavigationSplitView {' "${APP_SOURCE}"
/usr/bin/grep -Fq '.menuBarExtraStyle(.window)' "${APP_SOURCE}"

# New-device policy is explicitly opt-in. Password probing and mounting are
# independent controls, and menu-bar users must be able to enter credentials
# without navigating into the main window.
/usr/bin/grep -Fq 'safePartitionDefaults()' "${POLICY_SOURCE}"
/usr/bin/grep -Fq 'autoMount: false' "${POLICY_SOURCE}"
/usr/bin/grep -Fq 'autoProbePassword: false' "${POLICY_SOURCE}"
/usr/bin/grep -Fq 'builtInDefaultProbePassword = Array("0000aaaa".utf8)' "${CREDENTIAL_SOURCE}"
/usr/bin/grep -Fq 'default-probe-password.v1' "${CREDENTIAL_SOURCE}"
/usr/bin/grep -Fq '点击钥匙设置密码' "${APP_SOURCE}"
! /usr/bin/grep -Fq '请先在主界面保存密码' "${APP_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_DEFAULT_POLICY_RATCHETS_OK'

# Full in-place upgrades must terminate the old foreground UI before replacing
# the signed App bundle. Otherwise that stale process correctly fails the XPC
# peer signature check against the newly installed bundle and cannot control the
# privileged service.
PREINSTALL_SOURCE="${ROOT}/Apps/Drive/installer/scripts/native-preinstall"
/usr/bin/grep -Fq 'stop_running_drive_ui' "${PREINSTALL_SOURCE}"
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
echo 'RESULT=DRIVE_SYSTEM_PUBLICATION_METADATA_ONLY_TEARDOWN_OK'

# The storage regression harness must obey the same teardown rule as product
# code. Comparing DiskImages2 image-path values is lexical/metadata-only; never
# resolve the macFUSE volume.raw path or stat a transient synthetic /dev/diskN.
/usr/bin/grep -Fq 'Teardown is metadata-only.' "${STORAGE_RUNNER}"
! /usr/bin/grep -Fq 'os.path.realpath(' "${STORAGE_RUNNER}"
! /usr/bin/grep -Eq '\[\[[^]]*(-e|! -e)[[:space:]]+"/dev/\$bsd"' "${STORAGE_RUNNER}"
echo 'RESULT=DRIVE_SYSTEM_STORAGE_METADATA_ONLY_TEARDOWN_OK'

# Mount/unmount/eject/shutdown lifecycle is intentionally single-path and
# asynchronous. Never reintroduce polling sleeps or synchronous manager
# fallbacks into the production daemon; regression-only wait adapters stay
# isolated behind EDP_REGRESSION_TESTS.
TRANSPORT_SOURCE="${ROOT}/Apps/Drive/product/EDPTransportProvider.swift"
! /usr/bin/grep -Fq 'private func waitUntil(' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'usleep(' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'com.edp.drive.transport-stop-sync' "${TRANSPORT_SOURCE}"
! /usr/bin/grep -Fq 'func stop(' "${TRANSPORT_SOURCE}"
! /usr/bin/grep -Fq 'manager.mount(' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'manager.unmount(' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'manager.eject(' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'manager.unmountAll(' "${RUNTIME_SOURCE}"
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
/usr/bin/grep -Fq 'mediaProvider.registryEntryExists(disk.usbRegistryEntryID)' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'ejectCompletionWaiters' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'beginShutdownTeardownIfReadyLocked()' "${RUNTIME_SOURCE}"
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

# DiskImages2 publication and macFUSE scratch recovery are also asynchronous.
# The publisher may still invoke hdiutil as a bounded adapter, but it must never
# block a lifecycle queue with sleep/wait loops or expose a synchronous publish
# fallback.
! /usr/bin/grep -Fq 'Thread.sleep' "${PUBLISHER_SOURCE}"
! /usr/bin/grep -Fq 'waitUntilExit()' "${PUBLISHER_SOURCE}"
! /usr/bin/grep -Fq 'func publishWritableImage(' "${PUBLISHER_SOURCE}"
/usr/bin/grep -Fq 'func publishWritableImageAsync(' "${PUBLISHER_SOURCE}"
/usr/bin/grep -Fq 'func cleanupNewOrphansAsync(' "${PUBLISHER_SOURCE}"
/usr/bin/grep -Fq 'func cleanupOrphanAsync(' "${PUBLISHER_SOURCE}"
/usr/bin/grep -Fq 'runBoundedProcessAsync(' "${PUBLISHER_SOURCE}"
/usr/bin/grep -Fq 'ensurePublicationGoneAsync(' "${PUBLISHER_SOURCE}"
/usr/bin/grep -Fq 'A successful Disk Arbitration eject only means the BSD' "${PUBLISHER_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_ASYNC_BLOCK_PUBLISHER_OK'

# Repeated FSKit-over-DiskImages2 mounts must not reuse the previous generation
# as soon as Disk Arbitration reports eject success. Exact publication absence,
# transport exit, a monotonic quiescence barrier, and a unique per-attempt bridge
# path are all required before the same logical partition can mount again.
/usr/bin/grep -Fq 'struct EDPRemountQuiescenceGate' "${SCHEDULER_SOURCE}"
/usr/bin/grep -Fq 'guard active[token.sessionKey] == token else { return false }' "${SCHEDULER_SOURCE}"
/usr/bin/grep -Fq 'remountQuiescenceSeconds: TimeInterval = 3.0' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'event: "remountQuiescenceWait"' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'event: "nativeFilesystemQuiescenceStarted"' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'event: "nativeFilesystemQuiescenceComplete"' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'continueUnmountAfterNativeFilesystemQuiescence' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'wait_for_native_filesystem_quiescence' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'Keep the DiskImages2 IOMedia' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'event: "remountQuiescenceStarted"' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'event: "remountQuiescenceComplete"' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'operation.journalContext.id.uuidString.lowercased().prefix(8)' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'RESULT=REMOUNT_QUIESCENCE_GENERATION_OK' \
  "${ROOT}/Apps/Drive/native/EDPFSKitPoC/Tools/ValidateTransportLifecycle.swift"
echo 'RESULT=DRIVE_SYSTEM_REMOUNT_QUIESCENCE_OK'

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

# Lifecycle recovery decisions use typed failure categories. Stable helper/log
# strings may be parsed once at their adapter boundary, but controller/recovery
# policy code must never branch on user-facing error text.
/usr/bin/grep -Fq 'enum EDPLifecycleFailureCode' "${MOUNT_LIFECYCLE_SOURCE}"
/usr/bin/grep -Fq 'recognizedRawAccessFailure' "${MOUNT_LIFECYCLE_SOURCE}"
/usr/bin/grep -Fq 'struct EDPFSKitMountLifecycleMachine' "${MOUNT_LIFECYCLE_SOURCE}"
/usr/bin/grep -Fq 'enum EDPFSKitHostRecovery' "${MOUNT_LIFECYCLE_SOURCE}"
/usr/bin/grep -Fq 'restartConsoleAgentIfSafe()' "${MOUNT_LIFECYCLE_SOURCE}"
! /usr/bin/grep -Fq 'enum EDPLifecycleFailureCode' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'enum EDPFSKitHostRecovery' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'func lastFailureCode(deviceID:' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'failedMountCodes[partitionKey] == .bridgeExtensionUnavailable' "${RUNTIME_SOURCE}"
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
for scenario in S31 S32 S33 S34 S35; do
  /usr/bin/grep -Fq "SCENARIO=${scenario}_OK" "${ROOT}/Apps/Drive/Tests/VirtualUSB/ValidateCredentialPolicyServiceLifecycle.swift"
done
echo 'RESULT=DRIVE_SYSTEM_RAW_EBUSY_RECOVERY_OK'

# Lifecycle deadlines are monotonic and scheduler-driven. Bridge activation and
# mount drain timeouts must not regress to wall-clock Date()/asyncAfter logic.
/usr/bin/grep -Fq 'protocol EDPLifecycleScheduling' "${SCHEDULER_SOURCE}"
/usr/bin/grep -Fq 'DispatchTime.now().uptimeNanoseconds' "${SCHEDULER_SOURCE}"
/usr/bin/grep -Fq 'scheduler.deadline(after: 8)' "${RUNTIME_SOURCE}"
[[ "$(/usr/bin/grep -Fc 'scheduler.deadline(after: 15)' "${RUNTIME_SOURCE}")" -ge 3 ]]
/usr/bin/grep -Fq 'scheduler.deadline(after: gracefulExitSeconds)' "${TRANSPORT_SOURCE}"
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

# Explicitly reopening the foreground App must restore discovery-service intent.
# A prior Stop/Complete Quit may stop the daemon for that UI session, but must
# never make the next visible app launch silently unable to discover USB media.
/usr/bin/grep -Fq 'Explicitly opening EDP Drive always restores the discovery daemon.' "${APP_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_APP_REOPEN_RESTORES_SERVICE_OK'

# Normal product lifecycle must not fall back to shell-side process inspection
# or codesign/umount helpers. Runtime signature validation is Security.framework,
# service liveness is SMAppService + XPC, and VFS teardown is unmount(2).
! /usr/bin/grep -Fq '/bin/launchctl' "${APP_SOURCE}"
! /usr/bin/grep -Fq '/usr/bin/codesign' "${MACFUSE_POLICY_SOURCE}"
/usr/bin/grep -Fq 'SecStaticCodeCheckValidity' "${MACFUSE_POLICY_SOURCE}"
/usr/bin/grep -Fq 'kSecCodeInfoTeamIdentifier' "${MACFUSE_POLICY_SOURCE}"
! /usr/bin/grep -Fq '/usr/bin/pluginkit' "${MACFUSE_POLICY_SOURCE}"
! /usr/bin/grep -Fq '/sbin/umount' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'Darwin.unmount(path, flags)' "${NATIVE_SYSTEM_SOURCE}"
/usr/bin/grep -Fq 'Task.detached(priority: .utility)' "${APP_SOURCE}"
/usr/bin/grep -Fq 'edpMacFUSEEnablementMaxAttempts = 5' "${APP_SOURCE}"
/usr/bin/grep -Fq 'for attempt in 1...edpMacFUSEEnablementMaxAttempts' "${APP_SOURCE}"
/usr/bin/grep -Fq 'macFUSELocalEnablementReady()' "${APP_SOURCE}"
/usr/bin/grep -Fq 'Require the user FSKit state to remain stable for one' "${APP_SOURCE}"
! /usr/bin/grep -Fq 'while !macFUSELocalEnablementReady()' "${APP_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_FSKIT_ENABLEMENT_BOUNDED_RETRY_OK'
echo 'RESULT=DRIVE_SYSTEM_NATIVE_RUNTIME_CONTROL_OK'

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
