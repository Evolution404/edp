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

mkdir -p "$BASE"
: > "$REPORT"

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
section() { log ""; log "=== $* ==="; }

snapshot() {
  local label="$1"
  local outfile="$BASE/${label}.txt"
  : > "$outfile"

  {
    printf '=== timestamp ===\n'
    /bin/date '+%Y-%m-%d %H:%M:%S %z'

    printf '\n=== system ===\n'
    /usr/bin/sw_vers
    /usr/bin/uname -m
    printf 'uid=%s gid=%s user=%s\n' "$UID_NOW" "$GID_NOW" "$(id -un)"

    printf '\n=== macFUSE receipt ===\n'
    /usr/sbin/pkgutil --pkg-info io.macfuse.installer.components.core 2>&1 || true

    printf '\n=== PluginKit local ===\n'
    /usr/bin/pluginkit -m -A -D -i "$LOCAL_ID" 2>&1 || true

    printf '\n=== PluginKit generic ===\n'
    /usr/bin/pluginkit -m -A -D -i "$GENERIC_ID" 2>&1 || true

    printf '\n=== FSKit/macFUSE processes ===\n'
    /bin/ps -axo pid,ppid,user,lstart,command | /usr/bin/grep -E '[f]skit|[m]acfuse' || true

    printf '\n=== macFUSE launch daemon ===\n'
    /bin/launchctl print system/io.macfuse.app.launchservice.daemon 2>&1 || true

    printf '\n=== user FSKit agent service ===\n'
    /bin/launchctl print "gui/${UID_NOW}/com.apple.fskit.fskit_agent" 2>&1 || true

    printf '\n=== recent FSKit/macFUSE/PluginKit log ===\n'
    /usr/bin/log show --debug --info \
      --predicate '(subsystem IN {"com.apple.FSKit","com.apple.LiveFS","io.macfuse"}) OR (process == "pkd") OR (process == "fskitd") OR (process == "fskit_agent")' \
      --last 4m 2>&1 | /usr/bin/tail -n 450 || true
  } >> "$outfile" 2>&1

  /bin/cat "$outfile" | tee -a "$REPORT"
}

extract_loopback_result() {
  if [[ ! -f "$LOOPBACK_REPORT" ]]; then
    printf 'NO_REPORT'
    return
  fi
  /usr/bin/awk -F= '/^RESULT=/{value=$2} END{if (value != "") print value; else print "UNKNOWN"}' "$LOOPBACK_REPORT"
}

extract_runtime_signals() {
  local file="$1"
  local prefix="$2"
  local start_extension=0
  local activate_volume=0
  local channel_created=0
  local channel_invalidated=0
  local extension_not_found=0
  local plugin_rejected=0

  if [[ -f "$file" ]]; then
    /usr/bin/grep -E -q 'Starting startExtension|startExtension:' "$file" && start_extension=1 || true
    /usr/bin/grep -E -q 'activateVolume' "$file" && activate_volume=1 || true
    /usr/bin/grep -E -q 'Channel created|Connection to file system extension established' "$file" && channel_created=1 || true
    /usr/bin/grep -E -q 'Connection to file system (server|extension) invalidated|MFDaemon\.MountError Code=4' "$file" && channel_invalidated=1 || true
    /usr/bin/grep -E -q 'File system extension .* not found|File system extension not found' "$file" && extension_not_found=1 || true
    /usr/bin/grep -E -q 'rejecting; Ignoring mis-configured plugin' "$file" && plugin_rejected=1 || true
  fi

  log "${prefix}_start_extension=$start_extension ${prefix}_activate_volume=$activate_volume ${prefix}_channel_created=$channel_created ${prefix}_channel_invalidated=$channel_invalidated ${prefix}_extension_not_found=$extension_not_found ${prefix}_plugin_rejected=$plugin_rejected"
}

run_loopback() {
  local label="$1"
  local out="$BASE/${label}-loopback.txt"
  : > "$out"

  section "$label: official LoopbackFS"
  set +e
  bash scripts/test-macfuse-official-loopback.sh > >(tee -a "$REPORT" "$out") 2> >(tee -a "$REPORT" "$out" >&2)
  local rc=$?
  set -e

  local result
  result="$(extract_loopback_result)"
  log "${label}_loopback_rc=$rc"
  log "${label}_loopback_result=$result"
  extract_runtime_signals "$out" "$label"

  printf '%s' "$result"
}

