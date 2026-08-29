#!/bin/bash
set -euo pipefail

# Repeatable first-install acceptance harness for EDP Drive.
#
# Destructive scope is deliberately narrow:
# - EDP Drive installed app/runtime/state/receipts/credentials
# - macFUSE runtime and its per-user containers/settings
# - EDP embedded service FDA entry when factory-first-install mode is requested
#
# The cleanup commands refuse to run while any external physical disk is
# connected. They never format, partition, erase, or write raw disk sectors.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP="/Applications/EDP Drive.app"
OLD_APP="/Applications/EDP USB Vault.app"
OLD_RAW_ACCESS_APP="/Applications/EDP USB Vault Raw Access.app"
APP_BIN="${APP}/Contents/MacOS/EDP Drive"
SERVICE_BIN="${APP}/Contents/Library/LaunchServices/edp-drive-service"
PRODUCT_ROOT="/Library/Application Support/EDP USB Vault"
DATA_ROOT="/var/db/com.edp.usbvault"
LEGACY_PLIST="/Library/LaunchDaemons/com.edp.usbvault.mountd.plist"
MACFUSE_ROOT="/Library/Filesystems/macfuse.fs"
MACFUSE_PREFPANE="/Library/PreferencePanes/macFUSE.prefPane"
RAW_ACCESS_BUNDLE_ID="com.edp.usbvault.mountd.v2"
MACFUSE_GENERIC_ID="io.macfuse.app.fsmodule.macfuse"
MACFUSE_LOCAL_ID="io.macfuse.app.fsmodule.macfuse-local"
REPORT_ROOT="${EDP_ACCEPTANCE_REPORT_ROOT:-/Users/Shared/EDP USB Vault Acceptance}"
SESSION_POINTER="${REPORT_ROOT}/current-session"

fail() {
  echo "ERROR=$*" >&2
  exit 1
}

info() {
  echo "$*"
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || fail "this stage must be run with sudo"
}

require_non_root() {
  [[ "$(id -u)" -ne 0 ]] || fail "this stage must run as the logged-in user, not with sudo"
}

target_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s\n' "${SUDO_USER}"
  else
    /usr/bin/stat -f '%Su' /dev/console
  fi
}

target_uid() {
  /usr/bin/id -u "$(target_user)"
}

target_home() {
  /usr/bin/dscl . -read "/Users/$(target_user)" NFSHomeDirectory 2>/dev/null \
    | /usr/bin/awk '{print $2}'
}

as_target_user() {
  local user uid
  user="$(target_user)"
  uid="$(target_uid)"
  if [[ "$(id -u)" -eq 0 ]]; then
    /bin/launchctl asuser "${uid}" /usr/bin/sudo -u "${user}" "$@"
  else
    "$@"
  fi
}

ensure_report_root() {
  [[ ! -L "${REPORT_ROOT}" ]] || fail "acceptance report root must not be a symlink: ${REPORT_ROOT}"
  /bin/mkdir -p "${REPORT_ROOT}"
  /bin/chmod 0700 "${REPORT_ROOT}"
  if [[ "$(id -u)" -eq 0 ]]; then
    /usr/sbin/chown "$(target_user)" "${REPORT_ROOT}"
  fi
}

start_session() {
  ensure_report_root
  local id dir
  id="$(/bin/date -u '+%Y%m%dT%H%M%SZ')-$$"
  dir="${REPORT_ROOT}/${id}"
  [[ ! -L "${SESSION_POINTER}" ]] || fail "acceptance session pointer must not be a symlink"
  /bin/mkdir -p "${dir}"
  /bin/chmod 0700 "${dir}"
  /usr/bin/printf '%s\n' "${id}" > "${SESSION_POINTER}"
  /usr/bin/printf 'SESSION_ID=%s\nSTARTED_AT_UTC=%s\n' \
    "${id}" "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" > "${dir}/session.env"
  if [[ "$(id -u)" -eq 0 ]]; then
    /usr/sbin/chown "$(target_user)" "${SESSION_POINTER}" "${dir}" "${dir}/session.env"
  fi
  echo "ACCEPTANCE_SESSION=${id}"
  echo "REPORT_DIR=${dir}"
}

