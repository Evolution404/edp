#!/bin/bash
set -u
set -o pipefail

BASE="${TMPDIR:-/tmp}/edp-macfuse-orphan-cleanup"
REPORT="$BASE/report.txt"
HDI_BEFORE="$BASE/hdi-before.txt"
HDI_AFTER="$BASE/hdi-after.txt"
mkdir -p "$BASE"
: > "$REPORT"

log(){ printf '%s\n' "$*" | tee -a "$REPORT"; }
section(){ log ""; log "=== $* ==="; }

whole_disks(){
  /bin/ls /dev/disk* 2>/dev/null | /usr/bin/grep -E '^/dev/disk[0-9]+$' | /usr/bin/sed 's#^/dev/##' | /usr/bin/sort -V
}

is_safe_temp_path(){
  case "$1" in
    /var/folders/zz/*/T/*.dmg) return 0 ;;
    *) return 1 ;;
  esac
}

get_diskinfo(){
  /usr/sbin/diskutil info "$1" 2>/dev/null || true
}

is_candidate_disk(){
  local dev="$1"
  local info="$2"
  local path="$3"

  is_safe_temp_path "$path" || return 1
  printf '%s\n' "$info" | /usr/bin/grep -Eq '^   Whole:[[:space:]]+Yes$' || return 1
  printf '%s\n' "$info" | /usr/bin/grep -Eq '^   Protocol:[[:space:]]+Disk Image$' || return 1
  printf '%s\n' "$info" | /usr/bin/grep -Eq '^   Virtual:[[:space:]]+Yes$' || return 1
  printf '%s\n' "$info" | /usr/bin/grep -Eq '^   Disk Size:.*\(4096 Bytes\)' || return 1
  printf '%s\n' "$info" | /usr/bin/grep -Eq '^   File System:[[:space:]]+None$' || return 1
  printf '%s\n' "$info" | /usr/bin/grep -Eq '^   Mounted:[[:space:]]+(Not applicable \(no file system\)|No)$' || return 1
  [[ -b "$dev" ]] || return 1
  return 0
}

section "Safety precheck"
log "This script only detaches whole 4096-byte virtual Disk Image devices with no filesystem whose backing image is under /var/folders/zz/*/T/*.dmg."
log "It does not touch physical disks, mounted filesystems, macFUSE registration, SIP, or security settings."

/usr/bin/hdiutil info > "$HDI_BEFORE" 2>&1 || true
section "Whole disks before cleanup"
whole_disks | tee -a "$REPORT"

section "Current disk-image mappings"
/usr/bin/awk '
  /^image-path[[:space:]]*:/ { path=$0; sub(/^[^:]*:[[:space:]]*/, "", path) }
  /^\/dev\/disk[0-9]+([[:space:]]|$)/ { print path "\t" $1 }
' "$HDI_BEFORE" | tee -a "$REPORT"

CANDIDATES=0
DETACHED=0
FORCED=0
FAILED=0
SKIPPED=0

while IFS=$'\t' read -r path dev; do
  [[ -n "${path:-}" && -n "${dev:-}" ]] || continue
  case "$dev" in
    /dev/disk[0-9]*) ;;
    *) continue ;;
  esac

  info="$(get_diskinfo "$dev")"
  if ! is_candidate_disk "$dev" "$info" "$path"; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  CANDIDATES=$((CANDIDATES + 1))
  log "candidate=$dev image_path=$path"
  printf '%s\n' "$info" | /usr/bin/grep -E 'Device Identifier|Whole:|File System:|Mounted:|Protocol:|Disk Size:|Virtual:' | tee -a "$REPORT" || true

done < <(/usr/bin/awk '
  /^image-path[[:space:]]*:/ { path=$0; sub(/^[^:]*:[[:space:]]*/, "", path) }
  /^\/dev\/disk[0-9]+([[:space:]]|$)/ { print path "\t" $1 }
' "$HDI_BEFORE")

if [[ "$CANDIDATES" -eq 0 ]]; then
  section "SUMMARY"
  log "candidates=0 detached=0 forced=0 failed=0 skipped=$SKIPPED"
  log "RESULT=NO_ORPHAN_MACFUSE_DISKIMAGES_FOUND"
  log "REPORT=$REPORT"
  exit 0
fi

section "Detach verified orphan devices"
sudo -v

while IFS=$'\t' read -r path dev; do
  [[ -n "${path:-}" && -n "${dev:-}" ]] || continue
  info="$(get_diskinfo "$dev")"
  is_candidate_disk "$dev" "$info" "$path" || continue

  log "detaching=$dev"
  if sudo /usr/bin/hdiutil detach "$dev" >> "$REPORT" 2>&1; then
    DETACHED=$((DETACHED + 1))
  else
    log "normal_detach_failed=$dev retry=force"
    if sudo /usr/bin/hdiutil detach -force "$dev" >> "$REPORT" 2>&1; then
      DETACHED=$((DETACHED + 1))
      FORCED=$((FORCED + 1))
    else
      FAILED=$((FAILED + 1))
      log "detach_failed=$dev"
    fi
  fi

done < <(/usr/bin/awk '
  /^image-path[[:space:]]*:/ { path=$0; sub(/^[^:]*:[[:space:]]*/, "", path) }
  /^\/dev\/disk[0-9]+([[:space:]]|$)/ { print path "\t" $1 }
' "$HDI_BEFORE")

sleep 1
/usr/bin/hdiutil info > "$HDI_AFTER" 2>&1 || true

REMAINING=0
section "Verified orphan devices remaining"
while IFS=$'\t' read -r path dev; do
  [[ -n "${path:-}" && -n "${dev:-}" ]] || continue
  info="$(get_diskinfo "$dev")"
  if is_candidate_disk "$dev" "$info" "$path"; then
    REMAINING=$((REMAINING + 1))
    log "remaining=$dev image_path=$path"
  fi
done < <(/usr/bin/awk '
  /^image-path[[:space:]]*:/ { path=$0; sub(/^[^:]*:[[:space:]]*/, "", path) }
  /^\/dev\/disk[0-9]+([[:space:]]|$)/ { print path "\t" $1 }
' "$HDI_AFTER")

section "Whole disks after cleanup"
whole_disks | tee -a "$REPORT"

section "SUMMARY"
log "candidates=$CANDIDATES detached=$DETACHED forced=$FORCED failed=$FAILED remaining=$REMAINING skipped=$SKIPPED"
if [[ "$FAILED" -eq 0 && "$REMAINING" -eq 0 ]]; then
  log "RESULT=ORPHAN_MACFUSE_DISKIMAGES_CLEANED"
  log "Interpretation: stale 4096-byte temporary Disk Image devices from failed macFUSE local mounts were detached. Re-run one known-good FSKit baseline from this clean device state before changing EDP or macFUSE configuration."
else
  log "RESULT=ORPHAN_MACFUSE_DISKIMAGE_CLEANUP_INCOMPLETE"
  log "Interpretation: one or more strictly matched temporary virtual disks could not be detached. Do not run more FSKit mount tests until the remaining devices are understood."
fi
log "REPORT=$REPORT"
