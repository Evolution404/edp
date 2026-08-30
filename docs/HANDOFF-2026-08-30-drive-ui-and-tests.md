# EDP Drive 交接：UI 全量改造 + 无物理 U 盘自动回归套件（2026-08-30）

## 0. 给下一位 AI 的一句话

继续 `Evolution404/edp` 的 `codex/ui-macos26-liquid-glass` 分支，**不要新建 worktree**。代码基线是 `fd10092 fix(drive): require five-factor physical device identity`。接下来有两个独立大任务：

1. 按已审核方案完整重做 EDP Drive 主窗口与菜单栏 UI；
2. 建立不需要实际插 U 盘的完整自动化回归测试套件，尤其覆盖“物理 U 盘各种状态”的虚拟化测试。

严格按本文与两个计划文档执行，不要重新研究已经解决的 sidebar bug、五因素身份规则或旧版免密归属。

---

## 1. 仓库与分支

仓库：

```text
Evolution404/edp
```

当前工作目录：

```text
/Users/zhangyuxi/edp
```

目标分支：

```text
codex/ui-macos26-liquid-glass
```

交接时核心代码基线：

```text
fd10092 fix(drive): require five-factor physical device identity
```

关键此前提交：

```text
d537675 refactor(drive): remove obsolete ui shell and update ratchet
7361252 fix(drive): use native split view for smooth sidebar
027c918 fix(drive): smooth navigation and clean stale ui instances
4494bb2 fix(drive): unify navigation and deployment workflow
```

开始工作后第一步仍应：

```bash
git fetch origin
git status
git log -5 --oneline
```

以远端实际最新 HEAD 为准，不要假定本文 SHA 永远不变。

---

## 2. 必须先读的文档

按顺序：

```text
docs/HANDOFF-2026-08-30-drive-ui-and-tests.md
docs/PLAN-2026-08-30-drive-ui-redesign.md
docs/PLAN-2026-08-30-drive-regression-suite.md
docs/PROGRESS-2026-08-30-drive-ui-and-tests.md
docs/UI-MACOS26-LIQUID-GLASS.md
Apps/Drive/README.md
Apps/Drive/docs/FIRST-INSTALL-ACCEPTANCE.md
```

历史背景需要时再读：

```text
docs/HANDOFF-2026-08-29.md
docs/PLAN-2026-08-29-ui-and-copy-performance.md
Apps/Drive/docs/diagnostics/2026-08-29-edp-metadata-public-research.md
```

---

## 3. 产品硬约束

### 3.1 平台

- macOS 26+；
- 原生 SwiftUI + AppKit；
- 不恢复 Tauri/WebView；
- macFUSE Local + DiskImages2 + Apple native filesystem；
- 单 App：`/Applications/EDP Drive.app`；
- embedded privileged service：`com.edp.drive.service`。

### 3.2 不要恢复的旧路径

禁止重新引入：

- FUSE-T；
- ntfs-3g production path；
- macFUSE kernel backend；
- DriverKit 自研块设备；
- Tauri/Rust UI；
- 单独 Raw Access GUI app；
- 每次插盘 sudo/admin 授权；
- 依赖固定 `/dev/diskN` 身份。

### 3.3 真实盘安全

除非用户明确要求 real-hardware acceptance：

- 不写真实 raw sector；
- 不格式化真实盘；
- 不擦除分区；
- 不把真实密码写入聊天、脚本、环境变量、仓库。

新自动化测试默认必须完全不使用真实 U 盘。

---

## 4. 当前已经解决、禁止重复研究的问题

### 4.1 Sidebar `»` 与弹簧动画

用户曾反复看到：

- sidebar 展开时 toolbar 出现 `»`；
- detail 先整体向右移动，再反弹；
- 自定义按钮曾出现蓝色 focus ring。

已经通过 Apple 官方 Instruments、AppKit 原型和逐帧 geometry 确认：

- SwiftUI `NavigationSplitView` 在 macOS 26 的 hosting/layout 动画是问题来源；
- 不是性能 hitch；
- 不是 Picker；
- 不是窗口单纯太窄；
- 不是把 sidebar 改到 220 就能修。