session_dir() {
  ensure_report_root
  [[ ! -L "${SESSION_POINTER}" ]] || fail "acceptance session pointer must not be a symlink"
  if [[ ! -f "${SESSION_POINTER}" ]]; then
    start_session >/dev/null
  fi
  local id
  id="$(/bin/cat "${SESSION_POINTER}")"
  [[ "${id}" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || fail "invalid acceptance session pointer"
  /bin/mkdir -p "${REPORT_ROOT}/${id}"
  /bin/chmod 0700 "${REPORT_ROOT}/${id}"
  printf '%s\n' "${REPORT_ROOT}/${id}"
}

record() {
  local dir
  dir="$(session_dir)"
  /usr/bin/printf '%s\t%s\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" \
    >> "${dir}/results.log"
}

assert_no_external_physical_disk() {
  local output
  output="$(/usr/sbin/diskutil list external physical 2>&1 || true)"
  if /usr/bin/printf '%s\n' "${output}" | /usr/bin/grep -Eq '^/dev/disk[0-9]+'; then
    /usr/bin/printf '%s\n' "${output}" >&2
    fail "external physical disk detected; physically remove all USB disks before cleanup"
  fi
  echo "RESULT=NO_EXTERNAL_PHYSICAL_DISK"
}

assert_no_mounted_macfuse_volume() {
  if /sbin/mount | /usr/bin/grep -Eiq 'macfuse|EDP .* Transport'; then
    /sbin/mount | /usr/bin/grep -Ei 'macfuse|EDP .* Transport' >&2 || true
    fail "macFUSE/EDP transport volume is still mounted"
  fi
  echo "RESULT=NO_MACFUSE_OR_EDP_TRANSPORT_MOUNT"
}

assert_user_keychain_safe() {
  local default search
  default="$(as_target_user /usr/bin/security default-keychain -d user 2>/dev/null || true)"
  search="$(as_target_user /usr/bin/security list-keychains -d user 2>/dev/null || true)"
  [[ "${default}" == *"login.keychain"* ]] \
    || fail "user DefaultKeychain is not login.keychain: ${default}"
  if /usr/bin/printf '%s\n%s\n' "${default}" "${search}" \
      | /usr/bin/grep -Eiq '/private/tmp/edp-|edp-acceptance.*keychain'; then
    fail "temporary EDP signing keychain is still present in user keychain state"
  fi
  echo "DEFAULT_KEYCHAIN=${default}"
  echo "RESULT=USER_KEYCHAIN_STATE_SAFE"
}

capture_host_baseline() {
  local dir
  dir="$(session_dir)"
  {
    echo "TIMESTAMP_UTC=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
    /usr/bin/sw_vers
    echo "USER=$(target_user)"
    echo "UID=$(target_uid)"
    as_target_user /usr/bin/security default-keychain -d user 2>/dev/null || true
    as_target_user /usr/bin/security list-keychains -d user 2>/dev/null || true
    /usr/sbin/diskutil list external physical 2>&1 || true
    /sbin/mount
    /usr/sbin/pkgutil --pkgs | /usr/bin/grep -Ei '^(com\.edp\.usbvault|io\.macfuse)' || true
  } > "${dir}/host-baseline.txt"
  echo "RESULT=HOST_BASELINE_CAPTURED"
}

preflight() {
  start_session
  assert_no_external_physical_disk
  assert_no_mounted_macfuse_volume
  assert_user_keychain_safe
  capture_host_baseline
  record "PRECHECK PASS"
  echo "RESULT=FIRST_INSTALL_PREFLIGHT_OK"
}

remove_fskit_module_preferences() {
  require_non_root
  local home settings
  home="$(target_home)"
  settings="${home}/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist"

  /usr/bin/pluginkit -e ignore -i "${MACFUSE_GENERIC_ID}" >/dev/null 2>&1 || true
  /usr/bin/pluginkit -e ignore -i "${MACFUSE_LOCAL_ID}" >/dev/null 2>&1 || true

  if [[ -f "${settings}" && -x /usr/bin/python3 ]]; then
    SETTINGS_PATH="${settings}" \
    MODULE_A="${MACFUSE_GENERIC_ID}" \
    MODULE_B="${MACFUSE_LOCAL_ID}" \
    /usr/bin/python3 -c '
import os, plistlib
p=os.environ["SETTINGS_PATH"]
with open(p,"rb") as f: value=plistlib.load(f)
if isinstance(value,list):
    blocked={os.environ["MODULE_A"],os.environ["MODULE_B"]}
    value=[x for x in value if x not in blocked]
    with open(p,"wb") as f: plistlib.dump(value,f,fmt=plistlib.FMT_XML,sort_keys=False)
' || true
  fi

  /bin/rm -rf \
    "${home}/Library/Group Containers/3T5GSNBU6W.io.macfuse.app" \
    "${home}/Library/Containers/io.macfuse.app" \
    "${home}/Library/Containers/io.macfuse.app.fsmodule.macfuse" \
    "${home}/Library/Containers/io.macfuse.app.fsmodule.macfuse-local"
}

assert_user_cleanup_state_clean() {
  local home settings path
  home="$(target_home)"
  settings="${home}/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist"

  for path in \
    "${home}/Library/Group Containers/3T5GSNBU6W.io.macfuse.app" \
    "${home}/Library/Containers/io.macfuse.app" \
    "${home}/Library/Containers/io.macfuse.app.fsmodule.macfuse" \
    "${home}/Library/Containers/io.macfuse.app.fsmodule.macfuse-local" \
    "${home}/Library/Preferences/com.edp.usbvault.app.plist" \
    "${home}/Library/Caches/com.edp.usbvault.app" \
    "${home}/Library/Saved Application State/com.edp.usbvault.app.savedState"; do
    [[ ! -e "${path}" ]] || fail "user cleanup still contains ${path}"
  done

  if [[ -f "${settings}" ]] \
     && /usr/bin/plutil -p "${settings}" 2>/dev/null \
       | /usr/bin/grep -Eq "${MACFUSE_GENERIC_ID}|${MACFUSE_LOCAL_ID}"; then
    fail "macFUSE FSKit module enablement remains in the logged-in user's settings"
  fi
  echo "RESULT=USER_TCC_SCOPED_STATE_CLEAN"
}

user_cleanup_marker() {
  printf '%s/user-cleanup.done\n' "$(session_dir)"
}

assert_user_cleanup_prepared() {
  local marker expected
  marker="$(user_cleanup_marker)"
  [[ ! -L "${marker}" ]] || fail "user cleanup marker must not be a symlink"
  [[ -f "${marker}" ]] || fail "run '$0 user-cleanup' as the logged-in user before the sudo cleanup stage"
  expected="USER_CLEANUP_UID=$(target_uid)"
  /usr/bin/grep -Fxq "${expected}" "${marker}" \
    || fail "user cleanup marker does not match the current console user"
  echo "RESULT=USER_CLEANUP_PREPARED"
}

user_cleanup() {
  require_non_root
  assert_no_external_physical_disk
  assert_no_mounted_macfuse_volume
  assert_user_keychain_safe

  remove_fskit_module_preferences

  local home marker
  home="$(target_home)"
  /bin/rm -f "${home}/Library/Preferences/com.edp.usbvault.app.plist"
  /bin/rm -rf "${home}/Library/Caches/com.edp.usbvault.app"
  /bin/rm -rf "${home}/Library/Saved Application State/com.edp.usbvault.app.savedState"

  assert_user_cleanup_state_clean
  marker="$(user_cleanup_marker)"
  /usr/bin/printf 'USER_CLEANUP_UID=%s\nCOMPLETED_AT_UTC=%s\n' \
    "$(target_uid)" "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" > "${marker}"
  /bin/chmod 0600 "${marker}"
  record "USER_CLEANUP PASS"
  echo "RESULT=USER_TCC_SCOPED_STATE_REMOVED"
}

forget_scoped_receipts() {
  local receipt
  while IFS= read -r receipt; do
    [[ -n "${receipt}" ]] || continue
    /usr/sbin/pkgutil --forget "${receipt}" >/dev/null 2>&1 || true
  done < <(/usr/sbin/pkgutil --pkgs \
    | /usr/bin/grep -E '^(com\.edp\.usbvault|io\.macfuse)' || true)
}

remove_edp_system_keychain_credentials() {
  local service
  for service in \
    com.edp.usbvault.partition-password.v4 \
    com.edp.usbvault.device-password.v3 \
    com.edp.usbvault.device-password; do
    /usr/bin/security delete-generic-password -s "${service}" \
      /Library/Keychains/System.keychain >/dev/null 2>&1 || true
  done
}

reset_edp_fda() {
  local user uid
  user="$(target_user)"
  uid="$(target_uid)"
  /bin/launchctl asuser "${uid}" /usr/bin/sudo -u "${user}" \
    /usr/bin/tccutil reset SystemPolicyAllFiles "${RAW_ACCESS_BUNDLE_ID}" \
    >/dev/null 2>&1 || fail "tccutil could not reset EDP service Full Disk Access"
  echo "RESULT=EDP_SERVICE_FDA_RESET"
}

uninstall_macfuse() {
  local uninstaller
  uninstaller="${MACFUSE_ROOT}/Contents/Resources/uninstall_macfuse.app/Contents/Resources/Scripts/uninstall_macfuse.sh"
  if [[ -f "${uninstaller}" ]]; then
    /bin/bash "${uninstaller}" >/dev/null 2>&1 || true
  fi

  /bin/rm -rf "${MACFUSE_ROOT}" "${MACFUSE_PREFPANE}"
  /bin/rm -f /Library/LaunchDaemons/io.macfuse.* 2>/dev/null || true
}

clean_common() {
  require_root
  assert_no_external_physical_disk
  assert_no_mounted_macfuse_volume
  assert_user_keychain_safe
  assert_user_cleanup_prepared

  if [[ -x "${PRODUCT_ROOT}/bin/edp-vaultctl" ]]; then
    "${PRODUCT_ROOT}/bin/edp-vaultctl" cleanup >/dev/null 2>&1 || true
  fi

  /bin/launchctl bootout system/com.edp.usbvault.mountd >/dev/null 2>&1 || true
  /bin/launchctl bootout system/com.edp.usbvault.mountd.v2 >/dev/null 2>&1 || true
  /usr/bin/pkill -f '/Applications/EDP Drive.app/Contents/MacOS/EDP Drive' \
    >/dev/null 2>&1 || true
  /usr/bin/pkill -f '/Applications/EDP Drive.app/Contents/Library/LaunchServices/edp-drive-service' \
    >/dev/null 2>&1 || true

  /bin/rm -rf \
    "${APP}" \
    "${OLD_APP}" \
    "${OLD_RAW_ACCESS_APP}" \
    "${PRODUCT_ROOT}" \
    "${DATA_ROOT}"
  /bin/rm -f "${LEGACY_PLIST}"

  remove_edp_system_keychain_credentials
  uninstall_macfuse
  forget_scoped_receipts

  assert_user_keychain_safe
  echo "RESULT=EDP_AND_MACFUSE_INSTALLED_STATE_REMOVED"
}

clean_install() {
  clean_common
  record "CLEAN_INSTALL PASS (FDA preserved)"
  echo "RESULT=CLEAN_INSTALL_BASELINE_READY"
}

factory_first_install() {
  require_root
  assert_no_external_physical_disk
  assert_user_keychain_safe
  # Reset while the helper bundle still exists when possible, so TCC can resolve
  # the exact bundle identity. This is the only TCC mutation and uses tccutil.
  reset_edp_fda
  clean_common
  record "FACTORY_FIRST_INSTALL_CLEAN PASS (FDA reset)"
  echo "RESULT=FACTORY_FIRST_INSTALL_BASELINE_READY"
}

verify_clean() {
  require_non_root
  assert_no_external_physical_disk
  assert_no_mounted_macfuse_volume
  assert_user_keychain_safe
  assert_user_cleanup_state_clean

  local path
  for path in "${APP}" "${OLD_APP}" "${OLD_RAW_ACCESS_APP}" "${PRODUCT_ROOT}" "${DATA_ROOT}" \
              "${LEGACY_PLIST}" "${MACFUSE_ROOT}" "${MACFUSE_PREFPANE}"; do
    [[ ! -e "${path}" ]] || fail "clean baseline still contains ${path}"
  done

  if /bin/launchctl print system/com.edp.usbvault.mountd >/dev/null 2>&1; then
    fail "legacy EDP LaunchDaemon is still loaded"
  fi
  if /bin/launchctl print system/com.edp.usbvault.mountd.v2 >/dev/null 2>&1; then
    fail "v2 EDP LaunchDaemon is still loaded"
  fi
  if /usr/sbin/pkgutil --pkgs | /usr/bin/grep -Eq '^(com\.edp\.usbvault|io\.macfuse)'; then
    /usr/sbin/pkgutil --pkgs | /usr/bin/grep -E '^(com\.edp\.usbvault|io\.macfuse)' >&2 || true
    fail "EDP/macFUSE package receipts remain"
  fi

  record "VERIFY_CLEAN PASS"
  echo "RESULT=FACTORY_CLEAN_BASELINE_VERIFIED"
  echo "NEXT=REBOOT_MAC_BEFORE_INSTALL"
}

install_package() {
  require_root
  local pkg="${1:-}"
  [[ -n "${pkg}" && -f "${pkg}" ]] || fail "usage: sudo $0 install /path/to/EDP-USB-Vault-*.pkg"
  assert_no_external_physical_disk
  assert_user_keychain_safe

  "${REPO_ROOT}/scripts/verify-clean-installer.sh" "${pkg}"
  /usr/sbin/installer -pkg "${pkg}" -target /
  record "INSTALL PASS package=${pkg} sha256=$(/usr/bin/shasum -a 256 "${pkg}" | /usr/bin/awk '{print $1}')"
  echo "RESULT=ACCEPTANCE_PACKAGE_INSTALLED"
}

verify_installed() {
  assert_no_external_physical_disk
  assert_user_keychain_safe

  [[ -x "${APP_BIN}" ]] || fail "EDP Drive app is not installed"
  [[ -x "${SERVICE_BIN}" ]] || fail "embedded EDP Drive service is not installed"
  [[ ! -e "${OLD_APP}" && ! -e "${OLD_RAW_ACCESS_APP}" ]] \
    || fail "obsolete EDP application bundle remains installed"
  [[ -d "${MACFUSE_ROOT}" ]] || fail "macFUSE runtime is not installed"
  [[ -x "${PRODUCT_ROOT}/bin/edp-mfmount-local-readwrite" ]] \
    || fail "macFUSE Local EDP transport is missing"

  /usr/bin/codesign --verify --strict "${APP}"
  /usr/bin/codesign --verify --strict "${SERVICE_BIN}"
  /usr/bin/codesign --verify --strict "${PRODUCT_ROOT}/bin/edp-mfmount-local-readwrite"

  local app_version
  app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist")"

  if ! /bin/launchctl print system/com.edp.usbvault.mountd >/dev/null 2>&1 \
     && ! /bin/launchctl print system/com.edp.usbvault.mountd.v2 >/dev/null 2>&1; then
    fail "EDP LaunchDaemon is not loaded"
  fi

  "${APP_BIN}" --xpc-smoke
  "${APP_BIN}" --xpc-snapshot
  record "VERIFY_INSTALLED PASS version=${app_version}"
  echo "RESULT=FRESH_INSTALL_RUNTIME_VERIFIED"
  echo "NEXT=RUN '$0 open-fda', GRANT FDA ONCE, THEN INSERT EDP USB"
}

open_fda() {
  [[ -x "${SERVICE_BIN}" ]] || fail "embedded EDP Drive service is not installed"
  as_target_user /usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles'
  as_target_user /usr/bin/open -R "${APP}"
  record "FDA_SETTINGS_OPENED"
  echo "RESULT=FDA_SETTINGS_OPENED"
}

snapshot_text() {
  [[ -x "${APP_BIN}" ]] || fail "EDP app is not installed"
  "${APP_BIN}" --xpc-snapshot
}

single_connected_device_id() {
  local snapshot lines count line
  snapshot="$(snapshot_text)"
  lines="$(/usr/bin/printf '%s\n' "${snapshot}" \
    | /usr/bin/grep '^SNAPSHOT_DEVICE=' \
    | /usr/bin/grep 'privilegedAccessReady=true' || true)"
  count="$(/usr/bin/printf '%s\n' "${lines}" | /usr/bin/grep -c '^SNAPSHOT_DEVICE=' || true)"
  [[ "${count}" -eq 1 ]] || {
    /usr/bin/printf '%s\n' "${snapshot}" >&2
    fail "expected exactly one connected EDP device with FDA raw access; found ${count}"
  }
  line="$(/usr/bin/printf '%s\n' "${lines}" | /usr/bin/head -1)"
  /usr/bin/printf '%s\n' "${line}" | /usr/bin/cut -d'|' -f2
}

verify_fda_device() {
  local expected_vidpid="${1:-}"
  local physical snapshot device_id
  physical="$(/usr/sbin/diskutil list external physical 2>&1 || true)"
  if ! /usr/bin/printf '%s\n' "${physical}" | /usr/bin/grep -Eq '^/dev/disk[0-9]+'; then
    fail "no external physical disk is connected"
  fi

  snapshot="$(snapshot_text)"
  /usr/bin/printf '%s\n' "${snapshot}"
  if [[ -n "${expected_vidpid}" ]] \
     && ! /usr/bin/printf '%s\n' "${snapshot}" | /usr/bin/grep -Fq "|${expected_vidpid}|"; then
    fail "connected EDP device does not match expected VID:PID ${expected_vidpid}"
  fi
  device_id="$(single_connected_device_id)"
  record "FDA_DEVICE_READY device=${device_id} expected_vidpid=${expected_vidpid:-any}"
  echo "DEVICE_ID=${device_id}"
  echo "RESULT=FDA_RETAINED_RAW_ACCESS_READY"
}

mountpoint_for_type() {
  case "${1}" in
    1) printf '%s\n' '/Volumes/启动区' ;;
    2) printf '%s\n' '/Volumes/交换区' ;;
    4) printf '%s\n' '/Volumes/保密区' ;;
    *) fail "partition type must be 1, 2, or 4" ;;
  esac
}

