# EDP USB Vault / macOS 15.7.9 FSKit 调试交接文档

## 1. 当前目标

继续研究：

> **如何让 macOS 15.7.9 上的 EDP USB Vault 使用 macFUSE FSKit backend 正常挂载，而不是依赖 kernel backend fallback。**

重点怀疑方向已经从“EDP/macFUSE 安装问题”转向：

> **macOS 15.7.9 上 `/sbin/mount -F` → LiveFS → fskitd 的 direct FSKit mount 路径存在异常。**

下一会话应继续验证：

1. 本机特有系统环境异常；
2. macOS 15.7.7/15.7.9 系统回归；
3. 可绕过 `/sbin/mount -F`、改走 Disk Arbitration / FSKitDiskArbHelper 的纯 FSKit workaround。

---

## 2. 项目环境

项目目录：

```text
/Users/zhangyuxi/Desktop/edp-usb-vault
```

Git branch：

```text
install/one-click-installer
```

Mac connector workspace：

```text
workspaceId = ws_f09923efa6
```

继续操作时复用这个 workspaceId。

---

## 3. 用户要求保留的架构

不要轻易推翻当前权限设计：

```text
root daemon
↓
root open /dev/rdiskN
↓
保留 raw disk FD
↓
launchctl asuser
↓
bridge 降权到登录用户
↓
MFMount / FSKit
```

原则：

- root 只负责真实磁盘访问；
- FUSE / FSKit bridge 应尽量运行在登录用户上下文；
- 不希望为了 FSKit 把整个 mount bridge 改成 root。

---

## 4. 当前系统环境

Mac：

```text
macOS 15.7.9
Build 24G830
Apple Silicon / arm64
```

今天刚升级：

```text
15.7.7 → 15.7.9
安装完成时间约 2026-08-25 06:52
```

系统更新结果：

```text
result = success
rootVolumeSealValid = true
targetOSVersion = 24G830
ota_result_success
```

当前：

```text
SIP = enabled
Authenticated Root = enabled
```

root filesystem：

```text
/dev/disk3s1s1 on /
APFS sealed
read-only
```

SystemVersion、Cryptex、root snapshot 全部一致：

```text
15.7.9 / 24G830
```

因此暂时没有证据说明 OTA 安装失败或 SSV 被破坏。

---

## 5. macFUSE 状态

安装版本：

```text
macFUSE 5.3.3
```

kernel backend：

```text
io.macfuse.filesystems.macfuse.23
version 5.3.3
Loaded: Yes
arm64e
```

所以 kernel backend 当前完全可用。

---

## 6. macFUSE 安装完整性已经彻底核验

官方 DMG：

```text
/Users/zhangyuxi/Downloads/macfuse-5.3.3.dmg
```

已经将官方 Core.pkg payload 与：

```text
/Library/Filesystems/macfuse.fs
```

逐文件 SHA-256 对比。

结果：

```text
missing_count = 0
diff_count    = 0
extra_count   = 0
```

关键文件全部 MATCH：

```text
MFMount.framework
macfuse.app
macfuse-local FSKit extension
generic macfuse FSKit extension
Info.plist
version.plist
```

特权 helper：

```text
/Library/PrivilegedHelperTools/io.macfuse.app.launchservice.daemon
```

与官方包内源文件 SHA-256 完全一致。

LaunchDaemon：

```text
/Library/LaunchDaemons/io.macfuse.app.launchservice.daemon.plist
```

Mach services：

```text
io.macfuse.mount
3T5GSNBU6W.io.macfuse.app.launchservice.daemon.xpc
```

均正常在线。

因此：

> **macFUSE 混装、文件损坏、helper 版本不匹配基本排除。**

---

## 7. FSKit extension 注册状态

有效 macFUSE local FSKit extension：

```text
/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app/Contents/Extensions/io.macfuse.app.fsmodule.macfuse-local.appex
```

PlugInKit 只有一个有效记录：

