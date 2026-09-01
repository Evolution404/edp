# EDP Drive 稳定化、结构收口与发布准备计划

日期：2026-09-01
分支：`codex/ui-macos26-liquid-glass`
计划基线：`3463295b1e6f86a315075732543ef3f53c510d18`
实时跟踪：`docs/PROGRESS-2026-09-01-drive-stabilization-and-release.md`

## 1. 目标

在真实 EDP 盘 raw access、三分区 capability-aware mount/unmount、safe eject、FDA retention 已完成收口的基础上，把 EDP Drive 从“核心链路可用且已验证”推进到“UI 性能稳定、代码职责清晰、发布门槛明确、风险可观测、文档无历史污染”的维护态。

本计划严格按以下顺序推进：

1. 先解决当前唯一明确失败的 UI sidebar 33 ms performance gate；
2. 再拆分过大的 runtime 与 App 文件，降低后续修改的耦合风险；
3. 再补发布级可靠性与 recovery 可观测性；
4. 再收口文档、测试矩阵和 release checklist；
5. 最后对 NTFS RW 做独立产品/架构决策，不把新文件系统能力混入已经稳定的生命周期代码。

## 2. 当前事实基线

### 2.1 已完成且本计划不得回退

- 标准加密 EDP 盘五因素身份：VID + PID + LBA4 onlyId + capacity + LBA11 metadataDeviceID。
- 仅 `standardEncrypted` 进入 Drive raw/password/mount pipeline；ordinary / legacyNoPassword / currentNoPassword / unrecognizedEDP 必须留给系统。
- 单用户 App `com.edp.drive` + embedded privileged service `com.edp.drive.service`。
- 不给 service 单独 Full Disk Access；single-App FDA retained raw access 已通过真实拔插验证。
- raw access EBUSY 代码路径：exact registry generation `force whole-unmount` 后只允许一次 raw retry；S31-S35 已锁定边界。
- Disk Arbitration physical eject 已绑定 exact generation；设备已消失时幂等成功；diskN replacement 保护、duplicate eject single-flight、shutdown 等待 in-flight eject 已覆盖。
- 真实 SanDisk：type1 FAT16 read-only；type2/type4 Apple NTFS read-only；三分区 capability-aware mount/unmount/remount 已通过。
- 产品 XPC safe eject 连续实机 PASS；`kDAReturnBadArgument/-119930877` 未再复现。
- safe eject 终态 EDP mount、`.edp-block-*`、transport residue=0；Finder/UVFS/service 无 U-state。
- `drive-test-fast`、`drive-test-virtual-usb`、`drive-test-system`、storage release gate 已建立。
- UI 功能、900×680 geometry、preview scenarios、accessibility 通过，但 sidebar animation 33 ms performance gate 当前失败。

### 2.2 当前已知未完成项

- exact-head `make drive-test-ui` 仍有 sidebar Animation Hitches >33 ms；2026-09-01 19:29 基线复跑：`UI_HITCH_MAX_MS=41.666`、`UI_HITCH_COUNT_GT33MS=1`，此前同一代码也出现过 66.666 ms / 2 帧，说明存在实际抖动而非固定单帧开销。
- `EDPVaultRuntime.swift` 约 5.4k 行，设备发现、raw access、policy、auto-mount、mount lifecycle、eject、shutdown、diagnostics 多职责集中。
- `EDPUSBVaultApp.swift` 约 3.8k 行，App shell、sidebar、页面、service control、XPC smoke/automation 等职责集中。
- 生产路径仍依赖 macFUSE Local、Private DiskImages2、`hdiutil`，App FSKit enablement 仍有 `pluginkit` 与明确 stale-recovery 下的 agent reset；这些必须继续 bounded/fail-closed，并增加可观测性。
- ordinary USB / legacyNoPassword / currentNoPassword / unrecognizedEDP 的物理负例矩阵未全部拥有实物证据。
- 最新代码发布前还应补 exact-head reboot gate。
- 旧 STATUS / tracker 中存在已完成但仍未勾选、以及被后续实现推翻的历史描述。
- NTFS RW 是否属于 EDP Drive 发布要求尚未形成正式 ADR；当前 Apple native NTFS 按只读能力如实呈现。

## 3. 不可破坏的硬约束

### 3.1 真实介质安全

