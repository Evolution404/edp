#!/bin/bash
set -u
set -o pipefail

BASE="${TMPDIR:-/tmp}/edp-fskit-known-good"
REPORT="$BASE/report.txt"
LIVE_LOG="$BASE/live-system.log"
DEMO="$BASE/demo"
LOOPBACK3="$BASE/loopback3"
LOOP_SRC="$BASE/loop-src"
LOOP_MNT="/Volumes/edp-loopback-known-good"
LOOP_LOG="$BASE/loopback3.log"
ISSUE_JSON="$BASE/issue-1181.json"
MINFS_C="$BASE/minfs.c"
MINFS_BIN="$BASE/minfs"
MINFS_MNT="/Volumes/edp-minfs-1181"
MINFS_LOG="$BASE/minfs.log"
UID_NOW="$(id -u)"
GID_NOW="$(id -g)"
LOOP_PID=""
MINFS_PID=""
LOG_PID=""
LOOP_PASS=0
MINFS_PASS=0

mkdir -p "$BASE"
: > "$REPORT"
: > "$LIVE_LOG"
: > "$LOOP_LOG"
: > "$MINFS_LOG"

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
section() { log ""; log "=== $* ==="; }

cleanup_mount() {
  local mnt="$1"
  if /sbin/mount | /usr/bin/grep -F " on $mnt " >/dev/null 2>&1; then
    /sbin/umount "$mnt" >/dev/null 2>&1 || sudo /sbin/umount "$mnt" >/dev/null 2>&1 || true
  fi
  sudo /bin/rm -rf "$mnt" >/dev/null 2>&1 || true
}

cleanup() {
  if [[ -n "$LOOP_PID" ]] && kill -0 "$LOOP_PID" >/dev/null 2>&1; then kill "$LOOP_PID" >/dev/null 2>&1 || true; fi
  if [[ -n "$MINFS_PID" ]] && kill -0 "$MINFS_PID" >/dev/null 2>&1; then kill "$MINFS_PID" >/dev/null 2>&1 || true; fi
  if [[ -n "$LOG_PID" ]] && kill -0 "$LOG_PID" >/dev/null 2>&1; then sudo kill "$LOG_PID" >/dev/null 2>&1 || true; fi
  cleanup_mount "$LOOP_MNT"
  cleanup_mount "$MINFS_MNT"
}
trap cleanup EXIT INT TERM

wait_for_file() {
  local path="$1"
  for _ in $(seq 1 60); do
    if [[ -r "$path" ]]; then return 0; fi
    sleep 0.2
  done
  return 1
}

start_live_log() {
  section "Start live policy/runtime log"
  sudo /usr/bin/log stream --style compact --level debug \
    --predicate '(subsystem IN {"com.apple.FSKit","com.apple.LiveFS","io.macfuse"}) OR (process IN {"fskitd","fskit_agent","pkd","runningboardd","syspolicyd","amfid","taskgated-helper","taskgated"})' \
    > "$LIVE_LOG" 2>&1 &
  LOG_PID=$!
  log "live_log_pid=$LOG_PID"
  sleep 1
}

stop_live_log() {
  if [[ -n "$LOG_PID" ]] && kill -0 "$LOG_PID" >/dev/null 2>&1; then
    sudo kill "$LOG_PID" >/dev/null 2>&1 || true
    sleep 0.5
  fi
}

section "System"
/usr/bin/sw_vers 2>&1 | tee -a "$REPORT"
/usr/bin/uname -m 2>&1 | tee -a "$REPORT"
log "uid=$UID_NOW gid=$GID_NOW user=$(id -un)"
/usr/sbin/pkgutil --pkg-info io.macfuse.installer.components.core 2>&1 | tee -a "$REPORT" || true
/usr/bin/pluginkit -m -A -D -i io.macfuse.app.fsmodule.macfuse-local 2>&1 | tee -a "$REPORT" || true

sudo -v
start_live_log

section "Known-good baseline A: stock LoopbackFS-libfuse3-C with subdir module"
/bin/rm -rf "$DEMO" "$LOOP_SRC"
mkdir -p "$LOOP_SRC"
printf 'known-good-loopback\n' > "$LOOP_SRC/probe.txt"

