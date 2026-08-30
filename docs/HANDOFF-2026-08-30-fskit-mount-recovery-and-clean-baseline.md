# EDP Drive 交接：FSKit 挂载恢复、首次安装基线与剩余 TEST-H

日期：2026-08-30

## 1. 接手位置

- 仓库：`/Users/zhangyuxi/edp`
- 分支：`codex/ui-macos26-liquid-glass`
- 使用当前 checkout，**不要创建 worktree**。
- 当前产品代码基线 HEAD（不含本交接文档自身的 docs-only 提交）：
  - `56567fc30cf00408cdae336ecf0ac1243acfeaea`
  - `56567fc chore(drive): add deterministic environment cleanup`
- 远端 `origin/codex/ui-macos26-liquid-glass` 已包含该产品代码基线。

关键已提交基线：

- `56567fc`：Makefile + `Tools/drive-environment.sh`，可确定性检查/清理 EDP Drive + macFUSE 环境。
- `297d672`：拆分硬件无关 release gates。
- `299f7e0`：新设备默认策略、默认密码探测、菜单栏密码入口、diskN 复用安全修复、teardown hardening。
- `2379870`：macOS UI acceptance automation。

## 2. 非常重要：当前工作区有未提交 WIP，禁止 reset

当前 dirty 文件：

```text
 M .github/workflows/drive.yml
 M Apps/Drive/Tests/UI/ValidateUIAutomation.swift
 M Apps/Drive/Tests/VirtualUSB/ValidateCredentialPolicyServiceLifecycle.swift
 M Apps/Drive/Tests/run-service-lifecycle.sh
 M Apps/Drive/Tests/run-storage.sh
 M Apps/Drive/Tests/run-system.sh
 M Apps/Drive/installer/scripts/native-preinstall
 M Apps/Drive/product/EDPTransportProvider.swift
 M Apps/Drive/product/EDPVaultRuntime.swift
 M Tools/drive-environment.sh
```

**不要 `git reset --hard`、不要 checkout 覆盖、不要丢弃这些修改。**

这些 WIP 分成四组：

### A. 当前最高优先级：交换区挂载卡 20 秒的 FSKit 自动恢复

`Apps/Drive/product/EDPVaultRuntime.swift`：

- 原来 hidden macFUSE Local bridge 激活固定等待 20 秒：

```swift
waitUntil(seconds: 20) {
    EDPNativeMountTable.isMountpoint(bridgeMount) || !transportSession.isRunning
}
```

- 实机故障时 transport 仍活着、bridge 没出现，所以用户每次点击“挂载交换区”会白等满 20 秒，最终：

```text
operation timed out after 20 seconds
```

- 已将 bridge 激活窗口缩为 8 秒，并新增：
  - `EDPFSKitMountRecoveryPolicy.shouldRecoverBridgeActivation(...)`
  - 只把以下情况判为 FSKit bridge activation 可恢复故障：
    - timed out + transport still running + bridge not mounted；
    - log 包含 `mount(8) returned 69`；
    - log 包含 `File system extension not found`。
  - 密码错误、DiskImages2 错误等**不得触发** FSKit host recovery。
  - recover 前仍遵循现有安全条件：全系统没有其他 FSKit mount 时，才允许重启当前 console user 的 `fskit_agent`。
  - 一次 mount 请求最多自动恢复并重试 **1 次**，禁止无限重试。

`Apps/Drive/product/EDPTransportProvider.swift`：

- `EDPTransportSession.stop(...)` WIP 改为返回 `Bool`，表示 teardown 过程中是否已经执行了 `recoverStuckProcess`。
- 目的：避免 transport.stop 已经重启了一次 `fskit_agent` 后，外层 mount catch 又重复重启一次。
- 当前 source 已实现：外层使用 `stopRecoveredHost || restartConsoleAgentIfSafe()`。

### B. 新增 S11 回归

`Apps/Drive/Tests/VirtualUSB/ValidateCredentialPolicyServiceLifecycle.swift`：

新增：

```text
SCENARIO=S11_OK fskit_bridge_recovery_classifier_is_narrow
```

覆盖：

- timeout/live transport -> recoverable；
- `mount(8)=69` -> recoverable；
- `File system extension not found` -> recoverable；
- password validation failure -> NOT recoverable；
- DiskImages2 failure -> NOT recoverable；
- bridge 已经 mounted -> NOT recoverable。

