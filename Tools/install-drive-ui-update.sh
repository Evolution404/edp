#!/bin/bash
set -euo pipefail

PACKAGE="${1:?usage: install-drive-ui-update.sh /path/to/EDP-Drive-UI.pkg}"
INSTALLED_APP="${EDP_INSTALLED_APP:-/Applications/EDP Drive.app}"
EXPECTED_UI_SHA="${PACKAGE}.ui-sha256"
UI_MANAGER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/manage-drive-ui.sh"

[[ -f "${PACKAGE}" && -f "${EXPECTED_UI_SHA}" ]] || {
  echo "UI package or checksum is missing. Run make drive-ui-package first." >&2
  exit 2
}

# Request authorization before closing the running UI. The package contains the
# foreground App only and deliberately leaves the service and mounts untouched.
/usr/bin/sudo -v

relaunch_required=0
relaunch_on_exit() {
  if [[ "${relaunch_required}" == "1" && -d "${INSTALLED_APP}" ]]; then
    EDP_INSTALLED_APP="${INSTALLED_APP}" "${UI_MANAGER}" start >/dev/null 2>&1 || true
  fi
}
trap relaunch_on_exit EXIT INT TERM

EDP_INSTALLED_APP="${INSTALLED_APP}" "${UI_MANAGER}" stop
relaunch_required=1

/usr/bin/sudo /usr/sbin/installer -pkg "${PACKAGE}" -target /
/usr/bin/shasum -a 256 -c "${EXPECTED_UI_SHA}"
/usr/bin/codesign --verify --strict "${INSTALLED_APP}"
EDP_INSTALLED_APP="${INSTALLED_APP}" "${UI_MANAGER}" start
relaunch_required=0

echo "RESULT=EDP_DRIVE_UI_UPDATE_INSTALLED"