最终修复：

```text
EDPNativeSplitViewController : NSSplitViewController
```

sidebar/detail 使用两个 `NSHostingController`。

关键行为：

```swift
minimumThicknessForInlineSidebars = 0
sidebarItem.canCollapseFromWindowResize = false
sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
```

验收过的 900px 展开序列单调：

```text
sidebar: 5 -> 13 -> 25 -> ... -> 188
detail x: 同步
detail width: 895 -> ... -> 712
split width: 始终 900
```

Instruments：

```text
hitches = 0
hitches-updates = 0
```

focus ring 最终通过：

```swift
.focusEffectDisabled()
```

**不要把主容器改回 `NavigationSplitView`。**

### 4.2 菜单栏级联菜单问题

以前多级 AppKit Menu 横向移动鼠标容易意外关闭。当前使用：

```swift
.menuBarExtraStyle(.window)
```

后续 UI 要继续做 window-style Mini Control Center，不要改回 `.menu` / `Menu(...)` 级联。

---

## 5. 当前严格设备身份规则

最新提交 `fd10092` 已把设备身份收紧为五因素：

```text
VID
+ PID
+ LBA4 onlyId
+ whole-device capacity
+ LBA11 deviceId
```

**只有五项全部一致才认定同一个设备。**

### 5.1 LBA4 onlyId

格式：

```text
$$$<纯数字>$$$
```

生产 parser：

```text
EDPMetadataProbe.lba4OnlyID(...)
```

非数字、缺失、UInt64 overflow 都无效。

真实 fixture：

```text
disk4 onlyId = 3164177653
disk5 onlyId = 2387350191
```

### 5.2 Stable physical ID

当前版本：

```text
EDP-PHYSICAL-ID-V3
```

`stablePhysicalDeviceID(...)` 现在明确包含：

- normalized VID；
- normalized PID；
- labelOnlyID；
- sizeBytes；
- metadataDeviceID。

### 5.3 不兼容旧身份

用户明确要求：**不要考虑现有盘记录兼容性。**

因此已经删除：

```text
EDPDevicePolicyStore.migrateDeviceID
EDPCredentialStore.migrateDeviceID
runtime 自动 legacy ID migration
```

新身份不继承旧：

- display name；
- auto-mount；
- Keychain credential。

不要恢复 migration。

### 5.4 UI model

`EDPXPCDevice` 已暴露：

```swift
metadataDeviceID: String?
labelOnlyID: UInt64?
```

新 UI 应显示它们。

---

## 6. 介质分类规则

当前 `EDPMetadataProbe.MediaKind`：

```text
standardEncrypted
legacyNoPassword
currentNoPassword
unrecognizedEDP
ordinaryUSB
```

只有：

```text
standardEncrypted
```

进入 Drive 的 raw access / credential / mount 链。

其他全部直接由 macOS / Disk Arbitration / Finder 接管。

特别注意：不要再得出“LBA12 entry0 type=2 就能区分原盘/旧盘”之类结论。当前分类器已经基于 LBA0/LBA4/LBA7/LBA11/LBA12 多证据和 geometry。

---

## 7. 大任务 A：UI 全量改造

完整规范：

```text
docs/PLAN-2026-08-30-drive-ui-redesign.md
```

### 7.1 用户已经审核通过的总体方向

- 整体效果图风格认可；
- 认为最初 6 个一级 sidebar 过多，有重复；
- 最终 sidebar 要收敛为 4 项：

```text
总览
设备
活动
设置
```

- “挂载”“安全”放到设备页内部；
- 设备内部：

```text
概览 | 分区 | 安全
```

- 菜单栏重新设计成 Liquid Glass Mini Control Center；
- 整体要“高大上”，但不是网页式玻璃卡片墙。

### 7.2 主要页面

总览：

- device hero；
- service/FDA/macFUSE/auto-mount 状态；
- 分区结构；
- 快捷操作；
- 最近活动。

