#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/EDP Drive.app/Contents/MacOS/EDP Drive"
ACCEPTANCE="${ROOT}/Apps/Drive/scripts/first-install-acceptance.sh"
HELPER="${ROOT}/artifacts/test-tools/edp-usb-reenumerate"
VID_PID="${1:-}"
TIMEOUT="${2:-15}"

usage() {
  cat >&2 <<'EOF'
Usage: Tools/drive-usb-reenumerate.sh VID:PID [timeout-seconds]
Example: Tools/drive-usb-reenumerate.sh 21c4:0cd1 15

Test-only workflow:
  1. verify exactly one matching IOUSBHostDevice exists
  2. pause EDP Drive runtime (releases raw lease but keeps the service/DA owner alive)
  3. request public IOUSBHostDevice reset/re-enumeration with macOS administrator authorization
  4. resume EDP Drive runtime
  5. require retained FDA raw access to recover automatically
  6. require rawBusyRecoveryCount/forcedWholeUnmountCount not to increase

This simulates USB IOService removal/re-enumeration. It is not a VBUS power cycle and does not replace the one final physical unplug/replug release smoke.
EOF
}

if [[ ! "${VID_PID}" =~ ^[0-9A-Fa-f]{1,4}:[0-9A-Fa-f]{1,4}$ ]]; then
  usage
  exit 2
fi
if [[ ! "${TIMEOUT}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "ERROR=timeout must be numeric" >&2
  exit 2
fi

VID="${VID_PID%%:*}"
PID="${VID_PID##*:}"

if [[ ! -x "${APP}" ]]; then
  echo "ERROR=installed EDP Drive app is required" >&2
  exit 3
fi

make -s -C "${ROOT}" drive-usb-reenumerate-tool
"${HELPER}" --vid "${VID}" --pid "${PID}" --dry-run

metric_from_diagnostics() {
  local key="$1"
  "${APP}" --xpc-diagnostics \
    | /usr/bin/awk -v key="\"${key}\"" '$1 == key { value=$3; gsub(/[,[:space:]]/, "", value); print value; exit }'
}

BASE_RAW_BUSY="$(metric_from_diagnostics rawBusyRecoveryCount)"
BASE_FORCE_UNMOUNT="$(metric_from_diagnostics forcedWholeUnmountCount)"
if [[ -z "${BASE_RAW_BUSY}" || -z "${BASE_FORCE_UNMOUNT}" ]]; then
  echo "ERROR=could not read baseline runtime metrics" >&2
  exit 4
fi

echo "BASE_RAW_BUSY_RECOVERY_COUNT=${BASE_RAW_BUSY}"
echo "BASE_FORCED_WHOLE_UNMOUNT_COUNT=${BASE_FORCE_UNMOUNT}"

RESUME_NEEDED=0
resume_runtime() {
  if [[ "${RESUME_NEEDED}" == "1" ]]; then
    "${APP}" --xpc-runtime-control-smoke resume >/dev/null 2>&1 || true
  fi
}
trap resume_runtime EXIT

"${APP}" --xpc-runtime-control-smoke pause
RESUME_NEEDED=1

RESET_OUTPUT="$(/usr/bin/osascript \
  -e 'on run argv' \
  -e 'set helperPath to item 1 of argv' \
  -e 'set vidValue to item 2 of argv' \
  -e 'set pidValue to item 3 of argv' \
  -e 'set timeoutValue to item 4 of argv' \
  -e 'set commandText to quoted form of helperPath & " --vid " & quoted form of vidValue & " --pid " & quoted form of pidValue & " --timeout " & quoted form of timeoutValue' \
  -e 'return do shell script commandText with administrator privileges' \
  -e 'end run' \
  "${HELPER}" "${VID}" "${PID}" "${TIMEOUT}")"
printf '%s\n' "${RESET_OUTPUT}"
/usr/bin/grep -Fq 'RESULT=EDP_USB_SOFTWARE_REENUMERATION_OK' <<<"${RESET_OUTPUT}"

"${APP}" --xpc-runtime-control-smoke resume
RESUME_NEEDED=0

READY=0
for _ in $(/usr/bin/seq 1 80); do
  if "${ACCEPTANCE}" verify-fda-device "${VID_PID}" >/dev/null 2>&1; then
    READY=1
    break
  fi
  /bin/sleep 0.25
done
if [[ "${READY}" != "1" ]]; then
  echo "ERROR=EDP Drive did not recover retained raw access after software re-enumeration" >&2
  exit 5
fi
"${ACCEPTANCE}" verify-fda-device "${VID_PID}"

AFTER_RAW_BUSY="$(metric_from_diagnostics rawBusyRecoveryCount)"
AFTER_FORCE_UNMOUNT="$(metric_from_diagnostics forcedWholeUnmountCount)"
echo "AFTER_RAW_BUSY_RECOVERY_COUNT=${AFTER_RAW_BUSY}"
echo "AFTER_FORCED_WHOLE_UNMOUNT_COUNT=${AFTER_FORCE_UNMOUNT}"
if [[ "${AFTER_RAW_BUSY}" != "${BASE_RAW_BUSY}" ]]; then
  echo "ERROR=rawBusyRecoveryCount increased during software re-enumeration" >&2
  exit 6
fi
if [[ "${AFTER_FORCE_UNMOUNT}" != "${BASE_FORCE_UNMOUNT}" ]]; then
  echo "ERROR=forcedWholeUnmountCount increased during software re-enumeration" >&2
  exit 7
fi

echo "RESULT=DRIVE_USB_SOFTWARE_REENUMERATION_ACCEPTANCE_OK"
