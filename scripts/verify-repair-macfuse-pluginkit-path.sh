#!/bin/bash
set -u
set -o pipefail

BASE="${TMPDIR:-/tmp}/edp-macfuse-pluginkit-path"
REPORT="$BASE/report.txt"
BEFORE="$BASE/pluginkit-before.txt"
AFTER="$BASE/pluginkit-after.txt"
BASELINE="$BASE/baseline.txt"
FSROOT="/Library/Filesystems/macfuse.fs"
APP="$FSROOT/Contents/Resources/macfuse.app"
LOCAL="$APP/Contents/Extensions/io.macfuse.app.fsmodule.macfuse-local.appex"
LOCAL_ID="io.macfuse.app.fsmodule.macfuse-local"
MACFUSE_BIN="$APP/Contents/MacOS/macfuse"

mkdir -p "$BASE"
: > "$REPORT"
: > "$BEFORE"
: > "$AFTER"
: > "$BASELINE"

log(){ printf '%s\n' "$*" | tee -a "$REPORT"; }
section(){ log ""; log "=== $* ==="; }

canonical_path() {
  /usr/bin/python3 - "$1" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
}

plugin_path_from_verbose() {
  local file="$1"
  /usr/bin/awk '
    /^[[:space:]]*Path[[:space:]]*=/ {
      sub(/^[[:space:]]*Path[[:space:]]*=[[:space:]]*/, "")
      path=$0
    }
    END { if (path != "") print path }
  ' "$file"
}

query_plugin() {
  local outfile="$1"
  /usr/bin/pluginkit -mAvvv -i "$LOCAL_ID" > "$outfile" 2>&1 || true
  /bin/cat "$outfile" | tee -a "$REPORT"
}

restart_registration_runtime() {
  section "Restart PluginKit / FSKit runtime after official re-registration"
  sudo /usr/bin/killall pkd >/dev/null 2>&1 || true
  sudo /usr/bin/killall fskitd >/dev/null 2>&1 || true
  /usr/bin/killall fskit_agent >/dev/null 2>&1 || true
  sleep 2
  log "pkd_pid=$(/usr/bin/pgrep -x pkd | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//' || true)"
  log "fskitd_pid=$(/usr/bin/pgrep -x fskitd | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//' || true)"
  log "fskit_agent_pid=$(/usr/bin/pgrep -x fskit_agent | /usr/bin/tr '\n' ',' | /usr/bin/sed 's/,$//' || true)"
}

section "System"
/usr/bin/sw_vers 2>&1 | tee -a "$REPORT"
/usr/sbin/pkgutil --pkg-info io.macfuse.installer.components.core 2>&1 | tee -a "$REPORT" || true
log "installed_local_path=$LOCAL"

if [[ ! -d "$LOCAL" ]]; then
  section "SUMMARY"
  log "RESULT=INSTALLED_LOCAL_EXTENSION_MISSING"
  log "REPORT=$REPORT"
  exit 2
fi

if [[ ! -x "$MACFUSE_BIN" ]]; then
  section "SUMMARY"
  log "RESULT=MACFUSE_INSTALLER_HELPER_MISSING"
  log "REPORT=$REPORT"
  exit 2
fi

section "PluginKit verbose record before"
query_plugin "$BEFORE"

INSTALLED_REAL="$(canonical_path "$LOCAL")"
BEFORE_PATH="$(plugin_path_from_verbose "$BEFORE")"
BEFORE_REAL=""
if [[ -n "$BEFORE_PATH" ]]; then
  BEFORE_REAL="$(canonical_path "$BEFORE_PATH")"
fi

log "installed_realpath=$INSTALLED_REAL"
log "pluginkit_path_before=${BEFORE_PATH:-<missing>}"
log "pluginkit_realpath_before=${BEFORE_REAL:-<missing>}"

BEFORE_MATCH=0
if [[ -n "$BEFORE_REAL" && "$BEFORE_REAL" == "$INSTALLED_REAL" ]]; then
  BEFORE_MATCH=1
fi
log "path_match_before=$BEFORE_MATCH"

REPAIR_ATTEMPTED=0
INSTALL_RC="not-run"
AFTER_MATCH=$BEFORE_MATCH
AFTER_PATH="$BEFORE_PATH"
AFTER_REAL="$BEFORE_REAL"

