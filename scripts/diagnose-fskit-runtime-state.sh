#!/bin/bash
set -u
set -o pipefail

BASE="${TMPDIR:-/tmp}/edp-fskit-runtime-state"
REPORT="$BASE/report.txt"
LOOPBACK_REPORT="${TMPDIR:-/tmp}/edp-macfuse-official-loopback-report.txt"
UID_NOW="$(id -u)"
GID_NOW="$(id -g)"
LOCAL_ID="io.macfuse.app.fsmodule.macfuse-local"
GENERIC_ID="io.macfuse.app.fsmodule.macfuse"
LAST_LOOPBACK_RESULT="UNKNOWN"
LAST_LOOPBACK_RC=99

mkdir -p "$BASE"
: > "$REPORT"

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
section() { log ""; log "=== $* ==="; }

plugin_state() {
  /usr/bin/pluginkit -m -A -D -i "$LOCAL_ID" 2>&1 || true
  /usr/bin/pluginkit -m -A -D -i "$GENERIC_ID" 2>&1 || true
}

snapshot() {
  local label="$1"
  local out="$BASE/${label}.txt"
  : > "$out"

  {
    printf '=== timestamp ===\n'
    /bin/date '+%Y-%m-%d %H:%M:%S %z'

    printf '\n=== system ===\n'
    /usr/bin/sw_vers
    /usr/bin/uname -m
    printf 'uid=%s gid=%s user=%s\n' "$UID_NOW" "$GID_NOW" "$(id -un)"

    printf '\n=== macFUSE receipt ===\n'
    /usr/sbin/pkgutil --pkg-info io.macfuse.installer.components.core 2>&1 || true

    printf '\n=== PluginKit records ===\n'
    plugin_state

    printf '\n=== FSKit/macFUSE processes ===\n'
    /bin/ps -axo pid,ppid,user,lstart,command | /usr/bin/grep -E '[f]skit|[m]acfuse' || true

    printf '\n=== macFUSE launch daemon ===\n'
    /bin/launchctl print system/io.macfuse.app.launchservice.daemon 2>&1 || true

    printf '\n=== user FSKit agent service ===\n'
    /bin/launchctl print "gui/${UID_NOW}/com.apple.fskit.fskit_agent" 2>&1 || true

    printf '\n=== recent runtime log ===\n'
    /usr/bin/log show --debug --info \
      --predicate '(subsystem IN {"com.apple.FSKit","com.apple.LiveFS","io.macfuse"}) OR (process == "pkd") OR (process == "fskitd") OR (process == "fskit_agent")' \
      --last 4m 2>&1 | /usr/bin/tail -n 500 || true
  } >> "$out" 2>&1

  /bin/cat "$out" | tee -a "$REPORT"
}

extract_loopback_result() {
  if [[ ! -f "$LOOPBACK_REPORT" ]]; then
    printf 'NO_REPORT'
    return
  fi
  /usr/bin/awk -F= '/^RESULT=/{value=$2} END{if (value != "") print value; else print "UNKNOWN"}' "$LOOPBACK_REPORT"
}

signal_summary() {
  local file="$1"
  local prefix="$2"
  local start_extension=0
  local activate_volume=0
  local channel_created=0
  local channel_invalidated=0
  local extension_not_found=0
  local plugin_rejected=0

  [[ -f "$file" ]] || return
  /usr/bin/grep -E -q 'Starting startExtension|startExtension:' "$file" && start_extension=1 || true
  /usr/bin/grep -E -q 'activateVolume' "$file" && activate_volume=1 || true
  /usr/bin/grep -E -q 'Channel created|Connection to file system extension established' "$file" && channel_created=1 || true
  /usr/bin/grep -E -q 'Connection to file system (server|extension) invalidated|MFDaemon\.MountError Code=4' "$file" && channel_invalidated=1 || true
  /usr/bin/grep -E -q 'File system extension .* not found|File system extension not found' "$file" && extension_not_found=1 || true
  /usr/bin/grep -E -q 'rejecting; Ignoring mis-configured plugin' "$file" && plugin_rejected=1 || true

  log "${prefix}_start_extension=$start_extension ${prefix}_activate_volume=$activate_volume ${prefix}_channel_created=$channel_created ${prefix}_channel_invalidated=$channel_invalidated ${prefix}_extension_not_found=$extension_not_found ${prefix}_plugin_rejected=$plugin_rejected"
}

run_loopback() {
  local label="$1"
  local out="$BASE/${label}-loopback.txt"
  : > "$out"

  section "$label: official LoopbackFS"
  bash scripts/test-macfuse-official-loopback.sh 2>&1 | tee -a "$REPORT" "$out"
  LAST_LOOPBACK_RC=${PIPESTATUS[0]}
  LAST_LOOPBACK_RESULT="$(extract_loopback_result)"

  log "${label}_loopback_rc=$LAST_LOOPBACK_RC"
  log "${label}_loopback_result=$LAST_LOOPBACK_RESULT"
  signal_summary "$out" "$label"
}

