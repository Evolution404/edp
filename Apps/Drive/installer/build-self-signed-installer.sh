#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIFIED_IDENTITY="EDP Project Code Signing"
EXPECTED_CERT_SHA256="D9142CE44ABCB5DD662DF9621D48A88C88EDBCB0392D3C74EBACBB1292B7B5A7"
EXPECTED_CERT_ROOT_SHA1="040b5488fb2b6c02b0786e76b674cb4460658ca2"
LOGIN_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

export EDP_APP_SIGN_IDENTITY="${UNIFIED_IDENTITY}"
unset EDP_APP_SIGN_KEYCHAIN

CERT_PEM="$(/usr/bin/security find-certificate -c "${UNIFIED_IDENTITY}" -p "${LOGIN_KEYCHAIN}" 2>/dev/null || true)"
[[ -n "${CERT_PEM}" ]] || {
  echo "unified EDP signing certificate is not installed in login.keychain" >&2
  exit 2
}
ACTUAL_CERT_SHA256="$(/usr/bin/printf '%s' "${CERT_PEM}" \
  | /usr/bin/openssl x509 -noout -fingerprint -sha256 \
  | /usr/bin/cut -d= -f2 | /usr/bin/tr -d ':')"
[[ "${ACTUAL_CERT_SHA256}" == "${EXPECTED_CERT_SHA256}" ]] || {
  echo "unexpected unified EDP signing certificate fingerprint: ${ACTUAL_CERT_SHA256}" >&2
  exit 2
}

PROBE="$(/usr/bin/mktemp /private/tmp/edp-drive-signing-probe.XXXXXX)"
cleanup_probe() { /bin/rm -f "${PROBE}"; }
trap cleanup_probe EXIT INT TERM
/bin/cp /usr/bin/true "${PROBE}"
/usr/bin/codesign --force --sign "${UNIFIED_IDENTITY}" --timestamp=none "${PROBE}" >/dev/null
REQUIREMENT="$(/usr/bin/codesign -dr - "${PROBE}" 2>&1)"
/usr/bin/grep -Fq "certificate root = H\"${EXPECTED_CERT_ROOT_SHA1}\"" <<<"${REQUIREMENT}" || {
  echo "unified EDP signing private key does not match the pinned certificate root" >&2
  exit 2
}
cleanup_probe
trap - EXIT INT TERM

export EDP_SELF_SIGNED_DISTRIBUTION=1
export EDP_SERVICE_MODE=legacy
unset EDP_LEGACY_DIAGNOSTIC

exec "${REPO_ROOT}/installer/build-clean-installer.sh" "$@"