restart_fskit_only() {
  section "Restart FSKit runtime only"
  log "before_fskitd_pid=$(/usr/bin/pgrep -x fskitd | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//' || true)"
  log "before_fskit_agent_pid=$(/usr/bin/pgrep -x fskit_agent | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//' || true)"

  set +e
  /usr/bin/killall fskit_agent 2>&1 | tee -a "$REPORT"
  AGENT_KILL_RC=${PIPESTATUS[0]}
  sudo /usr/bin/killall fskitd 2>&1 | tee -a "$REPORT"
  FSKITD_KILL_RC=${PIPESTATUS[0]}
  set -e

  log "fskit_agent_kill_rc=$AGENT_KILL_RC fskitd_kill_rc=$FSKITD_KILL_RC"

  for _ in $(seq 1 50); do
    if /usr/bin/pgrep -x fskitd >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done

  sleep 1
  log "after_fskitd_pid=$(/usr/bin/pgrep -x fskitd | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//' || true)"
  log "after_fskit_agent_pid=$(/usr/bin/pgrep -x fskit_agent | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//' || true)"
}

restart_pluginkit_and_fskit() {
  section "Restart PluginKit and FSKit runtime"
  log "before_pkd_pid=$(/usr/bin/pgrep -x pkd | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//' || true)"

  set +e
  sudo /usr/bin/killall pkd 2>&1 | tee -a "$REPORT"
  PKD_KILL_RC=${PIPESTATUS[0]}
  /usr/bin/killall fskit_agent 2>&1 | tee -a "$REPORT"
  AGENT2_KILL_RC=${PIPESTATUS[0]}
  sudo /usr/bin/killall fskitd 2>&1 | tee -a "$REPORT"
  FSKITD2_KILL_RC=${PIPESTATUS[0]}
  set -e

  log "pkd_kill_rc=$PKD_KILL_RC fskit_agent_kill_rc=$AGENT2_KILL_RC fskitd_kill_rc=$FSKITD2_KILL_RC"

  sleep 2

  /usr/bin/pluginkit -m -A -D -i "$LOCAL_ID" 2>&1 | tee -a "$REPORT" || true
  /usr/bin/pluginkit -m -A -D -i "$GENERIC_ID" 2>&1 | tee -a "$REPORT" || true

  for _ in $(seq 1 50); do
    if /usr/bin/pgrep -x fskitd >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done

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
snapshot "after-fskit-restart-before-test"
RESULT_A="$(run_loopback phase_a)"
snapshot "after-phase-a"

if [[ "$RESULT_A" == "OFFICIAL_LOOPBACK_PASS" ]]; then
  section "SUMMARY"
  log "phase_a_result=$RESULT_A"
  log "phase_b_result=not-run"
  log "RESULT=FSKIT_RUNTIME_RESTART_REPAIRED"
  log "Interpretation: restarting fskitd/fskit_agent alone restored the official macFUSE FSKit mount. The failure was stale FSKit runtime state."
  log "REPORT=$REPORT"
  exit 0
fi

restart_pluginkit_and_fskit
snapshot "after-pkd-fskit-restart-before-test"
RESULT_B="$(run_loopback phase_b)"
snapshot "after-phase-b"

section "SUMMARY"
log "phase_a_result=$RESULT_A"
log "phase_b_result=$RESULT_B"

if [[ "$RESULT_B" == "OFFICIAL_LOOPBACK_PASS" ]]; then
  log "RESULT=PLUGIN_FSKIT_RESYNC_REPAIRED"
  log "Interpretation: restarting FSKit alone was insufficient, but restarting PluginKit plus FSKit restored the official mount. The failure was a PluginKit-to-FSKit runtime synchronization state problem."
elif [[ "$RESULT_B" == "OFFICIAL_LOOPBACK_EXTENSION_NOT_FOUND" ]]; then
  log "RESULT=FSKIT_MODULE_ENUMERATION_BROKEN"
  log "Interpretation: after rebuilding both PluginKit and FSKit runtime processes, fskitd still cannot resolve the registered macFUSE module. Focus on per-user FSKit module state."
elif [[ "$RESULT_B" == "OFFICIAL_LOOPBACK_CHANNEL_INVALIDATED" ]]; then
  log "RESULT=CHANNEL_INVALIDATED_AFTER_FULL_RUNTIME_RESYNC"
  log "Interpretation: PluginKit records, fskitd, fskit_agent and their runtime caches were all restarted, yet the stock macFUSE LoopbackFS still loses its channel after activation. The cause is deeper than stale registration/runtime caches; inspect the exact channel setup logs and system policy state next."
else
  log "RESULT=FSKIT_RUNTIME_FAIL_OTHER"
  log "Interpretation: inspect phase B server/runtime logs for the first failure after the complete runtime resync."
fi

log "REPORT=$REPORT"
exit 0
