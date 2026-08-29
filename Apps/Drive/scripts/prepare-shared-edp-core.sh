#!/bin/bash
set -euo pipefail

: "${REPO_ROOT:?REPO_ROOT must be set before sourcing prepare-shared-edp-core.sh}"

EDP_CORE_EXPECTED_REV="fc19f95afa769bed7f8bb65d8796e407668b9fb7"
EDP_CORE_ROOT="${EDP_CORE_ROOT:-${REPO_ROOT}/../edp-core}"
EDP_CORE_ALLOW_UNPINNED="${EDP_CORE_ALLOW_UNPINNED:-0}"
EDP_CORE_DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

[[ -f "${EDP_CORE_ROOT}/Package.swift" ]] || {
  echo "shared edp-core checkout not found: ${EDP_CORE_ROOT}" >&2
  echo "expected sibling checkout at ../edp-core or EDP_CORE_ROOT override" >&2
  exit 2
}

ACTUAL_EDP_CORE_REV="$(git -C "${EDP_CORE_ROOT}" rev-parse HEAD)"
if [[ "${ACTUAL_EDP_CORE_REV}" != "${EDP_CORE_EXPECTED_REV}" && "${EDP_CORE_ALLOW_UNPINNED}" != "1" ]]; then
  echo "shared edp-core revision mismatch" >&2
  echo "expected=${EDP_CORE_EXPECTED_REV}" >&2
  echo "actual=${ACTUAL_EDP_CORE_REV}" >&2
  echo "set EDP_CORE_ALLOW_UNPINNED=1 only while intentionally developing both repositories together" >&2
  exit 2
fi

DEVELOPER_DIR="${EDP_CORE_DEVELOPER_DIR}" /usr/bin/swift build \
  --package-path "${EDP_CORE_ROOT}" \
  -c release \
  --product EDPCore >/dev/null

EDP_CORE_RELEASE="${EDP_CORE_ROOT}/.build/arm64-apple-macosx/release"
EDP_CORE_MODULES="${EDP_CORE_RELEASE}/Modules"
EDP_CORE_C_INCLUDE="${EDP_CORE_ROOT}/Sources/CEDPCore/include"
[[ -f "${EDP_CORE_RELEASE}/libEDPCore.a" ]] || {
  echo "shared edp-core static library missing after build" >&2
  exit 2
}

EDP_CORE_SWIFTC_FLAGS=(
  -D EDP_REQUIRE_SHARED_CORE
  -I "${EDP_CORE_MODULES}"
  -I "${EDP_CORE_C_INCLUDE}"
  -L "${EDP_CORE_RELEASE}"
  -lEDPCore
)

echo "EDP_CORE_REV=${ACTUAL_EDP_CORE_REV}"
echo "EDP_CORE_RELEASE=${EDP_CORE_RELEASE}"
