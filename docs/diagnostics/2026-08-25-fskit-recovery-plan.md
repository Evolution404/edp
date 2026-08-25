# EDP USB Vault — FSKit 回归根因与修复研究计划

更新时间：2026-08-25 11:13（UTC+8）

分支：`install/one-click-installer`

## 1. 研究目标

目标不是继续枚举 macOS 小版本，而是找到并验证一个可在 macOS 15.7.7 / 15.7.9 上工作的纯 FSKit 挂载路径，最终让 EDP USB Vault 不再因为 Apple `/sbin/mount -F` 回归而被迫使用 kernel backend。

在独立 PoC 证明方案之前，不直接大改 EDP 主挂载代码。

---

## 2. 已确认的根因

目前证据已经足以把问题定位为 Apple LiveFS / FSKit 的 client/server contract regression，而不是 EDP、macFUSE 安装损坏或本机环境污染。

### 2.1 版本 A/B

已得到以下独立结果：

| 环境 | 系统 | `/sbin/mount -F -t msdos` | `diskutil mount` / Disk Arbitration |
|---|---|---:|---:|
| Codemagic M2 | macOS 15.7 / 24G222 | 成功，`DIRECT_RC=0` | 成功 |
| GitHub Hosted ARM64 | macOS 15.7.7 / 24G720 | 失败，`DIRECT_RC=69` | 成功 |
| 用户 Apple Silicon Mac | macOS 15.7.9 / 24G830 | 失败，`DIRECT_RC=69` | 成功 |

15.7、15.7.7、15.7.9 的 `/sbin/mount` SHA-256 相同：

```text
74f56b33ff3fde9203e6f0b3682718d600687fc7f7ec5b1b6a2d2cf8db97ab15
```

因此不是 `/sbin/mount` 二进制本身在 15.7.7 被更新坏掉，而是它依赖的 LiveFS / fskitd 服务端契约发生了改变。

### 2.2 15.7 与 15.7.7+ 的 protocol 差异

macOS 15.7：

```text
LiveFSMounterUnentitled: MISSING
LiveFSMounter:
  switchToFSKit:
  mountVolume:fileSystem:...
  ...
```

macOS 15.7.7 / 15.7.9：

```text
LiveFSMounterUnentitled:
  required switchToFSKit:

LiveFSMounter:
  mountVolume:fileSystem:...
  ...
```

失败时 fskitd 明确记录：

```text
Incomming connection, entitled 0
Hello FSClient! entitlement no
NSXPCDecoder: received a message or reply block that is not in the interface
mountVolume:fileSystem:displayName:provider:domainError:on:how:options:reply:
```

也就是说：

```text
/sbin/mount
  ↓ 没有 com.apple.private.LiveFS.connection
fskitd: entitled 0
  ↓
只暴露 LiveFSMounterUnentitled
  ↓ 该 interface 只有 switchToFSKit:
/sbin/mount 仍发送 mountVolume:...
  ↓
NSXPCDecoder 拒绝
  ↓
RC=69
```

### 2.3 Disk Arbitration 为什么成功

`diskarbitrationd` 具备：

```text
com.apple.private.LiveFS.connection = true
com.apple.private.fskit.module-runner = true
```

其连接日志是：

```text
Incomming connection, entitled 1
Hello FSClient! entitlement yes
```

因此同一 FAT16 设备通过 Disk Arbitration 可以使用完整 `LiveFSMounter` 并成功完成 FSKit mount。

### 2.4 macFUSE 为什么同步中招

EDP 目前通过 libfuse + `MFMount.framework` 使用：

```text
backend=fskit
```

macFUSE 公开的 `MFMount.framework` / `Mounter.swift` 源码显示，FSKit mount service 最终仍有一阶段调用 system `mount(8)`；错误模型中明确存在：

```text
mountCommandFailed
```

源码注释也明确说明该错误来自：

```text
the mount(8) system command called by the mount service on behalf of the user
```

所以 macFUSE 5.3.3 的 FSKit backend 会继承 15.7.7 / 15.7.9 的 Apple `mount(8)` → LiveFS 回归。

---

## 3. 一个重要修正：不要把直接调用 FSKitDiskArbHelper 当作最终方案

已确认私有类：

```objc
FSKitDiskArbHelper
+ DAMountFSKitVolume:deviceName:mountPoint:volumeName:...
```

