#!/bin/bash
set -euo pipefail

IDENTITY="${EDP_CODE_SIGN_IDENTITY:-EDP Project Code Signing}"
EXPECTED_CERT_SHA256="D9142CE44ABCB5DD662DF9621D48A88C88EDBCB0392D3C74EBACBB1292B7B5A7"
EXPECTED_CERT_ROOT_SHA1="040b5488fb2b6c02b0786e76b674cb4460658ca2"
LOGIN_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

fail() {
  echo "ERROR=$*" >&2
  exit 1
}

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
/usr/bin/codesign --force --sign "${IDENTITY}" --timestamp=none "${PROBE}" >/dev/null
REQUIREMENT="$(/usr/bin/codesign -dr - "${PROBE}" 2>&1)"
/usr/bin/grep -Fq "certificate root = H\"${EXPECTED_CERT_ROOT_SHA1}\"" <<<"${REQUIREMENT}" \
  || fail "unified EDP signing private key does not match the pinned certificate root"

echo "RESULT=EDP_PROJECT_SIGNING_IDENTITY_READY"
