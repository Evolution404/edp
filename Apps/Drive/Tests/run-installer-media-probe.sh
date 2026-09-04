#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DRIVE_ROOT="${ROOT}/Apps/Drive"
BUILD_ROOT="${TMPDIR:-/tmp}/edp-installer-media-probe-test-$$"
BIN="${BUILD_ROOT}/edp-installer-media-probe"
ORDINARY="${BUILD_ROOT}/ordinary"
mkdir -p "${BUILD_ROOT}" "${ORDINARY}"
trap 'rm -rf "${BUILD_ROOT}"' EXIT

REPO_ROOT="${DRIVE_ROOT}"
. "${DRIVE_ROOT}/scripts/prepare-shared-edp-core.sh"
CORE_SOURCES=(
  "${DRIVE_ROOT}/native/EDPFSKitPoC/Extension/EDPRawIO.swift"
  "${DRIVE_ROOT}/native/EDPFSKitPoC/Extension/EDPMetadataProbe.swift"
  "${DRIVE_ROOT}/native/EDPFSKitPoC/Extension/EDPCrypto.swift"
  "${DRIVE_ROOT}/native/EDPFSKitPoC/Extension/EDPVolumeMetadata.swift"
  "${DRIVE_ROOT}/native/EDPFSKitPoC/Extension/EDPEncryptedPartitionReader.swift"
  "${DRIVE_ROOT}/native/EDPFSKitPoC/Extension/EDPBlockDevice.swift"
  "${DRIVE_ROOT}/native/EDPFSKitPoC/Extension/EDPFileRawDevice.swift"
)

xcrun swiftc -O -swift-version 6 -warnings-as-errors \
  -framework CryptoKit -framework CoreFoundation -framework IOKit \
  "${EDP_CORE_SWIFTC_FLAGS[@]}" \
  "${CORE_SOURCES[@]}" \
  "${DRIVE_ROOT}/installer/EDPInstallerMediaProbe.swift" \
  -o "${BIN}"

STANDARD_OUTPUT="$(
  "${BIN}" --fixture \
    "${DRIVE_ROOT}/fixtures/real_disks/disk4" \
    21c4 0cd1 124736503808
)"
/usr/bin/grep -Fq 'EDP_INSTALLER_FIXTURE_KIND=standardEncrypted' <<<"${STANDARD_OUTPUT}"
echo 'SCENARIO=INSTALLER_MEDIA_PROBE_STANDARD_EDP_OK'

/bin/dd if=/dev/zero of="${ORDINARY}/lba0_16.bin" bs=512 count=16 2>/dev/null
for name in LBA4 LBA7 LBA11 LBA12; do
  /bin/dd if=/dev/zero of="${ORDINARY}/${name}.bin" bs=512 count=1 2>/dev/null
done
ORDINARY_OUTPUT="$(
  "${BIN}" --fixture "${ORDINARY}" 1234 5678 64000000000
)"
/usr/bin/grep -Fq 'EDP_INSTALLER_FIXTURE_KIND=ordinaryUSB' <<<"${ORDINARY_OUTPUT}"
echo 'SCENARIO=INSTALLER_MEDIA_PROBE_ORDINARY_USB_OK'

echo 'RESULT=DRIVE_INSTALLER_MEDIA_PROBE_OK'
