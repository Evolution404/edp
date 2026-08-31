#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DRIVE_ROOT="$ROOT/Apps/Drive"
BUILD_ROOT="${TMPDIR:-/tmp}/edp-drive-regression-fast"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"

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

run_and_require() {
  local marker="$1"
  local output="$2"
  shift 2
  "$@" | tee "$output"
  grep -Fq "$marker" "$output"
}

xcrun swiftc -O -swift-version 6 -warnings-as-errors \
  -framework CryptoKit -framework Security \
  "${EDP_CORE_SWIFTC_FLAGS[@]}" \
  "${CORE_SOURCES[@]}" \
  native/EDPFSKitPoC/Tools/ValidateEDPNativeCore.swift \
  -o "$BUILD_ROOT/validate-edp-native-core"
run_and_require \
  'RESULT=SWIFT_NATIVE_ENCRYPTED_READER_OK' \
  "$BUILD_ROOT/native-core.txt" \
  "$BUILD_ROOT/validate-edp-native-core" fixtures/golden/disks.json
for scenario in P10 P11 P12 P13 P14 P15; do
  grep -Fq "SCENARIO=${scenario}_OK" "$BUILD_ROOT/native-core.txt"
done

xcrun swiftc -O -swift-version 6 -warnings-as-errors \
  native/EDPFSKitPoC/Extension/EDPAlignedRead.swift \
  native/EDPFSKitPoC/Extension/EDPMetadataProbe.swift \
  native/EDPFSKitPoC/Tools/ValidateEDPMetadataProbe.swift \
  -o "$BUILD_ROOT/validate-edp-media-classifier"
run_and_require \
  'REAL_STANDARD_CLASSIFICATION_OK=disk5' \
  "$BUILD_ROOT/media-classifier.txt" \
  "$BUILD_ROOT/validate-edp-media-classifier" fixtures/golden/disks.json

grep -Fq 'MEDIA_CLASS_STANDARD_ENCRYPTED=OK' "$BUILD_ROOT/media-classifier.txt"
grep -Fq 'MEDIA_CLASS_LEGACY_NOPWD=OK' "$BUILD_ROOT/media-classifier.txt"
grep -Fq 'MEDIA_CLASS_CURRENT_NOPWD=OK' "$BUILD_ROOT/media-classifier.txt"
grep -Fq 'MEDIA_CLASS_UNRECOGNIZED_EDP=OK' "$BUILD_ROOT/media-classifier.txt"
grep -Fq 'MEDIA_CLASS_ORDINARY_USB=OK' "$BUILD_ROOT/media-classifier.txt"
grep -Fq 'LBA4_ONLY_ID_NEGATIVE_CONTROLS=OK' "$BUILD_ROOT/media-classifier.txt"
for scenario in P01 P02 P03 P04 P05 P06 P07 P08 P09; do
  grep -Fq "SCENARIO=${scenario}_OK" "$BUILD_ROOT/media-classifier.txt"
done

xcrun swiftc -O -swift-version 6 -warnings-as-errors \
  product/EDPLifecycleScheduler.swift \
  product/EDPTransportProvider.swift \
  native/EDPFSKitPoC/Tools/ValidateTransportLifecycle.swift \
  -o "$BUILD_ROOT/validate-transport-lifecycle"
run_and_require \
  'RESULT=TRANSPORT_LIFECYCLE_HARDENING_OK' \
  "$BUILD_ROOT/transport-lifecycle.txt" \
  "$BUILD_ROOT/validate-transport-lifecycle"
grep -Fq 'RESULT=TRANSPORT_LIFECYCLE_VIRTUAL_CLOCK_OK' "$BUILD_ROOT/transport-lifecycle.txt"

xcrun swiftc -O -swift-version 6 -warnings-as-errors \
  product/EDPXPCProtocol.swift \
  product/EDPDevicePolicyStore.swift \
  product/Tests/ValidateProductModels.swift \
  -o "$BUILD_ROOT/validate-product-models"
run_and_require \
  'RESULT=EDP_PRODUCT_MODELS_OK' \
  "$BUILD_ROOT/product-models.txt" \
  "$BUILD_ROOT/validate-product-models"

echo 'RESULT=DRIVE_CORE_OK'
echo 'RESULT=DRIVE_IDENTITY_OK'
echo 'RESULT=DRIVE_FAST_OK'
