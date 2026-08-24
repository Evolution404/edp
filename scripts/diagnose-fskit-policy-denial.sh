#!/bin/bash
set -u
set -o pipefail

BASE="${TMPDIR:-/tmp}/edp-fskit-policy-denial"
REPORT="$BASE/report.txt"
LIVE="$BASE/live.log"
MINFS_LOG="$BASE/minfs.log"
ISSUE_JSON="$BASE/issue-1181.json"
MINFS_C="$BASE/minfs.c"
MINFS_BIN="$BASE/minfs"
MNT="/Volumes/edp-fskit-policy-test"
UID_NOW="$(id -u)"
GID_NOW="$(id -g)"
LOG_PID=""
MINFS_PID=""
PASS=0

mkdir -p "$BASE"
: > "$REPORT"
: > "$LIVE"
: > "$MINFS_LOG"

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
section() { log ""; log "=== $* ==="; }

cleanup() {
  if [[ -n "$MINFS_PID" ]] && kill -0 "$MINFS_PID" >/dev/null 2>&1; then kill "$MINFS_PID" >/dev/null 2>&1 || true; fi
  if [[ -n "$LOG_PID" ]] && kill -0 "$LOG_PID" >/dev/null 2>&1; then sudo kill "$LOG_PID" >/dev/null 2>&1 || true; fi
  if /sbin/mount | /usr/bin/grep -F " on $MNT " >/dev/null 2>&1; then
    /sbin/umount "$MNT" >/dev/null 2>&1 || sudo /sbin/umount "$MNT" >/dev/null 2>&1 || true
  fi
  sudo /bin/rm -rf "$MNT" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

section "System"
/usr/bin/sw_vers 2>&1 | tee -a "$REPORT"
/usr/bin/uname -m 2>&1 | tee -a "$REPORT"
log "uid=$UID_NOW gid=$GID_NOW user=$(id -un)"
/usr/sbin/pkgutil --pkg-info io.macfuse.installer.components.core 2>&1 | tee -a "$REPORT" || true

section "SIP status (read-only)"
/usr/bin/csrutil status 2>&1 | tee -a "$REPORT" || true

section "DetachedSignatures state"
if [[ -e /private/var/db/DetachedSignatures ]]; then
  /bin/ls -ldeO@ /private/var/db/DetachedSignatures 2>&1 | tee -a "$REPORT" || true
  log "detached_signatures_exists=1"
else
  log "detached_signatures_exists=0"
fi

APP="/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app"
LOCAL_APPEX="$APP/Contents/Extensions/io.macfuse.app.fsmodule.macfuse-local.appex"
GENERIC_APPEX="$APP/Contents/Extensions/io.macfuse.app.fsmodule.macfuse.appex"
HELPER="/Library/PrivilegedHelperTools/io.macfuse.app.launchservice.daemon"

section "macFUSE code signatures"
for p in "$APP" "$LOCAL_APPEX" "$GENERIC_APPEX" "$HELPER"; do
  log "--- $p ---"
  if [[ -e "$p" ]]; then
    /usr/bin/codesign --verify --deep --strict --verbose=4 "$p" 2>&1 | tee -a "$REPORT" || true
    /usr/bin/codesign -dv --verbose=4 "$p" 2>&1 | /usr/bin/grep -E 'Identifier=|TeamIdentifier=|Authority=|Runtime Version|CodeDirectory|CDHash=' | tee -a "$REPORT" || true
    /usr/bin/codesign -d --entitlements :- "$p" 2>&1 | tee -a "$REPORT" || true
  else
    log "missing=1"
  fi
done

section "PluginKit state"
/usr/bin/pluginkit -m -A -D -i io.macfuse.app.fsmodule.macfuse-local 2>&1 | tee -a "$REPORT" || true
/usr/bin/pluginkit -m -A -D -i io.macfuse.app.fsmodule.macfuse 2>&1 | tee -a "$REPORT" || true

section "Build exact issue-1181 minfs"
if ! /usr/bin/curl -fsSL https://api.github.com/repos/macfuse/macfuse/issues/1181 -o "$ISSUE_JSON"; then
  log "RESULT=ISSUE_FETCH_FAILED"
  exit 2
fi

if ! /usr/bin/python3 - "$ISSUE_JSON" "$MINFS_C" <<'PY'
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
  log "RESULT=MINFS_EXTRACT_FAILED"
  exit 2
fi

if ! /usr/bin/cc -o "$MINFS_BIN" "$MINFS_C" -D_FILE_OFFSET_BITS=64 -DFUSE_USE_VERSION=26 -I/usr/local/include -L/usr/local/lib -lfuse >> "$REPORT" 2>&1; then
  log "RESULT=MINFS_BUILD_FAILED"
  exit 2
fi

log "minfs_sha256=$(/usr/bin/shasum -a 256 "$MINFS_BIN" | /usr/bin/awk '{print $1}')"
/usr/bin/codesign -dv --verbose=4 "$MINFS_BIN" 2>&1 | tee -a "$REPORT" || true

sudo -v
if /sbin/mount | /usr/bin/grep -F " on $MNT " >/dev/null 2>&1; then sudo /sbin/umount "$MNT" >/dev/null 2>&1 || true; fi
sudo /bin/rm -rf "$MNT"
sudo /bin/mkdir "$MNT"
sudo /usr/sbin/chown "$UID_NOW:$GID_NOW" "$MNT"
/bin/chmod 700 "$MNT"

section "Start strict live log"
sudo /usr/bin/log stream --style compact --level debug \
  --predicate '(process IN {"syspolicyd","amfid","taskgated","taskgated-helper","runningboardd","sandboxd","pkd","fskitd","fskit_agent"}) OR (subsystem IN {"com.apple.FSKit","com.apple.LiveFS","io.macfuse"})' \
  > "$LIVE" 2>&1 &
LOG_PID=$!
sleep 1

section "Run exact minfs"
log "command=$MINFS_BIN -f -o backend=fskit,uid=$UID_NOW,gid=$GID_NOW $MNT"
"$MINFS_BIN" -f -o "backend=fskit,uid=$UID_NOW,gid=$GID_NOW" "$MNT" > "$MINFS_LOG" 2>&1 &
MINFS_PID=$!

for _ in $(seq 1 60); do
  if [[ -r "$MNT/small.sh" ]]; then
    if /bin/cat "$MNT/small.sh" >/dev/null 2>&1; then PASS=1; fi
    break
  fi
  sleep 0.2
done

sleep 1
if [[ -n "$LOG_PID" ]] && kill -0 "$LOG_PID" >/dev/null 2>&1; then sudo kill "$LOG_PID" >/dev/null 2>&1 || true; fi
sleep 0.5

section "Minfs server log"
/bin/cat "$MINFS_LOG" 2>&1 | tee -a "$REPORT" || true

section "Strict security/policy matches"
STRICT="$BASE/strict-policy.txt"
: > "$STRICT"
/usr/bin/grep -i -E \
  'deny|denied|reject|rejected|invalid signature|code signature|signature invalid|missing entitlement|entitlement.*(missing|fail|deny|invalid)|sandbox.*deny|not permitted|operation not permitted|responsibility|validation failed|could not validate|failed.*validation|termination reason|killed by|EXC_|CS_KILL|library validation' \
  "$LIVE" > "$STRICT" 2>/dev/null || true
/bin/cat "$STRICT" | tee -a "$REPORT"

section "FSKit channel lifecycle"
/usr/bin/grep -i -E \
  'startExtension|checkIn|loadResource|activateVolume|Channel created|Connection to file system|invalidated|MFDaemon\.MountError|File system extension' \
  "$LIVE" | /usr/bin/tail -n 300 | tee -a "$REPORT" || true

section "Process-specific strict matches"
for proc in syspolicyd amfid taskgated taskgated-helper runningboardd sandboxd pkd fskitd fskit_agent; do
  log "--- $proc ---"
  /usr/bin/grep -i "$proc" "$STRICT" | /usr/bin/tail -n 80 | tee -a "$REPORT" || true
done

CHANNEL_INVALIDATED=0
SIGNING_DENIAL=0
SANDBOX_DENIAL=0
RUNNINGBOARD_DENIAL=0
PLUGIN_REJECTED=0
DETACHED_MISSING=0

/usr/bin/grep -i -E -q 'Connection to file system (server|extension) invalidated|MFDaemon\.MountError Code=4' "$LIVE" "$MINFS_LOG" 2>/dev/null && CHANNEL_INVALIDATED=1 || true
/usr/bin/grep -i -E -q '(amfid|taskgated|syspolicyd).*(deny|denied|reject|invalid|validation failed|not permitted)|code signature.*(invalid|fail|deny)|missing entitlement' "$STRICT" 2>/dev/null && SIGNING_DENIAL=1 || true
/usr/bin/grep -i -E -q 'sandbox.*deny|sandboxd.*(deny|denied)' "$STRICT" 2>/dev/null && SANDBOX_DENIAL=1 || true
/usr/bin/grep -i -E -q 'runningboardd.*(deny|denied|reject|not permitted|validation failed|termination reason|killed)' "$STRICT" 2>/dev/null && RUNNINGBOARD_DENIAL=1 || true
/usr/bin/grep -i -E -q 'pkd:.*rejecting; Ignoring mis-configured plugin' "$LIVE" 2>/dev/null && PLUGIN_REJECTED=1 || true
[[ -e /private/var/db/DetachedSignatures ]] || DETACHED_MISSING=1

section "SUMMARY"
log "minfs_pass=$PASS channel_invalidated=$CHANNEL_INVALIDATED signing_denial=$SIGNING_DENIAL sandbox_denial=$SANDBOX_DENIAL runningboard_denial=$RUNNINGBOARD_DENIAL plugin_rejected=$PLUGIN_REJECTED detached_signatures_missing=$DETACHED_MISSING"

if [[ "$PASS" -eq 1 ]]; then
  log "RESULT=MINFS_PASS"
  log "Interpretation: the known-good minfs mounted successfully during the strict policy trace; prior failure was transient or caused by the broader test environment."
elif [[ "$SIGNING_DENIAL" -eq 1 ]]; then
  log "RESULT=CODE_SIGNING_POLICY_DENIAL"
  log "Interpretation: amfid/taskgated/syspolicyd emitted a concrete signing or entitlement denial correlated with the FSKit mount. Inspect Strict security/policy matches for the exact object and requirement."
elif [[ "$SANDBOX_DENIAL" -eq 1 ]]; then
  log "RESULT=SANDBOX_POLICY_DENIAL"
  log "Interpretation: a sandbox denial is correlated with the FSKit channel setup. Inspect the exact denied operation/path in Strict security/policy matches."
elif [[ "$RUNNINGBOARD_DENIAL" -eq 1 ]]; then
  log "RESULT=RUNNINGBOARD_POLICY_DENIAL"
  log "Interpretation: RunningBoard rejected or terminated the FSKit extension process during channel setup. Inspect the termination/validation reason."
elif [[ "$PLUGIN_REJECTED" -eq 1 ]]; then
  log "RESULT=PLUGIN_REJECTED_DURING_MOUNT"
  log "Interpretation: PluginKit is still rejecting the macFUSE extension during this exact mount attempt; this is a registration/protection issue, not a FUSE-server issue."
elif [[ "$CHANNEL_INVALIDATED" -eq 1 && "$DETACHED_MISSING" -eq 1 ]]; then
  log "RESULT=CHANNEL_INVALIDATED_WITH_DETACHED_SIGNATURES_DB_MISSING"
  log "Interpretation: the channel still invalidates and /private/var/db/DetachedSignatures is absent, but no strict signing/sandbox rejection was captured. Treat the missing database as a lead, not yet a proven cause."
elif [[ "$CHANNEL_INVALIDATED" -eq 1 ]]; then
  log "RESULT=CHANNEL_INVALIDATED_WITHOUT_STRICT_POLICY_DENIAL"
  log "Interpretation: the channel invalidates but no concrete amfid/taskgated/sandbox/RunningBoard denial is present. The earlier policy_denial=1 was a false positive; continue inside macFUSE/FSKit channel handshake rather than system security policy."
else
  log "RESULT=FAIL_OTHER"
  log "Interpretation: inspect the lifecycle and strict policy sections for the first abnormal event."
fi
log "REPORT=$REPORT"

if [[ "$PASS" -eq 1 ]]; then exit 0; else exit 1; fi
