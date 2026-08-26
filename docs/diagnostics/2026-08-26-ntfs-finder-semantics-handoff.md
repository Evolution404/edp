# EDP USB Vault — NTFS Finder 读写与本地卷语义交接

更新时间：2026-08-26
目标分支：`feat/macos26-native-fskit`
稳定读写基线：`56dcf39 feat: enable Finder NTFS read-write mounts`
当前 WIP 保全提交：`4f0171d wip: preserve Finder local-volume and performance work`

> 本文用于迁移到新的 AI/开发会话。不要重复已经完成的 macFUSE 重装、FSKit enablement、Keychain/raw authorization、基础 NTFS 读写打通。当前重点已经从“能不能挂载/能不能写”转为“Finder 本地卷语义、TextEdit 原子保存、Trash、多文件操作和性能”。

## 1. 当前产品目标

目标平台仅 macOS 26+。

当前阶段目标：

1. 用户通过 EDP USB Vault UI 挂载真实 EDP U 盘交换区；
2. Finder 中显示可正常浏览的 NTFS 交换区；
3. NTFS 必须真实可读写；
4. Finder 行为应尽可能接近正常本地外置磁盘：TextEdit 保存、批量复制、批量删除/Trash、重命名等语义正常；
5. 性能至少达到可接受的 USB 文件复制体验，避免双层 FUSE + Swift SM4 热路径造成数量级退化；
6. 保持 fail-closed：NTFS dirty/hibernated/非法卷必须拒绝读写挂载；
7. 不要求关闭 SIP、Reduced Security，也不依赖 macFUSE kernel backend。

## 2. 已经真正完成且不要重复

### 2.1 macFUSE/FSKit

- macFUSE 5.3.3 已重装并通过官方 `install --force` 重新注册。
- 用户已在系统设置启用 macFUSE File System Extension。
- generic module `io.macfuse.app.fsmodule.macfuse` 已在 UID 501 用户会话中完成真实 FSKit mount。
- `FSClient.fetchInstalledExtensions` 在 macOS 26 上仍只返回 Apple 模块，不能作为第三方 macFUSE enablement 判据；产品已移除该错误 preflight。
- root 直接启动 FUSE 会走错误/不同的 module/session；当前正确架构是 root daemon 编排，FUSE/NTFS 通过 `edp-console-exec` 降权到控制台用户 UID 501。

### 2.2 自动重试/弹窗风暴

- 原 `failureDeadline + 30s` 重试逻辑已移除。
- 失败后按 device/partition 锁存，只允许用户主动重试、重新授权或设备重连再次尝试。
- UI “挂载交换区”现在等待本轮挂载结果，后台失败会返回 UI，不再表现为“点了没反应”。

### 2.3 Keychain 与 raw-device 授权

- 旧 System Keychain item 因 ad-hoc daemon cdhash 变化导致 `-25308`，已升级为 v3 root-oriented policy；普通用户直接读取失败。
- App 针对真实 raw device 请求精确 Authorization right。
- 读写版已切为：`sys.openfile.readwrite./dev/rdiskN`。
- external Authorization form 通过 XPC 交给 daemon，再传给 `authopen -extauth`。

### 2.4 真实 EDP NTFS 读写

稳定基线 commit：`56dcf39`。

真实 `/dev/disk4` 端到端已经通过：

```text
physical EDP USB
-> raw /dev/rdisk4
-> password + LBA metadata validation
-> Swift SM4 block translation
-> edp-readwrite-fuse --device-auth
-> hidden volume.raw
-> ntfs-3g.probe --readwrite
-> ntfs-3g backend=fskit
-> /Volumes/EDP-NTFS
-> Finder
```

实机写验证：

- 创建 44-byte 临时 probe 文件成功；
- 读回内容一致；
- `sync` 成功；
- SHA256：`804aeb48591837af764647e84053b41b7bbdde80cf8f58125ccf22a95f2e5152`；
- 删除 probe 并再次 sync；
- 未修改既有用户文件。

partition type 2 为有效 NTFS；partition type 4 的 `ntfs-3g.probe --readwrite` 返回“not a valid NTFS volume”，应继续被忽略/拒绝，不影响 type 2 成功。

## 3. 用户当前反馈的三个问题

### 3.1 TextEdit 修改 txt 后无法保存

已稳定复现。

普通覆盖写没问题，但 TextEdit 常见的原子保存路径需要：

```text
create temp file
write temp
rename(temp, existing-target)
```

当前 macFUSE FSKit 下 `rename(old, existing-new)` 返回：

```text
errno = 102
EOPNOTSUPP
Operation not supported on socket
```

