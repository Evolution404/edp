#!/usr/bin/env python3
"""Replace the preview AppleScript launcher with a visible real-progress installer.

The privileged installer is detached after a single administrator authorization
and writes `installer -verboseR` output to /private/tmp. The foreground applet
polls that output and maps `installer:%NN.NNN` to its native progress bar.
"""
from pathlib import Path

p = Path("installer/build-one-click.sh")
text = p.read_text()
start = 'cat > "$LAUNCHER_SOURCE" <<APPLESCRIPT\n'
end = 'APPLESCRIPT\n\nosacompile -o "$LAUNCHER_APP" "$LAUNCHER_SOURCE"'
start_i = text.find(start)
end_i = text.find(end, start_i + len(start))
if start_i < 0 or end_i < 0:
    raise SystemExit("installer launcher AppleScript heredoc not found")

launcher = r'''cat > "$LAUNCHER_SOURCE" <<APPLESCRIPT
on run
    activate
    set appBundle to POSIX path of (path to me)
    set pkgPath to appBundle & "Contents/Resources/${PKG_NAME}"
    set tempPkg to "${TEMP_PKG}"
    set logPath to "/private/tmp/com.edp.usbvault-installer.log"
    set statusPath to "/private/tmp/com.edp.usbvault-installer.status"

    try
        display dialog "将安装 EDP USB Vault、macFUSE 5.3.3 和后台服务。安装过程中会要求输入 Mac 管理员密码。" buttons {"取消", "开始安装"} default button "开始安装" cancel button "取消" with title "EDP USB Vault 安装" with icon note

        set progress total steps to 100
        set progress completed steps to 2
        set progress description to "正在准备安装"
        set progress additional description to "正在准备 EDP USB Vault 安装包…"

        do shell script "/bin/rm -f " & quoted form of tempPkg & " " & quoted form of logPath & " " & quoted form of statusPath & "; /usr/bin/ditto " & quoted form of pkgPath & " " & quoted form of tempPkg

        set progress completed steps to 5
        set progress description to "等待管理员授权"
        set progress additional description to "请输入 Mac 管理员密码以继续安装。"

        -- Start the privileged installer detached so this foreground app remains
        -- responsive and can render actual -verboseR percentage updates.
        set workerCommand to "umask 022; /bin/rm -f " & quoted form of logPath & " " & quoted form of statusPath & "; (if /usr/sbin/installer -verboseR -pkg " & quoted form of tempPkg & " -target / > " & quoted form of logPath & " 2>&1; then /bin/echo 0 > " & quoted form of statusPath & "; else /bin/echo 1 > " & quoted form of statusPath & "; fi; /bin/rm -f " & quoted form of tempPkg & ") >/dev/null 2>&1 &"
        do shell script "/bin/sh -c " & quoted form of workerCommand with administrator privileges

        set progress description to "正在安装"
        set progress additional description to "正在安装 macFUSE、EDP USB Vault 和后台服务… 5%"

        repeat
            delay 0.25
            set doneText to do shell script "/usr/bin/test -f " & quoted form of statusPath & " && /bin/echo yes || /bin/echo no"

            try
                set pctText to do shell script "/usr/bin/grep 'installer:%' " & quoted form of logPath & " 2>/dev/null | /usr/bin/tail -1 | /usr/bin/sed -E 's/.*installer:%([0-9.]+).*/\\1/' | /usr/bin/cut -d. -f1"
                if pctText is not "" then
                    set pct to pctText as integer
                    if pct < 5 then set pct to 5
                    if pct > 99 then set pct to 99
                    set progress completed steps to pct
                    set progress additional description to "正在安装 macFUSE、EDP USB Vault 和后台服务… " & pct & "%"
                end if
            end try

            if doneText is "yes" then exit repeat
        end repeat

        set exitCode to do shell script "/bin/cat " & quoted form of statusPath
        if exitCode is not "0" then
            set logTail to ""
            try
                set logTail to do shell script "/usr/bin/tail -n 30 " & quoted form of logPath
            end try
            error "系统安装器执行失败。" & return & logTail number 1001
        end if

        set progress completed steps to 99
        set progress description to "正在完成配置"
        set progress additional description to "正在启动后台服务并检查安装结果…"
        do shell script "/usr/bin/test -d " & quoted form of "/Applications/EDP USB Vault.app"

        set progress completed steps to 100
        set progress description to "安装完成"
        set progress additional description to "EDP USB Vault 已成功安装。"
        delay 0.35

        do shell script "/bin/rm -f " & quoted form of logPath & " " & quoted form of statusPath

        set answer to display dialog "EDP USB Vault 已安装完成。后台服务保持管理员权限访问原始 U 盘，仅 macFUSE/FSKit 桥接进程进入当前用户会话。请保持 macFUSE 文件系统扩展为启用状态。" buttons {"稍后", "打开 EDP USB Vault"} default button "打开 EDP USB Vault" with title "安装完成" with icon note
        if button returned of answer is "打开 EDP USB Vault" then
            do shell script "/usr/bin/open -a " & quoted form of "/Applications/EDP USB Vault.app"
        end if
    on error errMsg number errNum
        try
            do shell script "/bin/rm -f " & quoted form of tempPkg & " " & quoted form of statusPath
        end try
        if errNum is not -128 then
            display dialog "安装失败：" & errMsg buttons {"关闭"} default button "关闭" with title "EDP USB Vault" with icon stop
        end if
    end try
end run
APPLESCRIPT

osacompile -o "$LAUNCHER_APP" "$LAUNCHER_SOURCE"'''

text = text[:start_i] + launcher + text[end_i + len(end):]
p.write_text(text)
print("Applied real installer percentage UI")
