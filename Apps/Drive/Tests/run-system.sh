#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TEST_ROOT="${ROOT}/Apps/Drive/Tests"
STORAGE_RUNNER="${TEST_ROOT}/run-storage.sh"
APP_SOURCE="${ROOT}/Apps/Drive/product/App/EDPUSBVaultApp.swift"
RUNTIME_SOURCE="${ROOT}/Apps/Drive/product/EDPVaultRuntime.swift"
POLICY_SOURCE="${ROOT}/Apps/Drive/product/EDPDevicePolicyStore.swift"
CREDENTIAL_SOURCE="${ROOT}/Apps/Drive/product/EDPCredentialStore.swift"

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
/usr/bin/grep -Fq 'assert_synthetic_device "$bsd" "$path"' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'diskutil eraseVolume "$filesystem" "$label" "$bsd"' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'backing escaped test root' "${STORAGE_RUNNER}"
/usr/bin/grep -Fq 'Virtual' "${STORAGE_RUNNER}"

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

# Canonical top-level gates must remain wired and hardware-free by construction.
/usr/bin/grep -Fq 'drive-test-system:' "${ROOT}/Makefile"
/usr/bin/grep -Fq 'drive-test-all: drive-test-fast drive-test-virtual-usb drive-test-storage drive-test-ui drive-test-system' "${ROOT}/Makefile"

echo 'RESULT=DRIVE_SYSTEM_NO_SUDO_OK'
echo 'RESULT=DRIVE_SYSTEM_NO_PHYSICAL_RAW_OPEN_OK'
echo 'RESULT=DRIVE_SYSTEM_SYNTHETIC_WRITE_GUARD_OK'
echo 'RESULT=DRIVE_SYSTEM_ARCHITECTURE_RATCHETS_OK'
echo 'RESULT=DRIVE_SYSTEM_OK'
