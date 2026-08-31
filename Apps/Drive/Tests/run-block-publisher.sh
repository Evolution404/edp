#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DRIVE_ROOT="$ROOT/Apps/Drive"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$DRIVE_ROOT"
BUILD_DIR="${TMPDIR:-/tmp}/edp-drive-block-publisher-${USER:-user}"
mkdir -p "$BUILD_DIR"
BINARY="$BUILD_DIR/validate-macfuse-scratch-cleanup"

xcrun swiftc -O -swift-version 6 -warnings-as-errors \
  product/EDPBlockDevicePublisher.swift \
  product/Tests/ValidateMacFUSEScratchCleanup.swift \
  -o "$BINARY"

OUTPUT="$($BINARY 2>&1)"
printf '%s\n' "$OUTPUT"
grep -Fq 'RESULT=MACFUSE_SCRATCH_CLEANUP_CONTRACT_OK' <<<"$OUTPUT"
printf '%s\n' 'RESULT=DRIVE_BLOCK_PUBLISHER_OK'
