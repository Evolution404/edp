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
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
"${LSREGISTER}" -f -R -trusted "${APP}"
while IFS= read -r extension; do
  pluginkit -a "${extension}" || true
done < <(find "${APP}/Contents" -maxdepth 5 -type d -name '*.appex' -print)
pluginkit -a "${APP}" || true
pluginkit -e use -i "${GENERIC_ID}" || true
pluginkit -e use -i "${LOCAL_ID}" || true

SETTINGS="${HOME}/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist"
mkdir -p "$(dirname "${SETTINGS}")"
python3 - "${SETTINGS}" "${GENERIC_ID}" "${LOCAL_ID}" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as handle:
    plistlib.dump(sys.argv[2:], handle, fmt=plistlib.FMT_XML, sort_keys=False)
PY
chmod 600 "${SETTINGS}"

killall -9 fskit_agent extensionkitservice 2>/dev/null || true
sudo killall -9 fskitd 2>/dev/null || true
sleep 3
pluginkit -m -p com.apple.fskit.fsmodule -A -D -vv >"${RUNNER_TEMP:-${TMPDIR:-/tmp}}/macfuse-plugins.txt" || true
grep -Fq "+    ${LOCAL_ID}" "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/macfuse-plugins.txt"
test -d /Library/Filesystems/macfuse.fs/Contents/Frameworks/MFMount.framework

echo 'RESULT=DRIVE_CI_MACFUSE_LOCAL_READY'