`run-service-lifecycle.sh` 已要求 S01–S11 全部出现。

### C. 首次安装/环境清理继续收口

`Tools/drive-environment.sh` 当前 WIP 在已提交 `56567fc` 基础上又补了：

- `/var/db/com.edp.drive`
- `/var/db/com.edp.usbvault`
- 当前用户 `com.edp.drive` / 旧 Vault UserDefaults
- 清理前停止仍驻留内存的 `EDP Drive` / `EDP USB Vault` 前台进程

这是必须保留的修复。

原因：此前 `make drive-clean-environment` 虽然删除 App/runtime/macFUSE，但遗漏 `/var/db/com.edp.drive/device-policies.json`，导致“全新安装、无 U 盘”时 snapshot 仍凭空出现旧 Lexar，甚至继承旧 `type2 autoMount=true`。

补修后已实际验证真正首次安装：

```text
SNAPSHOT_DEVICE_COUNT=0
RESULT=PRIVILEGED_XPC_SNAPSHOT_OK
```

注意：

```text
SNAPSHOT_GLOBAL_AUTOMOUNT=true
```

这是全局“允许自动挂载”的 master enable，并不表示新设备会自动挂载。三种分区的新设备默认策略仍是 `autoMount=false`；只有用户自己为某类/某设备开启 auto mount 后才会挂载。

### D. TEST-H / installer / storage WIP

仍有以下未提交改动：

- `.github/workflows/drive.yml`
  - 菜单栏后台服务 ratchet 已适配新的 icon-only service controls；
- `Apps/Drive/Tests/UI/ValidateUIAutomation.swift`
  - 900×680 geometry 改用 `contentView.bounds`，避免 `contentLayoutRect` 因 toolbar/titlebar 产生错误波动；
- `Apps/Drive/Tests/run-storage.sh`
  - fixture creation 与 product DiskImages2 publication 分离；
  - destructive fixture formatting 前严格验证 backing path 位于当前 WORK_DIR + `Virtual: Yes`；
  - 增加 fixture device 独立 cleanup；
  - 目标是消除 storage test 因 DiskImages2 publication readiness / stale device 导致的回归；
- `Apps/Drive/installer/scripts/native-preinstall`
  - full in-place upgrade 前先停止旧 foreground `EDP Drive`；
  - 原因：替换 App bundle 后，仍在内存执行的旧 UI 会因 code-signing identity 与新 bundle 不一致而被新 service 的 XPC peer validation 拒绝；
- `Apps/Drive/Tests/run-system.sh`
  - 新增上述 upgrade UI handoff ratchet。

这些都还没最终收口，不要与 A/B 的 FSKit mount recovery 混为“已完成”。

## 3. 最新故障的完整根因

用户报告：当前盘“交换区无法挂载，挂载超时 20 秒”。

实机复现：

```text
operation timed out after 20 seconds
```

对应代码位置是 `MountManager.mount()` 等待 hidden bridge：

```text
raw fd / password
  -> edp-console-exec
  -> edp-mfmount-local-readwrite
  -> MFMount macFUSE Local
  -> 等待 /Volumes/.edp-block-... 成为 FSKit mount
```

故障时：

- `edp-mfmount-local-readwrite` 没有及时退出；
- `.edp-block-*` 也没有形成 mount；
- 因此旧代码等满 20 秒；
- 历史日志也有明确：

```text
MFMount: Failed to mount volume: mount(8) returned 69
File system extension not found
```

人工实证过：当系统没有任何其他 FSKit mount 时，仅重建当前用户 `fskit_agent`，随后同一 Lexar type2 可以成功：

```text
XPC_MOUNT_SMOKE_DETAIL=mount completed
RESULT=XPC_MOUNT_SMOKE_OK
filesystem=ExFAT
readOnly=false
mountPoint=/Volumes/交换区
```

所以当前 WIP 的正确目标不是延长超时，而是“快速识别 stale FSKit host -> 安全恢复 -> 单次重试”。

## 4. 之前已经解决、不要重复研究的问题

### 4.1 diskN 复用导致错误 eject

