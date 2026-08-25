#!/bin/bash
set -euo pipefail

SDK="$(xcrun --sdk macosx --show-sdk-path)"
FSKIT_HEADERS="${SDK}/System/Library/Frameworks/FSKit.framework/Headers"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/edp-fskit-sdk-probe.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

[[ -d "${FSKIT_HEADERS}" ]] || {
    echo "RESULT=FAILED:FSKit_headers_missing:${FSKIT_HEADERS}" >&2
    exit 1
}

compile_probe() {
    local name="$1"
    local source="$2"
    local file="${WORK_DIR}/${name}.swift"
    printf '%s\n' "${source}" >"${file}"
    if xcrun swiftc -typecheck "${file}" >/dev/null 2>&1; then
        printf 'true'
    else
        printf 'false'
    fi
}

VOLUME_OPERATIONS="$(compile_probe volume-operations $'import FSKit\nprotocol EDPProbeVolumeOperations: FSVolume.Operations {}')"
READ_WRITE_OPERATIONS="$(compile_probe read-write-operations $'import FSKit\nprotocol EDPProbeReadWriteOperations: FSVolume.ReadWriteOperations {}')"
VOLUME_HANDLER="$(compile_probe volume-handler $'import FSKit\nprotocol EDPProbeVolumeHandler: FSVolume.Handler {}')"
READ_WRITE_HANDLER="$(compile_probe read-write-handler $'import FSKit\nprotocol EDPProbeReadWriteHandler: FSVolume.ReadWriteHandler {}')"
DIRECT_SETTINGS="$(compile_probe direct-settings $'import FSKit\nfunc probeDirectSettings() { _ = FSClient.shared.openFileSystemExtensionsSettings() }')"

printf 'FSKIT_SDK_PATH=%s\n' "${SDK}"
printf 'FSKIT_SDK_PRODUCT_VERSION=%s\n' "$(sw_vers -productVersion)"
printf 'FSKIT_SDK_VOLUME_OPERATIONS=%s\n' "${VOLUME_OPERATIONS}"
printf 'FSKIT_SDK_READ_WRITE_OPERATIONS=%s\n' "${READ_WRITE_OPERATIONS}"
printf 'FSKIT_SDK_VOLUME_HANDLER=%s\n' "${VOLUME_HANDLER}"
printf 'FSKIT_SDK_READ_WRITE_HANDLER=%s\n' "${READ_WRITE_HANDLER}"
printf 'FSKIT_SDK_CLIENT_DIRECT_SETTINGS=%s\n' "${DIRECT_SETTINGS}"

# Do not hard-code a specific API generation here. The production source graph
# is the compatibility gate. This probe records which generation the installed
# Swift SDK actually exposes and produces a stable marker for CI diagnostics.
echo 'RESULT=FSKIT_SDK_CAPABILITIES_PROBED'