wait_for_path_state() {
  local path="${1}" wanted="${2}" i
  for i in $(/usr/bin/seq 1 30); do
    if [[ "${wanted}" == "present" && -d "${path}" ]]; then return 0; fi
    if [[ "${wanted}" == "absent" && ! -d "${path}" ]]; then return 0; fi
    /bin/sleep 1
  done
  fail "timed out waiting for ${path} to become ${wanted}"
}

mount_partition() {
  local type="${1:-}" device_id="${2:-}"
  [[ "${type}" =~ ^(1|2|4)$ && -n "${device_id}" ]] \
    || fail "usage: $0 mount {1|2|4} DEVICE_ID"
  "${APP_BIN}" --xpc-mount-smoke "${type}" "${device_id}"
  wait_for_path_state "$(mountpoint_for_type "${type}")" present
  echo "RESULT=PARTITION_${type}_MOUNTED"
}

unmount_partition() {
  local type="${1:-}" device_id="${2:-}"
  [[ "${type}" =~ ^(1|2|4)$ && -n "${device_id}" ]] \
    || fail "usage: $0 unmount {1|2|4} DEVICE_ID"
  "${APP_BIN}" --xpc-unmount-smoke "${type}" "${device_id}"
  wait_for_path_state "$(mountpoint_for_type "${type}")" absent
  echo "RESULT=PARTITION_${type}_UNMOUNTED"
}

