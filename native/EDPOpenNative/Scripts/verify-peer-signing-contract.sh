#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IDENTITY="${EDP_CODE_SIGN_IDENTITY:-EDP Project Code Signing}"
LEAF_SHA1="040b5488fb2b6c02b0786e76b674cb4460658ca2"
APP_ID="com.evolution404.edpopen"
BROKER_ID="com.evolution404.edpopen.rawbroker"
APP_REQUIREMENT="identifier \"${APP_ID}\" and certificate leaf = H\"${LEAF_SHA1}\""
BROKER_REQUIREMENT="identifier \"${BROKER_ID}\" and certificate leaf = H\"${LEAF_SHA1}\""
LOGIN_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
DEFAULT_BEFORE="$(/usr/bin/security default-keychain -d user)"
SEARCH_BEFORE="$(/usr/bin/security list-keychains -d user)"
TMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/edpopen-peer-signing.XXXXXX")"

cleanup() {
  /bin/rm -rf "${TMP_ROOT}"
  local default_after search_after
  default_after="$(/usr/bin/security default-keychain -d user)"
  search_after="$(/usr/bin/security list-keychains -d user)"
  if [[ "${default_after}" != "${DEFAULT_BEFORE}" || "${search_after}" != "${SEARCH_BEFORE}" ]]; then
    echo "ERROR=user DefaultKeychain/SearchList changed during peer signing contract" >&2
    return 1
  fi
}
trap cleanup EXIT INT TERM

fail() {
  echo "ERROR=$*" >&2
  exit 1
}

/usr/bin/security find-identity -v -p codesigning "${LOGIN_KEYCHAIN}" | /usr/bin/grep -Fq "\"${IDENTITY}\"" \
  || fail "EDP project signing identity is not available in login.keychain"

GOOD_APP="${TMP_ROOT}/good-app"
GOOD_BROKER="${TMP_ROOT}/good-broker"
/bin/cp /usr/bin/true "${GOOD_APP}"
/bin/cp /usr/bin/true "${GOOD_BROKER}"

/usr/bin/codesign --force --identifier "${APP_ID}" --sign "${IDENTITY}" --timestamp=none "${GOOD_APP}" >/dev/null
/usr/bin/codesign --force --identifier "${BROKER_ID}" --sign "${IDENTITY}" --timestamp=none "${GOOD_BROKER}" >/dev/null
/usr/bin/codesign --verify --strict -R="${APP_REQUIREMENT}" "${GOOD_APP}"
/usr/bin/codesign --verify --strict -R="${BROKER_REQUIREMENT}" "${GOOD_BROKER}"

# Generate a completely separate self-signed code-signing identity and use it to sign
# real negative-test binaries. The identity is constructed directly from temporary DER
# certificate/private-key material, so no trust settings or keychain state are changed.
ALT_IDENTITY="EDPOpen Alternate Test Signing"
EXPLICIT_SIGNER="${TMP_ROOT}/explicit-identity-sign"
/usr/bin/cc -std=c17 -Wall -Wextra \
  "${SCRIPT_DIR}/explicit-identity-sign.c" \
  -framework Security -framework CoreFoundation \
  -o "${EXPLICIT_SIGNER}"
/usr/bin/openssl req -new -newkey rsa:2048 -nodes -x509 -sha256 -days 1 \
  -subj "/CN=${ALT_IDENTITY}/O=EDP Negative Test" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -keyout "${TMP_ROOT}/alternate.key.pem" \
  -out "${TMP_ROOT}/alternate.crt.pem" >/dev/null 2>&1
/usr/bin/openssl x509 \
  -in "${TMP_ROOT}/alternate.crt.pem" \
  -outform DER \
  -out "${TMP_ROOT}/alternate.crt.der"
/usr/bin/openssl rsa \
  -in "${TMP_ROOT}/alternate.key.pem" \
  -outform DER \
  -out "${TMP_ROOT}/alternate.key.der" >/dev/null 2>&1
ALT_SHA1="$(/usr/bin/openssl x509 -in "${TMP_ROOT}/alternate.crt.pem" -noout -fingerprint -sha1 \
  | /usr/bin/cut -d= -f2 | /usr/bin/tr -d ':')"
ALT_SHA1_LOWER="$(/usr/bin/printf '%s' "${ALT_SHA1}" | /usr/bin/tr '[:upper:]' '[:lower:]')"
[[ -n "${ALT_SHA1}" && "${ALT_SHA1_LOWER}" != "${LEAF_SHA1}" ]] \
  || fail "alternate self-signed certificate did not produce a distinct leaf fingerprint"
ALT_APP_REQUIREMENT="identifier \"${APP_ID}\" and certificate leaf = H\"${ALT_SHA1}\""
ALT_BROKER_REQUIREMENT="identifier \"${BROKER_ID}\" and certificate leaf = H\"${ALT_SHA1}\""
BAD_APP="${TMP_ROOT}/bad-app"
BAD_BROKER="${TMP_ROOT}/bad-broker"
/bin/cp /usr/bin/true "${BAD_APP}"
/bin/cp /usr/bin/true "${BAD_BROKER}"
/usr/bin/codesign --remove-signature "${BAD_APP}" >/dev/null 2>&1 || true
/usr/bin/codesign --remove-signature "${BAD_BROKER}" >/dev/null 2>&1 || true
"${EXPLICIT_SIGNER}" \
  "${TMP_ROOT}/alternate.crt.der" \
  "${TMP_ROOT}/alternate.key.der" \
  "${BAD_APP}" \
  "${APP_ID}" >/dev/null
"${EXPLICIT_SIGNER}" \
  "${TMP_ROOT}/alternate.crt.der" \
  "${TMP_ROOT}/alternate.key.der" \
  "${BAD_BROKER}" \
  "${BROKER_ID}" >/dev/null
/usr/bin/codesign --verify --strict -R="${ALT_APP_REQUIREMENT}" "${BAD_APP}"
/usr/bin/codesign --verify --strict -R="${ALT_BROKER_REQUIREMENT}" "${BAD_BROKER}"
if /usr/bin/codesign --verify --strict -R="${APP_REQUIREMENT}" "${BAD_APP}" >/dev/null 2>&1; then
  fail "production App requirement accepted a different self-signed leaf"
fi
if /usr/bin/codesign --verify --strict -R="${BROKER_REQUIREMENT}" "${BAD_BROKER}" >/dev/null 2>&1; then
  fail "production Broker requirement accepted a different self-signed leaf"
fi

APP_PATH="${EDPOPEN_APP_PATH:-/private/tmp/edpopen-native-derived-data/Build/Products/Debug/EDPOpen.app}"
BROKER_PATH="${EDPOPEN_BROKER_PATH:-/private/tmp/edpopen-native-derived-data/Build/Products/Debug/EDPOpenRawBroker}"
if [[ -e "${APP_PATH}" ]]; then
  /usr/bin/codesign --verify --strict -R="${APP_REQUIREMENT}" "${APP_PATH}"
fi
if [[ -e "${BROKER_PATH}" ]]; then
  /usr/bin/codesign --verify --strict -R="${BROKER_REQUIREMENT}" "${BROKER_PATH}"
fi

echo "RESULT=EDPOPEN_SHARED_LEAF_PEER_TRUST_OK"