```text
io.macfuse.app.fsmodule.macfuse-local
```

没有指向旧版本副本。

用户 FSKit 配置：

```text
~/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist
~/Library/Group Containers/group.com.apple.fskit.settings/probeOrder.plist
```

其中：

```text
io.macfuse.app.fsmodule.macfuse-local
```

已启用。

---

## 8. 用户级 FSKit 状态已经做过“干净状态”A/B

执行过：

1. 备份 `enabledModules.plist`
2. 备份 `probeOrder.plist`
3. 临时移除这两个文件
4. kill 用户级：
   - `fskit_agent`
   - `extensionkitservice`
5. 让系统重新生成干净运行状态
6. 使用 Apple 自带 FAT16 FSKit direct mount 测试
7. 测试结束后恢复原配置

原始 SHA：

```text
enabledModules.plist
62d8b25d8b45178e3d86b8b2c614aff4f061341f0d94f69b9899bf62fa19ceb5

probeOrder.plist
0ef04ce236f0b43489be867801d170e58ed665bfaf51276b0c5bde06ba7d3b0b
```

恢复后 SHA 完全一致。

结果：

```text
CLEAN_USER_STATE_DIRECT_FSKIT_FAILED
```

错误完全相同。

因此已排除：

- enabledModules 配置污染；
- probeOrder 配置污染；
- fskit_agent stale cache；
- extensionkitservice stale cache。

---

## 9. 关键系统组件检查

已检查：

```text
/sbin/mount
/usr/libexec/fskitd
/usr/libexec/fskit_agent
/usr/libexec/fskit_helper
/usr/libexec/diskarbitrationd
FSKit.framework
LiveFS.framework
```

全部：

- Apple 签名有效；
- 版本基线一致；
- minOS / SDK 均为 15.7；
- 文件时间戳属于同一系统版本。

关键 entitlement：

`diskarbitrationd`：

```text
com.apple.private.LiveFS.connection = true
com.apple.private.fskit.module-runner = true
```

`fskitd`：

```text
com.apple.private.LiveFS.connection = true
com.apple.private.LiveFS.setmachport = true
```

但是：

```text
/sbin/mount
```

没有：

```text
com.apple.private.LiveFS.connection
```

---

## 10. 最重要的 Apple 原生对照实验

已经完全绕开 macFUSE。

创建了真实 FAT16 磁盘映像，得到：

```text
/dev/disk4s1

File System Personality: MS-DOS FAT16
Partition Type: DOS_FAT_16
```

### 直接 mount

执行：

```bash
/sbin/mount -F -t msdos /dev/disk4s1 <mountpoint>
```

结果：

```text
mount: Final mount step ended with error:
Couldn’t communicate with a helper application.

mount: Unable to invoke task

mount_rc=69
```

日志：

```text
fskitd:
Incomming connection, entitled 0

NSXPCDecoder:
received a message or reply block that is not in the interface
of the remote object:

mountVolume:fileSystem:displayName:provider:
domainError:on:how:options:reply:
```

### 同一个 FAT16，改用 Disk Arbitration

紧接着执行：

```bash
diskutil mount /dev/disk4s1
```

成功。

mount 输出：

```text
/dev/disk4s1 on /Volumes/EDPFAT
(msdos, local, nodev, nosuid, noowners, noatime, fskit, mounted by zhangyuxi)
```

这是当前最重要的结论：

> FSKit 本身能工作。
>
> Apple 自带 msdos FSKit extension 能工作。
>
> Disk Arbitration → FSKit 能工作。
>
> **坏的是 direct `/sbin/mount -F` 的最终 LiveFS/XPC handoff。**

---

## 11. Runtime 已直接证明 LiveFS protocol 契约问题

使用 Objective-C runtime 枚举当前系统 protocol。

结果：

```text
PROTO LiveFSMounterUnentitled
  required switchToFSKit:
```

也就是说未授权客户端只有：

```text
switchToFSKit:
```

而完整 protocol：

