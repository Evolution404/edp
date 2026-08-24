#!/bin/bash
set -euo pipefail

MACFUSE_FS="/Library/Filesystems/macfuse.fs"
MACFUSE_APP="$MACFUSE_FS/Contents/Resources/macfuse.app"
MACFUSE_BIN="$MACFUSE_APP/Contents/MacOS/macfuse"
LOCAL_ID="io.macfuse.app.fsmodule.macfuse-local"
GENERIC_ID="io.macfuse.app.fsmodule.macfuse"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
REPORT="${TMPDIR:-/tmp}/edp-macfuse-fskit-registration-repair.txt"

: > "$REPORT"
log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
section() { log ""; log "=== $* ==="; }

plugin_output() {
  /usr/bin/pluginkit -m -A -D 2>&1 | /usr/bin/grep -i -C 5 'io\.macfuse\.app\.fsmodule' || true
}

local_present() {
  /usr/bin/pluginkit -m -A -D 2>/dev/null | /usr/bin/grep -F "$LOCAL_ID" >/dev/null 2>&1
}

generic_present() {
  /usr/bin/pluginkit -m -A -D 2>/dev/null | /usr/bin/grep -F "$GENERIC_ID" >/dev/null 2>&1
}

section "System"
/usr/bin/sw_vers | tee -a "$REPORT"
/usr/bin/csrutil status 2>&1 | tee -a "$REPORT" || true
log "uid=$(id -u) gid=$(id -g) user=$(id -un)"

section "Before: PluginKit records"
plugin_output | tee -a "$REPORT"
if local_present; then
  log "preexisting_local_record=yes"
else
  log "preexisting_local_record=no"
fi

if [[ ! -d "$MACFUSE_APP" ]]; then
  log "RESULT=MACFUSE_APP_MISSING"
  log "REPORT=$REPORT"
  exit 2
fi

if [[ ! -x "$MACFUSE_BIN" ]]; then
  log "RESULT=MACFUSE_CLI_MISSING"
  log "expected=$MACFUSE_BIN"
  log "REPORT=$REPORT"
  exit 2
fi

section "Stage 1: official macFUSE forced FSKit registration"
log "command: $MACFUSE_BIN install --components file-system-extensions --force"
set +e
"$MACFUSE_BIN" install --components file-system-extensions --force 2>&1 | tee -a "$REPORT"
INSTALL_RC=${PIPESTATUS[0]}
set -e
log "install_rc=$INSTALL_RC"
sleep 2

section "After stage 1: PluginKit records"
plugin_output | tee -a "$REPORT"

if ! local_present; then
  section "Stage 2: register the containing macfuse.app with LaunchServices"
  if [[ -x "$LSREGISTER" ]]; then
    log "command: $LSREGISTER -f $MACFUSE_APP"
    set +e
    "$LSREGISTER" -f "$MACFUSE_APP" 2>&1 | tee -a "$REPORT"
    LSREGISTER_RC=${PIPESTATUS[0]}
    set -e
    log "lsregister_rc=$LSREGISTER_RC"
    sleep 2
  else
    LSREGISTER_RC=127
    log "lsregister_missing=$LSREGISTER"
  fi

  section "After stage 2: PluginKit records"
  plugin_output | tee -a "$REPORT"
else
  LSREGISTER_RC=0
  log "Stage 2 skipped: local PluginKit record already exists after native registration."
fi

LOCAL_PRESENT=0
GENERIC_PRESENT=0
if local_present; then LOCAL_PRESENT=1; fi
if generic_present; then GENERIC_PRESENT=1; fi

if [[ "$LOCAL_PRESENT" -eq 1 ]]; then
  section "Enable discovered FSKit records"
  /usr/bin/pluginkit -e use -i "$LOCAL_ID" 2>&1 | tee -a "$REPORT" || true
  if [[ "$GENERIC_PRESENT" -eq 1 ]]; then
    /usr/bin/pluginkit -e use -i "$GENERIC_ID" 2>&1 | tee -a "$REPORT" || true
  fi
  sleep 1
fi

section "Final PluginKit records"
plugin_output | tee -a "$REPORT"

section "Recent registration logs"
/usr/bin/log show --debug --info \
  --predicate '(process == "pkd") OR (subsystem == "io.macfuse") OR (subsystem == "com.apple.PlugInKit") OR (subsystem == "com.apple.FSKit")' \
  --last 5m 2>&1 | /usr/bin/grep -E -i 'macfuse|plugin|register|reject|mis-configured|SIP|FSKit|extension' | /usr/bin/tail -n 250 | tee -a "$REPORT" || true

if [[ "$LOCAL_PRESENT" -eq 0 ]]; then
  section "SUMMARY"
  log "install_rc=$INSTALL_RC lsregister_rc=$LSREGISTER_RC local_plugin_record=0 generic_plugin_record=$GENERIC_PRESENT smoke_rc=not-run"
  log "RESULT=PLUGIN_REGISTRATION_STILL_MISSING"
  log "Interpretation: macFUSE native registration and parent-app LaunchServices registration both failed to produce a valid macfuse-local PluginKit record. Stop here; do not change EDP code or macOS security settings."
  log "REPORT=$REPORT"
  exit 1
fi

section "Standalone FSKit smoke test"
SMOKE_RC=99
if [[ -f scripts/test-fskit-smoke.sh ]]; then
  set +e
  bash scripts/test-fskit-smoke.sh 2>&1 | tee -a "$REPORT"
  SMOKE_RC=${PIPESTATUS[0]}
  set -e
else
  log "Smoke test script not found"
fi

section "SUMMARY"
log "install_rc=$INSTALL_RC lsregister_rc=$LSREGISTER_RC local_plugin_record=$LOCAL_PRESENT generic_plugin_record=$GENERIC_PRESENT smoke_rc=$SMOKE_RC"
if [[ "$SMOKE_RC" -eq 0 ]]; then
  log "RESULT=REPAIRED"
  log "Interpretation: macFUSE FSKit registration was repaired and standalone FSKit mounting now works."
  log "REPORT=$REPORT"
  exit 0
else
  log "RESULT=PLUGIN_REGISTERED_BUT_FSKIT_STILL_FAILS"
  log "Interpretation: PluginKit now sees macFUSE, but standalone FSKit still fails. Do not change EDP permissions; inspect FSKit runtime logs next."
  log "REPORT=$REPORT"
  exit 1
fi
