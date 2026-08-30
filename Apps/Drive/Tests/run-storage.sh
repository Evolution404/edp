#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DRIVE_ROOT="$ROOT/Apps/Drive"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$DRIVE_ROOT"
REPO_ROOT="$PWD"
. scripts/prepare-shared-edp-core.sh

LOOP_COUNT="${EDP_STORAGE_LOOP_COUNT:-50}"
case "$LOOP_COUNT" in
  ''|*[!0-9]*) echo "EDP_STORAGE_LOOP_COUNT must be an integer" >&2; exit 64 ;;
esac
if (( LOOP_COUNT < 50 || LOOP_COUNT > 100 )); then
  echo "EDP_STORAGE_LOOP_COUNT must remain within the accepted 50-100 range" >&2
  exit 64
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/edp-storage-e2e.XXXXXX")"
WORK_DIR="$(cd "$WORK_DIR" && pwd -P)"
BUILD_DIR="$WORK_DIR/build"
MOUNT_ROOT="$WORK_DIR/mounts"
LOG_ROOT="$WORK_DIR/logs"
ACTIVE_DEVICES="$WORK_DIR/active-devices.txt"
ACTIVE_PROCESSES="$WORK_DIR/active-processes.txt"
ACTIVE_MOUNTS="$WORK_DIR/active-mounts.txt"
mkdir -p "$BUILD_DIR" "$MOUNT_ROOT" "$LOG_ROOT"
: >"$ACTIVE_DEVICES"
: >"$ACTIVE_PROCESSES"
: >"$ACTIVE_MOUNTS"

ATTACH_BIN="$BUILD_DIR/diskimages2-attach"
PREPARE_BIN="$BUILD_DIR/prepare-edp-filesystem-fixture"
ADAPTER_BIN="$BUILD_DIR/edp-mfmount-fixture"
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

is_mounted() {
  /sbin/mount | /usr/bin/awk -v target="$1" '$3 == target { found=1 } END { exit found ? 0 : 1 }'
}