```text
PROTO LiveFSMounter
```

包含：

```text
listMounts:
mountVolume:displayName:provider:domainError:on:how:options:reply:
mountVolume:displayName:provider:domainError:on:how:reply:
mountVolume:fileSystem:displayName:provider:domainError:on:how:options:auditToken:reply:
mountVolume:fileSystem:displayName:provider:domainError:on:how:options:reply:
setVerboseLevel:
unmountVolume:how:reply:
...
```

而真实失败链为：

```text
/sbin/mount
↓
connect com.apple.filesystems.fskitd
↓
fskitd 日志：entitled 0
↓
服务端只允许 LiveFSMounterUnentitled
↓
/sbin/mount 却调用：
mountVolume:fileSystem:...reply:
↓
NSXPCDecoder 拒绝
```

因此当前系统运行路径存在非常明确的 client/server 契约矛盾。

---

## 12. `/sbin/mount` 自身也明确引用这些接口

`/sbin/mount` 动态依赖：

```text
FSKit.framework
LiveFS.framework
```

symbols：

```text
_OBJC_CLASS_$_FSClient
_OBJC_CLASS_$_LiveFSMountClient
```

strings 中包含：

```text
mountVolume:fileSystem:displayName:provider:domainError:on:how:options:
```

所以不是 macFUSE 自己构造了这个 selector。

---

## 13. Disk Arbitration 为什么能成功

`diskarbitrationd` 有：

```text
com.apple.private.LiveFS.connection = true
```

日志显示其连接：

```text
Incomming connection, entitled 1
Hello FSClient! entitlement yes
```

因此 Disk Arbitration 可以正常使用完整 LiveFSMounter protocol。

这就是 FAT16：

```text
diskutil mount
```

成功，而：

```text
/sbin/mount -F
```

失败的根本区别。

---

## 14. 本机第三方文件系统污染情况

本机历史比较复杂。

存在：

```text
/Library/Filesystems/iboysoft_NTFS.fs
/Library/Extensions/ms_ntfs.kext
/Library/StagedExtensions/Library/Extensions/ms_ntfs.kext
/Library/StagedExtensions/Library/Extensions/ufsd_NTFS.kext
```

安装 receipt：

```text
com.iboysoft.ntfsformac.kext.installer
com.iboysoft.ntfsassistant-zh-website
com.paragon-software.pkg.ntfs
```

iBoysoft `/Library/Filesystems/iboysoft_NTFS.fs`：

```text
version 4.5
macOS 11.1 SDK
```

并且它的 `FSMediaTypes` 会注册：

```text
DOS_FAT_12
DOS_FAT_16
DOS_FAT_32
...
```

所以 FAT16 probe 日志会先出现：

```text
iboysoft_NTFS
```

但是已经做过 A/B：

退出正在运行的：

```text
/Applications/赤友NTFS助手.app
```

后重新测试 Apple FAT16 direct FSKit mount。

结果：

```text
DIRECT_FSKIT_STILL_FAILS_WITH_IBOYSOFT_APP_OFF
```

失败仍是完全相同的：

```text
entitled 0
NSXPC mountVolume selector reject
```

因此 iBoysoft 属于环境污染因素，但目前没有证据证明它是根因。

注意：测试时“赤友NTFS助手”进程已退出，下一会话如需要可自行重新打开。

---

## 15. macFUSE FSKit module metadata

macFUSE local：

```text
FSShortName = macfuse-local
FSSupportsBlockResources = 1
FSSupportsGenericURLResources = 0
FSSupportsPathURLs = 0
FSMediaTypes = {}
LSMinimumSystemVersion = 15.4
```

关键点：

```text
FSMediaTypes = EMPTY
```

所以 macFUSE 创建出的约 4KB virtual disk：

```text
Content = ""
```

Disk Arbitration 无法通过媒体 probe 自动知道：

```text
这应该交给 macfuse-local
```

因此简单：

```bash
diskutil mount /dev/diskN
```

