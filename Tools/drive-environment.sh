#!/bin/bash
set -euo pipefail

MODE="${1:-status}"
ROOT_MODE="${2:-}"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
CONSOLE_UID="$(/usr/bin/stat -f '%u' /dev/console 2>/dev/null || true)"
CONSOLE_USER="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true)"
FSKIT_SETTINGS="${HOME}/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist"
MACFUSE_APP="/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app"
MACFUSE_LOCAL_ID="io.macfuse.app.fsmodule.macfuse-local"
MACFUSE_GENERIC_ID="io.macfuse.app.fsmodule.macfuse"

say() { printf '%s\n' "$*"; }

is_edp_mount_present() {
    /sbin/mount | /usr/bin/grep -Eq ' on /Volumes/\.edp-block-| on /Volumes/(交换区|保密区|EDP Boot|启动区)( | \()'
}

is_any_fskit_mount_present() {
    /sbin/mount | /usr/bin/grep -Fq ' fskit'
}

edp_test_images() {
    /usr/bin/hdiutil info -plist 2>/dev/null \
        | /usr/bin/plutil -convert json -o - - 2>/dev/null \
        | /usr/bin/grep -oE '"image-path":"[^"]*(edp-storage-e2e\.|edp-fskit-sdk-probe\.|edp-drive-|edp-usb-vault)[^"]*"' \
        | /usr/bin/cut -d'"' -f4 || true
}

show_status() {
    say '--- EDP Drive environment status ---'

    local dirty=0
    local path
    for path in \
        '/Applications/EDP Drive.app' \
        '/Applications/EDP USB Vault.app' \
        '/Library/Application Support/EDP Drive' \
        '/Library/Application Support/EDP USB Vault' \
        '/Library/LaunchDaemons/com.edp.drive.service.plist' \
        '/Library/LaunchDaemons/com.edp.usbvault.mountd.plist' \
        '/Library/LaunchDaemons/com.edp.usbvault.mountd.v2.plist' \
        '/Library/Filesystems/macfuse.fs' \
        '/Library/Frameworks/macFUSE.framework' \
        '/Library/PreferencePanes/macFUSE.prefPane' \
        '/Library/LaunchDaemons/io.macfuse.app.launchservice.daemon.plist' \
        '/Library/PrivilegedHelperTools/io.macfuse.app.launchservice.daemon'; do
        if [[ -e "$path" ]]; then
            say "PRESENT=$path"
            dirty=1
        fi
    done

    local processes='' name pids
    for name in \
        'EDP Drive' \
        'edp-drive-service' \
        'edp-mfmount-local-readonly' \
        'edp-mfmount-local-readwrite' \
        'edp-mfmount-fixt' \
        'edp-console-exec' \
        'edp-raw-metadata' \
        'diskimages2-attach'; do
        pids="$(/usr/bin/pgrep -x "$name" 2>/dev/null || true)"
        if [[ -n "$pids" ]]; then
            while IFS= read -r pid; do
                [[ "$pid" =~ ^[0-9]+$ ]] || continue
                processes+="$(/bin/ps -p "$pid" -o pid=,uid=,stat=,command= 2>/dev/null || true)"$'\n'
            done <<<"$pids"
        fi
    done
    if [[ -n "${processes//$'\n'/}" ]]; then
        say 'EDP_PROCESSES_BEGIN'
        printf '%s' "$processes"
        say 'EDP_PROCESSES_END'
        dirty=1
    fi

    local mounts
    mounts="$(/sbin/mount | /usr/bin/grep -E ' on /Volumes/\.edp-block-|macfuse' || true)"
    if [[ -n "$mounts" ]]; then
        say 'EDP_MOUNTS_BEGIN'
        printf '%s\n' "$mounts"
        say 'EDP_MOUNTS_END'
        dirty=1
    fi

    if /usr/bin/pluginkit -m -A -D 2>/dev/null | /usr/bin/grep -Fq 'io.macfuse.app.fsmodule'; then
        say 'MACFUSE_PLUGINKIT_REGISTERED=1'
        dirty=1
    else
        say 'MACFUSE_PLUGINKIT_REGISTERED=0'
    fi

    if [[ -f "$FSKIT_SETTINGS" ]] && /usr/bin/plutil -p "$FSKIT_SETTINGS" 2>/dev/null | /usr/bin/grep -Fq 'io.macfuse.app.fsmodule'; then
        say 'MACFUSE_FSKIT_ENABLED=1'
        dirty=1
    else
        say 'MACFUSE_FSKIT_ENABLED=0'
    fi

    local test_images
    test_images="$(edp_test_images)"
    if [[ -n "$test_images" ]]; then
        say 'EDP_TEST_IMAGES_BEGIN'
        printf '%s\n' "$test_images"
        say 'EDP_TEST_IMAGES_END'
        dirty=1
    fi

    local receipts
    receipts="$(/usr/sbin/pkgutil --pkgs 2>/dev/null | /usr/bin/grep -E '^(com\.edp\.drive\.|io\.macfuse\.installer\.)' || true)"
    if [[ -n "$receipts" ]]; then
        say 'INSTALL_RECEIPTS_BEGIN'
        printf '%s\n' "$receipts"
        say 'INSTALL_RECEIPTS_END'
        dirty=1
    fi

    if [[ "$dirty" -eq 0 ]]; then
        say 'RESULT=DRIVE_ENVIRONMENT_CLEAN'
    else
        say 'RESULT=DRIVE_ENVIRONMENT_DIRTY'
    fi
}

