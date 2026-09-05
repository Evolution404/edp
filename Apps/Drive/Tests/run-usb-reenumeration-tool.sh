#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SOURCE="${ROOT}/Tools/usb-reenumerate/EDPUSBReenumerate.m"
WRAPPER="${ROOT}/Tools/drive-usb-reenumerate.sh"
OUTPUT="${ROOT}/artifacts/test-tools/edp-usb-reenumerate"

mkdir -p "$(dirname "${OUTPUT}")"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  xcrun clang \
    -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -framework Foundation -framework IOKit -framework IOUSBHost \
    "${SOURCE}" -o "${OUTPUT}"

"${OUTPUT}" --self-test
"${OUTPUT}" --help 2>&1 | /usr/bin/grep -Fq 'Actual reset requires root and refuses ambiguous VID/PID matches.'

/bin/bash -n "${WRAPPER}"
/usr/bin/grep -Fq -- '--xpc-runtime-control-smoke pause' "${WRAPPER}"
/usr/bin/grep -Fq -- '--xpc-runtime-control-smoke resume' "${WRAPPER}"
/usr/bin/grep -Fq 'rawBusyRecoveryCount' "${WRAPPER}"
/usr/bin/grep -Fq 'forcedWholeUnmountCount' "${WRAPPER}"
/usr/bin/grep -Fq 'IOUSBHostObjectInitOptionsDeviceSeize' "${SOURCE}"
/usr/bin/grep -Fq 'resetWithError:' "${SOURCE}"
/usr/bin/grep -Fq 'MATCH_COUNT' "${SOURCE}"
/usr/bin/grep -Fq 'OLD_GENERATION_GONE' "${SOURCE}"
/usr/bin/grep -Fq 'NEW_USB_REGISTRY_ENTRY_ID' "${SOURCE}"

# The software re-enumeration helper is test infrastructure only. Production and
# installer code must never invoke it or link the USB reset behavior into normal
# device-management paths.
if /usr/bin/grep -R -Fq 'edp-usb-reenumerate' \
  "${ROOT}/Apps/Drive/product" \
  "${ROOT}/Apps/Drive/installer"; then
  echo 'ERROR=USB software re-enumeration leaked into production/installer code' >&2
  exit 1
fi

echo 'RESULT=DRIVE_USB_SOFTWARE_REENUMERATION_TOOL_OK'