因此 TextEdit 保存失败不是 NTFS 只读，而是“覆盖已有目标的原子 rename”语义缺失/不兼容。

已验证：

- 普通 create/read/overwrite 可工作；
- xattr set/remove 可工作；
- directory rename 可工作；
- rename 覆盖已有文件稳定失败。

这项目前仍是**未解决 P0**。

### 3.2 Finder 拷贝速度非常慢

最初观察到内层解密 `volume.raw` 顺序读只有约 5.8 MB/s，主要怀疑点是 Swift `EDPSM4` 每 16-byte block 大量 Array/slice/state 分配，加上双层 FUSE 上下文切换。

当前 WIP `4f0171d` 中已经保存一组性能实验：

- `EDPCrypto.swift`：SM4 ECB 热路径改为一次性 output buffer + 4 个 `UInt32` 状态寄存器，减少每 block 分配；
- inner `EDPReadWriteFuseBridge` 增加 `big_writes,noatime`；
- tracker 中记录的本机实验结果：内层 256 MiB 顺序读约提升至 55.8 MB/s，外层 NTFS 64 MiB fsync 顺序写约 37.8 MB/s，500×4 KiB 小文件约 6 秒。

注意：这些代码在 `4f0171d` 中是 **WIP 保全状态**。下一个 AI 必须重新跑现有 crypto/NTFS CI 与真实冷挂载回归，再决定是否视为稳定。

### 3.3 Finder 多选文件不能删除

底层普通 `unlink()` 并没有坏：批量 unlink 临时文件可以成功。

问题集中在 Finder Trash 语义：generic FSKit 挂载时 `/Volumes/EDP-NTFS/.Trashes` 虽看似存在，但 `listdir/mkdir` 返回 `EPERM`，Finder 删除默认需要把文件移动到 Trash，因此表现为多选删除失败。

当前 WIP `4f0171d` 在最外层 NTFS mount policy 增加 macFUSE `local` 选项：

```text
backend=fskit,local,...
```

现有 tracker 记录的实验结果：outer `local` 后 mount source/flags 获得本地卷语义，`.Trashes/501` 可访问，10 个临时文件移动 Trash 0 错误、100 个临时文件批量 unlink 0 错误。

重要限制：**不要给内层 `volume.raw` FUSE bridge 加 `local`**。现有实验发现 inner local 会导致 production `ntfs-3g.probe --readwrite` 假报 status 13/EIO。正确方向是：

```text
inner decrypted volume.raw: generic FSKit
outer NTFS-3G: local FSKit
```

## 4. 当前“网络卷”问题

稳定基线 `56dcf39` 的当前挂载曾实测：

```text
from = macfuse://UUID
fstype = macfuse
MNT_LOCAL = false
```

因此 Finder 把交换区归类为网络位置，即使数据实际来自本机 USB。

WIP `4f0171d` 将 `local` 只加到外层 NTFS mount policy，目的就是让 Finder 获得本地卷语义，并同时改善 Trash 行为。

下一个 AI 必须在安装/运行 WIP 后实际确认：

```text
mount
statfs /Volumes/EDP-NTFS
MNT_LOCAL
Finder sidebar/category
.Trashes/501
```

不要只看参数就宣称已解决。

## 5. 当前仓库状态与运行时状态要区分

### Git

- `56dcf39`：已验证的真实 NTFS 读写基线；
- `4f0171d`：为了迁移不丢失而保存的 local-volume + SM4/FUSE 性能 WIP。

### 本机运行时

不要假设 `/Applications/EDP USB Vault.app` 和 `/Library/Application Support/EDP USB Vault/bin/*` 一定等于 Git HEAD。

在用户要求停止时，不再继续安装/重新挂载 WIP。下个 AI 开始前应先检查：

```text
ps -axo pid,uid,command | grep edp-readwrite-fuse
ps -axo pid,uid,command | grep ntfs-3g
mount | grep EDP
codesign/hash of installed runtime vs newly built runtime
```

如果当前已经有用户文件在交换区打开，先安全卸载再替换 runtime。

## 6. 当前 WIP 文件

`4f0171d` 保存了以下实验性改动：

1. `.github/workflows/edp-crypto-ntfs3g-readwrite.yml`
   - CI mount policy 从“禁止 local”翻转为“必须包含 local”。
2. `product/EDPNTFSMountPolicy.swift`
   - outer NTFS fixed options 增加 `local`。
3. `native/EDPFSKitPoC/Tools/EDPReadWriteFuseBridge.c`
   - inner bridge 增加 `big_writes,noatime`，**没有加 local**。
4. `native/EDPFSKitPoC/Extension/EDPCrypto.swift`
   - SM4 ECB 热路径减少临时 Array 分配。

