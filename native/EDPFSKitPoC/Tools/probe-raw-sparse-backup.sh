#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/edp-raw-sparse.XXXXXX")"
cleanup() {
  rm -rf "${WORK}"
}
trap cleanup EXIT INT TERM

cc -O2 -Wall -Wextra -c "${ROOT}/product/EDPRawReadAuthorization.c" \
  -o "${WORK}/EDPRawReadAuthorization.o"
xcrun swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -O \
  -framework CryptoKit -framework Security \
  "${ROOT}/product/EDPRawSparseBackup.swift" \
  "${WORK}/EDPRawReadAuthorization.o" \
  -o "${WORK}/edp-raw-sparse"

FIXTURE="${WORK}/fixture.raw"
IMAGE="${WORK}/backup.raw"
MANIFEST="${WORK}/backup.json"
RESTORED="${WORK}/restored.raw"
LOGICAL_SIZE=$((64 * 1024 * 1024))
truncate -s "${LOGICAL_SIZE}" "${FIXTURE}"

# Non-zero ranges deliberately cover the head, a sparse-block boundary,
# separated middle extents, and the final sector of the logical disk.
printf 'EDP-MBR-HEAD' | dd of="${FIXTURE}" bs=1 seek=0 conv=notrunc status=none
dd if=/dev/urandom of="${FIXTURE}" bs=4096 count=17 seek=15 conv=notrunc status=none
dd if=/dev/urandom of="${FIXTURE}" bs=4096 count=256 seek=2048 conv=notrunc status=none
printf 'EDP-LBA11-LBA12' | dd of="${FIXTURE}" bs=1 seek=$((11 * 512)) conv=notrunc status=none
printf 'EDP-TAIL-SECTOR' | dd of="${FIXTURE}" bs=1 seek=$((LOGICAL_SIZE - 512)) conv=notrunc status=none

"${WORK}/edp-raw-sparse" backup \
  --source "${FIXTURE}" \
  --size "${LOGICAL_SIZE}" \
  --output "${IMAGE}" \
  --manifest "${MANIFEST}" \
  --chunk-size $((4 * 1024 * 1024)) \
  --sparse-block-size $((64 * 1024)) \
  --device-id synthetic-edp \
  --vid-pid 21c4:0cd1 | tee "${WORK}/backup.log"

"${WORK}/edp-raw-sparse" verify \
  --image "${IMAGE}" --manifest "${MANIFEST}" | tee "${WORK}/verify.log"
"${WORK}/edp-raw-sparse" restore \
  --image "${IMAGE}" --manifest "${MANIFEST}" --output "${RESTORED}" | tee "${WORK}/restore.log"

FIXTURE_SHA="$(shasum -a 256 "${FIXTURE}" | awk '{print $1}')"
IMAGE_SHA="$(shasum -a 256 "${IMAGE}" | awk '{print $1}')"
RESTORED_SHA="$(shasum -a 256 "${RESTORED}" | awk '{print $1}')"
[[ "${FIXTURE_SHA}" == "${IMAGE_SHA}" && "${IMAGE_SHA}" == "${RESTORED_SHA}" ]]
[[ "$(stat -f %z "${IMAGE}")" == "${LOGICAL_SIZE}" ]]
[[ "$(stat -f %z "${RESTORED}")" == "${LOGICAL_SIZE}" ]]
ALLOCATED="$(du -k "${IMAGE}" | awk '{print $1}')"
LOGICAL_KIB=$((LOGICAL_SIZE / 1024))
[[ "${ALLOCATED}" -lt $((LOGICAL_KIB / 4)) ]]

grep -F 'RESULT=EDP_RAW_SPARSE_BACKUP_OK' "${WORK}/backup.log"
grep -F 'RESULT=EDP_RAW_SPARSE_VERIFY_OK' "${WORK}/verify.log"
grep -F 'RESULT=EDP_RAW_SPARSE_RESTORE_OK' "${WORK}/restore.log"
grep -F '"logicalSize" : 67108864' "${MANIFEST}"
grep -F '"sourcePath"' "${MANIFEST}"
grep -F '"allocatedBytes"' "${MANIFEST}"
grep -F '"extents"' "${MANIFEST}"

if "${WORK}/edp-raw-sparse" restore \
  --image "${IMAGE}" --manifest "${MANIFEST}" --output /dev/edp-forbidden \
  >"${WORK}/forbidden.log" 2>&1; then
  echo 'restore unexpectedly accepted /dev output' >&2
  exit 1
fi
grep -F 'refusing raw/block-device output' "${WORK}/forbidden.log"
if grep -F 'O_RDWR' "${ROOT}/product/EDPRawReadAuthorization.c"; then
  echo 'raw backup authorization helper contains a write-open flag' >&2
  exit 1
fi

echo "FIXTURE_SHA256=${FIXTURE_SHA}"
echo "SPARSE_ALLOCATED_KIB=${ALLOCATED}"
echo 'RESULT=EDP_RAW_SPARSE_BACKUP_RESTORE_E2E_OK'