设备/概览：

- name/media；
- VID/PID；
- LBA4 onlyId；
- LBA11 deviceId；
- capacity；
- BSD name；
- stable internal ID；
- eject/delete record。

设备/分区：

- 三个 compact partition panel；
- auto mount；
- mount/unmount；
- Finder；
- filesystem/readOnly；
- error；
- credential secondary actions。

设备/安全：

- type 2/type 4 credential；
- update/delete；
- global integration status 只读/跳设置。

活动：时间线 + 筛选。

设置：常规/系统集成/后台服务/高级。

菜单栏：service + current devices + partition controls + auto mount + footer。

### 7.3 UI 必须保持的功能

详见 UI plan 的“全功能映射检查表”。不得为了视觉删除任何已存在功能。

### 7.4 UI 实施纪律

每阶段独立 commit：

```text
UI-A 信息架构
UI-B 总览
UI-C 设备三子页
UI-D 活动/设置
UI-E 菜单栏
UI-F accessibility/performance
UI-G CI/final acceptance
```

每阶段 Swift 6 warnings-as-errors。

不要一次性 1500 行改完后才编译。

---

## 8. 大任务 B：完整自动回归套件

完整规范：

```text
docs/PLAN-2026-08-30-drive-regression-suite.md
```

### 8.1 最重要的用户要求

必须研究并建立：

> 各种“物理 U 盘状态”的自动化测试，但**不需要用户实际插 U 盘**。

不能满足于 parser 单元测试。

### 8.2 总体方案

两条自动路径组合：

#### A. Virtual Physical USB Lifecycle

用 production dependency injection 模拟：

```text
IOKit media inventory
raw metadata source
insert/remove/reinsert
bsdName/diskN change
same diskN replacement
registry ID change
short read/EIO/detach
multi-device
```

测试 production discovery/runtime state machine。

#### B. Sparse Image Storage E2E

复用现有：

```text
PrepareEDPFilesystemFixture.swift
DirectMFMountEDPFixtureAdapter.c
macFUSE Local
DiskImages2
Apple native filesystem
```

测试真实 crypto + block translation + filesystem 行为。

两者结合后，绝大多数“真实盘才能测”的回归可以在无盘 CI 里发现。

### 8.3 不能用的偷懒方案

不接受只：

- mock 最终 `EDPXPCSnapshot`；
- mock classifier 返回值；
- 写一个假 mount manager 永远 success；
- 只测试 UI；
- 只用 `diskutil list` fixture 文本；
- 只验证 disk4/disk5 两份固定 metadata。

必须有 lifecycle + fault injection。

---

## 9. 现有测试资产不要重复造轮子

必须复用：

```text
Apps/Drive/fixtures/real_disks/disk4
Apps/Drive/fixtures/real_disks/disk5
Apps/Drive/fixtures/golden/disks.json
Apps/Drive/native/EDPFSKitPoC/Tools/PrepareEDPFilesystemFixture.swift
Apps/Drive/native/EDPFSKitPoC/Tools/MacFUSEMinimal/DirectMFMountEDPFixtureAdapter.c
Apps/Drive/native/EDPFSKitPoC/Tools/probe-edp-crypto-diskimages2-readwrite.sh
```

已有 real metadata fixture 是以后 mutation testing 的真实基线。

---

## 10. 建议执行顺序

两项任务可以在同一分支串行推进，但 commit 必须清晰分离。

推荐：

### 第 1 阶段：测试 TEST-A / TEST-B

先统一测试 runner、身份/classifier matrix。

理由：风险低，可以在 UI 改造前强化基础回归。

### 第 2 阶段：UI-A ~ UI-E

实现已审核 UI，不改 core runtime。

### 第 3 阶段：TEST-C ~ TEST-F

引入 production dependency seam、virtual USB、storage E2E。

这是对 runtime 侵入最大的阶段，需要 UI 已稳定后单独审查。

### 第 4 阶段：UI-F / TEST-G

把 UI automation/Instruments 纳入测试体系。

### 第 5 阶段：TEST-H / UI-G

