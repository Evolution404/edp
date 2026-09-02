#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DRIVE_ROOT="$ROOT/Apps/Drive"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$DRIVE_ROOT"
REPO_ROOT="$PWD"
. scripts/prepare-shared-edp-core.sh

STORAGE_PROFILE="${EDP_STORAGE_PROFILE:-release}"
case "$STORAGE_PROFILE" in
  smoke)
    LOOP_COUNT="${EDP_STORAGE_LOOP_COUNT:-5}"
    MIN_LOOPS=3
    MAX_LOOPS=10
    ;;
  release)
    LOOP_COUNT="${EDP_STORAGE_LOOP_COUNT:-5}"
    MIN_LOOPS=5
    MAX_LOOPS=100
    ;;
  *)
    echo "EDP_STORAGE_PROFILE must be smoke or release" >&2
    exit 64
    ;;
esac
case "$LOOP_COUNT" in
  ''|*[!0-9]*) echo "EDP_STORAGE_LOOP_COUNT must be an integer" >&2; exit 64 ;;
esac
if (( LOOP_COUNT < MIN_LOOPS || LOOP_COUNT > MAX_LOOPS )); then
  echo "EDP_STORAGE_LOOP_COUNT for $STORAGE_PROFILE must remain within $MIN_LOOPS-$MAX_LOOPS" >&2
  exit 64
fi

STORAGE_PHASE="${EDP_STORAGE_PHASE:-all}"
case "$STORAGE_PHASE" in
  all|prepare|core|stress|recovery|contracts|final) ;;
  *)
    echo "EDP_STORAGE_PHASE must be all, prepare, core, stress, recovery, contracts, or final" >&2
    exit 64
    ;;
esac

if [[ -n "${EDP_STORAGE_WORK_DIR:-}" ]]; then
  mkdir -p "$EDP_STORAGE_WORK_DIR"
  WORK_DIR="$(cd "$EDP_STORAGE_WORK_DIR" && pwd -P)"
  TMP_ROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
  [[ "$WORK_DIR" == "$TMP_ROOT"/edp-storage-e2e.* ]] || {
    echo "EDP_STORAGE_WORK_DIR must stay under $TMP_ROOT with edp-storage-e2e.* name" >&2
    exit 64
  }
  PRESERVE_WORK_DIR=1
else
  [[ "$STORAGE_PHASE" == all ]] || {
    echo "phased storage execution requires EDP_STORAGE_WORK_DIR" >&2
    exit 64
  }
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/edp-storage-e2e.XXXXXX")"
  WORK_DIR="$(cd "$WORK_DIR" && pwd -P)"
  PRESERVE_WORK_DIR=0
fi
BUILD_DIR="$WORK_DIR/build"
MOUNT_ROOT="$WORK_DIR/mounts"
LOG_ROOT="$WORK_DIR/logs"
ACTIVE_DEVICES="$WORK_DIR/active-devices.txt"
ACTIVE_FIXTURE_DEVICES="$WORK_DIR/active-fixture-devices.txt"
ACTIVE_PROCESSES="$WORK_DIR/active-processes.txt"
ACTIVE_MOUNTS="$WORK_DIR/active-mounts.txt"
mkdir -p "$BUILD_DIR" "$MOUNT_ROOT" "$LOG_ROOT"
touch "$ACTIVE_DEVICES" "$ACTIVE_FIXTURE_DEVICES" "$ACTIVE_PROCESSES" "$ACTIVE_MOUNTS"

ATTACH_BIN="$BUILD_DIR/diskimages2-attach"
PREPARE_BIN="$BUILD_DIR/prepare-edp-filesystem-fixture"
ADAPTER_BIN="$BUILD_DIR/edp-mfmount-fixture"
FSKIT_GUARD_BIN="$BUILD_DIR/edp-assert-no-fskit-mounts"
DA_MOUNT_BIN="$BUILD_DIR/edp-da-mount"
FAILURE_BIN="$BUILD_DIR/validate-storage-failures"
BOUNDED="$DRIVE_ROOT/Tests/Storage/RunBounded.py"
FIXTURE_DIR="$DRIVE_ROOT/fixtures/real_disks/disk4"
PASSWORD_FILE="$WORK_DIR/password"
DEVICE_SIZE=124736503808
VID=21c4
PID=0cd1
BOOT_SIZE=10453504
RW_FS_SIZE=$((384 * 1024 * 1024))
BOOT_RAW="$WORK_DIR/boot-fat16.raw"
EXCHANGE_RAW="$WORK_DIR/exchange-exfat.raw"
SECURE_RAW="$WORK_DIR/secure-exfat.raw"
EDP_IMAGE="$WORK_DIR/virtual-disk4.edp"

printf '0000aaaa' >"$PASSWORD_FILE"
chmod 0600 "$PASSWORD_FILE"

log() { printf '%s\n' "$*"; }

REMOUNT_QUIESCENCE_SECONDS=3

wait_for_native_filesystem_quiescence() {
  /bin/sleep "$REMOUNT_QUIESCENCE_SECONDS"
}

wait_for_remount_quiescence() {
  /bin/sleep "$REMOUNT_QUIESCENCE_SECONDS"
}

is_mounted() {
  [[ -x "$FSKIT_GUARD_BIN" ]] || return 1
  "$FSKIT_GUARD_BIN" --is-mounted "$1" >/dev/null 2>&1
}

cleanup_crashed_local_mount() {
  local target="$1"
  local source
  source="$("$FSKIT_GUARD_BIN" --mount-source "$target" 2>/dev/null || true)"
  [[ "$source" =~ ^/dev/disk[0-9]+$ ]] || {
    echo "refusing crash cleanup for unknown mount source: $target source=$source" >&2
    return 1
  }
  "$FSKIT_GUARD_BIN" --is-macfuse-mount "$target" >/dev/null 2>&1 || {
    echo "refusing crash cleanup for non-macFUSE mount: $target" >&2
    return 1
  }
  if ! "$FSKIT_GUARD_BIN" --assert-no-macfuse-mounts-outside "$WORK_DIR/"; then
    echo "refusing macFUSE Local module restart while unrelated Local mounts exist" >&2
    return 1
  fi

  local module_pattern='/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app/Contents/Extensions/io.macfuse.app.fsmodule.macfuse-local.appex/Contents/MacOS/io.macfuse.app.fsmodule.macfuse-local'
  local found=0
  local module_pid
  for module_pid in $(/usr/bin/pgrep -f "$module_pattern" || true); do
    [[ "$(/bin/ps -p "$module_pid" -o uid= | /usr/bin/tr -d ' ')" == "$(/usr/bin/id -u)" ]] || continue
    /bin/ps -p "$module_pid" -o command= | /usr/bin/grep -Fq "$module_pattern" || continue
    found=1
    /bin/kill -TERM "$module_pid"
  done
  (( found == 1 )) || {
    echo "no user-owned macFUSE Local module was available for bounded crash cleanup" >&2
    return 1
  }
  for _ in $(/usr/bin/seq 1 100); do
    is_mounted "$target" || return 0
    /bin/sleep 0.1
  done
  echo "macFUSE Local crash mount remained after module restart: $target" >&2
  return 1
}

adapter_log_is_transient_fskit_failure() {
  local log_path="$1"
  /usr/bin/grep -Eiq \
    'mount\(8\) returned 69|File system extension not found|File system extension not enabled' \
    "$log_path"
}

restart_console_fskit_agent_if_safe() {
  [[ -x "$FSKIT_GUARD_BIN" ]] || {
    echo "FSKit mount guard is unavailable" >&2
    return 1
  }
  if ! "$FSKIT_GUARD_BIN" --assert-no-fskit-mounts; then
    echo "refusing FSKit agent restart while an FSKit mount is active" >&2
    return 1
  fi

  local uid
  uid="$(/usr/bin/id -u)"
  local pids=""
  local pid command
  for pid in $(/usr/bin/pgrep -U "$uid" -x fskit_agent || true); do
    command="$(/bin/ps -p "$pid" -o command= 2>/dev/null | /usr/bin/xargs || true)"
    [[ "$command" == "/usr/libexec/fskit_agent" ]] || continue
    pids="${pids} ${pid}"
  done
  [[ -n "${pids// }" ]] || {
    echo "no exact console-user fskit_agent process found for recovery" >&2
    return 1
  }

  /bin/kill -KILL $pids >/dev/null 2>&1 || true
  for _ in $(/usr/bin/seq 1 50); do
    local alive=0
    for pid in $pids; do
      /bin/kill -0 "$pid" >/dev/null 2>&1 && alive=1
    done
    (( alive == 0 )) && break
    /bin/sleep 0.05
  done
  for pid in $pids; do
    /bin/kill -0 "$pid" >/dev/null 2>&1 && {
      echo "console-user fskit_agent did not exit after bounded recovery" >&2
      return 1
    }
  done
  log "STORAGE_FSKIT_HOST_RECOVERY=console-agent-restarted"
  /bin/sleep 1
  return 0
}

