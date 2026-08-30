#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DRIVE_ROOT="$ROOT/Apps/Drive"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$DRIVE_ROOT"
REPO_ROOT="$PWD"
. scripts/prepare-shared-edp-core.sh

CORE_SOURCES=(
  native/EDPFSKitPoC/Extension/EDPRawIO.swift
  native/EDPFSKitPoC/Extension/EDPMetadataProbe.swift
  native/EDPFSKitPoC/Extension/EDPCrypto.swift
  native/EDPFSKitPoC/Extension/EDPVolumeMetadata.swift
  native/EDPFSKitPoC/Extension/EDPEncryptedPartitionReader.swift
  native/EDPFSKitPoC/Extension/EDPBlockDevice.swift
  native/EDPFSKitPoC/Extension/EDPFileRawDevice.swift
)

BUILD_DIR="${TMPDIR:-/tmp}/edp-drive-tests-${USER:-user}"
mkdir -p "$BUILD_DIR"
BINARY="$BUILD_DIR/validate-discovery-seam"

xcrun swiftc -O -swift-version 6 -warnings-as-errors \
  -framework CryptoKit -framework Security -framework DiskArbitration -framework IOKit \
  "${EDP_CORE_SWIFTC_FLAGS[@]}" \
  "${CORE_SOURCES[@]}" \
  product/EDPNativeSystem.swift \
  Tests/VirtualUSB/ValidateDiscoverySeam.swift \
  -o "$BINARY"

OUTPUT="$($BINARY fixtures/real_disks/disk4)"
printf '%s\n' "$OUTPUT"
grep -Fq 'SCENARIO=TEST_C_INJECTED_DISCOVERY_OK' <<<"$OUTPUT"
grep -Fq 'SCENARIO=TEST_C_METADATA_READER_FAILURE_ISOLATED' <<<"$OUTPUT"
grep -Fq 'RESULT=DRIVE_DISCOVERY_SEAM_OK' <<<"$OUTPUT"
printf '%s\n' 'RESULT=DRIVE_VIRTUAL_USB_OK'