但普通 EDP / PoC 进程直接调用这个 framework helper，并不会自动继承 `diskarbitrationd` 的 private entitlement。

因此：

```text
EDP process
  ↓
FSKitDiskArbHelper
  ↓
FSClient / fskitd
```

仍然可能是 `entitled 0`。

真正的 Disk Arbitration workaround 必须让挂载请求实际进入 Apple 的 `diskarbitrationd` 进程，再由它执行 FSKit mount。

---

## 4. 当前仓库里已经存在的 PoC 基础

当前已有：

```text
tools/diagnostics/fskit_switch_poc.m
.github/workflows/fskit-switch-poc.yml
```

引入提交：

```text
67c26640ea91de1c72a7d19ab19e807526a3be2b
ci: run FSKit switch and helper PoC on macOS 15.7.7
```

注意：当前 `fskit_switch_poc.m` 主要完成：

1. 动态加载 FSKit / LiveFS；
2. 枚举 `LiveFSMounterUnentitled` / `LiveFSMounter` protocol 及 type encoding；
3. 枚举 `FSKitDiskArbHelper` class methods；
4. 建立 `FSClient` 基础对象并观察 extension；
5. 尝试直接 `FSKitDiskArbHelper` mount；
6. GitHub Actions 同时做 `/sbin/mount -F` 失败基线和 `diskutil mount` 成功对照，并抓 unified log。

**它目前还没有真正完成 `switchToFSKit:` handshake。** 下一阶段必须补这一部分，不能因为文件名叫 switch PoC 就误以为握手已验证。

---

## 5. 修复研究执行顺序

### P0 — 逆向 `LiveFSMounterUnentitled::switchToFSKit:`

这是当前最高优先级。

目标：确定 `switchToFSKit:` 的真实 ABI、调用对象、参数类型和调用后的连接状态。

GitHub Actions 应自动收集：

```text
protocol method type encoding
LiveFSMountClient instance/class method list
FSClient method list
selector references
nm / strings / otool / dyld info
LiveFS.framework 相关反汇编
调用前后 unified log
```

重点回答：

1. `switchToFSKit:` 参数究竟是什么对象；
2. 是否是 reply block / endpoint / proxy / state object；
3. 谁实际调用它；
4. 调用后是否更换 remote interface / XPC endpoint；
5. Apple 预期的合法 unentitled → FSKit handoff 流程是什么。

成功标准：完全确定 handshake 语义，不再猜 selector。

### P1 — Apple FAT16 最小 handshake PoC

继续使用 Apple 自带 FAT16，完全绕开 macFUSE 和 EDP。

实验：

```text
A. /sbin/mount -F
   → 预期 RC69，作为失败基线

B. 普通进程直接 mountVolume
   → 预期受 restricted interface 拒绝

C. 正确执行 switchToFSKit handshake
   → 再完成 mount
```

成功标准：

```text
macOS 15.7.7 / 15.7.9
不修改系统文件
不伪造 Apple private entitlement
不用 /sbin/mount -F 完成最后一步
FAT16 最终以 fskit 挂载成功
```

如果成功，说明找到了 Apple 新 contract 的正确兼容路径。

### P2 — 若 switchToFSKit 路线不可独立使用，则逆向真正的 Disk Arbitration broker

目标链路：

```text
PoC
  ↓ Disk Arbitration IPC
 disk arbitration daemon
  ↓ entitled 1
 FSKitDiskArbHelper
  ↓
 FSKit
```

关键问题不是 `diskutil mount` 本身，而是如何显式告诉 Disk Arbitration：

```text
filesystem short name = macfuse-local
```

因为 macFUSE local FSKit extension 当前：

```text
FSShortName = macfuse-local
FSSupportsBlockResources = 1
FSMediaTypes = {}
```

macFUSE 创建的虚拟 disk `Content` 为空，Disk Arbitration 无法像 FAT16 一样自动 probe 出 filesystem type。

需要研究：

```text
DADiskMount* / Disk Arbitration IPC
DAFileSystem kind
filesystem short name 如何传到 diskarbitrationd
最终如何进入 FSKitDiskArbHelper DAMountFSKitVolume
```

成功标准：从普通进程发起请求，但实际 mount 由 `diskarbitrationd` 的 entitled path 完成。

### P3 — macFUSE 独立 FSKit PoC

系统级 workaround 成功后，再进入 macFUSE。

