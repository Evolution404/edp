#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PROJECT_DIR}/../.." && pwd)"
OUTPUT="${1:-${REPO_ROOT}/artifacts/native/CaptureEDPDataFixture}"
DEPLOYMENT_TARGET="${EDP_CAPTURE_DEPLOYMENT_TARGET:-15.0}"
ARCH="${EDP_CAPTURE_ARCH:-$(uname -m)}"

case "${ARCH}" in
  arm64|x86_64) ;;
  *)
    echo "unsupported capture-tool architecture: ${ARCH}" >&2
    exit 2
    ;;
esac

mkdir -p "$(dirname "${OUTPUT}")"

xcrun swiftc -parse-as-library \
  -target "${ARCH}-apple-macosx${DEPLOYMENT_TARGET}" \
  "${PROJECT_DIR}/Extension/EDPRawIO.swift" \
  "${PROJECT_DIR}/Extension/EDPMetadataProbe.swift" \
  "${PROJECT_DIR}/Extension/EDPCrypto.swift" \
  "${PROJECT_DIR}/Extension/EDPVolumeMetadata.swift" \
  "${PROJECT_DIR}/Extension/EDPEncryptedPartitionReader.swift" \
  "${SCRIPT_DIR}/CaptureEDPDataFixture.swift" \
  -o "${OUTPUT}"

printf 'EDP_CAPTURE_TOOL_TARGET=%s-apple-macosx%s\n' "${ARCH}" "${DEPLOYMENT_TARGET}"
printf 'EDP_CAPTURE_TOOL_OUTPUT=%s\n' "${OUTPUT}"
echo 'RESULT=EDP_CAPTURE_TOOL_BUILT'