functional_partition() {
  local type="${1}" device_id="${2}" mountpoint marker content before after
  mountpoint="$(mountpoint_for_type "${type}")"
  marker="${mountpoint}/.edp-acceptance-$(/bin/cat "${SESSION_POINTER}" 2>/dev/null || echo session)-p${type}.txt"
  content="EDP-FIRST-INSTALL-ACCEPTANCE:$type:$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ'):$(/usr/bin/uuidgen)"

  mount_partition "${type}" "${device_id}"
  [[ ! -e "${marker}" ]] || fail "acceptance marker unexpectedly already exists: ${marker}"
  /usr/bin/printf '%s\n' "${content}" > "${marker}"
  /bin/sync
  before="$(/usr/bin/shasum -a 256 "${marker}" | /usr/bin/awk '{print $1}')"
  [[ -n "${before}" ]] || fail "could not hash partition ${type} acceptance marker"

  unmount_partition "${type}" "${device_id}"
  mount_partition "${type}" "${device_id}"
  [[ -f "${marker}" ]] || fail "partition ${type} marker did not persist across remount"
  after="$(/usr/bin/shasum -a 256 "${marker}" | /usr/bin/awk '{print $1}')"
  [[ "${before}" == "${after}" ]] || fail "partition ${type} marker hash changed across remount"
  /bin/rm -f "${marker}"
  /bin/sync
  unmount_partition "${type}" "${device_id}"

  record "PARTITION_${type}_RW_PERSISTENCE PASS sha256=${before}"
  echo "RESULT=PARTITION_${type}_RW_PERSISTENCE_OK"
}

