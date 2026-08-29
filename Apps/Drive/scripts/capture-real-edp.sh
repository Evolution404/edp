#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="${REPO_ROOT}/native/EDPFSKitPoC/Tools/build-capture-tool.sh"
CAPTURE_BIN="${REPO_ROOT}/artifacts/native/CaptureEDPDataFixture"
CAPTURE_ROOT="${REPO_ROOT}/.edp-captures"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/capture-real-edp.sh
  ./scripts/capture-real-edp.sh diskN

The script only reads the selected physical USB disk. It does not format,
mount, unmount, or write the disk. The EDP password is requested locally by
the capture binary without echo and is never written to the capture output.
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

for tool in diskutil ioreg plutil python3 xcrun; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "missing required tool: ${tool}" >&2
    exit 2
  }
done

[[ -x "${BUILD_SCRIPT}" || -f "${BUILD_SCRIPT}" ]] || {
  echo "capture build script not found: ${BUILD_SCRIPT}" >&2
  exit 2
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/edp-capture-discovery.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT INT TERM

LIST_PLIST="${TMP_DIR}/diskutil-list.plist"
USB_PLIST="${TMP_DIR}/ioreg-usb.plist"

diskutil list -plist >"${LIST_PLIST}"
ioreg -p IOUSB -l -w0 -a >"${USB_PLIST}"

SELECTED_DISK="$(python3 - "${LIST_PLIST}" "${1:-}" <<'PY'
import plistlib
import re
import subprocess
import sys

list_path, requested = sys.argv[1:]
with open(list_path, "rb") as handle:
    root = plistlib.load(handle)

candidates = []
for disk in root.get("AllDisksAndPartitions", []):
    ident = disk.get("DeviceIdentifier")
    if not isinstance(ident, str) or not re.fullmatch(r"disk\d+", ident):
        continue
    try:
        info = plistlib.loads(subprocess.check_output(["diskutil", "info", "-plist", f"/dev/{ident}"]))
    except subprocess.CalledProcessError:
        continue
    if info.get("Whole") is not True and info.get("WholeDisk") is not True:
        continue
    if info.get("Internal") is True:
        continue
    if info.get("VirtualOrPhysical") == "Virtual":
        continue
    size = info.get("DiskSize", info.get("TotalSize", info.get("Size", 0)))
    if size <= 0:
        continue
    candidates.append((ident, info))

if requested:
    requested = requested.removeprefix("/dev/").removeprefix("r")
    matches = [item for item in candidates if item[0] == requested]
    if len(matches) != 1:
        print(f"requested disk is not a unique external physical whole disk: {requested}", file=sys.stderr)
        sys.exit(3)
    print(matches[0][0])
    sys.exit(0)

if len(candidates) == 0:
    print("no external physical whole disk found", file=sys.stderr)
    sys.exit(4)
if len(candidates) > 1:
    print("multiple external disks found; rerun with one disk identifier:", file=sys.stderr)
    for ident, info in candidates:
        size = info.get("DiskSize", info.get("TotalSize", info.get("Size", 0)))
        print(f"  {ident}: {info.get('MediaName', 'unknown')}  {size} bytes  protocol={info.get('BusProtocol', 'unknown')}", file=sys.stderr)
    sys.exit(5)
print(candidates[0][0])
PY
)"

INFO_PLIST="${TMP_DIR}/disk-info.plist"
diskutil info -plist "/dev/${SELECTED_DISK}" >"${INFO_PLIST}"

IFS=$'\t' read -r DEVICE_SIZE MEDIA_NAME BUS_PROTOCOL < <(python3 - "${INFO_PLIST}" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "rb") as handle:
    info = plistlib.load(handle)
print(
    int(info.get("DiskSize", info.get("TotalSize", info.get("Size", 0)))),
    str(info.get("MediaName", "unknown")),
    str(info.get("BusProtocol", "unknown")),
    sep="\t",
)
PY
)

VID_PID="$(python3 - "${USB_PLIST}" "${INFO_PLIST}" "${SELECTED_DISK}" <<'PY'
import plistlib
import re
import sys

path, info_path, target = sys.argv[1:]
with open(path, "rb") as handle:
    tree = plistlib.load(handle)
with open(info_path, "rb") as handle:
    disk_info = plistlib.load(handle)

device_tree_path = str(disk_info.get("DeviceTreePath", ""))
location_match = re.search(r"@([0-9a-fA-F]+)$", device_tree_path)
target_location = location_match.group(1).lower() if location_match else None

