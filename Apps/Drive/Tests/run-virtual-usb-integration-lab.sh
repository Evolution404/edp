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
  product/EDPRuntimeMetrics.swift
  product/EDPTransportProvider.swift
  product/EDPTransportRuntimePolicy.swift
  product/EDPFinderVolumeDefaults.swift
  product/EDPIOKitLifecycle.swift
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
)

BUILD_DIR="${TMPDIR:-/tmp}/edp-drive-tests-${USER:-user}"
mkdir -p "$BUILD_DIR"
BINARY="$BUILD_DIR/validate-virtual-usb-integration-lab"
RAW_VALIDATION_OBJ="$BUILD_DIR/EDPRawValidation-virtual-lab.o"
RAW_BROKER_OBJ="$BUILD_DIR/EDPRawFDBroker-virtual-lab.o"
/usr/bin/cc -O2 -Wall -Wextra -Werror -Iproduct -c product/EDPRawValidation.c -o "$RAW_VALIDATION_OBJ"
/usr/bin/cc -O2 -Wall -Wextra -Werror -Iproduct -c product/EDPRawFDBroker.c -o "$RAW_BROKER_OBJ"

xcrun swiftc -O -swift-version 6 -warnings-as-errors \
  -D EDP_REGRESSION_TESTS \
  -Xfrontend -disable-availability-checking \
  -framework CryptoKit -framework Security -framework DiskArbitration -framework IOKit -framework CoreFoundation \
  "${EDP_CORE_SWIFTC_FLAGS[@]}" \
  "${CORE_SOURCES[@]}" \
  "${PRODUCT_SOURCES[@]}" \
  "${VIRTUAL_USB_SOURCES[@]}" \
  Tests/VirtualUSB/ValidateVirtualUSBIntegrationLab.swift \
  "$RAW_VALIDATION_OBJ" "$RAW_BROKER_OBJ" \
  -o "$BINARY"

OUTPUT="$($BINARY fixtures/real_disks/disk4 2>&1)"
printf '%s\n' "$OUTPUT"
for scenario in V01 V02 V03 V04 V05 V06 V07; do
  grep -Fq "SCENARIO=${scenario}_OK" <<<"$OUTPUT"
done
grep -Fq 'RESULT=DRIVE_VIRTUAL_USB_INTEGRATION_LAB_OK' <<<"$OUTPUT"
printf '%s\n' 'RESULT=DRIVE_FULLY_SOFTWARE_VIRTUAL_USB_OK'