曾发生：旧 synthetic session 记住 `disk31`，synthetic node 消失后，macOS 把 `disk31` 重新分配给真实 Lexar。旧代码仅按 BSD name teardown，有误操作物理盘风险。

`299f7e0` 已修：DiskImages2 publication teardown 以精确 backing `volume.raw` + DiskImages2 owner identity 为准，**不再信任 persisted diskN**。

回归：

```text
SCENARIO=D13_OK stale_diskn_reuse_never_ejects_without_backing_identity
```

### 4.2 启动区无法挂载

根因：`edp-console-exec` allowlist 漏 `edp-mfmount-local-readonly`。

已修并实机验证两块盘 FAT16 read-only。

### 4.3 `autoMount=false` 错误卸掉手动挂载

已修：关闭 auto mount 仅表示“不自动挂”，绝不能主动卸载用户手动挂载的分区。

回归：

```text
D10 manual_mount_survives_reconcile_when_auto_mount_off
```

### 4.4 停止后台服务失败 / DiskImages2 orphan

已做严格 fail-closed recovery：

- backing path 精确绑定当前 session；
- owner UID / device node / `_diskimagesiod` PID 二次校验；
- `system-entities=[]` orphan 才可处理；
- stale transport 只有系统 0 FSKit mounts 时才能重启当前 user `fskit_agent`。

此前实机已经验证：启动区挂载后 graceful stop，service / transport / hidden mount / DiskImages2 publication 都 0 残留。

### 4.5 默认配置

`299f7e0` 已完成：

- 启动区 / 交换区 / 保密区三类独立默认策略；
- 三类默认 `autoMount=false`；
- type2/type4 独立 `autoProbePassword`；
- 默认探测密码初始 `0000aaaa`；
- 默认密码只进 System Keychain；
- 新设备首次 observe 时复制当前 default；已有设备不被后续 defaults 回写；
- 自动探测与自动挂载解耦；
- 菜单栏加密分区有钥匙 icon，可直接设置密码。

D01–D13 已覆盖边界。

### 4.6 菜单栏后台服务 UI

用户已要求并实现：

- 不要大卡片；
- 放顶部；
- 单行紧凑；
- 一个状态图标 + `▶` / `■` / `↻` 三个 icon；
- 顶部继续显示 App/服务状态。

不要恢复旧 `EDPMenuServiceButton` 大卡片。

## 5. `make drive-clean-environment` 已成为正式入口

已提交 Make targets：

```bash
make drive-env-status
make drive-clean-environment
```

目标：以后不要临时拼环境清理命令。

清理范围包括：

- EDP Drive.app / 旧 EDP USB Vault.app；
- daemon / launchd / runtime；
- System Keychain EDP Drive partition/default-probe passwords；
- EDP Drive TCC/FDA/removable-volume records；
- `/var/db/com.edp.drive` 与 legacy `/var/db/com.edp.usbvault`（当前 dirty WIP 新增，尚未提交）；
- official app UserDefaults（当前 dirty WIP 新增）；
- macFUSE 官方卸载；
- macFUSE framework / prefPane / helper / receipt；
- pluginkit macFUSE Generic + Local；
- user FSKit enabledModules 中仅删除 macFUSE 两项，保留 Apple modules；
- strict 4 KiB macFUSE scratch；
- 标准 EDP test images（例如 `edp-storage-e2e.*`）。

明确不要碰：

- 项目源码 `/Users/zhangyuxi/edp`；
- Git；
- `com.edp.studio.rawbroker`；
- `com.evolution404.edpopen.rawbroker.poc` 等另一项目组件。

## 6. 当前 Mac 实际状态（交接时）

时间约 2026-08-30 20:36 +08。

### 6.1 外接物理盘

当前：**没有外接 physical USB**。

```text
diskutil list external physical
# 空
```

因此现在适合做无盘测试/清理，不要假定真实盘在。

### 6.2 当前已安装环境

已经从真正 clean baseline 重新安装：

- macFUSE 5.3.3；
- EDP Drive 0.6.0 Native；
- macFUSE Generic + Local FSKit modules 已注册且 enabledModules 中启用。

当前 `pluginkit` 已确认：

```text
+ io.macfuse.app.fsmodule.macfuse-local
+ io.macfuse.app.fsmodule.macfuse
```

当前 enabledModules：

