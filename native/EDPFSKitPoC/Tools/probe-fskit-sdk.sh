#!/bin/bash
set -euo pipefail

SDK="$(xcrun --sdk macosx --show-sdk-path)"
FSKIT_HEADERS="${SDK}/System/Library/Frameworks/FSKit.framework/Headers"

[[ -d "${FSKIT_HEADERS}" ]] || {
    echo "RESULT=FAILED:FSKit_headers_missing:${FSKIT_HEADERS}" >&2
    exit 1
}

has_symbol() {
    local symbol="$1"
    if grep -Rqs -- "${symbol}" "${FSKIT_HEADERS}"; then
        printf 'true'
    else
        printf 'false'
    fi
}

VOLUME_OPERATIONS="$(has_symbol 'FSVolumeOperations')"
VOLUME_HANDLER="$(has_symbol 'FSVolumeHandler')"
READ_WRITE_HANDLER="$(has_symbol 'FSVolumeReadWriteHandler')"
DIRECT_SETTINGS="$(has_symbol 'openFileSystemExtensionsSettings')"

printf 'FSKIT_SDK_PATH=%s\n' "${SDK}"
printf 'FSKIT_SDK_PRODUCT_VERSION=%s\n' "$(sw_vers -productVersion)"
printf 'FSKIT_SDK_VOLUME_OPERATIONS=%s\n' "${VOLUME_OPERATIONS}"
printf 'FSKIT_SDK_VOLUME_HANDLER=%s\n' "${VOLUME_HANDLER}"
printf 'FSKIT_SDK_READ_WRITE_HANDLER=%s\n' "${READ_WRITE_HANDLER}"
printf 'FSKIT_SDK_CLIENT_DIRECT_SETTINGS=%s\n' "${DIRECT_SETTINGS}"

# The current production source graph is intentionally pinned to the API that
# ships in Xcode 26.6 / macOS 26.5 SDK. Handler-style FSKit APIs are monitored
# here so we can migrate when they actually enter the installed SDK rather than
# coding against web documentation that may be ahead of the toolchain.
[[ "${VOLUME_OPERATIONS}" == "true" ]] || {
    echo 'RESULT=FAILED:FSVolumeOperations_baseline_missing' >&2
    exit 1
}

echo 'RESULT=FSKIT_SDK_CAPABILITIES_PROBED'