capture_hdiutil_info() {
  local output="$1"
  local attempts="${2:-20}"
  local error_log="${output}.stderr"
  local attempt candidate
  for attempt in $(/usr/bin/seq 1 "$attempts"); do
    candidate="$(/usr/bin/mktemp "${output}.tmp.XXXXXX")"
    : >"$error_log"
    if bounded 3 /usr/bin/hdiutil info -plist >"$candidate" 2>"$error_log" \
      && /usr/bin/plutil -lint "$candidate" >/dev/null 2>&1; then
      # Publish only a fully parsed snapshot. Several exact-identity helpers can
      # sample hdiutil in adjacent lifecycle callbacks; truncating the shared
      # destination before capture allowed another reader to observe partial XML.
      /bin/mv -f "$candidate" "$output"
      return 0
    fi
    /bin/rm -f "$candidate"
    /bin/sleep 0.1
  done
  echo "hdiutil info snapshot did not stabilize after $attempts attempts" >&2
  /usr/bin/tail -20 "$error_log" >&2 || true
  return 1
}

assert_synthetic_device() {
  local bsd="$1"
  local backing="$2"
  local info="$WORK_DIR/hdiutil-info.plist"
  [[ "$bsd" =~ ^disk[0-9]+$ ]] || {
    echo "unsafe synthetic BSD name: $bsd" >&2
    return 1
  }
  [[ "$backing" == "$WORK_DIR"/* || "$backing" == "$MOUNT_ROOT"/* ]] || {
    echo "synthetic backing escaped test root: $backing" >&2
    return 1
  }
  capture_hdiutil_info "$info" 20
  /usr/bin/python3 - "$info" "$bsd" "$backing" <<'PY'
import os
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    root = plistlib.load(handle)
expected_device = "/dev/" + sys.argv[2]
expected_path = os.path.abspath(os.path.normpath(sys.argv[3]))
for image in root.get("images", []):
    devices = [item.get("dev-entry") for item in image.get("system-entities", [])]
    if expected_device not in devices:
        continue
    actual_path = os.path.abspath(os.path.normpath(image.get("image-path", "")))
    valid = (
        actual_path == expected_path
        and image.get("diskimages2") is True
        and image.get("writeable") is True
        and image.get("removable") is True
    )
    raise SystemExit(0 if valid else 1)
raise SystemExit(1)
PY
}

synthetic_publication_exists() {
  local backing="$1"
  local info="$WORK_DIR/hdiutil-publication-check.plist"
  [[ "$backing" == "$WORK_DIR"/* || "$backing" == "$MOUNT_ROOT"/* ]] || return 1
  capture_hdiutil_info "$info" 5 >/dev/null 2>&1 || return 0
  /usr/bin/python3 - "$info" "$backing" <<'PY'
import os
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    root = plistlib.load(handle)
expected = os.path.abspath(os.path.normpath(sys.argv[2]))
for image in root.get("images", []):
    if os.path.abspath(os.path.normpath(image.get("image-path", ""))) != expected:
        continue
    if image.get("diskimages2") is True:
        raise SystemExit(0)
raise SystemExit(1)
PY
}

wait_for_synthetic_publication_gone() {
  local backing="$1"
  local attempts="${2:-100}"
  for _ in $(/usr/bin/seq 1 "$attempts"); do
    synthetic_publication_exists "$backing" || return 0
    /bin/sleep 0.1
  done
  return 1
}

synthetic_publication_owner_snapshot() {
  local bsd="$1"
  local backing="$2"
  local info="$WORK_DIR/hdiutil-synthetic-owner.plist"
  [[ "$bsd" =~ ^disk[0-9]+$ ]] || return 1
  [[ "$backing" == "$WORK_DIR"/* || "$backing" == "$MOUNT_ROOT"/* ]] || return 1
  capture_hdiutil_info "$info" 10 >/dev/null 2>&1 || return 1
  /usr/bin/python3 - "$info" "$backing" <<'PY'
import os
import plistlib
import re
import sys
with open(sys.argv[1], "rb") as handle:
    root = plistlib.load(handle)
expected_path = os.path.abspath(os.path.normpath(sys.argv[2]))
for image in root.get("images", []):
    if os.path.abspath(os.path.normpath(image.get("image-path", ""))) != expected_path:
        continue
    devices = [item.get("dev-entry") for item in image.get("system-entities", [])]
    pid = image.get("hdid-pid")
    synthetic_devices = all(
        isinstance(device, str)
        and re.fullmatch(r"/dev/disk\d+(?:s\d+)*", device) is not None
        for device in devices
    )
    valid = (
        synthetic_devices
        and image.get("diskimages2") is True
        and image.get("autodiskmount") is False
        and image.get("image-encrypted") is False
        and image.get("owner-uid") == os.getuid()
        and image.get("owner-mode") == 0o600
        and isinstance(pid, int)
        and pid > 1
    )
    if not valid:
        raise SystemExit(1)
    print(f"{pid}|{','.join(devices)}")
    raise SystemExit(0)
raise SystemExit(1)
PY
}

recover_synthetic_publication() {
  local bsd="$1"
  local backing="$2"
  local owner_snapshot="" pid="" devices=""
  owner_snapshot="$(synthetic_publication_owner_snapshot "$bsd" "$backing")" || return 1
  IFS='|' read -r pid devices <<<"$owner_snapshot"
  echo "STORAGE_DISKIMAGES_OWNER_RECOVERY_BEGIN=pid=$pid devices=${devices:-none}" >&2

  "$DA_MOUNT_BIN" --assert-process-path "$pid" /usr/libexec/diskimagesiod >/dev/null || {
    echo "STORAGE_DISKIMAGES_OWNER_RECOVERY_REFUSED=process-path" >&2
    return 1
  }

  /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
  if wait_for_synthetic_publication_gone "$backing" 15; then
    echo 'STORAGE_DISKIMAGES_OWNER_RECOVERY=term' >&2
    return 0
  fi

  local revalidated_snapshot=""
  revalidated_snapshot="$(synthetic_publication_owner_snapshot "$bsd" "$backing")" || {
    echo "STORAGE_DISKIMAGES_OWNER_RECOVERY_REFUSED=revalidation-missing" >&2
    return 1
  }
  [[ "$revalidated_snapshot" == "$owner_snapshot" ]] || {
    echo "STORAGE_DISKIMAGES_OWNER_RECOVERY_REFUSED=identity-changed" >&2
    return 1
  }
  "$DA_MOUNT_BIN" --assert-process-path "$pid" /usr/libexec/diskimagesiod >/dev/null || {
    echo "STORAGE_DISKIMAGES_OWNER_RECOVERY_REFUSED=process-path-changed" >&2
    return 1
  }
  /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
  if wait_for_synthetic_publication_gone "$backing" 20; then
    echo 'STORAGE_DISKIMAGES_OWNER_RECOVERY=kill' >&2
    return 0
  fi
  echo 'STORAGE_DISKIMAGES_OWNER_RECOVERY_REFUSED=owner-remained' >&2
  return 1
}

fixture_publication_exists() {
  local backing="$1"
  local info="$WORK_DIR/hdiutil-fixture-publication-check.plist"
  [[ "$backing" == "$WORK_DIR"/* ]] || return 1
  capture_hdiutil_info "$info" 5 >/dev/null 2>&1 || return 0
  /usr/bin/python3 - "$info" "$backing" <<'PY'
import os
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    root = plistlib.load(handle)
expected = os.path.abspath(os.path.normpath(sys.argv[2]))
for image in root.get("images", []):
    if os.path.abspath(os.path.normpath(image.get("image-path", ""))) != expected:
        continue
    valid = (
        image.get("diskimages2") is False
        and image.get("autodiskmount") is False
        and image.get("owner-uid") == os.getuid()
        and image.get("writeable") is True
        and image.get("removable") is True
    )
    raise SystemExit(0 if valid else 1)
raise SystemExit(1)
PY
}

wait_for_fixture_publication_gone() {
  local backing="$1"
  local attempts="${2:-100}"
  for _ in $(/usr/bin/seq 1 "$attempts"); do
    fixture_publication_exists "$backing" || return 0
    /bin/sleep 0.1
  done
  return 1
}

assert_fixture_device() {
  local bsd="$1"
  local backing="$2"
  local info="$WORK_DIR/hdiutil-fixture-info.plist"
  [[ "$bsd" =~ ^disk[0-9]+$ ]] || {
    echo "unsafe fixture BSD name: $bsd" >&2
    return 1
  }
  [[ "$backing" == "$WORK_DIR"/* ]] || {
    echo "fixture backing escaped test root: $backing" >&2
    return 1
  }
  capture_hdiutil_info "$info" 20
  /usr/bin/python3 - "$info" "$bsd" "$backing" <<'PY'
import os
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    root = plistlib.load(handle)
expected_device = "/dev/" + sys.argv[2]
expected_path = os.path.abspath(os.path.normpath(sys.argv[3]))
for image in root.get("images", []):
    devices = [item.get("dev-entry") for item in image.get("system-entities", [])]
    if expected_device not in devices:
        continue
    actual_path = os.path.abspath(os.path.normpath(image.get("image-path", "")))
    valid = (
        actual_path == expected_path
        and image.get("diskimages2") is False
        and image.get("autodiskmount") is False
        and image.get("owner-uid") == os.getuid()
        and image.get("writeable") is True
        and image.get("removable") is True
        and isinstance(image.get("blockcount"), int)
        and image.get("blockcount") > 0
        and image.get("blocksize") == 512
    )
    raise SystemExit(0 if valid else 1)
raise SystemExit(1)
PY
}

recover_fixture_image() {
  local bsd="$1"
  local backing="$2"
  local info="$WORK_DIR/hdiutil-fixture-recovery.plist"
  local pid=""
  [[ "$bsd" =~ ^disk[0-9]+$ ]] || return 1
  [[ "$backing" == "$WORK_DIR"/* ]] || return 1

  capture_hdiutil_info "$info" 10 >/dev/null 2>&1 || return 1
  pid="$(/usr/bin/python3 - "$info" "$bsd" "$backing" <<'PY'
import os
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    root = plistlib.load(handle)
expected_device = "/dev/" + sys.argv[2]
expected_path = os.path.abspath(os.path.normpath(sys.argv[3]))
for image in root.get("images", []):
    if os.path.abspath(os.path.normpath(image.get("image-path", ""))) != expected_path:
        continue
    devices = [item.get("dev-entry") for item in image.get("system-entities", [])]
    pid = image.get("hdid-pid")
    valid = (
        image.get("diskimages2") is False
        and image.get("autodiskmount") is False
        and image.get("owner-uid") == os.getuid()
        and image.get("writeable") is True
        and image.get("removable") is True
        and (not devices or expected_device in devices)
        and isinstance(pid, int)
        and pid > 1
    )
    if not valid:
        raise SystemExit(1)
    print(pid)
    raise SystemExit(0)
raise SystemExit(1)
PY
)" || return 1

  local process_uid process_command
  process_uid="$(/bin/ps -p "$pid" -o uid= 2>/dev/null | /usr/bin/tr -d ' ')"
  process_command="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$process_uid" == "$(/usr/bin/id -u)" ]] || return 1
  [[ "$process_command" == /System/Library/PrivateFrameworks/DiskImages.framework/Resources/diskimages-helper* ]] || return 1

  /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
  for _ in $(/usr/bin/seq 1 60); do
    if capture_hdiutil_info "$info" 3 >/dev/null 2>&1 && ! /usr/bin/python3 - "$info" "$backing" <<'PY'
import os
import plistlib
import sys
with open(sys.argv[1], "rb") as handle:
    root = plistlib.load(handle)
expected = os.path.abspath(os.path.normpath(sys.argv[2]))
raise SystemExit(0 if any(os.path.abspath(os.path.normpath(item.get("image-path", ""))) == expected for item in root.get("images", [])) else 1)
PY
    then
      return 0
    fi
    /bin/sleep 0.1
  done

  [[ "$(/bin/ps -p "$pid" -o uid= 2>/dev/null | /usr/bin/tr -d ' ')" == "$(/usr/bin/id -u)" ]] || return 1
  [[ "$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)" == /System/Library/PrivateFrameworks/DiskImages.framework/Resources/diskimages-helper* ]] || return 1
  /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
  for _ in $(/usr/bin/seq 1 40); do
    if capture_hdiutil_info "$info" 3 >/dev/null 2>&1 && ! /usr/bin/python3 - "$info" "$backing" <<'PY'
import os
import plistlib
import sys
with open(sys.argv[1], "rb") as handle:
    root = plistlib.load(handle)
expected = os.path.abspath(os.path.normpath(sys.argv[2]))
raise SystemExit(0 if any(os.path.abspath(os.path.normpath(item.get("image-path", ""))) == expected for item in root.get("images", [])) else 1)
PY
    then
      return 0
    fi
    /bin/sleep 0.1
  done
  return 1
}

bounded() {
  local seconds="$1"
  shift
  /usr/bin/python3 "$BOUNDED" --timeout "$seconds" "$@"
}

cleanup() {
  local status=$?
  set +e
  if [[ -f "$ACTIVE_FIXTURE_DEVICES" ]]; then
    while IFS='|' read -r bsd backing; do
      [[ -n "$bsd" && -n "$backing" ]] || continue
      if assert_fixture_device "$bsd" "$backing" >/dev/null 2>&1; then
        bounded 12 /usr/sbin/diskutil unmountDisk "$bsd" >/dev/null 2>&1 || true
        if ! bounded 12 /usr/bin/hdiutil detach "/dev/$bsd" -force >/dev/null 2>&1; then
          recover_fixture_image "$bsd" "$backing" >/dev/null 2>&1 || true
        fi
      else
        recover_fixture_image "$bsd" "$backing" >/dev/null 2>&1 || true
      fi
    done <"$ACTIVE_FIXTURE_DEVICES"
  fi
  if [[ -f "$ACTIVE_DEVICES" ]]; then
    while IFS='|' read -r bsd backing; do
      [[ -n "$bsd" && -n "$backing" ]] || continue
      # Reuse the exact normal teardown path. In particular, never issue a
      # pre-detach diskutil unmountDisk that can drop the DiskImages2 IOMedia
      # identity before hdiutil has retired its owner publication.
      eject_image "$bsd" "$backing" >/dev/null 2>&1 || true
    done <"$ACTIVE_DEVICES"
  fi
  if [[ -f "$ACTIVE_PROCESSES" ]]; then
    while IFS='|' read -r pid command; do
      [[ -n "$pid" ]] || continue
      if /bin/kill -0 "$pid" >/dev/null 2>&1 &&
         /bin/ps -p "$pid" -o command= 2>/dev/null | /usr/bin/grep -Fq "$command"; then
        /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
        for _ in $(/usr/bin/seq 1 100); do
          /bin/kill -0 "$pid" >/dev/null 2>&1 || break
          /bin/sleep 0.1
        done
        /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
      fi
    done <"$ACTIVE_PROCESSES"
  fi
  if [[ -f "$ACTIVE_MOUNTS" ]]; then
    while IFS= read -r mountpoint; do
      [[ -n "$mountpoint" ]] || continue
      if is_mounted "$mountpoint"; then
        if "$FSKIT_GUARD_BIN" --is-macfuse-mount "$mountpoint" >/dev/null 2>&1; then
          cleanup_crashed_local_mount "$mountpoint" >/dev/null 2>&1 || true
        else
          bounded 8 /sbin/umount -f "$mountpoint" >/dev/null 2>&1 || true
        fi
      fi
    done <"$ACTIVE_MOUNTS"
  fi
  if (( status != 0 )); then
    echo "STORAGE_E2E_ARTIFACTS=$WORK_DIR" >&2
  elif (( PRESERVE_WORK_DIR == 0 )) || [[ "$STORAGE_PHASE" == final ]]; then
    /usr/bin/find "$WORK_DIR" -depth -delete >/dev/null 2>&1 || true
  else
    echo "STORAGE_E2E_WORK_DIR=$WORK_DIR"
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

attach_image() {
  local backing="$1"
  local output_variable="$2"
  local tag="$3"
  local attach_log="$LOG_ROOT/attach-$tag.log"
  "$ATTACH_BIN" --writable-noautomount "$backing" >"$attach_log"
  local attached_bsd
  attached_bsd="$(/usr/bin/awk -F= '/^DI_BSD_NAME=/{print $2}' "$attach_log" | /usr/bin/tail -1)"
  [[ -n "$attached_bsd" && -b "/dev/$attached_bsd" ]]
  assert_synthetic_device "$attached_bsd" "$backing"
  # DiskImages2 can return the BSD name a few milliseconds before the raw
  # device is openable. Exact backing + DiskImages2 provenance already proves
  # this is synthetic; use a direct raw-read readiness check instead of
  # diskutil metadata queries, which can enter an uninterruptible FSKit wait.
  local ready=0
  for _ in $(/usr/bin/seq 1 100); do
    if assert_synthetic_device "$attached_bsd" "$backing" >/dev/null 2>&1 \
      && /usr/bin/head -c 512 "/dev/r$attached_bsd" >/dev/null 2>&1; then
      ready=1
      break
    fi
    /bin/sleep 0.05
  done
  [[ "$ready" -eq 1 ]] || {
    echo "synthetic device did not become diskutil-ready: $attached_bsd" >&2
    return 1
  }
  printf '%s|%s\n' "$attached_bsd" "$backing" >>"$ACTIVE_DEVICES"
  printf -v "$output_variable" '%s' "$attached_bsd"
}

eject_image() {
  local bsd="$1"
  local backing="$2"
  [[ "$bsd" =~ ^disk[0-9]+$ ]] || {
    echo "unsafe synthetic BSD name during eject: $bsd" >&2
    return 1
  }
  [[ "$backing" == "$WORK_DIR"/* || "$backing" == "$MOUNT_ROOT"/* ]] || {
    echo "synthetic eject backing escaped test root: $backing" >&2
    return 1
  }

  # Teardown is metadata-only. Never stat the bridge backing or /dev/diskN
  # while nested FSKit/LIFS generations are deactivating: either lookup can
  # enter an uninterruptible filesystem wait. Exact DiskImages2 image-path +
  # system-entity identity is authoritative before any detach/eject action.
  if ! synthetic_publication_exists "$backing"; then
    return 0
  fi
  assert_synthetic_device "$bsd" "$backing"

  # Mirror the production publisher contract: exact synthetic identity is
  # proven above, Disk Arbitration performs the eject handoff, and success is
  # not reported until the exact DiskImages2 backing publication disappears.
  # If the callback succeeds but the owner remains, recover only the exact
  # current-user diskimagesiod proven by the same hdiutil owner snapshot.
  bounded 25 "$DA_MOUNT_BIN" --eject "$bsd" >/dev/null 2>&1 || true
  if wait_for_synthetic_publication_gone "$backing" 25; then
    return 0
  fi
  if recover_synthetic_publication "$bsd" "$backing"; then
    return 0
  fi

  echo "synthetic DiskImages2 publication remained after exact DA eject/owner recovery: $bsd backing=$backing" >&2
  return 1
}

filesystem_format_completed() {
  local path="$1"
  local filesystem="$2"
  if [[ "$filesystem" == "MS-DOS FAT16" ]]; then
    /sbin/fsck_msdos -n "$path" >/dev/null 2>&1
    return
  fi
  [[ "$filesystem" == "ExFAT" ]] || return 1
  /usr/bin/python3 - "$path" <<'PY'
import pathlib
import struct
import sys

data = pathlib.Path(sys.argv[1]).read_bytes()[: 12 * 512]
if len(data) != 12 * 512 or data[3:11] != b"EXFAT   " or data[510:512] != b"\x55\xaa":
    raise SystemExit(1)
checksum = 0
for index, value in enumerate(data[: 11 * 512]):
    if index in (106, 107, 112):
        continue
    checksum = (((checksum << 31) | (checksum >> 1)) + value) & 0xFFFFFFFF
expected = struct.pack("<I", checksum)
checksum_sector = data[11 * 512 : 12 * 512]
raise SystemExit(0 if checksum_sector == expected * (512 // 4) else 1)
PY
}

format_raw_filesystem() {
  local path="$1"
  local size="$2"
  local filesystem="$3"
  local label="$4"
  local tag="$5"
  /usr/bin/truncate -s "$size" "$path"

  # A CRawDiskImage can occasionally disappear in the narrow handoff between
  # hdiutil publishing its BSD name and diskutil opening it for eraseVolume.
  # Retry the *entire* attach transaction rather than reusing a stale diskN.
  # Every transaction re-proves exact WORK_DIR backing + Virtual: Yes before
  # the destructive formatter is allowed to run.
  local format_log="$LOG_ROOT/format-$tag.log"
  local format_rc=1
  local transaction attach_output bsd ready stable_checks
  for transaction in 1 2 3; do
    if attach_output="$(bounded 15 /usr/bin/hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$path")"; then
      :
    else
      format_rc=$?
      echo "fixture hdiutil attach did not complete: tag=$tag transaction=$transaction rc=$format_rc" >&2
      /bin/sleep 2
      (( transaction < 3 )) && continue
      return "$format_rc"
    fi
    bsd="$(printf '%s\n' "$attach_output" \
      | /usr/bin/awk '/\/dev\/disk[0-9]+/ { gsub("/dev/", "", $1); print $1; exit }')"
    [[ -n "$bsd" && -b "/dev/$bsd" ]]
    assert_fixture_device "$bsd" "$path"
    printf '%s|%s\n' "$bsd" "$path" >>"$ACTIVE_FIXTURE_DEVICES"

    # Require three consecutive identity/open checks. One successful probe is
    # insufficient because DiskImages can briefly publish a device that is
    # already being torn down by the time diskutil consumes the BSD name.
    ready=0
    stable_checks=0
    for _ in $(/usr/bin/seq 1 100); do
      if assert_fixture_device "$bsd" "$path" >/dev/null 2>&1 \
        && /usr/bin/head -c 512 "/dev/r$bsd" >/dev/null 2>&1; then
        stable_checks=$((stable_checks + 1))
        if (( stable_checks >= 3 )); then
          ready=1
          break
        fi
      else
        stable_checks=0
      fi
      /bin/sleep 0.05
    done
    if (( ready != 1 )); then
      if assert_fixture_device "$bsd" "$path" >/dev/null 2>&1; then
        bounded 12 /usr/bin/hdiutil detach "/dev/$bsd" -force >/dev/null 2>&1 || true
      else
        recover_fixture_image "$bsd" "$path" >/dev/null 2>&1 || true
      fi
      if ! wait_for_fixture_publication_gone "$path" 100; then
        recover_fixture_image "$bsd" "$path" >/dev/null 2>&1 || true
        wait_for_fixture_publication_gone "$path" 100 || {
          echo "fixture publication remained after unstable-device cleanup: $path" >&2
          return 1
        }
      fi
      if (( transaction < 3 )); then
        /bin/sleep 1
        continue
      fi
      echo "fixture device did not become stably openable after $transaction transactions: $bsd" >&2
      return 1
    fi

    # DiskImages/Disk Arbitration can report a newly reused BSD name as
    # queryable slightly before eraseVolume can safely reopen it. Hold a short
    # settle window, then re-prove both exact backing identity and raw readability
    # immediately before the destructive synthetic-only formatter.
    /bin/sleep 2
    assert_fixture_device "$bsd" "$path"
    /usr/bin/head -c 512 "/dev/r$bsd" >/dev/null 2>&1
    if bounded 30 /usr/sbin/diskutil eraseVolume "$filesystem" "$label" "$bsd" \
      >"$format_log" 2>&1; then
      format_rc=0
    else
      format_rc=$?
    fi

    # diskutil can block in its final mount/reply phase even though newfs has
    # already completed. Judge the synthetic fixture by the persisted backing
    # result, not by the client process exit alone. FAT16 gets a full read-only
    # fsck; ExFAT verifies its complete main boot region checksum. Later native
    # mount/remount tests still provide the end-to-end filesystem proof.
    if filesystem_format_completed "$path" "$filesystem"; then
      if assert_fixture_device "$bsd" "$path" >/dev/null 2>&1; then
        bounded 15 /usr/sbin/diskutil unmountDisk "$bsd" >/dev/null 2>&1 || true
        if ! bounded 15 /usr/bin/hdiutil detach "/dev/$bsd" -force >/dev/null 2>&1; then
          recover_fixture_image "$bsd" "$path" >/dev/null 2>&1 || true
        fi
      else
        recover_fixture_image "$bsd" "$path" >/dev/null 2>&1 || true
      fi
      if ! wait_for_fixture_publication_gone "$path" 100; then
        recover_fixture_image "$bsd" "$path" >/dev/null 2>&1 || true
        wait_for_fixture_publication_gone "$path" 100 || {
          echo "fixture publication remained after successful format cleanup: $path" >&2
          return 1
        }
      fi
      return 0
    fi

    if (( format_rc == 124 )) \
      || ! /usr/bin/grep -Eq -- '-69879|Couldn.t open disk' "$format_log"; then
      /bin/cat "$format_log" >&2 || true
      return "$format_rc"
    fi

    # -69879 is retryable only for this proven synthetic fixture. The device
    # may already be gone; never carry its BSD name into the next attempt. A
    # successful detach call is not enough: wait until the exact CRawDiskImage
    # backing publication is gone before allowing diskN to be reused.
    if assert_fixture_device "$bsd" "$path" >/dev/null 2>&1; then
      bounded 12 /usr/bin/hdiutil detach "/dev/$bsd" -force >/dev/null 2>&1 || true
    else
      recover_fixture_image "$bsd" "$path" >/dev/null 2>&1 || true
    fi
    if ! wait_for_fixture_publication_gone "$path" 100; then
      recover_fixture_image "$bsd" "$path" >/dev/null 2>&1 || true
      wait_for_fixture_publication_gone "$path" 100 || {
        echo "fixture publication remained after retry cleanup: $path" >&2
        return 1
      }
    fi
    /bin/sleep 1
  done

  /bin/cat "$format_log" >&2 || true
  return 1
}

start_adapter() {
  local partition="$1"
  local bridge="$2"
  local tag="$3"
  local output_variable="$4"
  local adapter_log="$LOG_ROOT/adapter-$tag.log"
  mkdir -p "$bridge"
  printf '%s\n' "$bridge" >>"$ACTIVE_MOUNTS"

  local attempt adapter_pid
  for attempt in 1 2; do
    : >"$adapter_log"
    "$ADAPTER_BIN" \
      --raw-device-file "$EDP_IMAGE" \
      --vid "$VID" --pid "$PID" --device-size "$DEVICE_SIZE" \
      --partition-type "$partition" --password-file "$PASSWORD_FILE" \
      --mountpoint "$bridge" --volume-name "EDP Storage $tag" \
      >"$adapter_log" 2>&1 &
    adapter_pid=$!
    printf '%s|%s\n' "$adapter_pid" "$ADAPTER_BIN" >>"$ACTIVE_PROCESSES"

    for _ in $(/usr/bin/seq 1 200); do
      if is_mounted "$bridge" && [[ -f "$bridge/volume.raw" ]]; then
        printf -v "$output_variable" '%s' "$adapter_pid"
        return 0
      fi
      /bin/kill -0 "$adapter_pid" >/dev/null 2>&1 || break
      /bin/sleep 0.1
    done

    if /bin/kill -0 "$adapter_pid" >/dev/null 2>&1; then
      /bin/kill -TERM "$adapter_pid" >/dev/null 2>&1 || true
      for _ in $(/usr/bin/seq 1 50); do
        /bin/kill -0 "$adapter_pid" >/dev/null 2>&1 || break
        /bin/sleep 0.05
      done
      /bin/kill -0 "$adapter_pid" >/dev/null 2>&1 \
        && /bin/kill -KILL "$adapter_pid" >/dev/null 2>&1 || true
    fi
    wait "$adapter_pid" >/dev/null 2>&1 || true

    if (( attempt == 1 )) \
      && adapter_log_is_transient_fskit_failure "$adapter_log" \
      && restart_console_fskit_agent_if_safe; then
      log "STORAGE_FSKIT_HOST_RETRY=$tag attempt=2"
      continue
    fi

    /usr/bin/tail -80 "$adapter_log" >&2 || true
    echo "macFUSE Local adapter did not become ready: $tag attempt=$attempt" >&2
    return 1
  done
  return 1
}

stop_adapter() {
  local pid="$1"
  local bridge="$2"
  local tag="$3"
  if /bin/kill -0 "$pid" >/dev/null 2>&1; then
    /bin/kill -TERM "$pid"
  fi
  for _ in $(/usr/bin/seq 1 450); do
    /bin/kill -0 "$pid" >/dev/null 2>&1 || break
    /bin/sleep 0.1
  done
  if /bin/kill -0 "$pid" >/dev/null 2>&1; then
    echo "adapter ignored bounded SIGTERM teardown: $tag" >&2
    /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
    return 1
  fi
  wait "$pid" || {
    echo "adapter returned failure during teardown: $tag" >&2
    /usr/bin/tail -80 "$LOG_ROOT/adapter-$tag.log" >&2 || true
    return 1
  }
  for _ in $(/usr/bin/seq 1 100); do
    is_mounted "$bridge" || return 0
    /bin/sleep 0.1
  done
  log "M10_STALE_FSKIT_RECOVERY=$tag"
  cleanup_crashed_local_mount "$bridge"
}

mount_native() {
  local bsd="$1"
  local output_variable="$2"
  local output resolved_mountpoint
  output="$(bounded 25 "$DA_MOUNT_BIN" --mount "$bsd")"
  resolved_mountpoint="$(printf '%s\n' "$output" | /usr/bin/awk -F= '/^DA_MOUNTPOINT=/{print $2; exit}')"
  [[ -n "$resolved_mountpoint" ]]
  "$FSKIT_GUARD_BIN" --is-mounted "$resolved_mountpoint" >/dev/null
  printf '%s\n' "$resolved_mountpoint" >>"$ACTIVE_MOUNTS"
  printf -v "$output_variable" '%s' "$resolved_mountpoint"
}

mount_boot_read_only() {
  local bsd="$1"
  local mountpoint="$2"
  mkdir -p "$mountpoint"
  /usr/sbin/chown "$(/usr/bin/id -u):$(/usr/bin/id -g)" "$mountpoint"
  /bin/chmod 755 "$mountpoint"
  printf '%s\n' "$mountpoint" >>"$ACTIVE_MOUNTS"
  # Route FAT16 through the same Disk Arbitration semantics as production so
  # macOS 26 uses its staged msdos_fskit implementation. Avoid diskutil's
  # synchronous frontend: it can block in its final reply path even after DA
  # has successfully mounted an otherwise healthy nested FSKit volume.
  bounded 25 "$DA_MOUNT_BIN" --mount-readonly-at "$bsd" "$mountpoint" >/dev/null
  is_mounted "$mountpoint"
  "$FSKIT_GUARD_BIN" --assert-readonly "$mountpoint"
}

unmount_path() {
  local mountpoint="$1"
  if is_mounted "$mountpoint"; then
    local source bsd
    source="$("$FSKIT_GUARD_BIN" --mount-source "$mountpoint")"
    [[ "$source" =~ ^/dev/(disk[0-9]+)$ ]] || {
      echo "refusing DA unmount for unexpected source: $mountpoint source=$source" >&2
      return 1
    }
    bsd="${BASH_REMATCH[1]}"
    bounded 25 "$DA_MOUNT_BIN" --unmount "$bsd" >/dev/null
  fi
  ! is_mounted "$mountpoint" || return 1
  # Disk Arbitration reports the native mount gone before FSKit/UVFS has
  # necessarily finished deactivate/forgetVolume. Keep the DiskImages2 IOMedia
  # alive through that upper-filesystem quiescence window; only the caller may
  # detach the publication after this returns.
  wait_for_native_filesystem_quiescence
}

assert_no_test_artifacts() {
  local label="$1"
  if ! "$FSKIT_GUARD_BIN" --assert-no-mount-prefix "$WORK_DIR/"; then
    echo "test mount leaked after $label" >&2
    return 1
  fi
  capture_hdiutil_info "$WORK_DIR/hdiutil-artifact-check.plist" 20
  /usr/bin/python3 - "$WORK_DIR/hdiutil-artifact-check.plist" "$WORK_DIR" <<'PY'
import os, plistlib, sys
with open(sys.argv[1], "rb") as handle:
    root = plistlib.load(handle)
prefix = os.path.abspath(os.path.normpath(sys.argv[2])) + os.sep
leaks = []
for image in root.get("images", []):
    path = os.path.abspath(os.path.normpath(image.get("image-path", "")))
    if path.startswith(prefix):
        leaks.append(path)
if leaks:
    print("LEAKED_DISKIMAGES=" + ",".join(leaks), file=sys.stderr)
    raise SystemExit(1)
PY
  if /usr/bin/pgrep -f "$ADAPTER_BIN" >/dev/null 2>&1; then
    echo "adapter process leaked after $label" >&2
    return 1
  fi
}

reset_active_trackers() {
  : >"$ACTIVE_DEVICES"
  : >"$ACTIVE_FIXTURE_DEVICES"
  : >"$ACTIVE_PROCESSES"
  : >"$ACTIVE_MOUNTS"
}

storage_profile_marker="$WORK_DIR/.storage-profile"

record_storage_profile() {
  printf '%s|%s\n' "$STORAGE_PROFILE" "$LOOP_COUNT" >"$storage_profile_marker"
}

require_storage_profile() {
  [[ -f "$storage_profile_marker" ]] || {
    echo "shared storage fixture has no profile marker; run prepare first" >&2
    return 1
  }
  local expected="$STORAGE_PROFILE|$LOOP_COUNT"
  local actual
  actual="$(/bin/cat "$storage_profile_marker")"
  [[ "$actual" == "$expected" ]] || {
    echo "shared storage profile mismatch: expected=$expected actual=$actual" >&2
    return 1
  }
}

mark_storage_phase() {
  local phase="$1"
  local phase_upper
  phase_upper="$(printf '%s' "$phase" | /usr/bin/tr '[:lower:]' '[:upper:]')"
  printf '%s|%s\n' "$STORAGE_PROFILE" "$LOOP_COUNT" >"$WORK_DIR/.phase-$phase.ok"
  log "RESULT=DRIVE_STORAGE_PHASE_${phase_upper}_OK"
}

require_storage_phase() {
  local phase="$1"
  local marker="$WORK_DIR/.phase-$phase.ok"
  [[ -f "$marker" && "$(/bin/cat "$marker")" == "$STORAGE_PROFILE|$LOOP_COUNT" ]] || {
    echo "storage phase marker missing or mismatched: $phase" >&2
    return 1
  }
}

require_prepared_fixture() {
  require_storage_profile
  [[ -f "$EDP_IMAGE" ]]
  [[ "$(/usr/bin/stat -f %z "$EDP_IMAGE")" == "$DEVICE_SIZE" ]]
}

ensure_tools() {
  if [[ -x "$ATTACH_BIN" && -x "$PREPARE_BIN" && -x "$ADAPTER_BIN" && -x "$FSKIT_GUARD_BIN" && -x "$DA_MOUNT_BIN" && -x "$FAILURE_BIN" ]]; then
    return 0
  fi
  build_tools
}

build_tools() {
  log "=== Build storage E2E tools ==="
  xcrun clang -std=c17 -Wall -Wextra -Werror -fobjc-arc -fblocks \
    native/EDPFSKitPoC/Tools/DiskImages2Attach.m \
    -framework Foundation -o "$ATTACH_BIN"
  xcrun clang -std=c17 -Wall -Wextra -Werror \
    native/EDPFSKitPoC/Tools/MacFUSEMinimal/DirectMFMountUnmountHelper.c \
    -o "$FSKIT_GUARD_BIN"
  xcrun clang -std=c17 -Wall -Wextra -Werror \
    Tests/Storage/DiskArbitrationMountHelper.c \
    -framework CoreFoundation -framework DiskArbitration \
    -o "$DA_MOUNT_BIN"

  local core_sources=(
    native/EDPFSKitPoC/Extension/EDPRawIO.swift
    native/EDPFSKitPoC/Extension/EDPMetadataProbe.swift
    native/EDPFSKitPoC/Extension/EDPCrypto.swift
    native/EDPFSKitPoC/Extension/EDPVolumeMetadata.swift
    native/EDPFSKitPoC/Extension/EDPEncryptedPartitionReader.swift
    native/EDPFSKitPoC/Extension/EDPBlockDevice.swift
    native/EDPFSKitPoC/Extension/EDPFileRawDevice.swift
  )
  xcrun swiftc -O -swift-version 6 -warnings-as-errors \
    "${EDP_CORE_SWIFTC_FLAGS[@]}" \
    "${core_sources[@]}" \
    native/EDPFSKitPoC/Tools/PrepareEDPFilesystemFixture.swift \
    -o "$PREPARE_BIN"

  local source_dir="$BUILD_DIR/direct-src"
  local include_dir="$BUILD_DIR/include"
  local frameworks="${MACFUSE_FRAMEWORKS:-/Library/Filesystems/macfuse.fs/Contents/Frameworks}"
  mkdir -p "$source_dir" "$include_dir"
  [[ -d "$frameworks/MFMount.framework" ]]
  /usr/bin/curl -fsSL \
    'https://raw.githubusercontent.com/macfuse/library/9a3db24bf7e3896d69a514a70e91dc41eefb948b/include/fuse_kernel.h' \
    -o "$include_dir/fuse_kernel.h"
  /bin/cp native/EDPFSKitPoC/Tools/MacFUSEMinimal/DirectMFMountRawTransport.c \
    "$source_dir/DirectMFMountRawTransport.c"
  /bin/cp native/EDPFSKitPoC/Tools/MacFUSEMinimal/DirectMFMountEDPFixtureAdapter.c \
    "$source_dir/DirectMFMountEDPFixtureAdapter.c"
  /usr/bin/python3 - "$source_dir/DirectMFMountRawTransport.c" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
needle = '"nobrowse,volname=%s"'
if needle not in text:
    raise SystemExit("Direct MFMount option template is missing")
path.write_text(text.replace(needle, '"local,nobrowse,volname=%s"', 1))
PY
  xcrun clang -std=c17 -Wall -Wextra -Werror \
    -I"$include_dir" -I"$source_dir" -F"$frameworks" -DMFMount=EDPAsyncMFMount \
    -c "$source_dir/DirectMFMountEDPFixtureAdapter.c" -o "$BUILD_DIR/fixture-adapter.o"
  xcrun clang -std=c17 -Wall -Wextra -Werror \
    -I"$include_dir" -F"$frameworks" \
    -c native/EDPFSKitPoC/Tools/MacFUSEMinimal/DirectMFMountAsyncShim.c \
    -o "$BUILD_DIR/async-shim.o"
  xcrun swiftc -parse-as-library -O -swift-version 6 -warnings-as-errors \
    "${EDP_CORE_SWIFTC_FLAGS[@]}" \
    "${core_sources[@]}" \
    native/EDPFSKitPoC/Tools/EDPReadWriteBlockCBridge.swift \
    "$BUILD_DIR/fixture-adapter.o" "$BUILD_DIR/async-shim.o" \
    -F"$frameworks" -Xlinker -rpath -Xlinker "$frameworks" \
    -framework MFMount -framework CoreFoundation -framework DiskArbitration \
    -o "$ADAPTER_BIN"

  xcrun swiftc -O -swift-version 6 -warnings-as-errors \
    -D EDP_REGRESSION_TESTS \
    "${EDP_CORE_SWIFTC_FLAGS[@]}" \
    "${core_sources[@]}" \
    native/EDPFSKitPoC/Tools/EDPReadWriteBlockCBridge.swift \
    Tests/VirtualUSB/EDPFaultPlan.swift \
    Tests/VirtualUSB/EDPVirtualRawDevice.swift \
    Tests/Storage/ValidateStorageFailureContracts.swift \
    -o "$FAILURE_BIN"
  log "RESULT=DRIVE_STORAGE_TOOLS_BUILT_C17_SWIFT6_STRICT"
}

prepare_fixture() {
  log "=== Prepare sparse whole-device EDP fixture ==="
  format_raw_filesystem "$BOOT_RAW" "$BOOT_SIZE" 'MS-DOS FAT16' EDPBOOT boot
  format_raw_filesystem "$EXCHANGE_RAW" "$RW_FS_SIZE" ExFAT EDPXCHG exchange
  format_raw_filesystem "$SECURE_RAW" "$RW_FS_SIZE" ExFAT EDPSECURE secure

  /usr/bin/python3 Tests/Storage/PrepareBootFilesystemFixture.py \
    --fixture-dir "$FIXTURE_DIR" --boot-volume "$BOOT_RAW" \
    --device-size "$DEVICE_SIZE" --output "$EDP_IMAGE"
  for partition in 2 4; do
    local plaintext="$EXCHANGE_RAW"
    [[ "$partition" == 4 ]] && plaintext="$SECURE_RAW"
    "$PREPARE_BIN" \
      --lba4 "$FIXTURE_DIR/LBA4.bin" --lba7 "$FIXTURE_DIR/LBA7.bin" \
      --lba11 "$FIXTURE_DIR/LBA11.bin" --lba12 "$FIXTURE_DIR/LBA12.bin" \
      --vid "$VID" --pid "$PID" --device-size "$DEVICE_SIZE" \
      --partition-type "$partition" --plaintext "$plaintext" \
      --output "$EDP_IMAGE" --password-file "$PASSWORD_FILE" --merge-existing 1
  done
  [[ "$(/usr/bin/stat -f %z "$EDP_IMAGE")" == "$DEVICE_SIZE" ]]
  log "RESULT=DRIVE_STORAGE_COMBINED_SPARSE_FIXTURE_READY"
}

run_m01() {
  log "=== M01 boot FAT16 double read-only ==="
  local bridge="$MOUNT_ROOT/m01-bridge"
  local native_mount="$MOUNT_ROOT/m01-fat16"
  local pid="" bsd=""
  start_adapter 1 "$bridge" m01 pid
  attach_image "$bridge/volume.raw" bsd m01
  mount_boot_read_only "$bsd" "$native_mount"
  /usr/bin/python3 - "$native_mount" <<'PY'
import errno, os, pathlib, sys
target = pathlib.Path(sys.argv[1]) / "must-not-write.txt"
try:
    target.write_bytes(b"forbidden")
except OSError as error:
    if error.errno not in (errno.EROFS, errno.EACCES, errno.EPERM):
        raise
else:
    raise SystemExit("M01 filesystem write unexpectedly succeeded")
PY
  /usr/bin/python3 - "$bridge/volume.raw" <<'PY'
import errno, os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
try:
    try:
        os.pwrite(fd, b"EDP-M01-WRITE-MUST-FAIL", 4096)
    except OSError as error:
        if error.errno != errno.EROFS:
            raise
    else:
        raise SystemExit("M01 transport block write unexpectedly succeeded")
finally:
    os.close(fd)
PY
  unmount_path "$native_mount"
  eject_image "$bsd" "$bridge/volume.raw"
  stop_adapter "$pid" "$bridge" m01
  /usr/bin/grep -Fq 'readonly=1' "$LOG_ROOT/adapter-m01.log"
  /usr/bin/grep -Eq 'DIRECT_IO_SUMMARY writes=[1-9][0-9]*' "$LOG_ROOT/adapter-m01.log"
  assert_no_test_artifacts M01
  log "SCENARIO=M01_OK boot_fat16_native_readonly_transport_erofs"
}

run_exchange_core() {
  log "=== M02 and M04-M09 exchange filesystem operations ==="
  local bridge="$MOUNT_ROOT/m02-stage1-bridge"
  local pid="" bsd="" mountpoint="" output="" expected_hash=""
  start_adapter 2 "$bridge" m02-stage1 pid
  attach_image "$bridge/volume.raw" bsd m02-stage1
  mount_native "$bsd" mountpoint
  "$FSKIT_GUARD_BIN" --assert-writable "$mountpoint"
  output="$(/usr/bin/python3 Tests/Storage/ExerciseNativeFilesystem.py core "$mountpoint")"
  printf '%s\n' "$output"
  expected_hash="$(printf '%s\n' "$output" | /usr/bin/awk -F= '/^M02_SHA256=/{print $2}')"
  [[ -n "$expected_hash" ]]
  unmount_path "$mountpoint"
  eject_image "$bsd" "$bridge/volume.raw"
  stop_adapter "$pid" "$bridge" m02-stage1
  wait_for_remount_quiescence

  bridge="$MOUNT_ROOT/m02-remount-bridge"
  start_adapter 2 "$bridge" m02-remount pid
  attach_image "$bridge/volume.raw" bsd m02-remount
  mount_native "$bsd" mountpoint
  /usr/bin/python3 Tests/Storage/ExerciseNativeFilesystem.py \
    verify-remount "$mountpoint" "$expected_hash"
  unmount_path "$mountpoint"
  eject_image "$bsd" "$bridge/volume.raw"
  stop_adapter "$pid" "$bridge" m02-remount
  assert_no_test_artifacts M02-M09
}

run_secure_core() {
  log "=== M03 secure filesystem persistence ==="
  local bridge="$MOUNT_ROOT/m03-stage1-bridge"
  local pid="" bsd="" mountpoint="" output="" expected_hash=""
  start_adapter 4 "$bridge" m03-stage1 pid
  attach_image "$bridge/volume.raw" bsd m03-stage1
  mount_native "$bsd" mountpoint
  output="$(/usr/bin/python3 Tests/Storage/ExerciseNativeFilesystem.py secure "$mountpoint")"
  printf '%s\n' "$output"
  expected_hash="$(printf '%s\n' "$output" | /usr/bin/awk -F= '/^M03_SHA256=/{print $2}')"
  [[ -n "$expected_hash" ]]
  unmount_path "$mountpoint"
  eject_image "$bsd" "$bridge/volume.raw"
  stop_adapter "$pid" "$bridge" m03-stage1
  wait_for_remount_quiescence

  bridge="$MOUNT_ROOT/m03-remount-bridge"
  start_adapter 4 "$bridge" m03-remount pid
  attach_image "$bridge/volume.raw" bsd m03-remount
  mount_native "$bsd" mountpoint
  /usr/bin/python3 Tests/Storage/ExerciseNativeFilesystem.py \
    verify-secure-remount "$mountpoint" "$expected_hash"
  unmount_path "$mountpoint"
  eject_image "$bsd" "$bridge/volume.raw"
  stop_adapter "$pid" "$bridge" m03-remount
  assert_no_test_artifacts M03
}

run_m10() {
  log "=== M10 $LOOP_COUNT complete mount/attach/filesystem/teardown cycles ==="
  local baseline_fds
  baseline_fds="$(/usr/sbin/lsof -p $$ 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  local max_fds="$baseline_fds"
  for iteration in $(/usr/bin/seq 1 "$LOOP_COUNT"); do
    local bridge="$MOUNT_ROOT/m10-$iteration-bridge"
    local pid="" bsd="" mountpoint=""
    start_adapter 2 "$bridge" "m10-$iteration" pid
    attach_image "$bridge/volume.raw" bsd "m10-$iteration"
    mount_native "$bsd" mountpoint
    [[ -f "$mountpoint/m02-exchange-proof.bin" ]]
    unmount_path "$mountpoint"
    eject_image "$bsd" "$bridge/volume.raw"
    stop_adapter "$pid" "$bridge" "m10-$iteration"
    assert_no_test_artifacts "M10-$iteration"
    if (( iteration < LOOP_COUNT )); then
      wait_for_remount_quiescence
    fi
    local current_fds
    current_fds="$(/usr/sbin/lsof -p $$ 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    (( current_fds > max_fds )) && max_fds="$current_fds"
    if (( iteration % 10 == 0 || iteration == LOOP_COUNT )); then
      log "M10_PROGRESS=$iteration/$LOOP_COUNT"
    fi
  done
  if (( max_fds > baseline_fds + 8 )); then
    echo "M10 obvious runner fd growth: baseline=$baseline_fds max=$max_fds" >&2
    return 1
  fi
  log "M10_FD_BASELINE=$baseline_fds"
  log "M10_FD_MAX=$max_fds"
  log "SCENARIO=M10_OK loops=$LOOP_COUNT no_mount_device_process_or_fd_leak"
}

run_m12() {
  log "=== M12 transport crash and bounded recovery ==="
  local bridge="$MOUNT_ROOT/m12-crash-bridge"
  local pid="" bsd="" mountpoint=""
  start_adapter 2 "$bridge" m12-crash pid
  attach_image "$bridge/volume.raw" bsd m12-crash
  mount_native "$bsd" mountpoint
  /bin/kill -KILL "$pid"
  wait "$pid" >/dev/null 2>&1 || true
  cleanup_crashed_local_mount "$bridge"
  eject_image "$bsd" "$bridge/volume.raw"
  assert_no_test_artifacts M12-crash
  wait_for_remount_quiescence

  bridge="$MOUNT_ROOT/m12-recovery-bridge"
  start_adapter 2 "$bridge" m12-recovery pid
  attach_image "$bridge/volume.raw" bsd m12-recovery
  mount_native "$bsd" mountpoint
  [[ -f "$mountpoint/m02-exchange-proof.bin" ]]
  unmount_path "$mountpoint"
  eject_image "$bsd" "$bridge/volume.raw"
  stop_adapter "$pid" "$bridge" m12-recovery
  assert_no_test_artifacts M12-recovery
  log "SCENARIO=M12_OK transport_crash_bounded_cleanup_and_remount"
}

run_m14() {
  log "=== M14 concurrent type 1/2/4 sessions ==="
  local boot_bridge="$MOUNT_ROOT/m14-boot-bridge"
  local exchange_bridge="$MOUNT_ROOT/m14-exchange-bridge"
  local secure_bridge="$MOUNT_ROOT/m14-secure-bridge"
  local boot_pid="" exchange_pid="" secure_pid=""
  local boot_bsd="" exchange_bsd="" secure_bsd=""
  local boot_mount="$MOUNT_ROOT/m14-boot-fat16"
  local exchange_mount="" secure_mount=""

  start_adapter 1 "$boot_bridge" m14-boot boot_pid
  start_adapter 2 "$exchange_bridge" m14-exchange exchange_pid
  start_adapter 4 "$secure_bridge" m14-secure secure_pid
  attach_image "$boot_bridge/volume.raw" boot_bsd m14-boot
  attach_image "$exchange_bridge/volume.raw" exchange_bsd m14-exchange
  attach_image "$secure_bridge/volume.raw" secure_bsd m14-secure
  [[ "$boot_bsd" != "$exchange_bsd" && "$boot_bsd" != "$secure_bsd" && "$exchange_bsd" != "$secure_bsd" ]]
  mount_boot_read_only "$boot_bsd" "$boot_mount"
  mount_native "$exchange_bsd" exchange_mount
  mount_native "$secure_bsd" secure_mount

  /usr/bin/python3 - "$exchange_mount" "$secure_mount" <<'PY'
import os, pathlib, sys
exchange = pathlib.Path(sys.argv[1])
secure = pathlib.Path(sys.argv[2])
exchange_marker = exchange / "m14-exchange-only.txt"
secure_marker = secure / "m14-secure-only.txt"
exchange_marker.write_text("exchange-session", encoding="utf-8")
secure_marker.write_text("secure-session", encoding="utf-8")
for path in (exchange_marker, secure_marker):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
if (exchange / secure_marker.name).exists() or (secure / exchange_marker.name).exists():
    raise SystemExit("M14 partition state crossed between sessions")
PY

  unmount_path "$exchange_mount"
  eject_image "$exchange_bsd" "$exchange_bridge/volume.raw"
  stop_adapter "$exchange_pid" "$exchange_bridge" m14-exchange
  is_mounted "$boot_mount"
  [[ -f "$secure_mount/m14-secure-only.txt" ]]

  unmount_path "$boot_mount"
  eject_image "$boot_bsd" "$boot_bridge/volume.raw"
  stop_adapter "$boot_pid" "$boot_bridge" m14-boot
  [[ -f "$secure_mount/m14-secure-only.txt" ]]
  unmount_path "$secure_mount"
  eject_image "$secure_bsd" "$secure_bridge/volume.raw"
  stop_adapter "$secure_pid" "$secure_bridge" m14-secure
  assert_no_test_artifacts M14
  log "SCENARIO=M14_OK concurrent_partition_sessions_independent"
}

validate_failure_and_build_contracts() {
  "$FAILURE_BIN" 2>&1
  local production_bin="$BUILD_DIR/production"
  installer/build-transport-backends.sh "$production_bin"

  local core_sources=(
    native/EDPFSKitPoC/Extension/EDPRawIO.swift
    native/EDPFSKitPoC/Extension/EDPMetadataProbe.swift
    native/EDPFSKitPoC/Extension/EDPCrypto.swift
    native/EDPFSKitPoC/Extension/EDPVolumeMetadata.swift
    native/EDPFSKitPoC/Extension/EDPEncryptedPartitionReader.swift
    native/EDPFSKitPoC/Extension/EDPBlockDevice.swift
    native/EDPFSKitPoC/Extension/EDPFileRawDevice.swift
  )
  local product_sources=(
    product/EDPCredentialStore.swift
    product/EDPDevicePolicyStore.swift
    product/EDPMacFUSERuntimePolicy.swift
    product/EDPLifecycleScheduler.swift
    product/EDPLifecycleJournal.swift
    product/EDPTransportProvider.swift
    product/EDPTransportRuntimePolicy.swift
    product/EDPFinderVolumeDefaults.swift
    product/EDPNativeSystem.swift
    product/EDPBlockDevicePublisher.swift
    product/EDPXPCProtocol.swift
    product/EDPXPCSecurity.swift
    product/EDPRuntimeSupport.swift
    product/EDPRuntimeState.swift
    product/EDPDeviceOperations.swift
    product/EDPRawAccess.swift
    product/EDPRawAccessCoordinator.swift
    product/EDPAutomationState.swift
    product/EDPEjectCoordinator.swift
    product/EDPMountLifecycle.swift
    product/EDPMountSupport.swift
    product/EDPVaultRuntime.swift
  )
  local raw_validation_obj="$production_bin/EDPRawValidation.o"
  local raw_broker_obj="$production_bin/EDPRawFDBroker.o"
  /usr/bin/cc -O2 -Wall -Wextra -Iproduct -c product/EDPRawValidation.c -o "$raw_validation_obj"
  /usr/bin/cc -O2 -Wall -Wextra -Iproduct -c product/EDPRawFDBroker.c -o "$raw_broker_obj"
  xcrun swiftc -O -swift-version 6 -warnings-as-errors \
    -Xfrontend -disable-availability-checking \
    -framework CryptoKit -framework Security -framework DiskArbitration -framework IOKit -framework CoreFoundation \
    "${EDP_CORE_SWIFTC_FLAGS[@]}" \
    "${core_sources[@]}" "${product_sources[@]}" \
    "$raw_validation_obj" "$raw_broker_obj" \
    -o "$production_bin/edp-drive-service"
  log "RESULT=DRIVE_STORAGE_PRODUCTION_SWIFT6_C17_STRICT_OK"
}

for prohibited_pattern in \
  'diskutil[[:space:]]+erase''Disk' \
  'd''d.*of=/dev/' \
  '--raw-device[[:space:]]+/''dev/'; do
  if /usr/bin/grep -REn -- "$prohibited_pattern" Tests/Storage Tests/run-storage.sh >/dev/null; then
    echo "storage test contains a prohibited physical-device write pattern" >&2
    exit 1
  fi
done

if (( PRESERVE_WORK_DIR == 1 )); then
  if [[ -s "$ACTIVE_DEVICES" || -s "$ACTIVE_FIXTURE_DEVICES" || -s "$ACTIVE_PROCESSES" || -s "$ACTIVE_MOUNTS" ]]; then
    assert_no_test_artifacts "phase-start-$STORAGE_PHASE"
  fi
  reset_active_trackers
fi

case "$STORAGE_PHASE" in
  all)
    build_tools
    prepare_fixture
    run_m01
    run_exchange_core
    run_secure_core
    run_m10
    run_m12
    run_m14
    validate_failure_and_build_contracts
    assert_no_test_artifacts final
    log "RESULT=DRIVE_STORAGE_E2E_OK"
    ;;
  prepare)
    build_tools
    prepare_fixture
    record_storage_profile
    assert_no_test_artifacts prepare
    mark_storage_phase prepare
    ;;
  core)
    require_prepared_fixture
    ensure_tools
    run_m01
    run_exchange_core
    run_secure_core
    assert_no_test_artifacts core
    mark_storage_phase core
    ;;
  stress)
    require_prepared_fixture
    ensure_tools
    run_m10
    assert_no_test_artifacts stress
    mark_storage_phase stress
    ;;
  recovery)
    require_prepared_fixture
    ensure_tools
    run_m12
    run_m14
    assert_no_test_artifacts recovery
    mark_storage_phase recovery
    ;;
  contracts)
    require_storage_profile
    ensure_tools
    validate_failure_and_build_contracts
    assert_no_test_artifacts contracts
    mark_storage_phase contracts
    ;;
  final)
    require_storage_profile
    for phase in prepare core stress recovery contracts; do
      require_storage_phase "$phase"
    done
    assert_no_test_artifacts final
    log "RESULT=DRIVE_STORAGE_E2E_OK"
    ;;
esac
