#!/bin/bash
set -uo pipefail

WORK="${TMPDIR:-/tmp}/edp-fskit-matrix"
BIN="$WORK/minfs"
SRC="$WORK/minfs.c"
REPORT="$WORK/report.txt"
UID_NOW="$(id -u)"
GID_NOW="$(id -g)"
mkdir -p "$WORK"
: > "$REPORT"

log(){ printf '%s\n' "$*" | tee -a "$REPORT"; }
section(){ log ""; log "=== $* ==="; }
cleanup_mount(){
  local mp="$1"
  /sbin/umount "$mp" >/dev/null 2>&1 || sudo /sbin/umount "$mp" >/dev/null 2>&1 || true
  sudo /bin/rm -rf "$mp" >/dev/null 2>&1 || true
}

section "System"
/usr/bin/sw_vers | tee -a "$REPORT"
log "uid=$UID_NOW gid=$GID_NOW user=$(id -un)"
log "fuse_pkg=$(pkg-config --modversion fuse 2>/dev/null || echo missing)"
/bin/ls -l /usr/local/lib/libfuse.2.dylib 2>&1 | tee -a "$REPORT" || true
/usr/bin/otool -L /usr/local/lib/libfuse.2.dylib 2>&1 | /usr/bin/head -n 8 | tee -a "$REPORT" || true

section "FSKit registration"
/usr/bin/pluginkit -m -A -D -v -i io.macfuse.app.fsmodule.macfuse-local 2>&1 | tee -a "$REPORT" || true
/usr/bin/pluginkit -m -A -D -v -i io.macfuse.app.fsmodule.macfuse 2>&1 | tee -a "$REPORT" || true

cat > "$SRC" <<'EOF'
#define FUSE_USE_VERSION 26
#include <fuse.h>
#include <errno.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>
static const char msg[]="EDP FSKit matrix OK\n";
static int ga(const char*p,struct stat*s){memset(s,0,sizeof(*s));s->st_uid=getuid();s->st_gid=getgid();s->st_atime=s->st_mtime=s->st_ctime=1;if(!strcmp(p,"/")){s->st_ino=1;s->st_mode=S_IFDIR|0755;s->st_nlink=2;return 0;}if(!strcmp(p,"/hello.txt")){s->st_ino=2;s->st_mode=S_IFREG|0644;s->st_nlink=1;s->st_size=sizeof(msg)-1;s->st_blocks=(s->st_size+511)/512;return 0;}return -ENOENT;}
static int rd(const char*p,void*b,fuse_fill_dir_t f,off_t o,struct fuse_file_info*i){(void)o;(void)i;if(strcmp(p,"/"))return -ENOENT;f(b,".",0,0);f(b,"..",0,0);f(b,"hello.txt",0,0);return 0;}
static int op(const char*p,struct fuse_file_info*i){if(strcmp(p,"/hello.txt"))return -ENOENT;i->fh=1;return 0;}
static int re(const char*p,char*b,size_t z,off_t o,struct fuse_file_info*i){(void)i;if(strcmp(p,"/hello.txt"))return -ENOENT;size_t n=sizeof(msg)-1;if(o<0)return -EINVAL;if((size_t)o>=n)return 0;if((size_t)o+z>n)z=n-(size_t)o;memcpy(b,msg+o,z);return (int)z;}
static int sf(const char*p,struct statvfs*s){(void)p;memset(s,0,sizeof(*s));s->f_bsize=s->f_frsize=4096;s->f_blocks=1024;s->f_bfree=s->f_bavail=1024;s->f_files=2;s->f_ffree=100;s->f_namemax=255;return 0;}
static struct fuse_operations ops={.getattr=ga,.readdir=rd,.open=op,.read=re,.statfs=sf};
int main(int c,char**v){return fuse_main(c,v,&ops,0);}
EOF

section "Build"
if ! /usr/bin/cc "$SRC" -D_FILE_OFFSET_BITS=64 $(pkg-config --cflags fuse) $(pkg-config --libs fuse) -o "$BIN" 2>&1 | tee -a "$REPORT"; then
  log "RESULT=BUILD_FAIL"
  exit 2