CI job 拆分，exact-head 全绿，最终用户视觉验收。

如果下一位 AI 更擅长测试，也可以先完成全部 TEST-A~F 再做 UI；但不要在一个 commit 同时重构 UI 和 device discovery dependency injection。

---

## 11. Git/提交纪律

- 不创建 worktree；
- 开始先 fetch；
- 每个 Phase 独立 commit；
- 每阶段 push；
- 实时更新：

```text
docs/PROGRESS-2026-08-30-drive-ui-and-tests.md
```

建议 commit message：

```text
test(drive): unify regression suite entrypoints
test(drive): add strict physical identity matrix
refactor(drive): inject physical media discovery dependencies
test(drive): simulate physical usb lifecycle failures
test(drive): automate sparse-image storage lifecycle
feat(drive): establish redesigned information architecture
feat(drive): build liquid glass overview workspace
feat(drive): redesign device partition and security views
feat(drive): redesign activity and settings surfaces
feat(drive): redesign menu bar control center
test(drive): automate redesigned ui states
ci(drive): split regression and storage gates
```

---

## 12. 本机开发工具链

已经修正：

```text
xcode-select -p
/Applications/Xcode.app/Contents/Developer
```

当前完整 Xcode：

```text
Xcode 26.6 (17F113)
```

可直接使用：

```text
xcodebuild
xcrun
xctrace
Instruments
```

UI 动画问题请优先用 Apple 官方：

- View Debugger；
- SwiftUI Instruments；
- Animation Hitches。

不要重新回到大量私有类/LLDB 猜测式调试，除非官方工具无法定位。

---

## 13. 当前 CI

当前主要 workflow：

```text
.github/workflows/core.yml
.github/workflows/drive.yml
.github/workflows/studio.yml
```

Drive workflow 已有很多 grep ratchet。后续测试改造要减少“只靠 grep 证明行为”，把关键行为迁移到真正 executable regression。

不要删除仍有价值的 safety/architecture ratchet。

---

## 14. 最终双任务验收

### UI 完成

必须满足 `PLAN-2026-08-30-drive-ui-redesign.md` 第 17 节全部验收。

特别是：

- 4 一级模块；
- 设备 3 子页；
- menu bar Mini Control Center；
- 900px sidebar 无箭头/无弹簧；
- Instruments hitches=0；
- Light/Dark；
- 所有旧功能不丢。

### Test 完成

必须满足 `PLAN-2026-08-30-drive-regression-suite.md` 第 19 节全部验收。

最关键：

```text
make drive-test-all
```

应在**没有任何物理 U 盘**时完成核心回归；不得要求用户插盘。

并自动证明：

- five-factor identity；
- same-model different onlyId；
- diskN change same device；
- diskN reuse different device；
- detach/race/EIO/short read；
- multiple devices；
- credential isolation；
- mount/unmount/remount；
- encrypted RW persistence；
- failure propagation；
- UI states。

---

## 15. 什么时候才需要用户

正常开发绝大多数时间**不要让用户手动测试**。

只有以下阶段才需要：

1. UI 完成后的最终视觉审核；
2. signed installer / FDA 的真实系统交互；
3. 最终 release hardware qualification（如果用户决定执行）。

sidebar/UI 动画等问题应先自己通过 preview + Instruments + automation 验证，再请用户看最终视觉。

---

## 16. 交接完成状态

本次交接没有继续实现新 UI，也没有开始侵入式 test seam refactor。

已完成：

- sidebar 原生动画修复已经提交；
- UI 冗余壳清理已经提交；
- five-factor physical identity 已提交；
- LBA4 onlyId 已进入 recognition/stable ID/raw-FD revalidation/XPC snapshot；
- legacy device-ID 自动迁移已删除；
- 两项大任务计划已经明确；
- 工作应从 progress tracker 的未完成 Phase 开始。

不要把聊天里之前失败的实验（toolbar priority、fixed 180、fixed 220、columnVisibility、NavigationSplitView spring 等）重新带回正式代码。