credential_checkpoint() {
  local device_id="${1:-}" snapshot
  [[ -n "${device_id}" ]] || device_id="$(single_connected_device_id)"
  snapshot="$(snapshot_text)"

  local type expected
  for type in 1 2 4; do
    expected="saved"
    [[ "${type}" == "1" ]] && expected="notRequired"
    if ! /usr/bin/printf '%s\n' "${snapshot}" \
        | /usr/bin/grep -F "SNAPSHOT_PARTITION=${device_id}|type=${type}|" \
        | /usr/bin/grep -Fq "|credential=${expected}|"; then
      /usr/bin/printf '%s\n' "${snapshot}" >&2
      if [[ "${type}" == "2" || "${type}" == "4" ]]; then
        fail "partition ${type} credential is not saved; use the App UI to validate/save the real password, then rerun credential-checkpoint. Passwords must never be passed to this script or written to logs."
      fi
      fail "boot partition credential status is not notRequired"
    fi
  done

  record "CREDENTIAL_CHECKPOINT PASS device=${device_id}"
  echo "RESULT=PARTITION_CREDENTIAL_CHECKPOINT_OK"
}

policy_smoke() {
  local device_id="${1:-}"
  [[ -n "${device_id}" ]] || device_id="$(single_connected_device_id)"
  "${APP_BIN}" --xpc-policy-smoke "${device_id}"
  record "POLICY_SMOKE PASS device=${device_id}"
  echo "RESULT=DEVICE_POLICY_ROUNDTRIP_RESTORE_OK"
}

