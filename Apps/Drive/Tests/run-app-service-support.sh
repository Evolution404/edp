#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BUILD_ROOT="${TMPDIR:-/tmp}/edp-app-service-support-$$"
BIN="${BUILD_ROOT}/validate-app-service-support"
mkdir -p "${BUILD_ROOT}"
trap 'rm -rf "${BUILD_ROOT}"' EXIT

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

xcrun swiftc -O -swift-version 6 -warnings-as-errors \
  "${ROOT}/Apps/Drive/product/App/Service/EDPAppServiceSupport.swift" \
  "${ROOT}/Apps/Drive/product/Tests/ValidateAppServiceToolRunner.swift" \
  -o "${BIN}"

"${BIN}"
