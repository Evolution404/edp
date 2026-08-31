#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="${ROOT}/Apps/Drive/Tests"
STORAGE_RUNNER="${TEST_ROOT}/run-storage.sh"
APP_SOURCE="${ROOT}/Apps/Drive/product/App/EDPUSBVaultApp.swift"
RUNTIME_SOURCE="${ROOT}/Apps/Drive/product/EDPVaultRuntime.swift"
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
/usr/bin/grep -Fq 'A vanished BSD node is not sufficient teardown proof.' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'bounded 15 /usr/bin/hdiutil detach "/dev/$bsd" -force' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'wait_for_fixture_publication_gone "$path" 100' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'successful detach call is not enough' "${STORAGE_RUNNER}"
! /usr/bin/grep -Fq '[[ -e "/dev/$bsd" ]] || return 0' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'capture_hdiutil_info() {' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'bounded 3 /usr/bin/hdiutil info -plist' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'hdiutil info snapshot did not stabilize' "${STORAGE_RUNNER}"
[[ "$(/usr/bin/grep -Fc '/usr/bin/hdiutil info -plist' "${STORAGE_RUNNER}")" -eq 1 ]]
/usr/bin/grep -Fq 'capture_hdiutil_info "$WORK_DIR/hdiutil-artifact-check.plist" 20' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'The native filesystem has already been unmounted by the caller.' "${STORAGE_RUNNER}"
! /usr/bin/awk '/^eject_image\(\)/,/^filesystem_format_completed\(\)/' "${STORAGE_RUNNER}" \
  | /usr/bin/grep -Fq 'diskutil unmountDisk'
/usr/bin/grep -Fq 'pre-detach diskutil unmountDisk' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'REMOUNT_QUIESCENCE_SECONDS=3' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'wait_for_remount_quiescence' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'if (( iteration < LOOP_COUNT )); then' "${STORAGE_RUNNER}"
echo 'RESULT=DRIVE_SYSTEM_STORAGE_PUBLICATION_TEARDOWN_OK'
echo 'RESULT=DRIVE_SYSTEM_STORAGE_HDIUTIL_SNAPSHOT_BOUNDED_OK'
echo 'RESULT=DRIVE_SYSTEM_STORAGE_DETACH_ORDER_OK'

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
echo 'RESULT=DRIVE_SYSTEM_STORAGE_FSKIT_BOUNDED_RECOVERY_OK'

# The macFUSE Local FSKit module is only an internal block-transport bridge.
# It must stay nobrowse-only, not MNT_LOCAL: the user-visible outer filesystem
# is the native DiskImages2 volume. Marking the hidden bridge local makes
# Finder/CacheDelete/StorageKit enumerate it and can deadlock nested LIFS.
TRANSPORT_BUILD="${ROOT}/Apps/Drive/installer/build-transport-backends.sh"
TRANSPORT_PROVIDER="${ROOT}/Apps/Drive/product/EDPTransportProvider.swift"
RAW_TRANSPORT="${ROOT}/Apps/Drive/native/EDPFSKitPoC/Tools/MacFUSEMinimal/DirectMFMountRawTransport.c"
/usr/bin/grep -Fq '"nobrowse,volname=%s"' "${RAW_TRANSPORT}"
/usr/bin/grep -Fq 'localVolume: false' "${TRANSPORT_PROVIDER}"
/usr/bin/grep -Fq 'environment: [:]' "${TRANSPORT_PROVIDER}"
/usr/bin/grep -Fq 'must NOT carry MNT_LOCAL' "${TRANSPORT_BUILD}"
/usr/bin/grep -Fq 'nobrowse-only' "${STORAGE_RUNNER}"
! /usr/bin/grep -Fq 'local,nobrowse' "${TRANSPORT_BUILD}" "${TRANSPORT_PROVIDER}" "${STORAGE_RUNNER}"
echo 'RESULT=DRIVE_SYSTEM_TRANSPORT_BRIDGE_NONLOCAL_OK'

# The console launcher must allow both transport modes.  A missing read-only
# target breaks the boot FAT16 path while leaving encrypted partitions healthy,
# which is easy to miss in ordinary smoke testing.
/usr/bin/grep -Fq 'edp-mfmount-local-readwrite' "${ROOT}/Apps/Drive/product/EDPConsoleExec.c"
/usr/bin/grep -Fq 'edp-mfmount-local-readonly' "${ROOT}/Apps/Drive/product/EDPConsoleExec.c"
echo 'RESULT=DRIVE_SYSTEM_CONSOLE_TRANSPORT_ALLOWLIST_OK'

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
/usr/bin/grep -Fq 'refused to recover macFUSE scratch while an FSKit filesystem is mounted' "${PREINSTALL_SOURCE}"
/usr/bin/grep -Fq 'Never act on the recorded PID by itself.' "${PREINSTALL_SOURCE}"
/usr/bin/grep -Fq 'recover_stale_console_fskit_agent' "${PREINSTALL_SOURCE}"
! /usr/bin/grep -Fq 'refreshed_pid="$(hdi_value "${info}" "${image_index}" hdid-pid)"' "${PREINSTALL_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_UPGRADE_UI_HANDOFF_OK'
echo 'RESULT=DRIVE_SYSTEM_INSTALLER_TEST_ORPHAN_REVALIDATION_OK'

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
/usr/bin/grep -Fq 'event: "remountQuiescenceStarted"' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'event: "remountQuiescenceComplete"' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'operation.journalContext.id.uuidString.lowercased().prefix(8)' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'RESULT=REMOUNT_QUIESCENCE_GENERATION_OK' \
  "${ROOT}/Apps/Drive/native/EDPFSKitPoC/Tools/ValidateTransportLifecycle.swift"
echo 'RESULT=DRIVE_SYSTEM_REMOUNT_QUIESCENCE_OK'

# Lifecycle recovery decisions use typed failure categories. Stable helper/log
# strings may be parsed once at their adapter boundary, but controller/recovery
# policy code must never branch on user-facing error text.
/usr/bin/grep -Fq 'enum EDPLifecycleFailureCode' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'recognizedRawAccessFailure' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'func lastFailureCode(deviceID:' "${RUNTIME_SOURCE}"
/usr/bin/grep -Fq 'failedMountCodes[partitionKey] == .bridgeExtensionUnavailable' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'failure.contains("File system extension' "${RUNTIME_SOURCE}"
! /usr/bin/grep -Fq 'errorMessage.contains("EDP_RAW_' "${RUNTIME_SOURCE}"
echo 'RESULT=DRIVE_SYSTEM_TYPED_LIFECYCLE_ERRORS_OK'

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

echo 'RESULT=DRIVE_SYSTEM_NO_SUDO_OK'
echo 'RESULT=DRIVE_SYSTEM_NO_PHYSICAL_RAW_OPEN_OK'
echo 'RESULT=DRIVE_SYSTEM_SYNTHETIC_WRITE_GUARD_OK'
echo 'RESULT=DRIVE_SYSTEM_ARCHITECTURE_RATCHETS_OK'
echo 'RESULT=DRIVE_SYSTEM_OK'