cleanup_crashed_local_mount() {
  local target="$1"
  local source
  source="$(/sbin/mount | /usr/bin/awk -v target="$target" '$3 == target && $0 ~ /\(macfuse, local,/ { print $1 }')"
  [[ "$source" =~ ^/dev/disk[0-9]+$ ]] || {
    echo "refusing crash cleanup for unknown mount source: $target source=$source" >&2
    return 1
  }
  local outside_count
  outside_count="$(/sbin/mount | /usr/bin/awk -v root="$WORK_DIR/" \
    '$0 ~ /\(macfuse, local,/ && index($3, root) != 1 { count++ } END { print count + 0 }')"
  if (( outside_count != 0 )); then
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
  /usr/bin/hdiutil info -plist >"$info"
  /usr/bin/python3 - "$info" "$bsd" "$backing" <<'PY'
import os
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    root = plistlib.load(handle)
expected_device = "/dev/" + sys.argv[2]
expected_path = os.path.realpath(sys.argv[3])
for image in root.get("images", []):
    devices = [item.get("dev-entry") for item in image.get("system-entities", [])]
    if expected_device not in devices:
        continue
    actual_path = os.path.realpath(image.get("image-path", ""))
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

bounded() {
  local seconds="$1"
  shift
  /usr/bin/python3 "$BOUNDED" --timeout "$seconds" "$@"
}

cleanup() {
  local status=$?
  set +e
  if [[ -f "$ACTIVE_DEVICES" ]]; then
    while IFS='|' read -r bsd backing; do
      [[ -n "$bsd" && -e "/dev/$bsd" ]] || continue
      if assert_synthetic_device "$bsd" "$backing" >/dev/null 2>&1; then
        bounded 12 /usr/sbin/diskutil unmountDisk "$bsd" >/dev/null 2>&1 || true
        bounded 12 /usr/sbin/diskutil eject "$bsd" >/dev/null 2>&1 || true
      fi
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
        if /sbin/mount | /usr/bin/awk -v target="$mountpoint" \
          '$3 == target && $0 ~ /\(macfuse, local,/ { found=1 } END { exit found ? 0 : 1 }'; then
          cleanup_crashed_local_mount "$mountpoint" >/dev/null 2>&1 || true
        else
          bounded 8 /sbin/umount -f "$mountpoint" >/dev/null 2>&1 || true
        fi
      fi
    done <"$ACTIVE_MOUNTS"
  fi
  if (( status != 0 )); then
    echo "STORAGE_E2E_ARTIFACTS=$WORK_DIR" >&2
  else
    /usr/bin/find "$WORK_DIR" -depth -delete >/dev/null 2>&1 || true
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
  printf '%s|%s\n' "$attached_bsd" "$backing" >>"$ACTIVE_DEVICES"
  printf -v "$output_variable" '%s' "$attached_bsd"
}

eject_image() {
  local bsd="$1"
  local backing="$2"
  [[ -e "/dev/$bsd" ]] || return 0
  assert_synthetic_device "$bsd" "$backing"
  bounded 15 /usr/sbin/diskutil unmountDisk "$bsd" >/dev/null 2>&1 || true
  bounded 15 /usr/sbin/diskutil eject "$bsd" >/dev/null
  for _ in $(/usr/bin/seq 1 100); do
    [[ ! -e "/dev/$bsd" ]] && return 0
    /bin/sleep 0.05
  done
  echo "synthetic device remained after eject: $bsd" >&2
  return 1
}

format_raw_filesystem() {
  local path="$1"
  local size="$2"
  local filesystem="$3"
  local label="$4"
  local tag="$5"
  /usr/bin/truncate -s "$size" "$path"
  local bsd=""
  attach_image "$path" bsd "format-$tag"
  # The immediately preceding identity proof is the mandatory guard for this
  # destructive operation. The target is a test-created DiskImages2 device
  # backed by a regular file below WORK_DIR, never a physical disk.
  assert_synthetic_device "$bsd" "$path"
  bounded 30 /usr/sbin/diskutil eraseVolume "$filesystem" "$label" "$bsd" \
    >"$LOG_ROOT/format-$tag.log"
  /usr/sbin/diskutil info "$bsd" | /usr/bin/grep -Fq "File System Personality"
  eject_image "$bsd" "$path"
}

start_adapter() {
  local partition="$1"
  local bridge="$2"
  local tag="$3"
  local output_variable="$4"
  mkdir -p "$bridge"
  printf '%s\n' "$bridge" >>"$ACTIVE_MOUNTS"
  "$ADAPTER_BIN" \
    --raw-device-file "$EDP_IMAGE" \
    --vid "$VID" --pid "$PID" --device-size "$DEVICE_SIZE" \
    --partition-type "$partition" --password-file "$PASSWORD_FILE" \
    --mountpoint "$bridge" --volume-name "EDP Storage $tag" \
    >"$LOG_ROOT/adapter-$tag.log" 2>&1 &
  local adapter_pid=$!
  printf '%s|%s\n' "$adapter_pid" "$ADAPTER_BIN" >>"$ACTIVE_PROCESSES"
  for _ in $(/usr/bin/seq 1 200); do
    if is_mounted "$bridge" && [[ -f "$bridge/volume.raw" ]]; then
      printf -v "$output_variable" '%s' "$adapter_pid"
      return 0
    fi
    /bin/kill -0 "$adapter_pid" >/dev/null 2>&1 || break
    /bin/sleep 0.1
  done
  /usr/bin/tail -80 "$LOG_ROOT/adapter-$tag.log" >&2 || true
  echo "macFUSE Local adapter did not become ready: $tag" >&2
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
  bounded 20 /usr/sbin/diskutil mount "$bsd" >/dev/null
  local info="$WORK_DIR/disk-info-$bsd.plist"
  local resolved_mountpoint=""
  for _ in $(/usr/bin/seq 1 100); do
    /usr/sbin/diskutil info -plist "$bsd" >"$info"
    resolved_mountpoint="$(/usr/bin/python3 - "$info" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as handle:
    print(plistlib.load(handle).get("MountPoint") or "")
PY
)"
    [[ -n "$resolved_mountpoint" && -d "$resolved_mountpoint" ]] && break
    /bin/sleep 0.1
  done
  [[ -n "$resolved_mountpoint" && -d "$resolved_mountpoint" ]]
  printf '%s\n' "$resolved_mountpoint" >>"$ACTIVE_MOUNTS"
  printf -v "$output_variable" '%s' "$resolved_mountpoint"
}

mount_boot_read_only() {
  local bsd="$1"
  local mountpoint="$2"
  mkdir -p "$mountpoint"
  printf '%s\n' "$mountpoint" >>"$ACTIVE_MOUNTS"
  bounded 20 /sbin/mount_msdos \
    -o rdonly -u "$(/usr/bin/id -u)" -g "$(/usr/bin/id -g)" -m 755 \
    "/dev/$bsd" "$mountpoint"
  is_mounted "$mountpoint"
  /usr/sbin/diskutil info "$bsd" | /usr/bin/grep -Eq 'Volume Read-Only:[[:space:]]+Yes'
}

unmount_path() {
  local mountpoint="$1"
  if is_mounted "$mountpoint"; then
    bounded 15 /sbin/umount "$mountpoint"
  fi
  ! is_mounted "$mountpoint"
}

