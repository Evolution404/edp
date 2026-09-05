#!/usr/bin/env bash
set -euo pipefail

MACFUSE_VERSION="${MACFUSE_VERSION:-5.3.3}"
MACFUSE_DMG_SHA256="${MACFUSE_DMG_SHA256:-7a0b7b66c0e7f8932707d1215dc9cf486e178d097ae0a2dcdf17d8530566aa15}"
MACFUSE_DMG_URL="${MACFUSE_DMG_URL:-https://github.com/macfuse/macfuse/releases/download/macfuse-${MACFUSE_VERSION}/macfuse-${MACFUSE_VERSION}.dmg}"
LOCAL_ID="io.macfuse.app.fsmodule.macfuse-local"
GENERIC_ID="io.macfuse.app.fsmodule.macfuse"
DMG="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/macfuse-${MACFUSE_VERSION}.dmg"

if [[ "$(sw_vers -productVersion | cut -d. -f1)" -lt 26 ]]; then
  echo 'macOS 26+ is required for the Drive FSKit regression suite' >&2
  exit 1
fi

if [[ ! -d /Library/Filesystems/macfuse.fs ]]; then
  curl -fsSL --retry 3 "${MACFUSE_DMG_URL}" -o "${DMG}"
  [[ "$(shasum -a 256 "${DMG}" | awk '{print $1}')" == "${MACFUSE_DMG_SHA256}" ]]
  ATTACH="$(hdiutil attach -nobrowse -readonly "${DMG}")"
  VOL="$(printf '%s\n' "${ATTACH}" | awk -F '\t' '/\/Volumes\// {print $NF; exit}')"
  PKG="$(find "${VOL}" -maxdepth 2 \( -type f -o -type d \) -name '*.pkg' -print -quit)"
  pkgutil --check-signature "${PKG}"
  sudo installer -pkg "${PKG}" -target /
  hdiutil detach "${VOL}" >/dev/null
fi

APP="/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app"
MACFUSE_BIN="${APP}/Contents/MacOS/macfuse"
test -x "${MACFUSE_BIN}"
# Use macFUSE's supported registration path. The hosted runner cannot click the
# macOS File System Extensions approval UI, so the block below supplies only a
# CI fixture for that user-owned approval state; production code must never
# write this private plist or restart the system fskitd daemon.
"${MACFUSE_BIN}" install --components file-system-extensions --force

SETTINGS="${HOME}/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist"
mkdir -p "$(dirname "${SETTINGS}")"
python3 - "${SETTINGS}" "${GENERIC_ID}" "${LOCAL_ID}" <<'PY'
import os, plistlib, sys
path = sys.argv[1]
modules = []
if os.path.exists(path):
    with open(path, 'rb') as handle:
        value = plistlib.load(handle)
    if isinstance(value, list):
        modules = [item for item in value if isinstance(item, str)]
for module_id in sys.argv[2:]:
    if module_id not in modules:
        modules.append(module_id)
with open(path, 'wb') as handle:
    plistlib.dump(modules, handle, fmt=plistlib.FMT_XML, sort_keys=False)
PY
chmod 600 "${SETTINGS}"

# Restart only the disposable current-user agents so they reload the CI approval
# fixture. Never kill/reset system fskitd; the storage suite's real MFMount is
# the readiness authority and will fail if this setup did not converge.
killall -9 fskit_agent extensionkitservice 2>/dev/null || true

test -d /Library/Filesystems/macfuse.fs/Contents/Frameworks/MFMount.framework

echo 'RESULT=DRIVE_CI_MACFUSE_LOCAL_APPROVAL_FIXTURE_READY'