无法成为 macFUSE FSKit workaround。

---

## 16. generic macFUSE FSKit module

另一个 module：

```text
io.macfuse.app.fsmodule.macfuse.appex
```

配置：

```text
FSSupportedSchemes = ["macfuse"]
FSSupportsBlockResources = 0
FSSupportsGenericURLResources = 1
FSShortName = macfuse
LSMinimumSystemVersion = 26.0
```

因此：

```text
macfuse://UUID
```

generic URL FSKit 路径只有 macOS 26+ 可用。

15.7.9 只能走：

```text
macfuse-local
block device
```

---

## 17. 当前最有价值的新突破：FSKitDiskArbHelper

从当前系统：

```text
/System/Library/Frameworks/FSKit.framework
```

发现 Apple 私有类：

```text
FSKitDiskArbHelper
```

Runtime 方法：

```text
+ DAMountFSKitVolume:
    deviceName:
    mountPoint:
    volumeName:
    auditToken:
    mountOptions:

+ DAMountUserFSVolume:
    deviceName:
    mountPoint:
    volumeName:
    mountOptions:

+ DAMountUserFSVolume:
    deviceName:
    mountPoint:
    volumeName:
    auditToken:
    mountOptions:

+ getFileProviderID
+ waitForPreviousTasksToComplete:client:
```

这非常可能就是：

```text
Disk Arbitration
→ FSKit
```

的专用内部桥。

下一会话应重点继续逆向：

```text
DAMountFSKitVolume:
```

第一个参数是什么。

---

## 18. FSClient Runtime API 已枚举

当前 `FSClient` 包含：

```text
activateVolume:shortName:options:auditToken:replyHandler:
activateVolume:usingBundle:options:auditToken:replyHandler:

loadResource:shortName:options:auditToken:replyHandler:
loadResource:usingBundle:options:auditToken:replyHandler:

probeResource:usingBundle:auditToken:replyHandler:

checkResource:usingBundle:options:auditToken:connection:replyHandler:

installedExtensionWithBundleID:synchronous:replyHandler:
installedExtensionWithShortName:synchronous:replyHandler:

setEnabledStateForIdentifier:newState:replyHandler:
...
```

以及：

```text
FSBlockDeviceResource
```

有：

```text
proxyResourceForBSDName:
proxyResourceForBSDName:isWritable:
openWithBSDName:writable:auditToken:replyHandler:
```

这意味着理论上可以自己构造：

```text
FSBlockDeviceResource(/dev/diskN)
+
指定 io.macfuse.app.fsmodule.macfuse-local
```

完成 load/activate。

但问题仍然是最终 VFS mount，当前 `/sbin/mount` 这一步坏掉。

---

## 19. `FSKitDiskArbHelper` 很可能是下一步突破口

目标 PoC：

```text
macFUSE 创建 virtual disk
↓
得到 diskN
↓
不要调用 /sbin/mount -F
↓
改用 FSKitDiskArbHelper / Disk Arbitration 内部 FSKit mount
↓
让拥有 LiveFS entitlement 的进程完成最终 mount
```

理想目标：

```text
EDP
↓
macFUSE MFMount / FSKit
↓
virtual disk
↓
Disk Arbitration
↓
entitled 1
↓
FSKit final mount
↓
成功
```

如果成功，就可以在 15.7.9 上：

```text
完全不用 kernel backend
```

---

## 20. 当前 kernel fallback 状态

项目源码已经存在：

```text
FSKit first
↓
FSKit failure
↓
kernel backend fallback
```

并且已完整验证。

源码：

```text
crates/usbcore/src/session.rs
```

有：

```rust
static PREFER_KERNEL_AFTER_FSKIT_FAILURE: AtomicBool
```

逻辑：

```text
第一次先 FSKit
失败 → kernel

同一 daemon 后续 session
→ 直接 kernel
```

---

## 21. kernel backend 已通过完整 EDP 测试

测试：