- 绝不对真实 EDP U 盘执行格式化、分区、擦除、raw sector write 或 destructive fixture preparation。
- type1 永远不做 filesystem write acceptance。
- `readOnly=true` 的 type2/type4 只允许 mount/inspect/unmount/remount，不创建写 marker。
- 任何真实设备动作前重新枚举，不复用历史 `diskN`。
- 不触碰无关外接盘；特别是同时连接的 SN750 只能作为无关卷观察，不参与 EDP cleanup。

### 3.2 权限与身份

- 不给 `edp-drive-service` 单独 FDA。
- 不修改 TCC 数据库、AuthorizationDB、SIP 或 `/dev` 权限模型。
- 不恢复 authopen、Tauri、FUSE-T、ntfs-3g 或物理 `diskNs1` 依赖。
- 不读取、打印、传递用户分区密码；真实密码只通过 App UI 验证并保存到既有 Keychain 模型。

### 3.3 性能与测试门槛

- sidebar hitch 门槛固定为 33 ms；不得为“通过”而提高阈值、缩短测量窗口或减少 toggle 数量。
- UI 功能、geometry、accessibility 与视觉行为不得为了性能优化而退化。
- lifecycle deterministic tests、S01-S35、property model、system ratchets 不得削弱。
- storage release gate 不得通过减少资源 teardown 检查来换取稳定。

### 3.4 重构原则

- Phase B/C 首先是结构重构，不改变 production state-machine 语义。
- 每个抽取步骤必须可独立编译、测试和 commit；禁止一次性大爆炸重写。
- 新模块之间用窄 protocol / typed model 传递，不通过全局 singleton 或字符串 error 重新耦合。
- 保持 controller queue / lifecycle scheduler / completion once / generation ownership 语义。

## 4. Phase A — Sidebar 33 ms 性能收口

### 4.1 目标

把 `make drive-test-ui` 的 sidebar Animation Hitches gate 稳定修到：

- `UI_HITCH_COUNT_GT33MS=0`；
- 连续至少 3 次 exact-head 本机复跑均为 0；
- 900×680 sidebar 20 toggles geometry 全 PASS；
- preview/page rendering/accessibility 全 PASS；
- 不降低 33 ms 门槛。

### 4.2 定位步骤

1. 保留现有 `xctrace Animation Hitches` gate 作为最终权威。
2. 对 hitch-only runner 增加必要的 signpost/epoch，使 sidebar toggle、layout、detail refresh 能在 trace 中对齐。
3. 使用 Instruments/`xctrace` 导出 time-profile 或 SwiftUI/AppKit 相关表，定位 >33 ms 帧期间的主线程热点。
4. 分别验证以下候选：
   - `NSHostingController` live-resize layout / preferred-size feedback；
   - sidebar/detail SwiftUI tree 在每帧被重复重建；
   - `EDPWindowBackdrop` / glass material 合成与离屏渲染；
   - `@ObservedObject` snapshot refresh 在 toggle window 内触发无关页面刷新；
   - sidebar list selection/hover animation 与 split animation 叠加；
   - cold first-use shader/material/layout cost。
5. 优先消除无关工作，不关闭原生 sidebar 动画；若必须替换动画实现，仍需保持原生感、单调 geometry、无 overshoot/overflow。

### 4.3 允许的优化方向

- 缩小 sidebar 动画期间的 SwiftUI invalidation 范围；
- 缓存不随 toggle 变化的 detail/background 层；
- 把高成本 effect/material 从 live-resize subtree 移到固定容器；
- 避免同一 frame 中多重 `.animation`/implicit animation；
- 对 UI automation 使用与生产相同的 view tree，不增加只为测试通过的生产差异。

### 4.4 验收

- `make drive-test-ui` 连续 3 次 PASS；
- `git diff --check` PASS；
- `make drive-test-fast` PASS；
- `make drive-test-system` PASS；
- UI 源码增加必要的回归 ratchet，避免未来重新引入已确认的 hitch 根因。

### 4.5 提交策略

- 诊断 instrumentation 可独立提交；
- 根因修复独立提交；
- 不把 Phase B 结构重构混入 UI 性能修复 commit。

## 5. Phase B — Runtime 职责拆分

### 5.1 目标

逐步把 `EDPVaultRuntime.swift` 拆成明确生命周期组件，同时保持现有行为完全一致。

目标边界：

