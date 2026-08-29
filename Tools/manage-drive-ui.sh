#!/bin/bash
set -euo pipefail

ACTION="${1:-status}"
INSTALLED_APP="${EDP_INSTALLED_APP:-/Applications/EDP Drive.app}"

# Match foreground UI executables only. This deliberately excludes
# Contents/Library/LaunchServices/edp-drive-service and mount transports.
UI_PATTERN='/[^/]*EDP Drive[^/]*\.app/Contents/MacOS/EDP Drive[^/]*$|/artifacts/edp-drive-ui$'
OFFICIAL_UI_PATTERN="^${INSTALLED_APP}/Contents/MacOS/EDP Drive$"

ui_pids() {
  /usr/bin/pgrep -f "${UI_PATTERN}" || true
}

official_ui_count() {
  local pids
  pids="$(/usr/bin/pgrep -f "${OFFICIAL_UI_PATTERN}" || true)"
  if [[ -z "${pids}" ]]; then
    echo 0
  else
    echo "${pids}" | /usr/bin/wc -l | /usr/bin/tr -d ' '
  fi
}

print_status() {
  local pids pid
  pids="$(ui_pids)"
  if [[ -z "${pids}" ]]; then
    echo "EDP_DRIVE_UI_COUNT=0"
    return
  fi

  echo "EDP_DRIVE_UI_COUNT=$(echo "${pids}" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] && /bin/ps -p "${pid}" -o pid=,args=
  done <<< "${pids}"
}

stop_all() {
  local pids remaining
  pids="$(ui_pids)"
  if [[ -z "${pids}" ]]; then
    echo "EDP_DRIVE_UI_STOPPED=0"
    return
  fi

  echo "Stopping previous EDP Drive UI instances: $(echo "${pids}" | /usr/bin/tr '\n' ' ')"
  /bin/kill ${pids}
  for _ in {1..50}; do
    remaining="$(ui_pids)"
    [[ -z "${remaining}" ]] && break
    /bin/sleep 0.1
  done

  remaining="$(ui_pids)"
  if [[ -n "${remaining}" ]]; then
    echo "Forcing stale EDP Drive UI instances to exit: $(echo "${remaining}" | /usr/bin/tr '\n' ' ')" >&2
    /bin/kill -KILL ${remaining}
  fi

  for _ in {1..20}; do
    [[ -z "$(ui_pids)" ]] && break
    /bin/sleep 0.1
  done
  [[ -z "$(ui_pids)" ]] || {
    echo "Unable to stop every EDP Drive foreground UI instance." >&2
    exit 2
  }
  echo "EDP_DRIVE_UI_STOPPED=1"
}

start_one() {
  [[ -d "${INSTALLED_APP}" ]] || {
    echo "Installed EDP Drive was not found at ${INSTALLED_APP}." >&2
    exit 2
  }

  stop_all
  /usr/bin/open "${INSTALLED_APP}"
  for _ in {1..50}; do
    [[ "$(official_ui_count)" == "1" ]] && break
    /bin/sleep 0.1
  done

  local count
  count="$(official_ui_count)"
  [[ "${count}" == "1" ]] || {
    echo "Expected one official EDP Drive UI instance, found ${count}." >&2
    print_status >&2
    exit 2
  }
  echo "EDP_DRIVE_UI_STARTED=1"
}

case "${ACTION}" in
  status)
    print_status
    ;;
  stop)
    stop_all
    ;;
  start|restart)
    start_one
    ;;
  *)
    echo "usage: manage-drive-ui.sh {status|stop|start|restart}" >&2
    exit 2
    ;;
esac
