#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_BIN="${1:?usage: build-transport-backends.sh OUTPUT_BIN}"
FRAMEWORKS="${MACFUSE_FRAMEWORKS:-/Library/Filesystems/macfuse.fs/Contents/Frameworks}"
MOUNT_COMMIT="${MACFUSE_MOUNT_COMMIT:-313b9c68d04cd779bffc9f8bd9f32a4e1f5baf70}"
LIBRARY3_COMMIT="${MACFUSE_LIBRARY3_COMMIT:-9a3db24bf7e3896d69a514a70e91dc41eefb948b}"

[[ -d "${FRAMEWORKS}/MFMount.framework" ]] || {
  echo "MFMount.framework missing: ${FRAMEWORKS}" >&2
  exit 2
}
mkdir -p "${OUTPUT_BIN}"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/edp-transport-build.XXXXXX")"
trap 'rm -rf "${BUILD_ROOT}"' EXIT INT TERM
INC="${BUILD_ROOT}/include"
SRC="${BUILD_ROOT}/direct-src"
mkdir -p "${INC}/MFMount" "${SRC}"

/usr/bin/curl -fsSL \
  "https://raw.githubusercontent.com/macfuse/mount/${MOUNT_COMMIT}/Mount/MFMount.h" \
  -o "${INC}/MFMount/MFMount.h"
/usr/bin/curl -fsSL \
  "https://raw.githubusercontent.com/macfuse/library/${LIBRARY3_COMMIT}/include/fuse_kernel.h" \
  -o "${INC}/fuse_kernel.h"

CORE_SOURCES=(
  "${REPO_ROOT}/native/EDPFSKitPoC/Extension/EDPRawIO.swift"
  "${REPO_ROOT}/native/EDPFSKitPoC/Extension/EDPMetadataProbe.swift"
  "${REPO_ROOT}/native/EDPFSKitPoC/Extension/EDPCrypto.swift"
  "${REPO_ROOT}/native/EDPFSKitPoC/Extension/EDPVolumeMetadata.swift"
  "${REPO_ROOT}/native/EDPFSKitPoC/Extension/EDPEncryptedPartitionReader.swift"
  "${REPO_ROOT}/native/EDPFSKitPoC/Extension/EDPBlockDevice.swift"
  "${REPO_ROOT}/native/EDPFSKitPoC/Extension/EDPFileRawDevice.swift"
)

# Build the Direct MFMount Local product adapter. Patch only the copied generic
# transport source so the shared source remains usable for Generic A/B tests.
cp "${REPO_ROOT}/native/EDPFSKitPoC/Tools/MacFUSEMinimal/DirectMFMountRawTransport.c" \
  "${SRC}/DirectMFMountRawTransport.c"
cp "${REPO_ROOT}/native/EDPFSKitPoC/Tools/MacFUSEMinimal/DirectMFMountEDPAdapter.c" \
  "${SRC}/DirectMFMountEDPAdapter.c"
python3 - "${SRC}/DirectMFMountRawTransport.c" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = '"nobrowse,volname=%s"'
if old not in s:
    raise SystemExit("expected Direct MFMount option template not found")
p.write_text(s.replace(old, '"local,nobrowse,volname=%s"', 1))
PY

xcrun clang -std=c17 -Wall -Wextra -Werror \
  -I"${INC}" -I"${SRC}" -F"${FRAMEWORKS}" -DMFMount=EDPAsyncMFMount \
  -c "${SRC}/DirectMFMountEDPAdapter.c" -o "${BUILD_ROOT}/adapter.o"
xcrun clang -std=c17 -Wall -Wextra -Werror \
  -I"${INC}" -F"${FRAMEWORKS}" \
  -c "${REPO_ROOT}/native/EDPFSKitPoC/Tools/MacFUSEMinimal/DirectMFMountAsyncShim.c" \
  -o "${BUILD_ROOT}/async-shim.o"

xcrun swiftc -parse-as-library -O -swift-version 6 -warnings-as-errors \
  "${CORE_SOURCES[@]}" \
  "${REPO_ROOT}/native/EDPFSKitPoC/Tools/EDPReadWriteBlockCBridge.swift" \
  "${BUILD_ROOT}/adapter.o" "${BUILD_ROOT}/async-shim.o" \
  -F"${FRAMEWORKS}" -Xlinker -rpath -Xlinker "${FRAMEWORKS}" \
  -framework MFMount -framework CoreFoundation -framework DiskArbitration \
  -o "${OUTPUT_BIN}/edp-mfmount-local-readwrite"

test -x "${OUTPUT_BIN}/edp-mfmount-local-readwrite"

otool -L "${OUTPUT_BIN}/edp-mfmount-local-readwrite" > "${BUILD_ROOT}/local-otool.txt"
grep -Fq 'MFMount.framework' "${BUILD_ROOT}/local-otool.txt"
if grep -Eiq 'libfuse|libosxfuse|libmacfuse' "${BUILD_ROOT}/local-otool.txt"; then
  echo 'unexpected libfuse-family dynamic dependency in macFUSE Local transport' >&2
  exit 1
fi

echo 'RESULT=EDP_MACFUSE_LOCAL_TRANSPORT_BUILT'
