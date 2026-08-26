#!/bin/bash
set -euo pipefail

RUNTIME_ROOT="${1:?usage: probe-ntfs-failclosed.sh <ntfs-runtime-root>}"
BIN="${RUNTIME_ROOT}/bin"
LIB="${RUNTIME_ROOT}/lib"
TOOLS="${RUNTIME_ROOT}/test-tools"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/edp-ntfs-failclosed.XXXXXX")"
MOUNT_POINT="/Volumes/EDPNTFSFailClosed"
NTFS_PID=""

is_mounted() {
  /sbin/mount | /usr/bin/grep -Fq " on ${MOUNT_POINT} "
}

cleanup() {
  set +e
  if is_mounted; then
    /sbin/umount "${MOUNT_POINT}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${NTFS_PID}" ]] && kill -0 "${NTFS_PID}" >/dev/null 2>&1; then
    kill "${NTFS_PID}" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "${NTFS_PID}" >/dev/null 2>&1 || break
      sleep 0.1
    done
    kill -9 "${NTFS_PID}" >/dev/null 2>&1 || true
  fi
  rmdir "${MOUNT_POINT}" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT INT TERM

export DYLD_LIBRARY_PATH="${LIB}"

for required in ntfs-3g ntfs-3g.probe; do
  test -x "${BIN}/${required}"
done
for required in mkntfs ntfsfix; do
  test -x "${TOOLS}/${required}"
done

CLEAN="${WORK}/clean.img"
DIRTY="${WORK}/dirty.img"
HIBERNATED="${WORK}/hibernated.img"

/usr/bin/truncate -s 64m "${CLEAN}"
"${TOOLS}/mkntfs" -F -Q -L EDPFAILCLOSED "${CLEAN}" >/dev/null

"${BIN}/ntfs-3g.probe" --readwrite "${CLEAN}"
echo 'RESULT=NTFS_CLEAN_FIXTURE_WRITABLE'

cp "${CLEAN}" "${DIRTY}"
set +e
"${TOOLS}/ntfsfix" "${DIRTY}" >"${WORK}/ntfsfix.log" 2>&1
NTFSFIX_RC=$?
set -e
printf 'NTFSFIX_DIRTY_FIXTURE_RC=%d\n' "${NTFSFIX_RC}"

set +e
"${BIN}/ntfs-3g.probe" --readwrite "${DIRTY}" >"${WORK}/dirty-rw.log" 2>&1
DIRTY_RW_RC=$?
"${BIN}/ntfs-3g.probe" --readonly "${DIRTY}" >"${WORK}/dirty-ro.log" 2>&1
DIRTY_RO_RC=$?
set -e
printf 'DIRTY_RW_PROBE_RC=%d\n' "${DIRTY_RW_RC}"
printf 'DIRTY_RO_PROBE_RC=%d\n' "${DIRTY_RO_RC}"
test "${DIRTY_RW_RC}" -eq 15
test "${DIRTY_RO_RC}" -eq 0
echo 'RESULT=NTFS_DIRTY_FIXTURE_FAILS_CLOSED'

cp "${CLEAN}" "${HIBERNATED}"
mkdir -p "${MOUNT_POINT}"
"${BIN}/ntfs-3g" \
  -o backend=fskit \
  -o no_detach \
  -o norecover \
  -o noatime \
  -o big_writes \
  -o "uid=$(id -u)" \
  -o "gid=$(id -g)" \
  -o volname=EDPFAILHIBER \
  "${HIBERNATED}" "${MOUNT_POINT}" >"${WORK}/hiber-mount.log" 2>&1 &
NTFS_PID=$!

mounted=0
for _ in $(seq 1 100); do
  if is_mounted; then
    mounted=1
    break
  fi
  kill -0 "${NTFS_PID}" >/dev/null 2>&1 || break
  sleep 0.1
done
if [[ "${mounted}" -ne 1 ]]; then
  cat "${WORK}/hiber-mount.log" >&2
  exit 20
fi

/usr/bin/dd if=/dev/zero of="${MOUNT_POINT}/hiberfil.sys" bs=4096 count=1 status=none
printf 'HIBR' | /usr/bin/dd of="${MOUNT_POINT}/hiberfil.sys" bs=1 count=4 conv=notrunc status=none
/bin/sync
/sbin/umount "${MOUNT_POINT}"
wait "${NTFS_PID}" || true
NTFS_PID=""

set +e
"${BIN}/ntfs-3g.probe" --readwrite "${HIBERNATED}" >"${WORK}/hiber-rw.log" 2>&1
HIBER_RW_RC=$?
"${BIN}/ntfs-3g.probe" --readonly "${HIBERNATED}" >"${WORK}/hiber-ro.log" 2>&1
HIBER_RO_RC=$?
set -e
printf 'HIBERNATED_RW_PROBE_RC=%d\n' "${HIBER_RW_RC}"
printf 'HIBERNATED_RO_PROBE_RC=%d\n' "${HIBER_RO_RC}"
test "${HIBER_RW_RC}" -eq 14
test "${HIBER_RO_RC}" -eq 0
echo 'RESULT=NTFS_HIBERNATED_FIXTURE_FAILS_CLOSED'

echo 'RESULT=NTFS_FAIL_CLOSED_E2E_OK'
