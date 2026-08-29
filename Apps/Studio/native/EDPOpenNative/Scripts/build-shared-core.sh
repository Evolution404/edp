#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EDP_CORE_EXPECTED_REV="f7d8f25612d1446b0b690d8932062a8ece1c571f"
EDP_CORE_ROOT="${EDP_CORE_ROOT:-${PROJECT_ROOT}/../../../edp-core}"
EDP_CORE_ALLOW_UNPINNED="${EDP_CORE_ALLOW_UNPINNED:-0}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

fail() {
  echo "ERROR=$*" >&2
  exit 1
}

[[ -f "${EDP_CORE_ROOT}/Package.swift" ]] || fail "shared edp-core checkout not found: ${EDP_CORE_ROOT}"
ACTUAL_REV="$(/usr/bin/git -C "${EDP_CORE_ROOT}" rev-parse HEAD)"
if [[ "${ACTUAL_REV}" != "${EDP_CORE_EXPECTED_REV}" && "${EDP_CORE_ALLOW_UNPINNED}" != "1" ]]; then
  fail "shared edp-core revision mismatch: expected=${EDP_CORE_EXPECTED_REV} actual=${ACTUAL_REV}"
fi

DEVELOPER_DIR="${DEVELOPER_DIR}" /usr/bin/swift build \
  --package-path "${EDP_CORE_ROOT}" \
  -c release \
  --product EDPCore >/dev/null

RELEASE="${EDP_CORE_ROOT}/.build/arm64-apple-macosx/release"
[[ -f "${RELEASE}/libEDPCore.a" ]] || fail "libEDPCore.a missing after shared-core build"
[[ -f "${RELEASE}/Modules/EDPCore.swiftmodule" ]] || fail "EDPCore.swiftmodule missing after shared-core build"

echo "EDP_CORE_REV=${ACTUAL_REV}"
echo "RESULT=EDPOPEN_SHARED_EDP_CORE_READY"