functional_all() {
  local device_id="${1:-}"
  [[ -n "${device_id}" ]] || device_id="$(single_connected_device_id)"
  assert_user_keychain_safe
  credential_checkpoint "${device_id}"
  functional_partition 1 "${device_id}"
  functional_partition 2 "${device_id}"
  functional_partition 4 "${device_id}"
  record "ALL_THREE_PARTITIONS PASS device=${device_id}"
  echo "RESULT=ALL_THREE_PARTITIONS_RW_PERSISTENCE_OK"
}

safe_eject() {
  local device_id="${1:-}"
  [[ -n "${device_id}" ]] || device_id="$(single_connected_device_id)"
  "${APP_BIN}" --xpc-eject-smoke "${device_id}"
  /bin/sleep 3
  local snapshot
  snapshot="$(snapshot_text)"
  if /usr/bin/printf '%s\n' "${snapshot}" | /usr/bin/grep -F "|${device_id}|" \
       | /usr/bin/grep -q 'privilegedAccessReady=true'; then
    /usr/bin/printf '%s\n' "${snapshot}" >&2
    fail "raw access was reacquired after safe eject"
  fi
  for path in '/Volumes/启动区' '/Volumes/交换区' '/Volumes/保密区'; do
    [[ ! -d "${path}" ]] || fail "volume remained mounted after safe eject: ${path}"
  done
  record "SAFE_EJECT PASS device=${device_id}"
  echo "RESULT=SAFE_EJECT_SUPPRESSION_OK"
  echo "NEXT=PHYSICALLY_UNPLUG_USB_THEN_REINSERT_AND_RUN verify-fda-device"
}