不要把 inner bridge 改成 local，除非先重新证明 `ntfs-3g.probe --readwrite` 不会出现 status 13/EIO。

## 7. 下一步任务（按优先级）

### P0 — TextEdit 原子保存

目标：以下操作必须成功，并且不会破坏文件：

```text
create temp
write temp
fsync
rename(temp, existing target)
read target
```

任务：

1. 用最小 macFUSE FSKit filesystem 复现 rename-over-existing，与 NTFS-3G 解耦；
2. 比较 generic vs outer local 是否都返回 `EOPNOTSUPP`；
3. 查 macFUSE 5.3.3 FSKit rename/renamex_np/atomic replace 的已知限制和 upstream issue；
4. 判断问题在 macFUSE FSKit bridge、NTFS-3G FUSE callback，还是 macOS Finder/TextEdit 的特殊 rename flag；
5. 如果可以在 NTFS-3G/FUSE 用户态兼容，做最小 patch，并加入原子 replace regression test；
6. 不要以“先删除目标再 rename”这种非原子、可能丢数据的 hack 作为产品修复。

验收：TextEdit 打开真实交换区 txt，修改后 Cmd+S 成功；旧内容不会因中途失败丢失。

### P1 — 本地卷/Trash

1. 基于 `4f0171d` 构建并安装 WIP；
2. cold remount；
3. 确认 outer `/Volumes/EDP-NTFS` 为 local；
4. Finder 视觉分类应从“网络位置”变为本地/外置磁盘语义；
5. `.Trashes/501` 可访问；
6. Finder 多选 10/100 个临时文件删除成功；
7. 从 Trash 恢复与清空 Trash 也应验证；
8. inner `volume.raw` 保持 generic FSKit。

### P1 — 性能

1. 对 `4f0171d` 的 SM4 优化跑完整 `ValidateEDPNativeCore` / crypto E2E；
2. 真实盘 benchmark 固定口径：256 MiB sequential read、256 MiB sequential write+fsync、1000×4 KiB small files；
3. 分别测：raw encrypted device、inner `volume.raw`、outer NTFS，定位剩余损耗；
4. 确认 `big_writes` 请求尺寸实际放大；
5. 必要时再优化 Swift/C ABI buffer copying，而不是先改算法。

验收建议：连续读写至少进入几十 MB/s，且不出现 CPU 单核满载导致 UI 卡死。

### P2 — 回归与产品化

1. dirty/hibernated/invalid NTFS 继续 fail-closed；
2. copy/rename/delete/xattr/Trash/TextEdit regression tests；
3. daemon crash、拔盘、安全 eject；
4. clean installer 重建 + verifier；
5. GitHub Actions 全绿；
6. 再决定是否发布新安装包。

## 8. 明确不要重复/不要走的方向

不要重复：

- macFUSE 5.3.3 重装与基础 enablement 排查；
- `FSClient.fetchInstalledExtensions` 是否显示 macFUSE；
- root vs UID 501 module selection 基础定位；
- Keychain `-25308` 根因；
- raw Authorization external form 协议；
- “真实 NTFS 能不能写”的基础验证。

不要走：

- 为了 local volume 强制启用 macFUSE kernel backend；
- 要求用户进入 Recovery 降低启动安全策略；
- 为 TextEdit 保存用“先删旧文件再改名”的非原子 workaround；
- 将 inner decrypted bridge 设为 `local` 而不验证 NTFS probe；
- 绕过 `ntfs-3g.probe --readwrite` 的 dirty/hibernation gate。

## 9. 建议给下一个 AI 的启动提示词

```text
打开 /Users/zhangyuxi/Desktop/edp-usb-vault，切到 feat/macos26-native-fskit。
先读取 docs/STATUS.md、docs/diagnostics/2026-08-26-ntfs-finder-semantics-handoff.md 和 docs/PROGRESS-TRACKER-NTFS-FINDER-2026-08-26.md。
稳定 NTFS 读写基线是 56dcf39；4f0171d 是为了迁移保留的 outer-local + SM4/FUSE 性能 WIP，不要默认它已经是稳定发布版。
不要重复 macFUSE 安装、FSKit enablement、Keychain/raw authorization 和基础 NTFS 写入验证。
当前最高优先级是解决 TextEdit 原子保存：rename(temp, existing-target) 在 macFUSE 5.3.3 FSKit 返回 EOPNOTSUPP。其次复核 outer local 对 Finder 本地卷/Trash 的修复和 SM4 性能优化。所有真实盘测试只使用临时测试文件，不修改已有用户文件，并实时更新进度追踪文件后提交推送。
```
