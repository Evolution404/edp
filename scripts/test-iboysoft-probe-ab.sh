#!/bin/bash
set -u
set -o pipefail

BASE="${TMPDIR:-/tmp}/edp-iboysoft-probe-ab"
REPORT="$BASE/report.txt"
PHASE_A="$BASE/phase-a-enabled.txt"
PHASE_B="$BASE/phase-b-disabled.txt"
LIVE_LOG="$BASE/diskarbitration-live.log"
HOLD_DIR="/private/var/tmp/edp-iboysoft-probe-ab-$$"
IBOYSOFT_FS=""
HOLD_PATH=""
MOVED=0
RESTORED=0
LOG_PID=""

mkdir -p "$BASE"
: > "$REPORT"
: > "$PHASE_A"
: > "$PHASE_B"
: > "$LIVE_LOG"

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
section() { log ""; log "=== $* ==="; }

wait_for_da() {
  for _ in $(seq 1 50); do
    if /usr/bin/pgrep -x diskarbitrationd >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

restart_da() {
  set +e
  sudo /usr/bin/killall diskarbitrationd >/dev/null 2>&1
  local rc=$?
  set -e
  sleep 0.4
  wait_for_da >/dev/null 2>&1 || true
  log "diskarbitrationd_restart_rc=$rc pid=$(/usr/bin/pgrep -x diskarbitrationd | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//' || true)"
}

restore_iboysoft() {
  if [[ "$MOVED" -eq 1 && "$RESTORED" -eq 0 ]]; then
    section "Restore iBoysoft filesystem bundle"
    if [[ -e "$HOLD_PATH" && ! -e "$IBOYSOFT_FS" ]]; then
      sudo /bin/mv "$HOLD_PATH" "$IBOYSOFT_FS"
      RESTORED=1
      log "restored_bundle=$IBOYSOFT_FS"
      restart_da
    elif [[ -e "$IBOYSOFT_FS" ]]; then
      RESTORED=1
      log "restore_not_needed_original_present=1"
    else
      log "restore_failed_original_missing=1 hold_missing=1"
    fi
    sudo /bin/rmdir "$HOLD_DIR" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  if [[ -n "$LOG_PID" ]] && kill -0 "$LOG_PID" >/dev/null 2>&1; then
    sudo /bin/kill "$LOG_PID" >/dev/null 2>&1 || true
  fi
  restore_iboysoft
}
trap cleanup EXIT INT TERM

extract_value() {
  local key="$1"
  local file="$2"
  /usr/bin/awk -F= -v k="$key" '$1==k {v=$2} END {if (v!="") print v; else print "unknown"}' "$file"
}

run_known_good() {
  local label="$1"
  local outfile="$2"
  section "$label"
  set +e
  bash scripts/test-fskit-known-good-baselines.sh > >(tee "$outfile" | tee -a "$REPORT") 2> >(tee -a "$outfile" "$REPORT" >&2)
  local rc=$?
  set -e
  local loop minfs result
  loop="$(extract_value loopback3_pass "$outfile")"
  minfs="$(extract_value minfs1181_pass "$outfile")"
  result="$(extract_value RESULT "$outfile")"
  log "${label}_rc=$rc ${label}_loopback3_pass=$loop ${label}_minfs1181_pass=$minfs ${label}_result=$result"
}

if [[ ! -f scripts/test-fskit-known-good-baselines.sh ]]; then
  printf 'Missing scripts/test-fskit-known-good-baselines.sh\n' >&2
  exit 2
fi

section "System"
/usr/bin/sw_vers 2>&1 | tee -a "$REPORT"
log "uid=$(id -u) gid=$(id -g) user=$(id -un)"
/usr/sbin/pkgutil --pkg-info io.macfuse.installer.components.core 2>&1 | tee -a "$REPORT" || true

section "Locate iBoysoft filesystem bundle"
CANDIDATES="$(/usr/bin/find /Library/Filesystems -maxdepth 1 -type d -iname '*iboysoft*.fs' -print 2>/dev/null || true)"
COUNT="$(printf '%s\n' "$CANDIDATES" | /usr/bin/awk 'NF{n++} END{print n+0}')"
log "candidate_count=$COUNT"
printf '%s\n' "$CANDIDATES" | tee -a "$REPORT"

if [[ "$COUNT" -eq 0 ]]; then
  section "SUMMARY"
  log "RESULT=IBOYSOFT_BUNDLE_NOT_FOUND"
  log "Interpretation: Disk Arbitration logged iboysoft_NTFS, but no matching .fs bundle is currently present under /Library/Filesystems. Stop rather than modifying unrelated files."
  log "REPORT=$REPORT"
  exit 2
fi

if [[ "$COUNT" -ne 1 ]]; then
  section "SUMMARY"
  log "RESULT=IBOYSOFT_BUNDLE_AMBIGUOUS"
  log "Interpretation: more than one iBoysoft .fs bundle is installed. Stop rather than disabling multiple filesystem plugins automatically."
  log "REPORT=$REPORT"
  exit 2
fi

IBOYSOFT_FS="$(printf '%s\n' "$CANDIDATES" | /usr/bin/awk 'NF{print; exit}')"
HOLD_PATH="$HOLD_DIR/$(basename "$IBOYSOFT_FS")"
log "iboysoft_bundle=$IBOYSOFT_FS"
/usr/bin/defaults read "$IBOYSOFT_FS/Contents/Info" CFBundleIdentifier 2>&1 | tee -a "$REPORT" || true
/usr/bin/defaults read "$IBOYSOFT_FS/Contents/Info" CFBundleShortVersionString 2>&1 | tee -a "$REPORT" || true

section "Safety check"
if /sbin/mount | /usr/bin/grep -i -E 'iboysoft|[,( ]ntfs[ ,)]' | tee -a "$REPORT" | /usr/bin/grep -q .; then
  section "SUMMARY"
  log "RESULT=ACTIVE_NTFS_MOUNT_DETECTED"
  log "Interpretation: an NTFS/iBoysoft volume appears to be mounted. The A/B test was not run because restarting Disk Arbitration and hiding the filesystem plugin could disrupt that volume."
  log "REPORT=$REPORT"
  exit 2
fi
log "active_ntfs_mount=0"

sudo -v

section "Start Disk Arbitration correlation log"
sudo /usr/bin/log stream --style compact --level debug \
  --predicate '(process == "diskarbitrationd") OR (subsystem == "io.macfuse") OR (process == "io.macfuse.app.launchservice.daemon")' \
  > "$LIVE_LOG" 2>&1 &
LOG_PID=$!
log "live_log_pid=$LOG_PID"
sleep 1

run_known_good phase_a_enabled "$PHASE_A"

section "Temporarily disable only the iBoysoft .fs probe bundle"
sudo /bin/mkdir -p "$HOLD_DIR"
sudo /bin/mv "$IBOYSOFT_FS" "$HOLD_PATH"
MOVED=1
log "moved_from=$IBOYSOFT_FS"
log "moved_to=$HOLD_PATH"
if [[ -e "$IBOYSOFT_FS" || ! -e "$HOLD_PATH" ]]; then
  log "disable_verification_failed=1"
  restore_iboysoft
  section "SUMMARY"
  log "RESULT=IBOYSOFT_DISABLE_FAILED"
  log "REPORT=$REPORT"
  exit 2
fi
restart_da
sleep 1

run_known_good phase_b_disabled "$PHASE_B"

if [[ -n "$LOG_PID" ]] && kill -0 "$LOG_PID" >/dev/null 2>&1; then
  sudo /bin/kill "$LOG_PID" >/dev/null 2>&1 || true
  sleep 0.5
fi
LOG_PID=""

restore_iboysoft

section "Disk Arbitration iBoysoft/macFUSE events"
/usr/bin/grep -i -E 'iboysoft|created disk|removed disk|probed disk|unable to probe|claimed disk|Activate virtual device|Activated device|Failed to mount volume|MountError' "$LIVE_LOG" | /usr/bin/tail -n 500 | tee -a "$REPORT" || true

A_LOOP="$(extract_value loopback3_pass "$PHASE_A")"
A_MINFS="$(extract_value minfs1181_pass "$PHASE_A")"
B_LOOP="$(extract_value loopback3_pass "$PHASE_B")"
B_MINFS="$(extract_value minfs1181_pass "$PHASE_B")"

IBOYSOFT_PHASE_A=0
IBOYSOFT_PHASE_B=0
# The phase boundary itself is preserved in REPORT. These counts are only supporting signals.
/usr/bin/grep -i -q 'iboysoft_NTFS' "$LIVE_LOG" && IBOYSOFT_PHASE_A=1 || true
# After the bundle was moved and DA restarted, there should be no new iboysoft probe. The decisive signal is mount success/failure.
if [[ "$B_LOOP" == "1" || "$B_MINFS" == "1" ]]; then
  IBOYSOFT_PHASE_B=0
fi

section "SUMMARY"
log "phase_a_loopback3_pass=$A_LOOP phase_a_minfs1181_pass=$A_MINFS"
log "phase_b_loopback3_pass=$B_LOOP phase_b_minfs1181_pass=$B_MINFS"
log "iboysoft_bundle_restored=$RESTORED"

if [[ "$A_LOOP" == "0" && "$A_MINFS" == "0" && ( "$B_LOOP" == "1" || "$B_MINFS" == "1" ) ]]; then
  log "RESULT=IBOYSOFT_INTERFERENCE_CONFIRMED"
  log "Interpretation: the known-good macFUSE FSKit baseline failed with iBoysoft's filesystem probe installed and succeeded when only that .fs probe bundle was temporarily removed. This establishes a causal compatibility conflict in Disk Arbitration probing."
elif [[ ( "$A_LOOP" == "1" || "$A_MINFS" == "1" ) ]]; then
  log "RESULT=BASELINE_ALREADY_RECOVERED_WITH_IBOYSOFT_ENABLED"
  log "Interpretation: the known-good baseline succeeded before disabling iBoysoft, so iBoysoft is not required to explain the current state. Do not remove it based on this test."
elif [[ "$B_LOOP" == "0" && "$B_MINFS" == "0" ]]; then
  log "RESULT=IBOYSOFT_NOT_CAUSAL"
  log "Interpretation: removing iBoysoft from Disk Arbitration probing did not restore either known-good FSKit baseline. The iBoysoft probe is correlated but not the root cause; continue inside macFUSE's virtual-device initialization path."
else
  log "RESULT=IBOYSOFT_AB_INCONCLUSIVE"
  log "Interpretation: the A/B results were mixed or incomplete. Inspect both phase outputs before changing installed filesystem software."
fi
log "REPORT=$REPORT"

exit 0