cleanup_edp_test_images() {
    local info index image_path device
    info="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/edp-drive-user-hdi.XXXXXX")"
    /usr/bin/hdiutil info -plist >"$info" 2>/dev/null || { /bin/rm -f "$info"; return 0; }
    index=0
    while /usr/bin/plutil -type "images.$index" "$info" >/dev/null 2>&1; do
        image_path="$(/usr/bin/plutil -extract "images.$index.image-path" raw -o - "$info" 2>/dev/null || true)"
        device="$(/usr/bin/plutil -extract "images.$index.system-entities.0.dev-entry" raw -o - "$info" 2>/dev/null || true)"
        if [[ "$image_path" == *'/edp-storage-e2e.'* \
            || "$image_path" == *'/edp-fskit-sdk-probe.'* \
            || "$image_path" == *'/edp-drive-'* \
            || "$image_path" == *'/edp-usb-vault'* ]]; then
            if [[ "$device" =~ ^/dev/disk[0-9]+$ ]]; then
                say "CLEANING_EDP_TEST_IMAGE=$device"
                /usr/bin/hdiutil detach "$device" -force >/dev/null 2>&1 || true
            fi
        fi
        index=$((index + 1))
    done
    /bin/rm -f "$info"
}

remove_macfuse_from_user_settings() {
    /usr/bin/pluginkit -e ignore -i "$MACFUSE_LOCAL_ID" >/dev/null 2>&1 || true
    /usr/bin/pluginkit -e ignore -i "$MACFUSE_GENERIC_ID" >/dev/null 2>&1 || true
    if [[ -d "$MACFUSE_APP/Contents/Extensions/$MACFUSE_LOCAL_ID.appex" ]]; then
        /usr/bin/pluginkit -r "$MACFUSE_APP/Contents/Extensions/$MACFUSE_LOCAL_ID.appex" >/dev/null 2>&1 || true
    fi
    if [[ -d "$MACFUSE_APP/Contents/Extensions/$MACFUSE_GENERIC_ID.appex" ]]; then
        /usr/bin/pluginkit -r "$MACFUSE_APP/Contents/Extensions/$MACFUSE_GENERIC_ID.appex" >/dev/null 2>&1 || true
    fi

    local lsregister='/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister'
    if [[ -x "$lsregister" && -d "$MACFUSE_APP" ]]; then
        "$lsregister" -u "$MACFUSE_APP" >/dev/null 2>&1 || true
    fi

    if [[ -f "$FSKIT_SETTINGS" ]]; then
        local index value count
        count="$(/usr/bin/plutil -extract 0 raw -o - "$FSKIT_SETTINGS" >/dev/null 2>&1; /usr/bin/plutil -p "$FSKIT_SETTINGS" 2>/dev/null | /usr/bin/grep -c '=>' || true)"
        if [[ "$count" =~ ^[0-9]+$ ]]; then
            index=$((count - 1))
            while [[ "$index" -ge 0 ]]; do
                value="$(/usr/bin/plutil -extract "$index" raw -o - "$FSKIT_SETTINGS" 2>/dev/null || true)"
                if [[ "$value" == "$MACFUSE_LOCAL_ID" || "$value" == "$MACFUSE_GENERIC_ID" ]]; then
                    /usr/libexec/PlistBuddy -c "Delete :$index" "$FSKIT_SETTINGS" >/dev/null 2>&1 || true
                fi
                index=$((index - 1))
            done
        fi
    fi

    /usr/bin/tccutil reset SystemPolicyAllFiles com.edp.drive >/dev/null 2>&1 || true
    /usr/bin/tccutil reset SystemPolicyRemovableVolumes com.edp.drive >/dev/null 2>&1 || true
}