if isinstance(tree, dict):
    roots = [tree]
elif isinstance(tree, list):
    roots = tree
else:
    roots = []

def children(node):
    value = node.get("IORegistryEntryChildren", []) if isinstance(node, dict) else []
    return value if isinstance(value, list) else []

def descendant_has_disk(node):
    if not isinstance(node, dict):
        return False
    values = [node.get("BSD Name"), node.get("BSDName"), node.get("IOBSDName")]
    if target in values:
        return True
    return any(descendant_has_disk(child) for child in children(node))

def normalize(value):
    if isinstance(value, int):
        return value
    if isinstance(value, bytes):
        return int.from_bytes(value, "little")
    if isinstance(value, str):
        match = re.search(r"(?:0x)?([0-9a-fA-F]{1,4})", value)
        if match:
            return int(match.group(1), 16)
    return None

def walk(node, inherited_vid=None, inherited_pid=None):
    if not isinstance(node, dict):
        return None
    vid = normalize(node.get("idVendor"))
    pid = normalize(node.get("idProduct"))
    if vid is None:
        vid = inherited_vid
    if pid is None:
        pid = inherited_pid

    if vid is not None and pid is not None and descendant_has_disk(node):
        return vid, pid
    for child in children(node):
        result = walk(child, vid, pid)
        if result:
            return result
    return None

for root in roots:
    result = walk(root)
    if result:
        print(f"{result[0]:04x} {result[1]:04x}")
        sys.exit(0)

# On macOS 15 the IOUSB plane does not necessarily contain the IOMedia/BSD
# descendants. diskutil still provides a DeviceTreePath whose final USB
# location component matches IORegistryEntryLocation on the USB device.
def find_by_location(node):
    if not isinstance(node, dict):
        return None
    location = str(node.get("IORegistryEntryLocation", "")).lower()
    vid = normalize(node.get("idVendor"))
    pid = normalize(node.get("idProduct"))
    if target_location and location == target_location and vid is not None and pid is not None:
        return vid, pid
    for child in children(node):
        result = find_by_location(child)
        if result:
            return result
    return None

for root in roots:
    result = find_by_location(root)
    if result:
        print(f"{result[0]:04x} {result[1]:04x}")
        sys.exit(0)

print(f"unable to resolve USB VID/PID for {target} from IORegistry", file=sys.stderr)
sys.exit(6)
PY
)"
read -r VID PID <<<"${VID_PID}"

RAW_DEVICE="/dev/r${SELECTED_DISK}"
[[ -e "${RAW_DEVICE}" ]] || {
  echo "raw device not found: ${RAW_DEVICE}" >&2
  exit 7
}

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_DIR="${CAPTURE_ROOT}/${TIMESTAMP}-${SELECTED_DISK}"
mkdir -p "${OUTPUT_DIR}"

printf 'EDP_CAPTURE_DISK=%s\n' "${SELECTED_DISK}"
printf 'EDP_CAPTURE_RAW_DEVICE=%s\n' "${RAW_DEVICE}"
printf 'EDP_CAPTURE_MEDIA_NAME=%s\n' "${MEDIA_NAME}"
printf 'EDP_CAPTURE_BUS_PROTOCOL=%s\n' "${BUS_PROTOCOL}"
printf 'EDP_CAPTURE_DEVICE_SIZE=%s\n' "${DEVICE_SIZE}"
printf 'EDP_CAPTURE_USB_VID=%s\n' "${VID}"
printf 'EDP_CAPTURE_USB_PID=%s\n' "${PID}"
printf 'EDP_CAPTURE_OUTPUT=%s\n' "${OUTPUT_DIR}"
echo 'EDP_CAPTURE_MODE=READ_ONLY'

echo
echo "Building capture tool..."
bash "${BUILD_SCRIPT}" "${CAPTURE_BIN}"

echo
echo "Starting read-only capture. sudo is required only to open ${RAW_DEVICE}."
echo "The password prompt below is local and does not echo input."

sudo "${CAPTURE_BIN}" \
  "${RAW_DEVICE}" \
  "${VID}" \
  "${PID}" \
  "${DEVICE_SIZE}" \
  "${OUTPUT_DIR}" \
  2 \
  1048576

echo
printf 'RESULT=EDP_ONE_COMMAND_REAL_CAPTURE_OK\n'
printf 'CAPTURE_DIRECTORY=%s\n' "${OUTPUT_DIR}"