```bash
cargo test -p usbcore --test integration synthetic_full_pipeline -- --ignored --nocapture
```

结果：

```text
1 passed
```

完整测试包括：

```text
32 MB exFAT
→ EDP synthetic encrypted image
→ wrong password
→ mount
→ write proof
→ unmount
→ remount
→ persistence
→ readonly mount
→ write rejection
```

session：

```text
bridge_backend = kernel
```

全部成功。

---

## 22. 最新 signed release payload 也验证成功

精确测试了最终安装包中的 signed usbcore：

```text
/tmp/edp-tauri-target/release/bundle/macos/EDP USB Vault.app/Contents/Resources/usbcore
```

SHA：

```text
d7ec3d62a0b0891ab9e70a79867c8ef002d12451fbfed1026d0969ee5df70fb8
```

行为：

```text
FSKit 失败
↓
FSKit bridge 失败，尝试 macFUSE kernel backend
↓
kernel 成功
↓
/Volumes/EDPTEST
↓
文件可读
↓
unmount 成功
```

所以产品功能目前已有可靠 fallback。

---

## 23. 当前新 installer

路径：

```text
~/Desktop/edp-usb-vault/artifacts/EDP-USB-Vault-0.4.1-arm64-Installer.dmg
```

SHA-256：

```text
49abd03207cf97f6fd0b9356ccd7c75a358a430be42c02963c191ed5dec5896e
```

`hdiutil verify`：

```text
PASS
```

最终 DMG 内真正 payload 的 usbcore：

```text
d7ec3d62a0b0891ab9e70a79867c8ef002d12451fbfed1026d0969ee5df70fb8
```

包含 fallback。

但是：

> `/Applications/EDP USB Vault.app` 目前仍然是旧版本。

因为系统安装需要管理员认证，目前尚未真正安装新 DMG。

---

## 24. 当前 Git 修改，不要覆盖

最新已知 modified files：

```text
M Cargo.lock
M crates/edp-core/src/volume.rs
M crates/usbcore/build.rs
M crates/usbcore/src/bridge.rs
M crates/usbcore/src/bridge_libfuse.c
M crates/usbcore/src/main.rs
M crates/usbcore/src/session.rs
M docs/diagnostics/2026-08-25-fskit-mount-failure.md
M installer/build-one-click.sh
```

这些包含之前会话的重要工作和可能的用户修改。

不要：

```text
git reset --hard
git checkout .
```

不要覆盖未提交改动。

---

## 25. 当前质量门

最近已跑：

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo build -p usbcore --release
```

全部 PASS。

---

## 26. Tauri build 状态

原：

```text
gui/src-tauri/target/release/bundle/macos/EDP USB Vault.app
```

存在 root-owned stale bundle，导致普通用户无法删除。

没有强行修权限。

改用：

```bash
CARGO_TARGET_DIR=/tmp/edp-tauri-target
npm run tauri -- build --bundles app
```

成功。

不要为了这个问题破坏项目。

---

## 27. 尚未完成的小问题

integration test cleanup 有一个 bug：

```rust
whole = dev.split('s').next().unwrap_or(dev).to_string();
```

对于：

```text
/dev/disk5s1
```

会错误得到类似：

```text
/dev/di
```

正确思路应只在：

```text
/dev/diskN
```

suffix 全数字时认为它是 whole disk。

之前尝试 Mac.edit 被 connector safety 阻止。

这是测试清理问题，不影响生产代码。

---

## 28. 仍残留的 6 个 stopped root sudo wrapper

之前冻结实验留下：

```text
18079
18552
18830
19349
19648
20057
```

均为：

```text
root
state T
sudo -u #501 /sbin/mount ...
```

现在：

- 无 children
- 无 disk image
- 无 mount
- 无实际影响

因为没有 sudo auth cache，远程无法 kill root wrapper。

重启即可消失。

不要尝试绕过 sudo。

---

## 29. 下一会话推荐的优先研究顺序

### P0：继续 FSKitDiskArbHelper

逆向：

```text
+[FSKitDiskArbHelper DAMountFSKitVolume:
 deviceName:
 mountPoint:
 volumeName:
 auditToken:
 mountOptions:]