- `EDPDeviceDiscoveryController`：物理枚举、classifier input、generation identity；
- `EDPRawAccessController`：retained raw lease、EBUSY recovery、raw-ready/error state；
- `EDPMountCoordinator`：partition mount/unmount session 编排；
- `EDPAutoMountController`：policy、manual suppression、reconnect retry；
- `EDPEjectCoordinator`：device quiesce、partition drain、physical generation eject；
- `EDPRecoveryCoordinator`：persisted session、FSKit/DiskImages2 recovery 编排；
- `EDPServiceController`：XPC facing orchestration、shutdown、snapshot/diagnostics 聚合。

名称可在实现中微调，但职责边界必须保持。

### 5.2 实施顺序

1. 先抽纯 model/key/helper，零行为改变；
2. 抽 raw access；
3. 抽 auto-mount policy/suppression；
4. 抽 eject/shutdown orchestration；
5. 最后收窄 service controller；
6. 每步删除旧重复实现，不保留双路径 fallback。

### 5.3 验收

每个 commit 至少：

- Swift 6 warnings-as-errors build PASS；
- `drive-test-fast` PASS；
- `drive-test-system` PASS；
- `drive-test-virtual-usb` PASS；
- S01-S35 / lifecycle model 不减少覆盖；
- grep/system ratchet 证明没有 sync fallback、duplicate recovery 或 raw identity 弱化。

Phase B 收尾追加 storage smoke；如涉及 teardown ownership，再跑 release storage。

## 6. Phase C — App/UI 文件职责拆分

### 6.1 目标

把 `EDPUSBVaultApp.swift` 拆为可独立维护的原生 UI 模块，减少 sidebar 与页面刷新耦合。

建议结构：

- `App/EDPDriveApp.swift`
- `App/Model/EDPVaultViewModel.swift`
- `App/Shell/EDPMainWindow.swift`
- `App/Shell/EDPNativeSplitViewController.swift`
- `App/Sidebar/EDPSidebarView.swift`
- `App/Pages/EDPOverviewView.swift`
- `App/Pages/EDPDevicesView.swift`
- `App/Pages/EDPActivityView.swift`
- `App/Pages/EDPSettingsView.swift`
- `App/MenuBar/EDPMenuBarView.swift`
- `App/Service/EDPServiceControls.swift`
- 测试/CLI smoke 入口与正式 UI 分离到清晰文件，但继续构建进同一 App target。

### 6.2 约束

- 不改变现有 Liquid Glass 视觉基线；
- 不恢复 cascading AppKit menu；
- 不改变 “仅退出界面 / 完全退出” 语义；
- sidebar 性能修复不得在拆分过程中回退。

### 6.3 验收

- `make drive-test-ui` 连续 PASS；
- `drive-test-fast/system` PASS；
- App source build list/system ratchet 更新；
- 用户可见页面与 menu-bar preview 无差异回归。

## 7. Phase D — 发布可靠性与 recovery 可观测性

### 7.1 Recovery counters / diagnostics

在现有 structured lifecycle journal 基础上增加只记录计数/类别的诊断指标：

- `rawBusyRecoveryCount`；
- `forcedWholeUnmountCount`；
- `fskitAgentRecoveryCount`；
- `diskImagesAttachRecoveryCount`；
- `diskImagesDetachRecoveryCount`；
- `mountRetryCount`；
- `ejectAlreadyAbsentSuccessCount`。

要求：

- bounded；
- 不记录密码、key、raw plaintext；
- 可由 diagnostics snapshot 导出；
- deterministic tests 能验证计数只在对应事件发生时增加；
- 不为了 telemetry 改变 recovery 决策。

### 7.2 外部/私有依赖治理

审查 production：

- `hdiutil`；
- Private DiskImages2 helper；
- `pluginkit`；
- `killall fskit_agent/extensionkitservice`。

目标不是盲目“零 CLI”，而是：

- 正常稳定路径尽量不触发 recovery CLI；
- 所有调用 bounded、typed、可取消；
- destructive/restart 动作前 exact identity / global FSKit guard 保持 fail-closed；
- system ratchet 标出哪些属于正常路径，哪些只允许 recovery path。

### 7.3 发布物理矩阵

有对应实物时补：

- ordinary USB：Drive 不接管；
- legacyNoPassword：Drive 不接管；
- currentNoPassword：Drive 不接管；
- unrecognizedEDP：不创建 raw lease、不建立 mount session；
- standardEncrypted：五因素、credential persistence、auto-mount、safe eject、replug retained FDA。

缺少实物时保持 `BLOCKED_BY_FIXTURE`，不得用 synthetic 结果冒充物理证据。

### 7.4 Exact-head reboot gate

发布候选 HEAD：

