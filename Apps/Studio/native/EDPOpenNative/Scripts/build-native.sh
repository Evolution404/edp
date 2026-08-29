#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IDENTITY="${EDP_CODE_SIGN_IDENTITY:-EDP Project Code Signing}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CONFIGURATION="${EDPOPEN_CONFIGURATION:-Release}"
DERIVED_DATA="${EDPOPEN_DERIVED_DATA:-/private/tmp/edpopen-native-derived-data}"

fail() {
  echo "ERROR=$*" >&2
  exit 1
}

[[ -d "${DEVELOPER_DIR}" ]] || fail "Xcode developer directory not found: ${DEVELOPER_DIR}"
"${SCRIPT_DIR}/verify-signing-identity.sh"

exec env DEVELOPER_DIR="${DEVELOPER_DIR}" /usr/bin/xcodebuild \
  -project "${PROJECT_ROOT}/EDPOpenNative.xcodeproj" \
  -scheme EDPOpen \
  -configuration "${CONFIGURATION}" \
  -derivedDataPath "${DERIVED_DATA}" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM='' \
  CODE_SIGN_IDENTITY="${IDENTITY}" \
  build
