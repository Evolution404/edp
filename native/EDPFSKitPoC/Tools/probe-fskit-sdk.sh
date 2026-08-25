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

write_probe() {
    local name="$1"
    local source="$2"
    printf '%s\n' "${source}" >"${WORK_DIR}/${name}.swift"
}

write_probe volume-operations $'import FSKit\nprotocol EDPProbeVolumeOperations: FSVolume.Operations {}'
write_probe read-write-operations $'import FSKit\nprotocol EDPProbeReadWriteOperations: FSVolume.ReadWriteOperations {}'
write_probe volume-handler $'import FSKit\nprotocol EDPProbeVolumeHandler: FSVolume.Handler {}'
write_probe read-write-handler $'import FSKit\nprotocol EDPProbeReadWriteHandler: FSVolume.ReadWriteHandler {}'
write_probe direct-settings $'import FSKit\nfunc probeDirectSettings() { _ = FSClient.shared.openFileSystemExtensionsSettings() }'

# These probes are independent. Running the Swift frontends in parallel keeps
# this diagnostic from adding serial compiler startup cost to every fast CI run.
xcrun swiftc -typecheck "${WORK_DIR}/volume-operations.swift" >/dev/null 2>&1 &
volume_operations_pid=$!
xcrun swiftc -typecheck "${WORK_DIR}/read-write-operations.swift" >/dev/null 2>&1 &
read_write_operations_pid=$!
xcrun swiftc -typecheck "${WORK_DIR}/volume-handler.swift" >/dev/null 2>&1 &
volume_handler_pid=$!
xcrun swiftc -typecheck "${WORK_DIR}/read-write-handler.swift" >/dev/null 2>&1 &
read_write_handler_pid=$!
xcrun swiftc -typecheck "${WORK_DIR}/direct-settings.swift" >/dev/null 2>&1 &
direct_settings_pid=$!

if wait "${volume_operations_pid}"; then VOLUME_OPERATIONS=true; else VOLUME_OPERATIONS=false; fi
if wait "${read_write_operations_pid}"; then READ_WRITE_OPERATIONS=true; else READ_WRITE_OPERATIONS=false; fi
if wait "${volume_handler_pid}"; then VOLUME_HANDLER=true; else VOLUME_HANDLER=false; fi
if wait "${read_write_handler_pid}"; then READ_WRITE_HANDLER=true; else READ_WRITE_HANDLER=false; fi
if wait "${direct_settings_pid}"; then DIRECT_SETTINGS=true; else DIRECT_SETTINGS=false; fi

printf 'FSKIT_SDK_PATH=%s\n' "${SDK}"
printf 'FSKIT_SDK_PRODUCT_VERSION=%s\n' "$(sw_vers -productVersion)"
printf 'FSKIT_SDK_VOLUME_OPERATIONS=%s\n' "${VOLUME_OPERATIONS}"
printf 'FSKIT_SDK_READ_WRITE_OPERATIONS=%s\n' "${READ_WRITE_OPERATIONS}"
printf 'FSKIT_SDK_VOLUME_HANDLER=%s\n' "${VOLUME_HANDLER}"
printf 'FSKIT_SDK_READ_WRITE_HANDLER=%s\n' "${READ_WRITE_HANDLER}"
printf 'FSKIT_SDK_CLIENT_DIRECT_SETTINGS=%s\n' "${DIRECT_SETTINGS}"

# The production source graph remains the compatibility gate. These results are
# informational and let CI tell us when Apple's installed Swift SDK actually
# exposes a newer FSKit generation.
echo 'RESULT=FSKIT_SDK_CAPABILITIES_PROBED'