if /usr/bin/git clone --depth 1 https://github.com/macfuse/demo.git "$DEMO" >> "$REPORT" 2>&1; then
  LOOP_SRC_C="$DEMO/LoopbackFS/LoopbackFS-libfuse3-C/main.c"
  if [[ -f "$LOOP_SRC_C" ]]; then
    if /usr/bin/cc -O0 -D_FILE_OFFSET_BITS=64 -I/usr/local/include "$LOOP_SRC_C" -L/usr/local/lib -lfuse3 -o "$LOOPBACK3" >> "$REPORT" 2>&1; then
      cleanup_mount "$LOOP_MNT"
      sudo /bin/mkdir "$LOOP_MNT"
      sudo /usr/sbin/chown "$UID_NOW:$GID_NOW" "$LOOP_MNT"
      /bin/chmod 700 "$LOOP_MNT"
      log "command=$LOOPBACK3 -f -o backend=fskit,modules=subdir,subdir=$LOOP_SRC,volname=EDPKnownGood $LOOP_MNT"
      "$LOOPBACK3" -f -o "backend=fskit,modules=subdir,subdir=$LOOP_SRC,volname=EDPKnownGood" "$LOOP_MNT" > "$LOOP_LOG" 2>&1 &
      LOOP_PID=$!
      if wait_for_file "$LOOP_MNT/probe.txt"; then
        CONTENT="$(/bin/cat "$LOOP_MNT/probe.txt" 2>/dev/null || true)"
        if [[ "$CONTENT" == "known-good-loopback" ]]; then LOOP_PASS=1; fi
      fi
      log "loopback3_pass=$LOOP_PASS"
      /sbin/mount | /usr/bin/grep -i -E 'macfuse|edp-loopback-known-good' | tee -a "$REPORT" || true
      /bin/cat "$LOOP_LOG" | tee -a "$REPORT" || true
      if [[ -n "$LOOP_PID" ]] && kill -0 "$LOOP_PID" >/dev/null 2>&1; then kill "$LOOP_PID" >/dev/null 2>&1 || true; fi
      cleanup_mount "$LOOP_MNT"
    else
      log "loopback3_build_failed=1"
    fi
  else
    log "loopback3_source_missing=1"
  fi
else
  log "demo_clone_failed=1"
fi

section "Known-good baseline B: exact minfs.c from macFUSE issue #1181"
if /usr/bin/curl -fsSL https://api.github.com/repos/macfuse/macfuse/issues/1181 -o "$ISSUE_JSON"; then
  if /usr/bin/python3 - "$ISSUE_JSON" "$MINFS_C" <<'PY'
import json, re, sys
src, out = sys.argv[1], sys.argv[2]
with open(src, 'r', encoding='utf-8') as f:
    body = json.load(f)['body']
m = re.search(r'```c\n(.*?)\n```', body, re.S)
if not m:
    raise SystemExit(2)
with open(out, 'w', encoding='utf-8') as f:
    f.write(m.group(1))
PY
  then
    log "minfs_source_sha256=$(/usr/bin/shasum -a 256 "$MINFS_C" | /usr/bin/awk '{print $1}')"
    if /usr/bin/cc -o "$MINFS_BIN" "$MINFS_C" -D_FILE_OFFSET_BITS=64 -DFUSE_USE_VERSION=26 -I/usr/local/include -L/usr/local/lib -lfuse >> "$REPORT" 2>&1; then
      cleanup_mount "$MINFS_MNT"
      sudo /bin/mkdir "$MINFS_MNT"
      sudo /usr/sbin/chown "$UID_NOW:$GID_NOW" "$MINFS_MNT"
      /bin/chmod 700 "$MINFS_MNT"
      log "command=$MINFS_BIN -f -o backend=fskit,uid=$UID_NOW,gid=$GID_NOW $MINFS_MNT"
      "$MINFS_BIN" -f -o "backend=fskit,uid=$UID_NOW,gid=$GID_NOW" "$MINFS_MNT" > "$MINFS_LOG" 2>&1 &
      MINFS_PID=$!
      if wait_for_file "$MINFS_MNT/small.sh"; then
        if /bin/cat "$MINFS_MNT/small.sh" >/dev/null 2>&1; then MINFS_PASS=1; fi
      fi
      log "minfs1181_pass=$MINFS_PASS"
      /sbin/mount | /usr/bin/grep -i -E 'macfuse|edp-minfs-1181' | tee -a "$REPORT" || true
      /bin/cat "$MINFS_LOG" | tee -a "$REPORT" || true
      if [[ -n "$MINFS_PID" ]] && kill -0 "$MINFS_PID" >/dev/null 2>&1; then kill "$MINFS_PID" >/dev/null 2>&1 || true; fi
      cleanup_mount "$MINFS_MNT"
    else
      log "minfs_build_failed=1"
    fi
  else
    log "minfs_extract_failed=1"
  fi
