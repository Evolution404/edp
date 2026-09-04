#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DRIVE_ROOT="$ROOT/Apps/Drive"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$DRIVE_ROOT"
BUILD_DIR="${TMPDIR:-/tmp}/edp-drive-block-publisher-${USER:-user}"
mkdir -p "$BUILD_DIR"
BINARY="$BUILD_DIR/validate-macfuse-scratch-cleanup"
METRICS_BINARY="$BUILD_DIR/validate-runtime-metrics"

xcrun swiftc -O -swift-version 6 -warnings-as-errors \
  product/EDPRuntimeMetrics.swift \
  product/Tests/ValidateRuntimeMetrics.swift \
  -o "$METRICS_BINARY"

METRICS_OUTPUT="$($METRICS_BINARY 2>&1)"
printf '%s\n' "$METRICS_OUTPUT"
grep -Fq 'RESULT=DRIVE_RUNTIME_METRICS_CONTRACT_OK' <<<"$METRICS_OUTPUT"

xcrun swiftc -O -swift-version 6 -warnings-as-errors -D EDP_REGRESSION_TESTS \
  -framework IOKit \
  product/EDPRuntimeMetrics.swift \
  product/EDPIOKitLifecycle.swift \
  product/EDPBlockDevicePublisher.swift \
  product/Tests/ValidateMacFUSEScratchCleanup.swift \
  -o "$BINARY"

OUTPUT="$($BINARY 2>&1)"
printf '%s\n' "$OUTPUT"
grep -Fq 'RESULT=MACFUSE_SCRATCH_CLEANUP_CONTRACT_OK' <<<"$OUTPUT"
printf '%s\n' 'RESULT=DRIVE_BLOCK_PUBLISHER_OK'
