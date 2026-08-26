#!/bin/bash
set -euo pipefail

WORK_DIR="${RUNNER_TEMP:-/tmp}/edp-fuse2-create"
MOUNT_POINT="${EDP_FUSE2_CREATE_MOUNT_POINT:-/Volumes/edp-fuse2-create}"
BINARY="${WORK_DIR}/validate-fuse2-create"
SERVER_LOG="${WORK_DIR}/server.log"
PID=""
CLEANUP_DONE=0

mkdir -p "${WORK_DIR}"
: >"${SERVER_LOG}"

is_mounted() {
  /sbin/mount | /usr/bin/grep -F " on ${MOUNT_POINT} " >/dev/null 2>&1
}

stop_server() {
  if [[ -n "${PID}" ]] && kill -0 "${PID}" >/dev/null 2>&1; then
    kill -TERM "${PID}" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      kill -0 "${PID}" >/dev/null 2>&1 || return 0
      sleep 0.1
    done
    kill -KILL "${PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${PID}" ]]; then
    set +e
    wait "${PID}" >/dev/null 2>&1
    local rc=$?
    set -e
    printf 'FUSE2_SERVER_EXIT_STATUS=%s\n' "${rc}"
  fi
  PID=""
}

cleanup() {
  if (( CLEANUP_DONE )); then return 0; fi
  CLEANUP_DONE=1
  if is_mounted; then
    /sbin/umount "${MOUNT_POINT}" >/dev/null 2>&1 || sudo -n /sbin/umount "${MOUNT_POINT}" >/dev/null 2>&1 || true
  fi
  stop_server || true
  if ! is_mounted; then
    /bin/rmdir "${MOUNT_POINT}" >/dev/null 2>&1 || sudo -n /bin/rmdir "${MOUNT_POINT}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

FUSE_CFLAGS="$(pkg-config --cflags fuse)"
FUSE_LIBS="$(pkg-config --libs fuse)"
/usr/bin/cc native/EDPFSKitPoC/Tools/ValidateFuse2Create.c \
  -D_FILE_OFFSET_BITS=64 ${FUSE_CFLAGS} ${FUSE_LIBS} \
  -F/Library/Filesystems/macfuse.fs/Contents/Frameworks \
  -o "${BINARY}"
printf 'RESULT=FUSE2_CREATE_PROBE_BUILT\n'

if [[ "${MOUNT_POINT}" == /private/tmp/* ]]; then
  /bin/mkdir -p "${MOUNT_POINT}"
else
  sudo /bin/mkdir -p "${MOUNT_POINT}"
  sudo /usr/sbin/chown "$(id -u):$(id -g)" "${MOUNT_POINT}"
fi
chmod 700 "${MOUNT_POINT}"

"${BINARY}" "${MOUNT_POINT}" >"${SERVER_LOG}" 2>&1 &
PID=$!
printf 'FUSE2_SERVER_PID=%s\n' "${PID}"

for _ in $(seq 1 100); do
  is_mounted && break
  if ! kill -0 "${PID}" >/dev/null 2>&1; then break; fi
  sleep 0.1
done

if ! is_mounted; then
  printf 'FAIL=FUSE2_CREATE_PROBE_MOUNT_FAILED\n'
  /bin/cat "${SERVER_LOG}"
  if [[ -n "${PID}" ]]; then
    set +e
    wait "${PID}"
    rc=$?
    set -e
    PID=""
    printf 'FUSE2_SERVER_EXIT_STATUS=%s\n' "${rc}"
  fi
  exit 1
fi

MOUNT_LINE="$(/sbin/mount | /usr/bin/grep -F " on ${MOUNT_POINT} ")"
printf 'FUSE2_MOUNT_LINE=%s\n' "${MOUNT_LINE}"
printf '%s\n' "${MOUNT_LINE}" | /usr/bin/grep -Eq '^macfuse://[^ ]+ on .+\(macfuse,.*fskit'
printf 'RESULT=FUSE2_CREATE_PROBE_MOUNTED\n'

PROOF="${MOUNT_POINT}/created.txt"
set +e
printf 'hello-fuse2-create\n' >"${PROOF}"
CREATE_RC=$?
set -e
printf 'FUSE2_CREATE_RC=%s\n' "${CREATE_RC}"

if (( CREATE_RC != 0 )); then
  printf 'FAIL=FUSE2_REGULAR_FILE_CREATE_FAILED\n'
  /bin/cat "${SERVER_LOG}"
  exit 1
fi

ACTUAL="$(/bin/cat "${PROOF}")"
[[ "${ACTUAL}" == "hello-fuse2-create" ]]
printf 'RESULT=FUSE2_REGULAR_FILE_CREATE_WRITE_READ_OK\n'

TARGET="${MOUNT_POINT}/target.txt"
TARGET_BEFORE="$(/bin/cat "${TARGET}")"
[[ "${TARGET_BEFORE}" == "old-content" ]]
set +e
RENAME_OUTPUT="$("${BINARY}" --rename "${PROOF}" "${TARGET}" 2>&1)"
RENAME_RC=$?
set -e
printf '%s\n' "${RENAME_OUTPUT}"
printf 'FUSE2_RENAME_OVER_EXISTING_RC=%s\n' "${RENAME_RC}"
if (( RENAME_RC == 0 )); then
  printf 'RESULT=FUSE2_RENAME_OVER_EXISTING_SUPPORTED\n'
  TARGET_AFTER="$(/bin/cat "${TARGET}")"
  [[ "${TARGET_AFTER}" == "hello-fuse2-create" ]]
else
  printf '%s\n' "${RENAME_OUTPUT}" | /usr/bin/grep -F 'RENAME_CLIENT_ERRNO=102' >/dev/null
  printf 'RESULT=FUSE2_RENAME_OVER_EXISTING_EOPNOTSUPP_REPRODUCED\n'
fi

if [[ -e "${PROOF}" ]]; then
  /bin/rm "${PROOF}"
  [[ ! -e "${PROOF}" ]]
  printf 'RESULT=FUSE2_REGULAR_FILE_UNLINK_OK\n'
fi

/sbin/umount "${MOUNT_POINT}"
stop_server || true
if is_mounted; then
  printf 'FAIL=FUSE2_CREATE_PROBE_STILL_MOUNTED\n'
  exit 1
fi
CLEANUP_DONE=1
/bin/rmdir "${MOUNT_POINT}" >/dev/null 2>&1 || true
trap - EXIT INT TERM
/bin/cat "${SERVER_LOG}"
printf 'RESULT=FUSE2_CREATE_E2E_OK\n'