restart_console_fskit_agent_if_safe() {
    is_any_fskit_mount_present && return 0
    [[ "$CONSOLE_UID" =~ ^[0-9]+$ && "$CONSOLE_UID" -gt 0 ]] || return 0
    local agent
    agent="$(/bin/ps -axo pid=,uid=,command= | /usr/bin/awk -v uid="$CONSOLE_UID" '$2 == uid && $3 == "/usr/libexec/fskit_agent" { print $1; exit }')"
    if [[ "$agent" =~ ^[0-9]+$ ]]; then
        /bin/kill -KILL "$agent" >/dev/null 2>&1 || true
        /bin/sleep 2
    fi
}

validate_no_external_edp_mounts() {
    if is_edp_mount_present; then
        say 'ERROR=EDP filesystem is still mounted; refusing destructive environment cleanup.' >&2
        /sbin/mount | /usr/bin/grep -E ' on /Volumes/\.edp-block-| on /Volumes/(交换区|保密区|EDP Boot|启动区)( | \()' >&2 || true
        exit 1
    fi
}

is_uuid_dmg_path() {
    local path="$1"
    local base
    [[ "$path" == /var/folders/zz/*/T/*.dmg || "$path" == /private/var/folders/zz/*/T/*.dmg ]] || return 1
    base="${path##*/}"
    base="${base%.dmg}"
    [[ "$base" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

validate_diskimages_helper_pid() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || return 1
    local uid command
    uid="$(/bin/ps -p "$pid" -o uid= 2>/dev/null | /usr/bin/xargs || true)"
    command="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
    [[ "$uid" == '0' && "$command" == /System/Library/PrivateFrameworks/DiskImages.framework/Resources/diskimages-helper* ]]
}

cleanup_macfuse_scratch_images() {
    local info
    info="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/edp-drive-clean-hdi.XXXXXX")"
    /usr/bin/hdiutil info -plist >"$info" 2>/dev/null || { /bin/rm -f "$info"; return 0; }

    local index=0 image_path owner_uid diskimages2 autodiskmount writable removable
    local blockcount blocksize pid entity0 entity1 device
    while /usr/bin/plutil -type "images.$index" "$info" >/dev/null 2>&1; do
        image_path="$(/usr/bin/plutil -extract "images.$index.image-path" raw -o - "$info" 2>/dev/null || true)"
        owner_uid="$(/usr/bin/plutil -extract "images.$index.owner-uid" raw -o - "$info" 2>/dev/null || true)"
        diskimages2="$(/usr/bin/plutil -extract "images.$index.diskimages2" raw -o - "$info" 2>/dev/null || true)"
        autodiskmount="$(/usr/bin/plutil -extract "images.$index.autodiskmount" raw -o - "$info" 2>/dev/null || true)"
        writable="$(/usr/bin/plutil -extract "images.$index.writeable" raw -o - "$info" 2>/dev/null || true)"
        removable="$(/usr/bin/plutil -extract "images.$index.removable" raw -o - "$info" 2>/dev/null || true)"
        blockcount="$(/usr/bin/plutil -extract "images.$index.blockcount" raw -o - "$info" 2>/dev/null || true)"
        blocksize="$(/usr/bin/plutil -extract "images.$index.blocksize" raw -o - "$info" 2>/dev/null || true)"
        pid="$(/usr/bin/plutil -extract "images.$index.hdid-pid" raw -o - "$info" 2>/dev/null || true)"
        entity0="$(/usr/bin/plutil -type "images.$index.system-entities.0" "$info" >/dev/null 2>&1; echo $?)"
        entity1="$(/usr/bin/plutil -type "images.$index.system-entities.1" "$info" >/dev/null 2>&1; echo $?)"
        device="$(/usr/bin/plutil -extract "images.$index.system-entities.0.dev-entry" raw -o - "$info" 2>/dev/null || true)"

        if [[ "$owner_uid" == '0' \
            && "$diskimages2" == 'false' \
            && "$autodiskmount" == 'false' \
            && "$writable" == 'true' \
            && "$removable" == 'true' \
            && "$blockcount" == '8' \
            && "$blocksize" == '512' \
            && "$entity0" == '0' \
            && "$entity1" != '0' \
            && "$device" =~ ^/dev/disk[0-9]+$ ]] \
            && is_uuid_dmg_path "$image_path" \
            && validate_diskimages_helper_pid "$pid"; then
            say "CLEANING_MACFUSE_SCRATCH=$device"
            /usr/bin/hdiutil detach "$device" -force >/dev/null 2>&1 || true
            if [[ -e "$device" ]] && validate_diskimages_helper_pid "$pid"; then
                /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
                /bin/sleep 1
            fi
            if [[ -e "$device" ]] && validate_diskimages_helper_pid "$pid"; then
                /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
                /bin/sleep 1
            fi
        fi
        index=$((index + 1))
    done
    /bin/rm -f "$info"
}

root_cleanup() {
    [[ "$(/usr/bin/id -u)" -eq 0 ]] || { say 'ERROR=root cleanup requires administrator privileges' >&2; exit 1; }
    validate_no_external_edp_mounts

    /bin/launchctl bootout system/com.edp.drive.service >/dev/null 2>&1 || true
    /bin/launchctl bootout system/com.edp.usbvault.mountd >/dev/null 2>&1 || true
    /bin/launchctl bootout system/com.edp.usbvault.mountd.v2 >/dev/null 2>&1 || true

    /usr/bin/pkill -f '/Applications/EDP Drive.app/Contents/Library/LaunchServices/edp-drive-service' >/dev/null 2>&1 || true
    /usr/bin/pkill -x edp-drive-service >/dev/null 2>&1 || true
    /usr/bin/pkill -f 'edp-mfmount-local-readonly' >/dev/null 2>&1 || true
    /usr/bin/pkill -f 'edp-mfmount-local-readwrite' >/dev/null 2>&1 || true
    /usr/bin/pkill -f 'edp-mfmount-fixt' >/dev/null 2>&1 || true
    /usr/bin/pkill -x edp-console-exec >/dev/null 2>&1 || true
    /usr/bin/pkill -x edp-raw-metadata >/dev/null 2>&1 || true
    /usr/bin/pkill -x diskimages2-attach >/dev/null 2>&1 || true

    cleanup_macfuse_scratch_images

    local service
    for service in com.edp.drive.partition-password.v1 com.edp.drive.default-probe-password.v1; do
        while /usr/bin/security delete-generic-password -s "$service" /Library/Keychains/System.keychain >/dev/null 2>&1; do :; done
    done

    local uninstaller='/Library/Filesystems/macfuse.fs/Contents/Resources/uninstall_macfuse.app/Contents/Resources/Scripts/uninstall_macfuse.sh'
    if [[ -x "$uninstaller" ]]; then
        /bin/bash "$uninstaller" >/tmp/edp-drive-macfuse-uninstall.log 2>&1 || true
    fi

    /bin/launchctl bootout system/io.macfuse.app.launchservice.daemon >/dev/null 2>&1 || true
    /usr/bin/pkill -f '/Library/PrivilegedHelperTools/io.macfuse.app.launchservice.daemon' >/dev/null 2>&1 || true

    /bin/rm -rf \
        '/Applications/EDP Drive.app' \
        '/Applications/EDP USB Vault.app' \
        '/Library/Application Support/EDP Drive' \
        '/Library/Application Support/EDP USB Vault' \
        '/Library/Filesystems/macfuse.fs' \
        '/Library/Frameworks/macFUSE.framework' \
        '/Library/PreferencePanes/macFUSE.prefPane'

    /bin/rm -f \
        /Library/LaunchDaemons/com.edp.drive.service.plist \
        /Library/LaunchDaemons/com.edp.usbvault.mountd.plist \
        /Library/LaunchDaemons/com.edp.usbvault.mountd.v2.plist \
        /Library/LaunchDaemons/io.macfuse.app.launchservice.daemon.plist \
        /Library/PrivilegedHelperTools/io.macfuse.app.launchservice.daemon \
        /usr/local/bin/edp-vaultctl \
        /usr/local/bin/edp-console-exec \
        /usr/local/bin/edp-mfmount-local-readonly \
        /usr/local/bin/edp-mfmount-local-readwrite \
        /var/log/edp-drive.log

    local receipt
    for receipt in \
        com.edp.drive.native \
        com.edp.drive.runtime \
        com.edp.drive.ui-update \
        com.edp.drive.uihotfix \
        io.macfuse.installer.components.core \
        io.macfuse.installer.components.preferencepane; do
        /usr/sbin/pkgutil --forget "$receipt" >/dev/null 2>&1 || true
    done

    say 'RESULT=DRIVE_ENVIRONMENT_ROOT_CLEANUP_OK'
}

root_cleanup_needed() {
    local path
    for path in \
        '/Applications/EDP Drive.app' \
        '/Applications/EDP USB Vault.app' \
        '/Library/Application Support/EDP Drive' \
        '/Library/Application Support/EDP USB Vault' \
        '/Library/Filesystems/macfuse.fs' \
        '/Library/Frameworks/macFUSE.framework' \
        '/Library/PreferencePanes/macFUSE.prefPane' \
        '/Library/LaunchDaemons/com.edp.drive.service.plist' \
        '/Library/LaunchDaemons/io.macfuse.app.launchservice.daemon.plist' \
        '/Library/PrivilegedHelperTools/io.macfuse.app.launchservice.daemon'; do
        [[ -e "$path" ]] && return 0
    done
    /usr/sbin/pkgutil --pkgs 2>/dev/null | /usr/bin/grep -Eq '^(com\.edp\.drive\.|io\.macfuse\.installer\.)'
}

request_root_cleanup() {
    /usr/bin/osascript - "$SELF" <<'APPLESCRIPT'
on run argv
    set scriptPath to item 1 of argv
    do shell script quoted form of scriptPath & " clean --root" with administrator privileges
end run
APPLESCRIPT
}

case "$MODE" in
    status)
        show_status
        ;;
    clean)
        if [[ "$ROOT_MODE" == '--root' ]]; then
            root_cleanup
            exit 0
        fi
        validate_no_external_edp_mounts
        cleanup_edp_test_images
        remove_macfuse_from_user_settings
        restart_console_fskit_agent_if_safe
        if root_cleanup_needed; then
            request_root_cleanup
            restart_console_fskit_agent_if_safe
        fi
        show_status
        ;;
    *)
        say "usage: $0 {status|clean}" >&2
        exit 2
        ;;
esac
