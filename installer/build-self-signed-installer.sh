#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${EDP_APP_SIGN_IDENTITY:?Set EDP_APP_SIGN_IDENTITY to your stable self-signed code-signing identity}"

if [[ "${EDP_APP_SIGN_IDENTITY}" == "-" ]]; then
  echo "self-signed distribution cannot use ad-hoc signing" >&2
  exit 2
fi

export EDP_SELF_SIGNED_DISTRIBUTION=1
export EDP_SERVICE_MODE=legacy
unset EDP_LEGACY_DIAGNOSTIC

exec "${REPO_ROOT}/installer/build-clean-installer.sh" "$@"
