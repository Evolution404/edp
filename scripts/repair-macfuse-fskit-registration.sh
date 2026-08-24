#!/bin/bash
set -euo pipefail

MACFUSE_BIN="/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app/Contents/MacOS/macfuse"
LOCAL_ID="io.macfuse.app.fsmodule.macfuse-local"
GENERIC_ID="io.macfuse.app.fsmodule.macfuse"
REPORT="${TMPDIR:-/tmp}/edp-macfuse-fskit-registration-repair.txt"

: > "$REPORT"
log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
section() { log ""; log "=== $* ==="; }

section "System"
/usr/bin/sw_vers | tee -a "$REPORT"
/usr/bin/csrutil status 2>&1 | tee -a "$REPORT" || true
log "uid=$(id -u) gid=$(id -g) user=$(id -un)"

section "Before: PluginKit records"
/usr/bin/pluginkit -m -A -D 2>&1 | /usr/bin/grep -i -C 4 macfuse | tee -a "$REPORT" || log "No macFUSE PluginKit records before repair"

if [[ ! -x "$MACFUSE_BIN" ]]; then
  log "FAIL: macFUSE management binary not found: $MACFUSE_BIN"
  exit 2
fi

section "macFUSE install help"
"$MACFUSE_BIN" install --help 2>&1 | tee -a "$REPORT" || true

section "Re-register FSKit extensions"
log "Running official macFUSE registration repair: install --components file-system-extensions --force"
set +e
"$MACFUSE_BIN" install --components file-system-extensions --force 2>&1 | tee -a "$REPORT"
INSTALL_RC=${PIPESTATUS[0]}
set -e
log "install_rc=$INSTALL_RC"

sleep 2

section "After: PluginKit records"
PLUGIN_OUTPUT="$(/usr/bin/pluginkit -m -A -D 2>&1 | /usr/bin/grep -i -C 4 macfuse || true)"
printf '%s\n' "$PLUGIN_OUTPUT" | tee -a "$REPORT"

LOCAL_PRESENT=0
GENERIC_PRESENT=0
if printf '%s\n' "$PLUGIN_OUTPUT" | /usr/bin/grep -F "$LOCAL_ID" >/dev/null 2>&1; then LOCAL_PRESENT=1; fi
if printf '%s\n' "$PLUGIN_OUTPUT" | /usr/bin/grep -F "$GENERIC_ID" >/dev/null 2>&1; then GENERIC_PRESENT=1; fi

section "Recent registration logs"
/usr/bin/log show --debug --info \
  --predicate '(process == "pkd") OR (subsystem == "io.macfuse") OR (subsystem == "com.apple.FSKit")' \
  --last 3m 2>&1 | /usr/bin/grep -E -i 'macfuse|plugin|register|reject|FSKit|extension' | /usr/bin/tail -n 250 | tee -a "$REPORT" || true

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
log "install_rc=$INSTALL_RC local_plugin_record=$LOCAL_PRESENT generic_plugin_record=$GENERIC_PRESENT smoke_rc=$SMOKE_RC"
if [[ "$SMOKE_RC" -eq 0 ]]; then
  log "RESULT=REPAIRED"
  log "Interpretation: macFUSE FSKit registration was rebuilt and standalone FSKit mounting now works."
elif [[ "$LOCAL_PRESENT" -eq 0 ]]; then
  log "RESULT=PLUGIN_REGISTRATION_STILL_MISSING"
  log "Interpretation: official macFUSE force-registration did not produce a visible macfuse-local PluginKit record. Inspect the registration logs above; do not change EDP code."
else
  log "RESULT=PLUGIN_REGISTERED_BUT_FSKIT_STILL_FAILS"
  log "Interpretation: PluginKit now sees macFUSE, but the standalone FSKit mount still fails. This points to macOS FSKit/macFUSE runtime state rather than EDP."
fi
log "REPORT=$REPORT"
