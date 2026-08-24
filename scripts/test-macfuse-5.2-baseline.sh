#!/bin/bash
set -euo pipefail

VERSION="5.2.0"
DMG_URL="https://github.com/macfuse/macfuse/releases/download/macfuse-${VERSION}/macfuse-${VERSION}.dmg"
EXPECTED_SHA="09a4b4c23c1930af45335fc119696797da41562dec1630602d2db637f4804f27"
WORK="${TMPDIR:-/tmp}/edp-macfuse-5.2-baseline"
DMG="$WORK/macfuse-${VERSION}.dmg"
MOUNT="$WORK/mount"
REPORT="${TMPDIR:-/tmp}/edp-macfuse-5.2-baseline-report.txt"

rm -rf "$WORK"
mkdir -p "$WORK" "$MOUNT"
: > "$REPORT"
log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
section() { log ""; log "=== $* ==="; }

cleanup() {
  /usr/bin/hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

section "Before"
/usr/bin/sw_vers | tee -a "$REPORT"
/usr/sbin/pkgutil --pkg-info io.macfuse.installer.components.core 2>&1 | tee -a "$REPORT" || true

section "Download macFUSE 5.2.0"
/usr/bin/curl -fL --retry 3 --connect-timeout 15 "$DMG_URL" -o "$DMG" 2>&1 | tee -a "$REPORT"
ACTUAL_SHA="$(/usr/bin/shasum -a 256 "$DMG" | /usr/bin/awk '{print $1}')"
log "sha256=$ACTUAL_SHA"
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  log "RESULT=DOWNLOAD_HASH_MISMATCH"
  log "REPORT=$REPORT"
  exit 2
fi

section "Mount installer image"
/usr/bin/hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" 2>&1 | tee -a "$REPORT"
PKG="$(/usr/bin/find "$MOUNT" -maxdepth 3 -type f -name '*.pkg' -print | /usr/bin/head -n 1)"
if [[ -z "$PKG" ]]; then
  log "RESULT=PKG_NOT_FOUND"
  log "REPORT=$REPORT"
  exit 3
fi
log "pkg=$PKG"

section "Install macFUSE 5.2.0"
set +e
sudo /usr/sbin/installer -pkg "$PKG" -target / 2>&1 | tee -a "$REPORT"
INSTALL_RC=${PIPESTATUS[0]}
set -e
log "installer_rc=$INSTALL_RC"
if [[ "$INSTALL_RC" -ne 0 ]]; then
  log "RESULT=DOWNGRADE_INSTALL_FAILED"
  log "Interpretation: installer refused or failed the 5.2.0 downgrade. No uninstall was attempted."
  log "REPORT=$REPORT"
  exit 4
fi

cleanup
trap - EXIT

section "After install"
/usr/sbin/pkgutil --pkg-info io.macfuse.installer.components.core 2>&1 | tee -a "$REPORT" || true
MACFUSE_BIN="/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app/Contents/MacOS/macfuse"
if [[ -x "$MACFUSE_BIN" ]]; then
  "$MACFUSE_BIN" install --components file-system-extensions --force 2>&1 | tee -a "$REPORT" || true
fi
sleep 2
/usr/bin/pluginkit -m -A -D 2>&1 | /usr/bin/grep -i -C 4 macfuse | tee -a "$REPORT" || true

section "Official LoopbackFS baseline"
set +e
bash scripts/test-macfuse-official-loopback.sh 2>&1 | tee -a "$REPORT"
LOOPBACK_RC=${PIPESTATUS[0]}
set -e
log "loopback_rc=$LOOPBACK_RC"

section "SUMMARY"
INSTALLED_VERSION="$(/usr/sbin/pkgutil --pkg-info io.macfuse.installer.components.core 2>/dev/null | /usr/bin/awk -F': ' '/^version:/{print $2}' | /usr/bin/head -n1)"
log "installed_version=${INSTALLED_VERSION:-unknown} loopback_rc=$LOOPBACK_RC"
if [[ "$INSTALLED_VERSION" == "5.2.0" && "$LOOPBACK_RC" -eq 0 ]]; then
  log "RESULT=MACFUSE_5_2_LOOPBACK_PASS"
  log "Interpretation: macFUSE 5.2.0 works while 5.3.3 failed with channel invalidation. This strongly isolates a 5.3.x channel-transport regression/compatibility issue on this Mac."
elif [[ "$INSTALLED_VERSION" == "5.2.0" ]]; then
  log "RESULT=MACFUSE_5_2_LOOPBACK_STILL_FAILS"
  log "Interpretation: downgrading below the 5.3 channel API did not restore the official LoopbackFS. Focus next on macOS FSKit runtime state rather than EDP."
else
  log "RESULT=VERSION_NOT_5_2_AFTER_INSTALL"
  log "Interpretation: the downgrade did not actually replace the installed macFUSE core."
fi
log "REPORT=$REPORT"
