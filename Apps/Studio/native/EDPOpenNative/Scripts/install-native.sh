#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIGURATION="${EDPSTUDIO_CONFIGURATION:-${EDPOPEN_CONFIGURATION:-Release}}"
DERIVED_DATA="${EDPSTUDIO_DERIVED_DATA:-${EDPOPEN_DERIVED_DATA:-/private/tmp/edp-studio-native-derived-data}}"
APP_SOURCE="${EDPSTUDIO_APP_SOURCE:-${EDPOPEN_APP_SOURCE:-${DERIVED_DATA}/Build/Products/${CONFIGURATION}/EDP Studio.app}}"
BROKER_SOURCE="${EDPSTUDIO_BROKER_SOURCE:-${EDPOPEN_BROKER_SOURCE:-${DERIVED_DATA}/Build/Products/${CONFIGURATION}/EDPStudioRawBroker}}"
APP_DEST="/Applications/EDP Studio.app"
BROKER_DEST="/Library/PrivilegedHelperTools/com.edp.studio.rawbroker"
PLIST_SOURCE="${PROJECT_ROOT}/Installer/com.edp.studio.rawbroker.plist"
PLIST_DEST="/Library/LaunchDaemons/com.edp.studio.rawbroker.plist"
SERVICE="system/com.edp.studio.rawbroker"
OLD_APP="/Applications/EDPOpen.app"
OLD_BROKER="/Library/PrivilegedHelperTools/com.evolution404.edpopen.rawbroker"
OLD_PLIST="/Library/LaunchDaemons/com.evolution404.edpopen.rawbroker.plist"
OLD_SERVICE="system/com.evolution404.edpopen.rawbroker"
LEAF_SHA1="040b5488fb2b6c02b0786e76b674cb4460658ca2"
APP_REQUIREMENT="identifier \"com.edp.studio\" and certificate leaf = H\"${LEAF_SHA1}\""
BROKER_REQUIREMENT="identifier \"com.edp.studio.rawbroker\" and certificate leaf = H\"${LEAF_SHA1}\""

fail() {
  echo "ERROR=$*" >&2
  exit 1
}

[[ "$(/usr/bin/id -u)" -eq 0 ]] || fail "install-native.sh must run with sudo after a non-root signed build"
[[ -d "${APP_SOURCE}" && ! -L "${APP_SOURCE}" ]] || fail "built App missing or symlinked: ${APP_SOURCE}"
[[ -f "${BROKER_SOURCE}" && ! -L "${BROKER_SOURCE}" ]] || fail "built Raw Broker missing or symlinked: ${BROKER_SOURCE}"
[[ -f "${PLIST_SOURCE}" && ! -L "${PLIST_SOURCE}" ]] || fail "LaunchDaemon plist missing or symlinked: ${PLIST_SOURCE}"

# Root installation never signs code and therefore never needs access to the user's
# signing private key. It only accepts products already signed by the permanent EDP leaf.
/usr/bin/codesign --verify --strict -R="${APP_REQUIREMENT}" "${APP_SOURCE}"
/usr/bin/codesign --verify --strict -R="${BROKER_REQUIREMENT}" "${BROKER_SOURCE}"
/usr/bin/plutil -lint "${PLIST_SOURCE}" >/dev/null

/bin/launchctl bootout "${SERVICE}" >/dev/null 2>&1 || true
/bin/launchctl bootout "${OLD_SERVICE}" >/dev/null 2>&1 || true
/usr/bin/pkill -f '^/Applications/EDP Studio.app/Contents/MacOS/EDP Studio$' >/dev/null 2>&1 || true
/usr/bin/pkill -f '^/Applications/EDPOpen.app/Contents/MacOS/EDPOpen$' >/dev/null 2>&1 || true

/bin/rm -rf "${APP_DEST}"
/bin/mkdir -p /Library/PrivilegedHelperTools
/usr/bin/ditto "${APP_SOURCE}" "${APP_DEST}"
/usr/sbin/chown -R root:wheel "${APP_DEST}"
/bin/chmod -R go-w "${APP_DEST}"

/usr/bin/install -o root -g wheel -m 0755 "${BROKER_SOURCE}" "${BROKER_DEST}"
/usr/bin/install -o root -g wheel -m 0644 "${PLIST_SOURCE}" "${PLIST_DEST}"

# Verify the copied code before launchd is allowed to execute it.
/usr/bin/codesign --verify --strict -R="${APP_REQUIREMENT}" "${APP_DEST}"
/usr/bin/codesign --verify --strict -R="${BROKER_REQUIREMENT}" "${BROKER_DEST}"
/bin/launchctl bootstrap system "${PLIST_DEST}"

# The new identity is copied, signature-verified and bootstrapped before the
# retired EDPOpen installation is removed.
/bin/rm -rf "${OLD_APP}"
/bin/rm -f "${OLD_BROKER}" "${OLD_PLIST}"

/bin/bash "${SCRIPT_DIR}/verify-installed-native.sh"
echo "RESULT=EDP_STUDIO_NATIVE_INSTALL_OK"
