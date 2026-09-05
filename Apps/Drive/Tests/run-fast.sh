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
  native/EDPFSKitPoC/Extension/EDPAlignedRead.swift
  native/EDPFSKitPoC/Extension/EDPMetadataProbe.swift
  native/EDPFSKitPoC/Extension/EDPCrypto.swift
  native/EDPFSKitPoC/Extension/EDPVolumeMetadata.swift
  native/EDPFSKitPoC/Extension/EDPEncryptedPartitionReader.swift
  native/EDPFSKitPoC/Extension/EDPBlockDevice.swift
  native/EDPFSKitPoC/Extension/EDPFileRawDevice.swift
)

BINARY="$BUILD_ROOT/validate-fast-regression"
xcrun swiftc -Onone -swift-version 6 -warnings-as-errors \
  -framework CryptoKit -framework Security -framework DiskArbitration -framework IOKit -framework CoreFoundation \
  "${EDP_CORE_SWIFTC_FLAGS[@]}" \
  "${CORE_SOURCES[@]}" \
  product/EDPLifecycleScheduler.swift \
  product/EDPTransportProvider.swift \
  product/EDPIOKitLifecycle.swift \
  product/EDPNativeSystem.swift \
  product/EDPXPCProtocol.swift \
  product/EDPDevicePolicyStore.swift \
  native/EDPFSKitPoC/Tools/ValidateEDPNativeCore.swift \
  native/EDPFSKitPoC/Tools/ValidateEDPMetadataProbe.swift \
  native/EDPFSKitPoC/Tools/ValidateTransportLifecycle.swift \
  native/EDPFSKitPoC/Tools/ValidateBoundedVFS.swift \
  product/Tests/ValidateProductModels.swift \
  Tests/Fast/ValidateFastRegression.swift \
  -o "$BINARY"

OUTPUT="$($BINARY fixtures/golden/disks.json)"
printf '%s\n' "$OUTPUT"

grep -Fq 'RESULT=SWIFT_NATIVE_ENCRYPTED_READER_OK' <<<"$OUTPUT"
for scenario in P10 P11 P12 P13 P14 P15; do
  grep -Fq "SCENARIO=${scenario}_OK" <<<"$OUTPUT"
done
for marker in \
  'REAL_STANDARD_CLASSIFICATION_OK=disk5' \
  'MEDIA_CLASS_STANDARD_ENCRYPTED=OK' \
  'MEDIA_CLASS_LEGACY_NOPWD=OK' \
  'MEDIA_CLASS_CURRENT_NOPWD=OK' \
  'MEDIA_CLASS_UNRECOGNIZED_EDP=OK' \
  'MEDIA_CLASS_ORDINARY_USB=OK' \
  'LBA4_ONLY_ID_NEGATIVE_CONTROLS=OK' \
  'RESULT=TRANSPORT_LIFECYCLE_HARDENING_OK' \
  'RESULT=TRANSPORT_LIFECYCLE_VIRTUAL_CLOCK_OK' \
  'RESULT=BOUNDED_VFS_UNMOUNT_GUARD_OK' \
  'RESULT=EDP_PRODUCT_MODELS_OK' \
  'RESULT=DRIVE_FAST_COMBINED_BINARY_OK'; do
  grep -Fq "$marker" <<<"$OUTPUT"
done
for scenario in P01 P02 P03 P04 P05 P06 P07 P08 P09; do
  grep -Fq "SCENARIO=${scenario}_OK" <<<"$OUTPUT"
done

echo 'RESULT=DRIVE_CORE_OK'
echo 'RESULT=DRIVE_IDENTITY_OK'
echo 'RESULT=DRIVE_FAST_OK'
