#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MONOREPO_ROOT="$(cd "${PROJECT_ROOT}/../../../.." && pwd)"
EDP_CORE_ROOT="${MONOREPO_ROOT}/Packages/EDPCore"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

fail() {
  echo "ERROR=$*" >&2
  exit 1
}

[[ -f "${EDP_CORE_ROOT}/Package.swift" ]] || fail "monorepo EDPCore package not found: ${EDP_CORE_ROOT}"

DEVELOPER_DIR="${DEVELOPER_DIR}" /usr/bin/swift build \
  --package-path "${EDP_CORE_ROOT}" \
  -c release \
  --product EDPCore >/dev/null

RELEASE="${EDP_CORE_ROOT}/.build/arm64-apple-macosx/release"
[[ -f "${RELEASE}/libEDPCore.a" ]] || fail "libEDPCore.a missing after shared-core build"
[[ -f "${RELEASE}/Modules/EDPCore.swiftmodule" ]] || fail "EDPCore.swiftmodule missing after shared-core build"

echo "EDP_CORE_ROOT=${EDP_CORE_ROOT}"
echo "RESULT=EDP_STUDIO_SHARED_CORE_READY"