```

重点确认：

#### 参数 1 类型

可能是：

```text
DAFileSystem
FSBundle
NSString shortName
FSModuleIdentity
```

需要通过：

- Hopper/otool/llvm-objdump
- Objective-C metadata
- strings
- runtime tracing

确认。

#### 调用后是否

```text
直接当前进程 → fskitd
```

还是：

```text
当前进程 → diskarbitrationd → fskitd
```

如果后者，就很有希望。

### P1：找 Disk Arbitration 的内部“指定 filesystem”接口

已知普通：

```text
DADiskMountWithArguments
```

只能传 mount options，不支持显式：

```text
-t macfuse-local
```

但 daemon 内有：

```text
DAFileSystem
gDAFileSystemList
gDAFileSystemProbeList
FSKitDiskArbHelper
```

继续搜索：

```text
DAFileSystemCreate
DAFileSystemMount
_DADiskMount
_DAFileSystem...
```

私有 symbol / XPC request keys。

### P2：独立 PoC

不要一上来改 EDP。

先做一个独立实验：

```text
官方 macFUSE LoopbackFS
backend=fskit
↓
暂停 final /sbin/mount
↓
拿到 virtual diskN
↓
调用 FSKitDiskArbHelper / DA SPI
↓
看是否能完成 mount
```

成功后再接 EDP。

### P3：比较 15.7.5 / 15.7.7 / 15.7.9

已知外部资料里存在：

```text
macOS 15.7.5 + macFUSE 5.3.3
backend=fskit
成功
```

但当前没有 15.7.9 的公开样本。

最好进一步获得旧版本：

```text
/sbin/mount
/usr/libexec/fskitd
LiveFS.framework
```

比较：

```text
LiveFSMounterUnentitled
LiveFSMounter
LiveFSMountClient
mountVolume selector
entitlement gating
```

看 15.7.7 或 15.7.9 是否发生 ABI/接口变化。

---

## 30. 当前最合理的判断

### 很不可能

```text
EDP bridge bug
macFUSE 5.3.3 文件损坏
macFUSE helper 混装
PlugInKit stale entry
用户 FSKit 配置坏
fskit_agent 缓存
extensionkitservice 缓存
赤友 NTFS 前台进程
今天 OTA 明显失败
```

### 仍可能

```text
macOS 15.7.7/15.7.9 direct FSKit mount regression
```

### 也仍需验证

```text
长期安装多个第三方 filesystem driver
导致某个更底层系统状态异常
```

但目前 Apple 原生 FAT direct mount 失败的错误机制已经发生在：

```text
/sbin/mount ↔ fskitd protocol interface
```

因此第三方 filesystem 不像直接根因。

---

## 31. 当前最终错误机制一句话

可以这样理解：

```text
/sbin/mount：
“我要调用 mountVolume”

fskitd：
“你的连接没有 LiveFS entitlement，
我只允许你调用 switchToFSKit”

/sbin/mount：
“我还是调用 mountVolume”

NSXPC：
“接口里没有这个方法，拒绝消息”
```

而 Disk Arbitration：

```text
diskarbitrationd
有 LiveFS entitlement
↓
允许完整 LiveFSMounter
↓
mountVolume 合法
↓
FSKit mount 成功
```

---

## 32. 最终目标

不是继续证明问题，而是实现：

```text
15.7.9
+
macFUSE 5.3.3
+
EDP
+
FSKit
+
不使用 kernel kext
```

最有希望的路线目前是：

```text
绕过坏掉的 /sbin/mount -F final step
↓
利用 Disk Arbitration / FSKitDiskArbHelper
↓
由 entitled Apple daemon 完成最终 FSKit mount
```

这就是下一会话应继续深入的核心。