1. 安装 exact-head Clean.pkg；
2. Mac reboot；
3. 不追加 service FDA；
4. 启动 App / service health；
5. 插入标准 EDP；
6. retained raw access + policy/credential persistence；
7. safe eject residue/U-state=0。

## 8. Phase E — 文档、测试矩阵与 Release Checklist 收口

### 8.1 当前问题

旧 `STATUS.md`、handoff 和 tracker 同时描述多个历史实现，包含：

- 已完成但仍显示 `[ ]` 的旧任务；
- 已被后续架构替换的实现说明；
- 历史 incident 细节与当前 production truth 混在一起。

### 8.2 目标文档

形成四个当前真源：

- `Apps/Drive/docs/STATUS.md`：当前产品状态，只写仍有效事实；
- `Apps/Drive/docs/ARCHITECTURE.md`：当前生产拓扑、身份、安全边界、生命周期；
- `Apps/Drive/docs/TESTING.md`：hardware-free / synthetic / installed / physical gate 矩阵；
- `Apps/Drive/docs/RELEASE-CHECKLIST.md`：发布候选逐项验收。

历史 handoff/tracker 不删除 Git 历史；必要时在文件头标 `ARCHIVED/HISTORICAL` 或移动到明确 archive 目录，但不得让当前入口继续引用失效规则。

### 8.3 测试入口收口

确认并文档化：

- `make drive-test-fast`
- `make drive-test-virtual-usb`
- `make drive-test-storage-smoke`
- `make drive-test-storage`
- `make drive-test-ui`
- `make drive-test-system`
- `make drive-test-all`
- CI responsibility split + nightly storage/system。

清理旧 tracker 中已实现但未勾选的“假技术债”。

## 9. Phase F — NTFS RW 产品/架构决策

### 9.1 原则

本 Phase 首先产出 ADR，不直接把 NTFS 写能力塞进当前 lifecycle。

需要回答：

1. 真实部署介质中 NTFS type2/type4 的比例与 RW 是否为硬需求；
2. 若只读可接受，UI/文档如何明确 capability；
3. 若必须 RW，可用 provider 的 macOS 26 支持、签名/分发、FSKit 原生感、Finder semantics、性能、安全边界；
4. 新 provider 是否能保持：`EDPCore block translation -> filesystem provider` 分层；
5. 是否引入 kernel extension、付费签名、第三方闭源 runtime 等不可接受条件。

### 9.2 决策输出

新增 ADR，明确三选一：

- A：Apple native NTFS read-only 是正式产品能力边界；
- B：引入独立 NTFS RW provider，另开实现计划；
- C：发布介质规范改为 ExFAT/APFS 等已有 RW provider，不在 Drive 内承担 NTFS RW。

在 ADR 完成前，本计划不恢复 `ntfs-3g`，不修改已稳定的加密/raw/lifecycle 链路。

## 10. 每阶段提交与跟踪规则

- 每完成一个可验证小阶段即更新 progress tracker 并 commit/push。
- tracker 只记录实际执行结果；没有最终 marker 的测试不得写 PASS。
- 如发现新 blocker，记录根因、证据、下一动作，不通过扩大 timeout 或 kill 无关进程掩盖。
- 所有代码 commit 前执行 `git diff --check`。
- source 变更必须给出对应测试；文档-only commit 不伪称重新验证产品行为。

建议提交序列：

1. `docs(drive): plan stabilization and release hardening`
2. `perf(drive): remove sidebar animation hitch`（可拆诊断/修复）
3. `refactor(drive): split runtime responsibilities`（多 commit）
4. `refactor(drive): split native app views`（多 commit）
5. `feat(drive): expose bounded recovery diagnostics`
6. `docs(drive): consolidate release truth`
7. `docs(drive): decide NTFS write capability`

## 11. 最终完成定义

本计划完成时应满足：

- sidebar 33 ms gate 连续 3 次 0 hitch；
- fast/virtual/system/storage/UI required gates 全绿；
- runtime/App 不再由两个超大文件承担绝大多数职责；
- raw/eject/recovery invariants 与五因素身份没有削弱；
- recovery 使用频率可由无敏感信息的 diagnostics 直接判断；
- release physical matrix 明确哪些已证实、哪些因缺实物 blocked；
- exact-head reboot acceptance 完成；
- STATUS/ARCHITECTURE/TESTING/RELEASE-CHECKLIST 成为唯一当前真源；
- NTFS RW 有正式 ADR，不再处于模糊状态；
- 最终工作树 clean，分支与远端 exact HEAD 一致。
