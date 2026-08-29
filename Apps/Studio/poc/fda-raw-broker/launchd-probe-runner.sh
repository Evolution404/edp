#!/bin/sh
set -eu

PROBE=/Library/PrivilegedHelperTools/com.evolution404.edpopen.rawbroker.poc

# Enumerate external physical whole disks. Do not accept a path from the caller.
disks=$(/usr/sbin/diskutil list external physical | /usr/bin/awk '/^\/dev\/disk[0-9]+ \(external, physical\):$/ { gsub("/dev/disk", "", $1); print $1 }')
count=$(printf '%s\n' "$disks" | /usr/bin/awk 'NF { n++ } END { print n+0 }')

if [ "$count" -ne 1 ]; then
  echo "AUTO_PROBE=REFUSED external_physical_count=$count" >&2
  exit 20
fi

disk=$(printf '%s\n' "$disks" | /usr/bin/awk 'NF { print; exit }')
case "$disk" in
  ''|*[!0-9]*) echo "AUTO_PROBE=REFUSED invalid_disk=$disk" >&2; exit 21 ;;
esac

exec "$PROBE" probe "$disk"