fi
/usr/bin/otool -L "$BIN" | tee -a "$REPORT"
sudo -v

run_case(){
  local name="$1" opts="$2" idx="$3"
  local mp="/Volumes/edp-fskit-matrix-$idx"
  local slog="$WORK/$idx-server.log"
  cleanup_mount "$mp"
  sudo /bin/mkdir "$mp"
  sudo /usr/sbin/chown "$UID_NOW:$GID_NOW" "$mp"
  /bin/chmod 700 "$mp"
  : > "$slog"
  section "CASE $name"
  log "options=$opts"
  log "mountpoint=$mp"
  "$BIN" -d -o "$opts" "$mp" >"$slog" 2>&1 &
  local pid=$!
  local ok=0
  for _ in $(seq 1 50); do
    if /bin/cat "$mp/hello.txt" >"$WORK/$idx-read.txt" 2>/dev/null; then ok=1; break; fi
    sleep 0.2
  done
  local alive=0 rc="running"
  if kill -0 "$pid" >/dev/null 2>&1; then alive=1; else wait "$pid" >/dev/null 2>&1; rc=$?; fi
  log "pid=$pid alive=$alive rc=$rc readable=$ok"
  /sbin/mount | /usr/bin/grep -F " on $mp " | tee -a "$REPORT" || log "mount_table=none"
  if [[ -f "$WORK/$idx-read.txt" ]]; then log "read=$(cat "$WORK/$idx-read.txt")"; fi
  log "-- server log --"
  /usr/bin/tail -n 60 "$slog" | tee -a "$REPORT"
  log "-- relevant system log --"
  /usr/bin/log show --debug --info --last 45s --predicate 'subsystem IN {"com.apple.FSKit","com.apple.LiveFS","io.macfuse"}' 2>/dev/null \
    | /usr/bin/grep -E 'macfuse|MFMount|MountError|invalidated|activateVolume|File system extension|fskit_agent|fskitd' \
    | /usr/bin/tail -n 100 | tee -a "$REPORT" || true
  if [[ "$alive" -eq 1 ]]; then kill "$pid" >/dev/null 2>&1 || true; sleep 0.2; fi
  cleanup_mount "$mp"
  echo "$ok"
}

A=$(run_case "plain" "backend=fskit" 1 | tee /dev/stderr | tail -n 1)
B=$(run_case "uid-gid" "backend=fskit,uid=$UID_NOW,gid=$GID_NOW" 2 | tee /dev/stderr | tail -n 1)
C=$(run_case "explicit-local" "backend=fskit,local,uid=$UID_NOW,gid=$GID_NOW" 3 | tee /dev/stderr | tail -n 1)

section "SUMMARY"
log "plain=$A uid_gid=$B explicit_local=$C"
if [[ "$A" == 1 || "$B" == 1 || "$C" == 1 ]]; then
  log "RESULT=PASS_SOME_FSKit_MODE"
  log "Interpretation: macFUSE/FSKit can mount on this Mac. Compare the successful option set with EDP bridge."
  exit 0
fi

if /usr/bin/grep -q 'io.macfuse.app.fsmodule.macfuse-local' "$REPORT" && /usr/bin/grep -q 'activateVolume' "$REPORT" && /usr/bin/grep -q 'invalidated' "$REPORT"; then
  log "RESULT=FSKIT_CHANNEL_INVALIDATED"
  log "Interpretation: the macFUSE FSKit extension is registered and reaches activateVolume, but the FSKit/FUSE channel is invalidated even for a standalone minimal server. This is independent of EDP raw-disk permissions."
elif ! /usr/bin/grep -q 'io.macfuse.app.fsmodule.macfuse-local' "$REPORT"; then
  log "RESULT=LOCAL_EXTENSION_NOT_REGISTERED"
  log "Interpretation: macfuse-local is not visible to PluginKit for this user."
else
  log "RESULT=FSKIT_STANDALONE_FAIL_OTHER"
  log "Interpretation: standalone FSKit fails; inspect the three server logs and system-log excerpts above."
fi
log "REPORT=$REPORT"
exit 1