```text
com.apple.fskit.apfs
com.apple.fskit.exfat
com.apple.fskit.msdos
com.apple.filesystems.util.ntfs
com.apple.fskit.ftp
io.macfuse.app.fsmodule.macfuse
io.macfuse.app.fsmodule.macfuse-local
```

当前运行：

```text
EDP Drive foreground PID 4273
edp-drive-service PID 4984
```

当前 installed binary SHA256：

```text
EDP Drive:
32edbf5879da05068fc6c62dd05d4a9b926d62562be4a233420bc754fc3069ea

edp-drive-service:
81e873f70d13b1e1942a05351816c6ee0aa189cb4574ea03e0bdbc3d71d8e5d6
```

### 6.3 首次安装无盘验收

在补齐 `/var/db` 清理后，已验证：

```text
SNAPSHOT_SERVICE_VERSION=0.6.0
SNAPSHOT_DEVICE_COUNT=0
SNAPSHOT_GLOBAL_AUTOMOUNT=true
RESULT=PRIVILEGED_XPC_SNAPSHOT_OK
```

这证明旧设备 policy 没再带回来。

### 6.4 当前有一个 TEST-F synthetic image 残留

当前 `hdiutil info` 仍有：

```text
/private/var/folders/.../T/edp-storage-e2e.mVC2qC/boot-fat16.raw
/dev/disk6
DiskImages2=true
Virtual synthetic test image
```

它不是物理盘。

在做下一次“真正 clean baseline”前，用：

```bash
make drive-clean-environment
```

即可让清理脚本按 backing signature 处理标准 EDP test image；注意这个 target 也会卸载 EDP Drive 和 macFUSE，所以如果只为了继续 source-level tests，不需要立刻清。

## 7. 非常重要：当前 installed App 不是最新 dirty source

当前安装包是在最后一轮以下修改**之前**构建安装的：

- `EDPTransportSession.stop()` 返回是否已经恢复 host；
- `EDPFSKitMountRecoveryPolicy` 窄分类器；
- S11 classifier regression；
- environment cleanup 的 `/var/db` / defaults / foreground process 补丁。

因此：

> **不要用当前已安装 App 的行为作为上述最新 WIP 的最终验收。**

接手后必须先完成 source-level gates，再重新 `make drive-installer` 并安装最新包，才能做真实盘验证。

## 8. 当前最新快速测试状态

在当前 dirty source 上，刚刚通过：

```text
make drive-check                                  PASS
Apps/Drive/Tests/run-service-lifecycle.sh         PASS
bash -n Tools/drive-environment.sh                PASS
bash -n Apps/Drive/installer/scripts/native-preinstall PASS
git diff --check                                  PASS
RESULT=HANDOFF_FAST_GATES_OK
```

service lifecycle：

```text
C01-C08 PASS
D01-D13 PASS
S01-S11 PASS
M11 PASS
RESULT=DRIVE_CREDENTIAL_POLICY_SERVICE_OK
RESULT=DRIVE_SERVICE_LIFECYCLE_OK
```

注意：**最新 dirty source 尚未重新跑完整 `drive-test-virtual-usb / drive-test-storage / drive-test-ui / drive-test-system / drive-test-all`。**

## 9. 下一步执行顺序（严格按此推进）

### Phase 1 — 收口 mount recovery，不要先碰真实盘

1. 审查当前 `EDPTransportSession.stop() -> Bool` 设计是否所有 call site 都兼容。
2. 审查 `EDPFSKitMountRecoveryPolicy`，确保只覆盖 hidden bridge activation：
   - timeout/live transport；
   - mount69；
   - FS extension missing。
3. 确认 password / DiskImages2 / ExFAT / FAT/NTFS mount failure 不会重启 `fskit_agent`。
4. 确认一次用户 mount 请求：
   - 最多 restart agent 1 次；
   - 最多 retry mount 1 次；
   - retry failure 原样返回，不无限循环。
5. 保持安全 guard：有任何其他 FSKit mount 时禁止 agent recovery。

### Phase 2 — 完整硬件无关 gate

至少跑：

```bash
make drive-test-fast
make drive-test-virtual-usb
make drive-test-system
make drive-test-ui
```

然后重点处理 `drive-test-storage`：

