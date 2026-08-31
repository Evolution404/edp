#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="${ROOT}/Apps/Drive/Tests"
STORAGE_RUNNER="${TEST_ROOT}/run-storage.sh"
APP_SOURCE="${ROOT}/Apps/Drive/product/App/EDPUSBVaultApp.swift"
RUNTIME_SOURCE="${ROOT}/Apps/Drive/product/EDPVaultRuntime.swift"
NATIVE_SYSTEM_SOURCE="${ROOT}/Apps/Drive/product/EDPNativeSystem.swift"
MACFUSE_POLICY_SOURCE="${ROOT}/Apps/Drive/product/EDPMacFUSERuntimePolicy.swift"
PUBLISHER_SOURCE="${ROOT}/Apps/Drive/product/EDPBlockDevicePublisher.swift"
POLICY_SOURCE="${ROOT}/Apps/Drive/product/EDPDevicePolicyStore.swift"
CREDENTIAL_SOURCE="${ROOT}/Apps/Drive/product/EDPCredentialStore.swift"
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
/usr/bin/grep -Fq 'Virtual:                   Yes' "${STORAGE_RUNNER}"

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
echo 'RESULT=DRIVE_SYSTEM_UPGRADE_UI_HANDOFF_OK'

# launchd defaults to a 10-second minimum runtime. The Drive daemon is explicitly
# user-stoppable and restartable, so both packaging modes must override that
# throttle without reintroducing KeepAlive/RunAtLoad semantics.
for plist in "${EMBEDDED_SERVICE_PLIST}" "${LEGACY_SERVICE_PLIST}"; do
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :ThrottleInterval' "${plist}")" == "1" ]]
  ! /usr/libexec/PlistBuddy -c 'Print :KeepAlive' "${plist}" >/dev/null 2>&1
  ! /usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "${plist}" >/dev/null 2>&1
done
echo 'RESULT=DRIVE_SYSTEM_SERVICE_RESTART_THROTTLE_OK'

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
echo 'RESULT=DRIVE_SYSTEM_ASYNC_BLOCK_PUBLISHER_OK'

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
echo 'RESULT=DRIVE_SYSTEM_NATIVE_RUNTIME_CONTROL_OK'

# Canonical top-level gates must remain wired and hardware-free by construction.
/usr/bin/grep -Fq 'drive-test-storage-smoke:' "${ROOT}/Makefile"
/usr/bin/grep -Fq 'EDP_STORAGE_PROFILE=smoke EDP_STORAGE_LOOP_COUNT=5' "${ROOT}/Makefile"
/usr/bin/grep -Fq 'drive-test-system:' "${ROOT}/Makefile"
/usr/bin/grep -Fq 'drive-test-all: drive-test-fast drive-test-virtual-usb drive-test-storage drive-test-ui drive-test-system' "${ROOT}/Makefile"

echo 'RESULT=DRIVE_SYSTEM_NO_SUDO_OK'
echo 'RESULT=DRIVE_SYSTEM_NO_PHYSICAL_RAW_OPEN_OK'
echo 'RESULT=DRIVE_SYSTEM_SYNTHETIC_WRITE_GUARD_OK'
echo 'RESULT=DRIVE_SYSTEM_ARCHITECTURE_RATCHETS_OK'
echo 'RESULT=DRIVE_SYSTEM_OK'