不要先改 EDP。

使用最小 loopback/minfs：

```text
libfuse
  ↓
MFMount transport
  ↓
macFUSE virtual block device / macfuse-local
  ↓
替换掉最终 broken mount(8) 阶段
  ↓
FSKit mount
```

成功标准：

1. `mount` 输出明确含 `fskit`；
2. 真实读写工作；
3. 没有 fallback 到 kernel backend；
4. 15.7.7 / 15.7.9 均可行。

### P4 — 最后才集成 EDP

保留现有权限架构：

```text
root daemon
  ↓
root open /dev/rdiskN
  ↓
保留 raw disk FD
  ↓
launchctl asuser / bridge 降权
  ↓
libfuse / FSKit
```

不要为了 FSKit 把整个 bridge 改成 root；root 身份也不能替代 Apple private entitlement。

EDP 改动应限制在最终 mount path / compatibility layer，尽量不动加解密 I/O、session 和 raw-disk ownership 模型。

---

## 6. 产品侧临时策略

在纯 FSKit workaround 完成前，kernel backend fallback 仍是可靠保底。

可以考虑把现有“先等 FSKit 失败再 fallback”优化成能力检测：

```text
检测 LiveFSMounterUnentitled / 已知 broken contract
  ↓
若命中已知回归
  ↓
直接使用 kernel backend
```

但这属于产品体验优化，不是当前 P0 研究任务，不应抢占 `switchToFSKit:` PoC 优先级。

---

## 7. 明确不要重复的排查

以下已经完成，不要再浪费时间：

- 重装 macFUSE；
- 对比官方 macFUSE Core.pkg 完整性；
- PlugInKit / enabledModules / probeOrder 清理；
- fskit_agent / extensionkitservice cache 清理；
- 怀疑用户机器 OTA / SSV 损坏；
- iBoysoft / Paragon 是否是根因；
- Apple FAT16 是否能通过 FSKit 工作；
- Disk Arbitration 是否能成功；
- `/sbin/mount` 15.7.7 与 15.7.9 是否同一个二进制；
- 继续寻找更多 15.7.x 版本做版本枚举。

根因研究已从“环境排查”进入“Apple LiveFS contract compatibility / broker workaround”。

---

## 8. GitHub Actions 研究要求

研究 workflow 必须：

1. 独立于 EDP 产品构建；
2. 失败也上传 artifact；
3. 保存原始 runtime / disassembly / unified log；
4. 明确记录 `DIRECT_RC` / `DIRECT_MOUNTED` / PoC result / DA control；
5. 不把失败吞掉成没有证据的绿色 CI；
6. 不修改 runner 系统文件；
7. PoC 成功后再把实现迁移到产品代码。

建议后续拆为：

```text
fskit-switch-introspect.yml
fskit-switch-fat16-poc.yml
fskit-da-poc.yml
macfuse-fskit-workaround.yml
```

当前已有 `fskit-switch-poc.yml` 可继续迭代，也可以在证据明确后拆分。

---

## 9. 下一会话第一步

下一会话应先读取：

```text
docs/diagnostics/2026-08-25-fskit-handoff.md
docs/diagnostics/2026-08-25-fskit-recovery-plan.md
```

然后检查：

```text
tools/diagnostics/fskit_switch_poc.m
.github/workflows/fskit-switch-poc.yml
```

直接从 **P0：真正实现并验证 `switchToFSKit:` handshake** 继续。

如果 Mac 控制插件在新会话中可用，可以同时在用户 macOS 15.7.9 上跑相同独立 PoC；如果插件不可用，继续使用 GitHub Actions 15.7.7 做逆向和 PoC。

不要先修改 `crates/usbcore` 的产品路径。

---

## 10. 研究结束条件

只有达到以下之一，才认为本轮研究真正完成：

### 路线 A

```text
正确 switchToFSKit handshake
→ unentitled client 合法进入 FSKit mount path
→ FAT16 成功
→ macFUSE macfuse-local 成功
→ EDP FSKit 成功
```

### 路线 B

```text
switchToFSKit 不适合独立调用
→ 找到 Disk Arbitration 显式 filesystem broker path
→ diskarbitrationd entitled mount 成功
→ macfuse-local 成功
→ EDP FSKit 成功
```

在此之前，kernel backend 只是 fallback，不算 FSKit 问题已修复。