restart_app() {
  [[ -x "${APP_BIN}" ]] || fail "EDP app is not installed"
  /usr/bin/pkill -f '/Applications/EDP Drive.app/Contents/MacOS/EDP Drive' >/dev/null 2>&1 || true
  /bin/sleep 1
  as_target_user /usr/bin/open -a 'EDP Drive'
  /bin/sleep 3
  "${APP_BIN}" --xpc-smoke
  assert_user_keychain_safe
  record "APP_RESTART PASS"
  echo "RESULT=APP_RESTART_OK"
}

restart_daemon() {
  require_root
  if /bin/launchctl print system/com.edp.usbvault.mountd >/dev/null 2>&1; then
    /bin/launchctl kickstart -k system/com.edp.usbvault.mountd
  elif /bin/launchctl print system/com.edp.usbvault.mountd.v2 >/dev/null 2>&1; then
    /bin/launchctl kickstart -k system/com.edp.usbvault.mountd.v2
  else
    fail "EDP daemon is not loaded"
  fi
  /bin/sleep 3
  "${APP_BIN}" --xpc-smoke
  assert_user_keychain_safe
  record "DAEMON_RESTART PASS"
  echo "RESULT=DAEMON_RESTART_OK"
}

final_check() {
  assert_user_keychain_safe
  [[ -x "${APP_BIN}" ]] || fail "EDP app missing at final check"
  [[ -d "${MACFUSE_ROOT}" ]] || fail "macFUSE missing at final check"
  "${APP_BIN}" --xpc-smoke
  "${APP_BIN}" --xpc-snapshot
  record "FINAL_CHECK PASS"
  echo "RESULT=FIRST_INSTALL_FULL_ACCEPTANCE_BASELINE_OK"
}