restart_fskit_only() {
  section "Phase A: restart FSKit runtime only"
  log "before_fskitd_pid=$(/usr/bin/pgrep -x fskitd | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//' || true)"
  log "before_fskit_agent_pid=$(/usr/bin/pgrep -x fskit_agent | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//' || true)"

  /usr/bin/killall fskit_agent 2>&1 | tee -a "$REPORT"
  local agent_rc=${PIPESTATUS[0]}
  sudo /usr/bin/killall fskitd 2>&1 | tee -a "$REPORT"
  local fskitd_rc=${PIPESTATUS[0]}
  log "fskit_agent_kill_rc=$agent_rc fskitd_kill_rc=$fskitd_rc"

  sleep 2
  plugin_state | tee -a "$REPORT"
  sleep 1

  log "after_fskitd_pid=$(/usr/bin/pgrep -x fskitd | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//' || true)"
  log "after_fskit_agent_pid=$(/usr/bin/pgrep -x fskit_agent | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//' || true)"
}

restart_pluginkit_and_fskit() {
  section "Phase B: restart PluginKit plus FSKit runtime"
  log "before_pkd_pid=$(/usr/bin/pgrep -x pkd | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//' || true)"

  sudo /usr/bin/killall pkd 2>&1 | tee -a "$REPORT"
  local pkd_rc=${PIPESTATUS[0]}
  /usr/bin/killall fskit_agent 2>&1 | tee -a "$REPORT"
  local agent_rc=${PIPESTATUS[0]}
  sudo /usr/bin/killall fskitd 2>&1 | tee -a "$REPORT"
  local fskitd_rc=${PIPESTATUS[0]}
  log "pkd_kill_rc=$pkd_rc fskit_agent_kill_rc=$agent_rc fskitd_kill_rc=$fskitd_rc"

  sleep 2
  plugin_state | tee -a "$REPORT"
  sleep 1

  log "after_pkd_pid=$(/usr/bin/pgrep -x pkd | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//' || true)"
  log "after_fskitd_pid=$(/usr/bin/pgrep -x fskitd | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//' || true)"
  log "after_fskit_agent_pid=$(/usr/bin/pgrep -x fskit_agent | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//' || true)"
}

if [[ ! -f scripts/test-macfuse-official-loopback.sh ]]; then
  printf 'Missing scripts/test-macfuse-official-loopback.sh\n' >&2
  exit 2
fi

section "FSKit runtime-state diagnostic"
sudo -v
snapshot "before"

restart_fskit_only
snapshot "after-phase-a-restart-before-test"
run_loopback phase_a
RESULT_A="$LAST_LOOPBACK_RESULT"
snapshot "after-phase-a"

if [[ "$RESULT_A" == "OFFICIAL_LOOPBACK_PASS" ]]; then
  section "SUMMARY"
  log "phase_a_result=$RESULT_A"
  log "phase_b_result=not-run"
  log "RESULT=FSKIT_RUNTIME_RESTART_REPAIRED"
  log "Interpretation: restarting fskitd/fskit_agent alone restored the stock macFUSE FSKit mount. The failure was stale FSKit runtime state."
  log "REPORT=$REPORT"
  exit 0
fi

restart_pluginkit_and_fskit
snapshot "after-phase-b-restart-before-test"
run_loopback phase_b
RESULT_B="$LAST_LOOPBACK_RESULT"
snapshot "after-phase-b"

section "SUMMARY"
log "phase_a_result=$RESULT_A"
log "phase_b_result=$RESULT_B"

if [[ "$RESULT_B" == "OFFICIAL_LOOPBACK_PASS" ]]; then
  log "RESULT=PLUGIN_FSKIT_RESYNC_REPAIRED"
  log "Interpretation: FSKit-only restart was insufficient, but restarting PluginKit plus FSKit restored the stock mount. The failure was PluginKit-to-FSKit runtime state desynchronization."
elif [[ "$RESULT_B" == "OFFICIAL_LOOPBACK_EXTENSION_NOT_FOUND" ]]; then
  log "RESULT=FSKIT_MODULE_ENUMERATION_BROKEN"
  log "Interpretation: after restarting both PluginKit and FSKit runtime processes, fskitd still cannot resolve the registered macFUSE module. Focus on per-user FSKit module state."
elif [[ "$RESULT_B" == "OFFICIAL_LOOPBACK_CHANNEL_INVALIDATED" ]]; then
  log "RESULT=CHANNEL_INVALIDATED_AFTER_FULL_RUNTIME_RESYNC"
  log "Interpretation: PluginKit, fskitd and fskit_agent runtime processes were all rebuilt, yet stock LoopbackFS still loses its channel after activateVolume. The cause is deeper than stale runtime caches; inspect channel setup and system policy/signing state next."
else
  log "RESULT=FSKIT_RUNTIME_FAIL_OTHER"
  log "Interpretation: inspect phase B runtime logs for the first failure after the complete runtime resync."
fi

log "REPORT=$REPORT"
exit 0