if [[ "$BEFORE_MATCH" -eq 0 ]]; then
  section "Verified mismatch: run macFUSE official FSKit re-registration"
  REPAIR_ATTEMPTED=1
  sudo -v
  set +e
  sudo "$MACFUSE_BIN" install --components file-system-extensions --force 2>&1 | tee -a "$REPORT"
  INSTALL_RC=${PIPESTATUS[0]}
  set -e
  log "official_reregister_rc=$INSTALL_RC"
  restart_registration_runtime

  section "PluginKit verbose record after"
  query_plugin "$AFTER"
  AFTER_PATH="$(plugin_path_from_verbose "$AFTER")"
  AFTER_REAL=""
  if [[ -n "$AFTER_PATH" ]]; then
    AFTER_REAL="$(canonical_path "$AFTER_PATH")"
  fi
  log "pluginkit_path_after=${AFTER_PATH:-<missing>}"
  log "pluginkit_realpath_after=${AFTER_REAL:-<missing>}"
  AFTER_MATCH=0
  if [[ -n "$AFTER_REAL" && "$AFTER_REAL" == "$INSTALLED_REAL" ]]; then
    AFTER_MATCH=1
  fi
  log "path_match_after=$AFTER_MATCH"
else
  section "PluginKit path already matches installed extension"
  log "No registration mutation performed."
fi

BASELINE_RC="not-run"
MINFS_PASS="unknown"
BASELINE_RESULT="unknown"
if [[ "$AFTER_MATCH" -eq 1 && -f scripts/test-fskit-known-good-baselines.sh ]]; then
  section "Run known-good FSKit baseline"
  set +e
  bash scripts/test-fskit-known-good-baselines.sh > >(tee "$BASELINE" | tee -a "$REPORT") 2> >(tee -a "$BASELINE" "$REPORT" >&2)
  BASELINE_RC=$?
  set -e
  MINFS_PASS="$(/usr/bin/sed -n 's/.*minfs1181_pass=\([01]\).*/\1/p' "$BASELINE" | /usr/bin/tail -n 1)"
  [[ -n "$MINFS_PASS" ]] || MINFS_PASS="unknown"
  BASELINE_RESULT="$(/usr/bin/sed -n 's/.*RESULT=\([A-Z0-9_]*\).*/\1/p' "$BASELINE" | /usr/bin/tail -n 1)"
  [[ -n "$BASELINE_RESULT" ]] || BASELINE_RESULT="unknown"
fi

section "SUMMARY"
log "path_match_before=$BEFORE_MATCH repair_attempted=$REPAIR_ATTEMPTED official_reregister_rc=$INSTALL_RC path_match_after=$AFTER_MATCH"
log "minfs1181_pass=$MINFS_PASS baseline_rc=$BASELINE_RC baseline_result=$BASELINE_RESULT"

if [[ "$BEFORE_MATCH" -eq 1 && "$MINFS_PASS" == "1" ]]; then
  log "RESULT=PLUGIN_PATH_WAS_ALREADY_CORRECT_BASELINE_PASS"
  log "Interpretation: PluginKit already resolved macfuse-local to the installed appex, and the known-good baseline now mounts. The earlier path-mismatch diagnosis was a false positive."
elif [[ "$BEFORE_MATCH" -eq 1 ]]; then
  log "RESULT=PLUGIN_PATH_ALREADY_CORRECT_BASELINE_STILL_FAILS"
  log "Interpretation: the previous path-mismatch result was a diagnostic false positive. Registration-path mismatch is not the cause; continue with virtual-disk FSKit metadata/activation."
elif [[ "$REPAIR_ATTEMPTED" -eq 1 && "$AFTER_MATCH" -eq 0 ]]; then
  log "RESULT=VERIFIED_PLUGIN_PATH_MISMATCH_NOT_REPAIRED"
  log "Interpretation: verbose PluginKit data proves a real stale/missing path, and macFUSE's official forced re-registration did not correct it. Do not proceed to EDP; inspect the exact before/after Path lines."
elif [[ "$AFTER_MATCH" -eq 1 && "$MINFS_PASS" == "1" ]]; then
  log "RESULT=PLUGIN_PATH_REPAIR_RESTORED_FSKIT"
  log "Interpretation: a verified stale PluginKit path was corrected by macFUSE's official registration flow, and the known-good minfs mount recovered. This establishes the stale registration as causal."
elif [[ "$AFTER_MATCH" -eq 1 ]]; then
  log "RESULT=PLUGIN_PATH_REPAIRED_BASELINE_STILL_FAILS"
  log "Interpretation: the PluginKit path mismatch was real and is now fixed, but it was not sufficient to restore FSKit. Continue below registration into virtual-disk activation/matching."
else
  log "RESULT=PLUGIN_PATH_DIAGNOSTIC_OTHER"
fi
log "REPORT=$REPORT"