usage() {
  cat <<'EOF'
EDP USB Vault first-install acceptance

Stages:
  preflight
      Refuse cleanup if a physical USB disk is connected; capture host/keychain baseline.

  user-cleanup
      Remove TCC-protected per-user EDP/macFUSE container, preference, cache, and FSKit enablement state.
      Must run as the logged-in user before either sudo cleanup stage.

  factory-first-install        (sudo)
      Require completed user-cleanup, reset only EDP Raw Access FDA, then remove system EDP + macFUSE + EDP credentials/state.

  clean-install               (sudo)
      Same installed-state cleanup but preserve FDA for reinstall/upgrade continuity tests.

  verify-clean
      Assert the first-install baseline is clean. Reboot after this stage.

  install /path/to/pkg        (sudo)
      Verify the package, then install it.

  verify-installed
      Verify App/helper/macFUSE/daemon/code signatures/XPC with no USB connected.

  open-fda
      Open Full Disk Access settings and reveal the Raw Access helper.

  verify-fda-device [VID:PID]
      With one EDP USB inserted, require privilegedAccessReady=true.

  credential-checkpoint [DEVICE_ID]
      Require boot=notRequired and exchange/secret=saved. Real passwords stay in the App UI/System Keychain.

  policy-smoke [DEVICE_ID]
      Round-trip device name/global automount/three partition automount policies, then restore original values.

  mount {1|2|4} DEVICE_ID
  unmount {1|2|4} DEVICE_ID

  functional-all [DEVICE_ID]
      Normal filesystem read/write/remount persistence test for boot/exchange/secret.
      Runs credential-checkpoint before any write test.

  safe-eject [DEVICE_ID]
      XPC safe eject; verify volumes and retained raw access stay suppressed.

  restart-app
  restart-daemon              (sudo)
  final-check

Canonical first-install order:
  1. preflight
  2. user-cleanup
  3. sudo factory-first-install
  4. verify-clean
  5. reboot Mac
  6. verify-clean
  7. sudo install <pkg>
  8. verify-installed
  9. open-fda -> user grants EDP Raw Access FDA exactly once
 10. insert real EDP USB
 11. verify-fda-device [VID:PID]
 12. save exchange/secret credentials once in UI (never pass passwords to this script)
 13. credential-checkpoint
 14. policy-smoke
 15. functional-all
 16. safe-eject -> physically unplug -> reinsert -> verify-fda-device
 17. restart-app -> verify-fda-device
 18. sudo restart-daemon -> physically reinsert if raw lease cannot be reacquired -> verify-fda-device
 19. reboot Mac -> verify-fda-device -> credential-checkpoint -> policy-smoke -> functional-all
 20. final-check
EOF
}

command="${1:-}"
case "${command}" in
  preflight) preflight ;;
  user-cleanup) user_cleanup ;;
  factory-first-install) factory_first_install ;;
  clean-install) clean_install ;;
  verify-clean) verify_clean ;;
  install) shift; install_package "${1:-}" ;;
  verify-installed) verify_installed ;;
  open-fda) open_fda ;;
  verify-fda-device) shift; verify_fda_device "${1:-}" ;;
  credential-checkpoint) shift; credential_checkpoint "${1:-}" ;;
  policy-smoke) shift; policy_smoke "${1:-}" ;;
  mount) shift; mount_partition "${1:-}" "${2:-}" ;;
  unmount) shift; unmount_partition "${1:-}" "${2:-}" ;;
  functional-all) shift; functional_all "${1:-}" ;;
  safe-eject) shift; safe_eject "${1:-}" ;;
  restart-app) restart_app ;;
  restart-daemon) restart_daemon ;;
  final-check) final_check ;;
  -h|--help|help|'') usage ;;
  *) usage; fail "unknown stage: ${command}" ;;
esac
