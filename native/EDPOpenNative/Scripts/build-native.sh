#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IDENTITY="EDP Unified Local Code Signing"
EXPECTED_CERT_SHA256="EA97420A16432AAB05E6E775E8E1698FD9A0E33B3F65CA66186A8AA683850F85"
EXPECTED_CERT_ROOT_SHA1="fda987d4d26950461a1f1810b3a66eb8bf8724c3"
LOGIN_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CONFIGURATION="${EDPOPEN_CONFIGURATION:-Debug}"
DERIVED_DATA="${EDPOPEN_DERIVED_DATA:-/private/tmp/edpopen-native-derived-data}"

fail() {
  echo "ERROR=$*" >&2
  exit 1
}

[[ -d "${DEVELOPER_DIR}" ]] || fail "Xcode developer directory not found: ${DEVELOPER_DIR}"
[[ -f "${LOGIN_KEYCHAIN}" ]] || fail "login keychain not found: ${LOGIN_KEYCHAIN}"

CERT_PEM="$(/usr/bin/security find-certificate -c "${IDENTITY}" -p "${LOGIN_KEYCHAIN}" 2>/dev/null || true)"
[[ -n "${CERT_PEM}" ]] || fail "unified EDP signing certificate is not installed in login.keychain"
ACTUAL_CERT_SHA256="$(/usr/bin/printf '%s' "${CERT_PEM}" \
  | /usr/bin/openssl x509 -noout -fingerprint -sha256 \
  | /usr/bin/cut -d= -f2 | /usr/bin/tr -d ':')"
[[ "${ACTUAL_CERT_SHA256}" == "${EXPECTED_CERT_SHA256}" ]] \
  || fail "unexpected unified EDP signing certificate fingerprint: ${ACTUAL_CERT_SHA256}"

PROBE="$(/usr/bin/mktemp /private/tmp/edpopen-signing-probe.XXXXXX)"
cleanup() { /bin/rm -f "${PROBE}"; }
trap cleanup EXIT INT TERM
/bin/cp /usr/bin/true "${PROBE}"
/usr/bin/codesign --force --sign "${IDENTITY}" "${PROBE}" >/dev/null
REQUIREMENT="$(/usr/bin/codesign -dr - "${PROBE}" 2>&1)"
/usr/bin/grep -Fq "certificate root = H\"${EXPECTED_CERT_ROOT_SHA1}\"" <<<"${REQUIREMENT}" \
  || fail "unified EDP signing private key does not match the pinned certificate root"

exec env DEVELOPER_DIR="${DEVELOPER_DIR}" /usr/bin/xcodebuild \
  -project "${PROJECT_ROOT}/EDPOpenNative.xcodeproj" \
  -scheme EDPOpen \
  -configuration "${CONFIGURATION}" \
  -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM='' \
  CODE_SIGN_IDENTITY="${IDENTITY}" \
  build
