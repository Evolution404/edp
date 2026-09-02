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

PRODUCT_SOURCES=(
  product/EDPCredentialStore.swift
  product/EDPDevicePolicyStore.swift
  product/EDPMacFUSERuntimePolicy.swift
  product/EDPLifecycleScheduler.swift
  product/EDPLifecycleJournal.swift
  product/EDPTransportProvider.swift
  product/EDPTransportRuntimePolicy.swift
  product/EDPFinderVolumeDefaults.swift
  product/EDPNativeSystem.swift
  product/EDPBlockDevicePublisher.swift
  product/EDPXPCProtocol.swift
  product/EDPXPCSecurity.swift
  product/EDPRuntimeSupport.swift
  product/EDPRuntimeState.swift
  product/EDPDeviceOperations.swift
  product/EDPDeviceDiscoveryController.swift
  product/EDPRawAccess.swift
  product/EDPRawAccessCoordinator.swift
  product/EDPAutomationState.swift
  product/EDPActivityStore.swift
  product/EDPEjectCoordinator.swift
  product/EDPServiceLifecycleState.swift
  product/EDPRecoveryCoordinator.swift
  product/EDPMountLifecycle.swift
  product/EDPMountSupport.swift
  product/EDPXPCService.swift
  product/EDPServiceMain.swift
  product/EDPVaultRuntime.swift
)

VIRTUAL_USB_SOURCES=(
  Tests/VirtualUSB/EDPFaultPlan.swift
  Tests/VirtualUSB/EDPVirtualMedia.swift
  Tests/VirtualUSB/EDPVirtualMediaProvider.swift
  Tests/VirtualUSB/EDPVirtualRawDevice.swift
  Tests/VirtualUSB/EDPVirtualDiskFactory.swift
  Tests/VirtualUSB/ValidateLifecycleModelProperties.swift
)

BUILD_DIR="${TMPDIR:-/tmp}/edp-drive-tests-${USER:-user}"
mkdir -p "$BUILD_DIR"
BINARY="$BUILD_DIR/validate-credential-policy-service-lifecycle"
RAW_VALIDATION_OBJ="$BUILD_DIR/EDPRawValidation.o"
RAW_BROKER_OBJ="$BUILD_DIR/EDPRawFDBroker.o"
/usr/bin/cc -O2 -Wall -Wextra -Iproduct -c product/EDPRawValidation.c -o "$RAW_VALIDATION_OBJ"
/usr/bin/cc -O2 -Wall -Wextra -Iproduct -c product/EDPRawFDBroker.c -o "$RAW_BROKER_OBJ"

xcrun swiftc -O -swift-version 6 -warnings-as-errors \
  -D EDP_REGRESSION_TESTS \
  -Xfrontend -disable-availability-checking \
  -framework CryptoKit -framework Security -framework DiskArbitration -framework IOKit -framework CoreFoundation \
  "${EDP_CORE_SWIFTC_FLAGS[@]}" \
  "${CORE_SOURCES[@]}" \
  "${PRODUCT_SOURCES[@]}" \
  "${VIRTUAL_USB_SOURCES[@]}" \
  Tests/VirtualUSB/ValidateCredentialPolicyServiceLifecycle.swift \
  "$RAW_VALIDATION_OBJ" "$RAW_BROKER_OBJ" \
  -o "$BINARY"

OUTPUT="$($BINARY fixtures/real_disks/disk4 2>&1)"
printf '%s\n' "$OUTPUT"
for scenario in C01 C02 C03 C04 C05 C06 C07 C08; do
  grep -Fq "SCENARIO=${scenario}_OK" <<<"$OUTPUT"
done
for scenario in D01 D02 D03 D04 D05 D06 D07 D08 D09 D10 D11 D12 D13; do
  grep -Fq "SCENARIO=${scenario}_OK" <<<"$OUTPUT"
done
for scenario in S01 S02 S03 S04 S05 S06 S07 S08 S09 S10 S11 S12 S13 S14 S15 S16 S17 S18 S19 S20 S21 S22 S23 S24 S25 S26 S27 S28 S29 S30 S31 S32 S33 S34 S35; do
  grep -Fq "SCENARIO=${scenario}_OK" <<<"$OUTPUT"
done
grep -Fq 'SCENARIO=M11_OK' <<<"$OUTPUT"
grep -Fq 'MODEL_SEQUENCES=10000' <<<"$OUTPUT"
grep -Fq 'RESULT=DRIVE_LIFECYCLE_MODEL_PROPERTIES_OK' <<<"$OUTPUT"
grep -Fq 'RESULT=DRIVE_CREDENTIAL_POLICY_SERVICE_OK' <<<"$OUTPUT"
printf '%s\n' 'RESULT=DRIVE_SERVICE_LIFECYCLE_OK'
