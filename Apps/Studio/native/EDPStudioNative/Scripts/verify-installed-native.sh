#!/bin/bash
set -euo pipefail

APP="/Applications/EDP Studio.app"
APP_BIN="${APP}/Contents/MacOS/EDP Studio"
BROKER="/Library/PrivilegedHelperTools/com.edp.studio.rawbroker"
PLIST="/Library/LaunchDaemons/com.edp.studio.rawbroker.plist"
LEAF_SHA1="040b5488fb2b6c02b0786e76b674cb4460658ca2"
APP_ID="com.edp.studio"
BROKER_ID="com.edp.studio.rawbroker"
APP_REQUIREMENT="identifier \"${APP_ID}\" and certificate leaf = H\"${LEAF_SHA1}\""
BROKER_REQUIREMENT="identifier \"${BROKER_ID}\" and certificate leaf = H\"${LEAF_SHA1}\""

fail() {
  echo "ERROR=$*" >&2
  exit 1
}

[[ -d "${APP}" && ! -L "${APP}" ]] || fail "installed App missing or symlinked: ${APP}"
[[ -f "${APP_BIN}" && ! -L "${APP_BIN}" ]] || fail "installed App executable missing or symlinked"
[[ -f "${BROKER}" && ! -L "${BROKER}" ]] || fail "installed Raw Broker missing or symlinked"
[[ -f "${PLIST}" && ! -L "${PLIST}" ]] || fail "installed LaunchDaemon plist missing or symlinked"

/usr/bin/codesign --verify --strict -R="${APP_REQUIREMENT}" "${APP}"
/usr/bin/codesign --verify --strict -R="${BROKER_REQUIREMENT}" "${BROKER}"

[[ "$(/usr/bin/stat -f '%Su:%Sg' "${BROKER}")" == "root:wheel" ]] \
  || fail "Raw Broker must be root:wheel"
[[ "$(/usr/bin/stat -f '%Lp' "${BROKER}")" == "755" ]] \
  || fail "Raw Broker mode must be 0755"
[[ "$(/usr/bin/stat -f '%Su:%Sg' "${PLIST}")" == "root:wheel" ]] \
  || fail "LaunchDaemon plist must be root:wheel"
[[ "$(/usr/bin/stat -f '%Lp' "${PLIST}")" == "644" ]] \
  || fail "LaunchDaemon plist mode must be 0644"

APP_MODE="$(/usr/bin/stat -f '%Lp' "${APP_BIN}")"
if (( (8#${APP_MODE} & 022) != 0 )); then
  fail "installed App executable must not be group/world writable: mode=${APP_MODE}"
fi

/usr/bin/plutil -lint "${PLIST}" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "${PLIST}")" == "${BROKER_ID}" ]] \
  || fail "LaunchDaemon label mismatch"
[[ "$(/usr/libexec/PlistBuddy -c "Print :MachServices:${BROKER_ID}" "${PLIST}")" == "true" ]] \
  || fail "LaunchDaemon Mach service mismatch"
/bin/launchctl print system/com.edp.studio.rawbroker >/dev/null \
  || fail "Raw Broker LaunchDaemon is not bootstrapped"

if /usr/bin/codesign -dv --verbose=4 "${APP}" 2>&1 | /usr/bin/grep -Fq 'TeamIdentifier=W82WPH8HY7'; then
  fail "installed App still uses retired Apple Development Team ID"
fi
if /usr/bin/codesign -dv --verbose=4 "${BROKER}" 2>&1 | /usr/bin/grep -Fq 'TeamIdentifier=W82WPH8HY7'; then
  fail "installed Raw Broker still uses retired Apple Development Team ID"
fi

[[ ! -e "/Applications/EDPOpen.app" ]] || fail "retired EDPOpen.app still exists"
[[ ! -e "/Library/PrivilegedHelperTools/com.evolution404.edpopen.rawbroker" ]] \
  || fail "retired EDPOpen Raw Broker still exists"
[[ ! -e "/Library/LaunchDaemons/com.evolution404.edpopen.rawbroker.plist" ]] \
  || fail "retired EDPOpen LaunchDaemon still exists"

echo "RESULT=EDP_STUDIO_INSTALLED_SHARED_SIGNING_TRUST_OK"
