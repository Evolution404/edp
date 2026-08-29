#!/bin/bash
set -euo pipefail

: "${REPO_ROOT:?REPO_ROOT must be set before sourcing prepare-shared-edp-core.sh}"

MONOREPO_ROOT="$(cd "${REPO_ROOT}/../.." && pwd)"
EDP_CORE_ROOT="${MONOREPO_ROOT}/Packages/EDPCore"
EDP_CORE_DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

[[ -f "${EDP_CORE_ROOT}/Package.swift" ]] || {
  echo "monorepo EDPCore package not found: ${EDP_CORE_ROOT}" >&2
  exit 2
}

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

echo "EDP_CORE_ROOT=${EDP_CORE_ROOT}"
echo "EDP_CORE_RELEASE=${EDP_CORE_RELEASE}"