- 当前 `run-storage.sh` 是 dirty WIP；
- fixture formatting 必须只操作 WORK_DIR backing + Virtual Yes；
- **绝不允许 physical `/dev/diskN` 进入 eraseVolume**；
- 连续至少 2 次 M01–M14；
- 每次后检查 synthetic / FSKit / transport 0 残留；
- 再跑 `make drive-test-all`。

### Phase 3 — 构建并重装最新 dirty source

在无真实 U 盘状态下：

1. 如需重新建立首次安装基线：

```bash
make drive-clean-environment
```

2. 安装固定 macFUSE 5.3.3，必须校验：

```text
SHA256=7a0b7b66c0e7f8932707d1215dc9cf486e178d097ae0a2dcdf17d8530566aa15
```

3. 注册/启用 Generic + Local FSKit；
4. `make drive-installer`；
5. 安装最新版；
6. 无盘 snapshot 必须：

```text
DEVICE_COUNT=0
```

### Phase 4 — 真实 U 盘最终验收

用户插入真实标准 EDP 盘后再做，不要提前猜 diskN。

必须重新读取当前 identity：VID + PID + LBA4 numeric onlyId + whole capacity + LBA11 metadataDeviceID。

重点验证 Lexar type2：

```text
点击挂载交换区
-> 不应再卡 20 秒
-> hidden bridge 成功
-> DiskImages2 publication 成功
-> ExFAT RW
-> Finder /Volumes/交换区
```

然后：

```text
卸载交换区
-> XPC_UNMOUNT_SMOKE_OK
-> user volume 0
-> .edp-block-* 0
-> DiskImages2 publication 0
-> edp-mfmount-local-readwrite 0
-> 真实 physical disk 仍在，Virtual: No
```

至少重复挂载/卸载 5 次，观察是否再次出现 mount69 或 stale agent。如果人为制造 stale agent 验证 recovery，**只能在确认系统无其他 FSKit mount 时做**。

绝对不要：

- format/erase 真实 U 盘；
- 对真实 `/dev/rdisk*` 做测试写入；
- 用 diskN 名称作为长期 identity；
- 为了“绿”而放宽 fail-closed guard。

### Phase 5 — 收口 TEST-H / 提交

当前 WIP 应按逻辑拆 commit，不要全揉成一个：

建议：

1. `fix(drive): recover stalled fskit bridge activation`
   - EDPTransportProvider
   - EDPVaultRuntime
   - S11 / lifecycle tests
2. `test(drive): harden clean install and storage fixtures`
   - drive-environment WIP
   - run-storage
   - native-preinstall + system ratchet
3. `test(drive): align ui and ci acceptance ratchets`
   - UI automation
   - workflow

每个 commit 后 push，并检查 exact HEAD CI。

## 10. UI / 产品约束不要回退

- macOS 26+ native SwiftUI + AppKit；
- 不回 Tauri/WebView；
- sidebar 是 native `NSSplitViewController`，必须保留原生 collapse/expand animation；
- sidebar 固定导航：总览 / 设备 / 活动 / 设置；
- overview 多设备必须全部显示，不能只显示 primary device；
- 菜单栏 `.menuBarExtraStyle(.window)`；
- 后台服务控制是一行紧凑 icon，不恢复大卡片；
- 加密区菜单栏有直接密码设置入口；
- 三类新设备默认 autoMount 都是 false；
- `0000aaaa` 是默认探测密码，但只存 Keychain；
- 自动探测密码 != 自动挂载。

## 11. 身份与安全不变量

同一物理盘严格由五因素共同决定：

```text
VID
PID
LBA4 numeric onlyId
whole-device capacity
LBA11 metadataDeviceID
```

stable identity：`EDP-PHYSICAL-ID-V3`。

只有 `standardEncrypted` 才由 EDP Drive 接管；其他盘让系统接管。

任何 synthetic cleanup 都必须有精确 backing / owner / Virtual identity；不得用“diskN 看起来像测试盘”作为依据。

## 12. 建议接手后的第一条命令

```bash
cd /Users/zhangyuxi/edp
git status --short --branch
git rev-parse HEAD
git diff --check
```

然后完整阅读本文件，**不要先 reset、不要先插盘测试、不要重复已经完成的 diskN / DiskImages2 根因研究。**