else
  log "issue_fetch_failed=1"
fi

stop_live_log

section "Relevant live policy/runtime events"
/usr/bin/grep -i -E 'activateVolume|Channel created|channel|invalidat|deny|denied|reject|signature|entitlement|sandbox|terminate|termination|kill|memorystatus|extension|MFDaemon|MFMount' "$LIVE_LOG" | /usr/bin/tail -n 500 | tee -a "$REPORT" || true

CHANNEL_INVALIDATED=0
POLICY_DENIAL=0
if /usr/bin/grep -i -E -q 'Connection to file system (server|extension) invalidated|MFDaemon\.MountError Code=4' "$LIVE_LOG" "$LOOP_LOG" "$MINFS_LOG" 2>/dev/null; then CHANNEL_INVALIDATED=1; fi
if /usr/bin/grep -i -E -q 'deny|denied|rejected|code signature.*invalid|missing entitlement|sandbox.*deny|taskgated.*reject|amfid.*reject' "$LIVE_LOG" 2>/dev/null; then POLICY_DENIAL=1; fi

section "SUMMARY"
log "loopback3_pass=$LOOP_PASS minfs1181_pass=$MINFS_PASS channel_invalidated=$CHANNEL_INVALIDATED policy_denial=$POLICY_DENIAL"
if [[ "$LOOP_PASS" -eq 1 && "$MINFS_PASS" -eq 1 ]]; then
  log "RESULT=KNOWN_GOOD_BASELINES_PASS"
  log "Interpretation: macFUSE FSKit is healthy. Earlier official LoopbackFS diagnostics were false negatives caused by an incorrect backing-directory invocation. Return to EDP bridge comparison."
elif [[ "$MINFS_PASS" -eq 1 ]]; then
  log "RESULT=MINFS1181_PASS_LOOPBACK_FAIL"
  log "Interpretation: the exact known-good macOS 15.7 minfs path works, so FSKit itself is healthy; investigate LoopbackFS/module invocation separately and return to EDP with the minfs baseline as reference."
elif [[ "$LOOP_PASS" -eq 1 ]]; then
  log "RESULT=LOOPBACK_PASS_MINFS1181_FAIL"
  log "Interpretation: FSKit can mount the stock LoopbackFS correctly; the issue-1181 reproducer path differs, but the system runtime is not globally broken."
elif [[ "$POLICY_DENIAL" -eq 1 ]]; then
  log "RESULT=KNOWN_GOOD_FAIL_WITH_POLICY_DENIAL"
  log "Interpretation: both known-good baselines failed and live system logs contain a policy/signing/sandbox denial. Inspect the matched events above; this is more specific than a generic FSKit runtime failure."
elif [[ "$CHANNEL_INVALIDATED" -eq 1 ]]; then
  log "RESULT=KNOWN_GOOD_BASELINES_CHANNEL_INVALIDATED"
  log "Interpretation: both corrected stock LoopbackFS and the exact issue-1181 minfs fail at channel establishment without an obvious policy denial. The failure is genuinely below EDP; inspect ExtensionKit/RunningBoard process lifecycle and code-signing database state next."
else
  log "RESULT=KNOWN_GOOD_BASELINES_FAIL_OTHER"
  log "Interpretation: inspect build/server/live logs above for the first failing operation."
fi
log "REPORT=$REPORT"

if [[ "$LOOP_PASS" -eq 1 || "$MINFS_PASS" -eq 1 ]]; then exit 0; else exit 1; fi
