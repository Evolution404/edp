#!/bin/bash
set -euo pipefail

VERSION="2026.7.7"
ARCHIVE="ntfs-3g_ntfsprogs-${VERSION}.tgz"
SOURCE_URL="https://tuxera.com/opensource/${ARCHIVE}"
SOURCE_SHA256="d67b769025d32860549d35c2147e45024d172f81c540d750390ce3602c059dab"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CREATE_MODE_PATCH="${REPO_ROOT}/patches/ntfs-3g-2026.7.7-macfuse-fskit-create-mode.patch"
RENAMEX_PATCH="${REPO_ROOT}/patches/ntfs-3g-2026.7.7-macfuse-fskit-renamex.patch"
# Autotools' generated PLUGIN_DIR define is not safely quoted when prefix has
# spaces. Build under a space-free canonical prefix, then make the selected
# runtime dylib relocatable with @loader_path below.
INSTALL_PREFIX="/Library/EDPUSBVault/ntfs-3g"
OUTPUT_DIR="${1:?usage: build-ntfs3g-runtime.sh <output-directory>}"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/edp-ntfs3g.XXXXXX")"

cleanup() {
  rm -rf "${BUILD_ROOT}"
}
trap cleanup EXIT INT TERM

for tool in curl shasum tar make pkg-config patch; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "missing build dependency: ${tool}" >&2
    exit 2
  }
done

if [[ ! -f /usr/local/include/fuse/fuse.h || ! -f /usr/local/lib/libfuse.2.dylib ]]; then
  echo "macFUSE development runtime is required to build NTFS-3G" >&2
  exit 3
fi

mkdir -p "${OUTPUT_DIR}"
curl --fail --location --retry 3 --output "${BUILD_ROOT}/${ARCHIVE}" "${SOURCE_URL}"
printf '%s  %s\n' "${SOURCE_SHA256}" "${BUILD_ROOT}/${ARCHIVE}" | shasum -a 256 -c -
tar -xzf "${BUILD_ROOT}/${ARCHIVE}" -C "${BUILD_ROOT}"

SOURCE_DIR="$(find "${BUILD_ROOT}" -maxdepth 1 -type d -name 'ntfs-3g-*' -print -quit)"
[[ -n "${SOURCE_DIR}" ]] || {
  echo "NTFS-3G source directory missing after extraction" >&2
  exit 4
}
for compatibility_patch in "${CREATE_MODE_PATCH}" "${RENAMEX_PATCH}"; do
  [[ -f "${compatibility_patch}" ]] || {
    echo "NTFS-3G macFUSE FSKit compatibility patch missing: ${compatibility_patch}" >&2
    exit 4
  }
done
(
  cd "${SOURCE_DIR}"
  patch --forward --batch -p1 <"${CREATE_MODE_PATCH}"
  patch --forward --batch -p1 <"${RENAMEX_PATCH}"
)

(
  cd "${SOURCE_DIR}"
  export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
  export CPPFLAGS="-I/usr/local/include"
  export LDFLAGS="-L/usr/local/lib -F/Library/Filesystems/macfuse.fs/Contents/Frameworks"
  ./configure \
    --prefix="${INSTALL_PREFIX}" \
    --with-fuse=external \
    --disable-static \
    --enable-extras
  make -j"$(sysctl -n hw.logicalcpu)"
)

for artifact in \
  "${SOURCE_DIR}/src/.libs/ntfs-3g" \
  "${SOURCE_DIR}/src/.libs/ntfs-3g.probe" \
  "${SOURCE_DIR}/ntfsprogs/.libs/ntfslabel" \
  "${SOURCE_DIR}/ntfsprogs/.libs/mkntfs" \
  "${SOURCE_DIR}/libntfs-3g/.libs/libntfs-3g.90.dylib"; do
  [[ -e "${artifact}" ]] || {
    echo "expected NTFS-3G artifact missing: ${artifact}" >&2
    exit 5
  }
done

rm -rf "${OUTPUT_DIR}/ntfs-3g"
mkdir -p "${OUTPUT_DIR}/ntfs-3g/bin" "${OUTPUT_DIR}/ntfs-3g/lib" \
  "${OUTPUT_DIR}/ntfs-3g/licenses" "${OUTPUT_DIR}/ntfs-3g/source" \
  "${OUTPUT_DIR}/ntfs-3g/test-tools"
cp "${SOURCE_DIR}/src/.libs/ntfs-3g" "${OUTPUT_DIR}/ntfs-3g/bin/"
cp "${SOURCE_DIR}/src/.libs/ntfs-3g.probe" "${OUTPUT_DIR}/ntfs-3g/bin/"
cp "${SOURCE_DIR}/ntfsprogs/.libs/ntfslabel" "${OUTPUT_DIR}/ntfs-3g/bin/"
# mkntfs is retained only for synthetic CI fixtures. The installer copies
# bin/lib/licenses/source explicitly, so test-tools is never shipped.
cp "${SOURCE_DIR}/ntfsprogs/.libs/mkntfs" "${OUTPUT_DIR}/ntfs-3g/test-tools/"
cp "${SOURCE_DIR}/libntfs-3g/.libs/libntfs-3g.90.dylib" \
  "${OUTPUT_DIR}/ntfs-3g/lib/"
cp "${SOURCE_DIR}/COPYING" "${SOURCE_DIR}/COPYING.LIB" \
  "${OUTPUT_DIR}/ntfs-3g/licenses/"
cp "${BUILD_ROOT}/${ARCHIVE}" "${OUTPUT_DIR}/ntfs-3g/source/"
cp "${CREATE_MODE_PATCH}" "${OUTPUT_DIR}/ntfs-3g/source/"
cp "${RENAMEX_PATCH}" "${OUTPUT_DIR}/ntfs-3g/source/"

for binary in ntfs-3g ntfs-3g.probe ntfslabel; do
  install_name_tool -change \
    "${INSTALL_PREFIX}/lib/libntfs-3g.90.dylib" \
    "@loader_path/../lib/libntfs-3g.90.dylib" \
    "${OUTPUT_DIR}/ntfs-3g/bin/${binary}" 2>/dev/null || true
done
install_name_tool -change \
  "${INSTALL_PREFIX}/lib/libntfs-3g.90.dylib" \
  "@loader_path/../lib/libntfs-3g.90.dylib" \
  "${OUTPUT_DIR}/ntfs-3g/test-tools/mkntfs" 2>/dev/null || true
install_name_tool -id "@loader_path/libntfs-3g.90.dylib" \
  "${OUTPUT_DIR}/ntfs-3g/lib/libntfs-3g.90.dylib"

codesign --force --sign - "${OUTPUT_DIR}/ntfs-3g/lib/libntfs-3g.90.dylib"
for binary in ntfs-3g ntfs-3g.probe ntfslabel; do
  codesign --force --sign - "${OUTPUT_DIR}/ntfs-3g/bin/${binary}"
done
codesign --force --sign - "${OUTPUT_DIR}/ntfs-3g/test-tools/mkntfs"

printf 'NTFS3G_VERSION=%s\n' "${VERSION}"
printf 'NTFS3G_SOURCE_SHA256=%s\n' "${SOURCE_SHA256}"
printf 'RESULT=NTFS3G_REPRODUCIBLE_RUNTIME_BUILT\n'