assert_no_test_artifacts() {
  local label="$1"
  if /sbin/mount | /usr/bin/grep -F "$WORK_DIR" >/dev/null; then
    echo "test mount leaked after $label" >&2
    /sbin/mount | /usr/bin/grep -F "$WORK_DIR" >&2 || true
    return 1
  fi
  /usr/bin/hdiutil info -plist >"$WORK_DIR/hdiutil-artifact-check.plist"
  /usr/bin/python3 - "$WORK_DIR/hdiutil-artifact-check.plist" "$WORK_DIR" <<'PY'
import os, plistlib, sys
with open(sys.argv[1], "rb") as handle:
    root = plistlib.load(handle)
prefix = os.path.realpath(sys.argv[2]) + os.sep
leaks = []
for image in root.get("images", []):
    path = os.path.realpath(image.get("image-path", ""))
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

build_tools() {
  log "=== Build storage E2E tools ==="
  xcrun clang -std=c17 -Wall -Wextra -Werror -fobjc-arc -fblocks \
    native/EDPFSKitPoC/Tools/DiskImages2Attach.m \
    -framework Foundation -o "$ATTACH_BIN"

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
  /usr/sbin/diskutil info "$bsd" | /usr/bin/grep -Eq 'Volume Read-Only:[[:space:]]+No'
  output="$(/usr/bin/python3 Tests/Storage/ExerciseNativeFilesystem.py core "$mountpoint")"
  printf '%s\n' "$output"
  expected_hash="$(printf '%s\n' "$output" | /usr/bin/awk -F= '/^M02_SHA256=/{print $2}')"
  [[ -n "$expected_hash" ]]
  eject_image "$bsd" "$bridge/volume.raw"
  stop_adapter "$pid" "$bridge" m02-stage1

  bridge="$MOUNT_ROOT/m02-remount-bridge"
  start_adapter 2 "$bridge" m02-remount pid
  attach_image "$bridge/volume.raw" bsd m02-remount
  mount_native "$bsd" mountpoint
  /usr/bin/python3 Tests/Storage/ExerciseNativeFilesystem.py \
    verify-remount "$mountpoint" "$expected_hash"
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
  eject_image "$bsd" "$bridge/volume.raw"
  stop_adapter "$pid" "$bridge" m03-stage1

  bridge="$MOUNT_ROOT/m03-remount-bridge"
  start_adapter 4 "$bridge" m03-remount pid
  attach_image "$bridge/volume.raw" bsd m03-remount
  mount_native "$bsd" mountpoint
  /usr/bin/python3 Tests/Storage/ExerciseNativeFilesystem.py \
    verify-secure-remount "$mountpoint" "$expected_hash"
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
    eject_image "$bsd" "$bridge/volume.raw"
    stop_adapter "$pid" "$bridge" "m10-$iteration"
    assert_no_test_artifacts "M10-$iteration"
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

  bridge="$MOUNT_ROOT/m12-recovery-bridge"
  start_adapter 2 "$bridge" m12-recovery pid
  attach_image "$bridge/volume.raw" bsd m12-recovery
  mount_native "$bsd" mountpoint
  [[ -f "$mountpoint/m02-exchange-proof.bin" ]]
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

  eject_image "$exchange_bsd" "$exchange_bridge/volume.raw"
  stop_adapter "$exchange_pid" "$exchange_bridge" m14-exchange
  is_mounted "$boot_mount"
  [[ -f "$secure_mount/m14-secure-only.txt" ]]

  unmount_path "$boot_mount"
  eject_image "$boot_bsd" "$boot_bridge/volume.raw"
  stop_adapter "$boot_pid" "$boot_bridge" m14-boot
  [[ -f "$secure_mount/m14-secure-only.txt" ]]
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
    product/EDPTransportProvider.swift
    product/EDPTransportRuntimePolicy.swift
    product/EDPFinderVolumeDefaults.swift
    product/EDPNativeSystem.swift
    product/EDPBlockDevicePublisher.swift
    product/EDPXPCProtocol.swift
    product/EDPXPCSecurity.swift
    product/EDPVaultRuntime.swift
  )
  xcrun swiftc -O -swift-version 6 -warnings-as-errors \
    -Xfrontend -disable-availability-checking \
    -framework CryptoKit -framework Security -framework DiskArbitration -framework IOKit \
    "${EDP_CORE_SWIFTC_FLAGS[@]}" \
    "${core_sources[@]}" "${product_sources[@]}" \
    -o "$production_bin/edp-drive-service"
  log "RESULT=DRIVE_STORAGE_PRODUCTION_SWIFT6_C17_STRICT_OK"
}

for prohibited_pattern in \
  'diskutil[[:space:]]+erase''Disk' \
  'd''d.*of=/dev/' \
  '--raw-device[[:space:]]+/''dev/'; do
  if rg -n -- "$prohibited_pattern" Tests/Storage Tests/run-storage.sh >/dev/null; then
    echo "storage test contains a prohibited physical-device write pattern" >&2
    exit 1
  fi
done

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
