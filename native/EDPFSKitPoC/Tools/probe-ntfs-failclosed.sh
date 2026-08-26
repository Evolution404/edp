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

stop_mount_cleanly() {
  if is_mounted; then
    /sbin/umount "${MOUNT_POINT}"
  fi
  if [[ -n "${NTFS_PID}" ]]; then
    wait "${NTFS_PID}" || true
    NTFS_PID=""
  fi
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

start_mount() {
  local image="$1"
  local label="$2"
  local log_file="$3"

  mkdir -p "${MOUNT_POINT}"
  "${BIN}/ntfs-3g" \
    -o backend=fskit \
    -o no_detach \
    -o norecover \
    -o noatime \
    -o big_writes \
    -o "uid=$(id -u)" \
    -o "gid=$(id -g)" \
    -o "volname=${label}" \
    "${image}" "${MOUNT_POINT}" >"${log_file}" 2>&1 &
  NTFS_PID=$!

  local mounted=0
  for _ in $(seq 1 100); do
    if is_mounted; then
      mounted=1
      break
    fi
    kill -0 "${NTFS_PID}" >/dev/null 2>&1 || break
    sleep 0.1
  done
  if [[ "${mounted}" -ne 1 ]]; then
    cat "${log_file}" >&2
    return 1
  fi
}

export DYLD_LIBRARY_PATH="${LIB}"

for required in ntfs-3g ntfs-3g.probe; do
  test -x "${BIN}/${required}"
done
test -x "${TOOLS}/mkntfs"

CLEAN="${WORK}/clean.img"
UNCLEAN="${WORK}/unclean.img"
HIBERNATED="${WORK}/hibernated.img"

/usr/bin/truncate -s 64m "${CLEAN}"
"${TOOLS}/mkntfs" -F -Q -L EDPFAILCLOSED "${CLEAN}" >/dev/null

"${BIN}/ntfs-3g.probe" --readwrite "${CLEAN}"
echo 'RESULT=NTFS_CLEAN_FIXTURE_WRITABLE'

# Create a real unclean-journal fixture: mount read-write with norecover,
# modify metadata/data, then kill the filesystem process without unmounting.
cp "${CLEAN}" "${UNCLEAN}"
start_mount "${UNCLEAN}" EDPFAILUNCLEAN "${WORK}/unclean-mount.log"
printf 'unclean-power-loss\n' >"${MOUNT_POINT}/power-loss.txt"
/bin/sync
kill -9 "${NTFS_PID}"
wait "${NTFS_PID}" 2>/dev/null || true
NTFS_PID=""
for _ in $(seq 1 100); do
  is_mounted || break
  sleep 0.1
done
if is_mounted; then
  /sbin/umount "${MOUNT_POINT}" >/dev/null 2>&1 || true
fi

set +e
"${BIN}/ntfs-3g.probe" --readwrite "${UNCLEAN}" >"${WORK}/unclean-rw.log" 2>&1
UNCLEAN_RW_RC=$?
"${BIN}/ntfs-3g.probe" --readonly "${UNCLEAN}" >"${WORK}/unclean-ro.log" 2>&1
UNCLEAN_RO_RC=$?
set -e
printf 'UNCLEAN_RW_PROBE_RC=%d\n' "${UNCLEAN_RW_RC}"
printf 'UNCLEAN_RO_PROBE_RC=%d\n' "${UNCLEAN_RO_RC}"
if [[ "${UNCLEAN_RW_RC}" -ne 15 ]]; then
  cat "${WORK}/unclean-rw.log" >&2
  exit 21
fi
test "${UNCLEAN_RO_RC}" -eq 0
echo 'RESULT=NTFS_UNCLEAN_FIXTURE_FAILS_CLOSED'

# Create a hibernation fixture using the detector's actual contract: a root
# hiberfil.sys with a 4096-byte header beginning with HIBR, then cleanly unmount.
cp "${CLEAN}" "${HIBERNATED}"
start_mount "${HIBERNATED}" EDPFAILHIBER "${WORK}/hiber-mount.log"
/usr/bin/dd if=/dev/zero of="${MOUNT_POINT}/hiberfil.sys" bs=4096 count=1 status=none
printf 'HIBR' | /usr/bin/dd of="${MOUNT_POINT}/hiberfil.sys" bs=1 count=4 conv=notrunc status=none
/bin/sync
stop_mount_cleanly

set +e
"${BIN}/ntfs-3g.probe" --readwrite "${HIBERNATED}" >"${WORK}/hiber-rw.log" 2>&1
HIBER_RW_RC=$?
"${BIN}/ntfs-3g.probe" --readonly "${HIBERNATED}" >"${WORK}/hiber-ro.log" 2>&1
HIBER_RO_RC=$?
set -e
printf 'HIBERNATED_RW_PROBE_RC=%d\n' "${HIBER_RW_RC}"
printf 'HIBERNATED_RO_PROBE_RC=%d\n' "${HIBER_RO_RC}"
if [[ "${HIBER_RW_RC}" -ne 14 ]]; then
  cat "${WORK}/hiber-rw.log" >&2
  exit 22
fi
test "${HIBER_RO_RC}" -eq 0
echo 'RESULT=NTFS_HIBERNATED_FIXTURE_FAILS_CLOSED'

echo 'RESULT=NTFS_FAIL_CLOSED_E2E_OK'
