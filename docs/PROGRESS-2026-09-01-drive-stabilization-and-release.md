# EDP Drive 稳定化、结构收口与发布准备 — 实时进度

日期：2026-09-01
分支：`codex/ui-macos26-liquid-glass`
计划：`docs/PLAN-2026-09-01-drive-stabilization-and-release.md`
计划基线：`3463295b1e6f86a315075732543ef3f53c510d18`

> 只记录实际完成并有证据的结果。未执行、无最终 marker、缺少真实介质的项目保持 TODO/BLOCKED，不得伪记 PASS。

## 总览

| Phase | 内容 | 状态 |
|---|---|---|
| A | Sidebar 33 ms 性能收口 | CI VERIFY |
| B | Runtime 职责拆分 | IN PROGRESS |
| C | App/UI 文件职责拆分 | TODO |
| D | 发布可靠性与 recovery 可观测性 | TODO |
| E | 文档、测试矩阵、Release Checklist 收口 | TODO |
| F | NTFS RW 产品/架构 ADR | TODO |

## 当前不可回退基线

- [x] 标准 EDP 五因素身份保持：VID/PID/LBA4 onlyId/capacity/LBA11 metadataDeviceID。
- [x] single-App FDA；不授予 service 单独 FDA。
- [x] EBUSY exact-generation force-whole + single raw retry 已由 S31-S35 锁定。
- [x] physical eject generation hardening / duplicate eject single-flight / shutdown ordering 已锁定。
- [x] 真实 SanDisk type1 FAT16 RO、type2/type4 Apple NTFS RO capability-aware 验收完成。
- [x] 产品 XPC safe eject 实机 PASS，BadArgument 未复现。
- [x] safe eject 终态 EDP mount/backing/transport residue=0，Finder/UVFS/service 无 U-state。
- [x] fresh physical replug retained raw access PASS，type2/type4 credential persistence PASS。
- [x] 当前分支起点 clean 且 `HEAD == origin/codex/ui-macos26-liquid-glass == 3463295b1e6f86a315075732543ef3f53c510d18`。

## Phase A — Sidebar 33 ms 性能收口

状态：DONE（CI-only gate PASS）

### A1 基线

- [x] exact-head 复跑 `make drive-test-ui`。
- [x] preview scenarios PASS。
- [x] page rendering PASS。
- [x] 900×680 sidebar 20 toggles geometry PASS。
- [x] accessibility structure PASS。
- [x] GitHub Actions Animation Hitches 33 ms gate PASS；run `33595043724` 已给出 `UI_HITCH_COUNT_GT33MS=0`，后续 run `33598617878` 同样 PASS。
- [x] CI-only xctrace 改为 `--launch`，消除 attach PID 竞态；当前剩余问题是 trace timebase 与 app epoch 对齐，33 ms 判定本身未放宽。

2026-09-01 19:29 基线：

```text
UI_HITCH_FRAME_COUNT=27
UI_HITCH_MAX_MS=41.666
UI_HITCH_COUNT_GT33MS=1
```

此前同一代码已出现 `66.666ms / 2 frames >33ms`，因此记录为波动型性能缺陷，不按固定冷启动单帧处理。

### A2 定位

- [x] 审查现有 hitch-only runner / trace window / automation toggle timing。
- [x] 复用 epoch marker 对齐 Animation Hitches / Time Profiler。
- [x] 导出 Time Profiler：观察到 `NSHostingView.setFrameSize`、text metrics、display-list render 等 live-resize 工作。
- [x] 历史 exact known-good `fff906c` 在当前本机同样可出现 66–75 ms，排除当前代码独有回归。
- [x] 关闭第二个已安装 EDP Drive UI 后曾连续得到 16.667 / 16.667 / 25.000 ms，证明本机 compositor/workload 会污染结果。
- [x] 用户明确要求：本机不再执行 UI 性能测试，33 ms 只在 GitHub Actions 执行。

### A3 修复与验收

- [x] `run-ui.sh` 将 compositor-sensitive xctrace 性能段收口为 `GITHUB_ACTIONS=true` 才执行；本机只输出 `DRIVE_UI_PERF_CI_ONLY_SKIPPED_LOCALLY`，不产生性能 PASS 证据。
- [x] 33 ms 阈值、toggle 数量、测量窗口未降低。
- [x] system ratchet 锁定 CI-only policy 与 `THRESHOLD_NS = 33_000_000`。
- [x] `make drive-test-fast` PASS，`RESULT=DRIVE_FAST_OK`。
- [x] `make drive-test-system` PASS，含 `RESULT=DRIVE_SYSTEM_UI_PERF_CI_ONLY_OK`。
- [x] `git diff --check` PASS。
- [x] Phase A CI-only policy commit/push：`2945d54`。
- [x] macOS 26 runner geometry contract 已修正为 900 px 宽 + split usable height ≥620；不把 toolbar 后 content height 锁死为 680。
- [x] xctrace runner race 已定位：先启动 preview 再 `--attach PID` 时，GitHub runner 的 xctrace 启动可能晚于 preview 生命周期；已改为 Instruments 原生 `--launch -- ${BIN} --hitch-only`。
- [x] Xcode 26 TOC 已确认 `hitches-frame-lifetimes` schema 存在，但 GitHub macOS 26 runner 在本 workload 中导出 0 row；最终 gate 保持历史语义：读取同一 Animation Hitches trace 的稀疏 `hitches` 事件，显式按 `THRESHOLD_NS = 33_000_000` 判定，0 row 表示 Instruments 未记录到超过 hitch 条件的事件，不提高阈值。
- [x] parser 保留 frame-lifetime 兼容路径，并兼容 raw ns、s/ms/µs/ns fmt 与 ref 复用；frame-lifetime 为空时回退 `hitches` event schema，仍只接受 `duration > 33_000_000ns` 为失败。
- [x] GitHub Actions run `33595043724` / `regression-ui-system` PASS：`UI_HITCH_COUNT_GT33MS=0`、`RESULT=DRIVE_UI_ANIMATION_HITCHES_ZERO`、`RESULT=DRIVE_UI_OK`；本机未执行 UI 性能段。

## Phase B — Runtime 职责拆分

状态：IMPLEMENTATION DONE（等待最终 exact-head CI 复核）

- [x] 第一阶段纯 lifecycle model 抽取：`EDPLifecycleFailure*`、FSKit recovery policy、mount lifecycle state machine 移至 `EDPMountLifecycle.swift`；runtime 减少 302 行，行为不变。
- [x] 通用 runtime support 抽取：`RuntimeError/fail/secureZero/run/plist/atomicWrite` 移至 `EDPRuntimeSupport.swift`；runtime 再减少 101 行，并由 system ratchet 禁止回流。
- [x] raw access primitive 抽取：`EDPRawAccessLease`、broker raw open、raw metadata read、五因素/metadata revalidation、`EDPPrivilegedRawMetadataReader` 移至 `EDPRawAccess.swift`；controller 继续只拥有 single-flight/EBUSY orchestration。
- [x] `EDPVaultRuntime.swift` 已由约 5462 行降至 4839 行。
- [x] raw primitive 抽取后 S01-S35、320000-step property、fast/system/virtual 全绿。
- [x] FSKit host recovery helper 已从主 runtime 移至 `EDPMountLifecycle.swift`，保持 mount-free fail-closed agent recovery 语义不变。
- [x] persistent runtime state 已抽至 `EDPRuntimeState.swift`：state roots、legacy migration、credential/policy store factory 不再属于 daemon orchestration；runtime 降至 4697 行。
- [x] device operations 已抽至 `EDPDeviceOperations.swift`：discovery、filesystem probe、credential verify、CLI authorize 不再属于 daemon orchestration；runtime 降至 4548 行。
- [x] mount support 已抽至 `EDPMountSupport.swift`：transport spawn、raw-fd child inheritance、session model、mount operation box 不再属于主 runtime；runtime 降至 4361 行。
- [x] raw-access orchestration 已抽至 `EDPRawAccessCoordinator.swift`：retained lease、single-flight waiters、ready/error state、raw worker queue、temporary whole-unmount、EBUSY exact-generation force-whole + single retry 全部移出 daemon controller；controller 仅提供当前 generation predicate 与 activity 回调。S31-S35/property/fast/system/virtual 全绿；runtime 降至 4202 行。
- [x] auto-mount/manual suppression 状态已抽至 `EDPAutomationState.swift`：failed mount message/code、manual unmount suppression、default password probe suppression 统一由 controller queue confined state 管理；D01-D13、S01-S35、320000-step property、system/virtual 全绿；runtime 降至 4183 行。
- [x] eject single-flight / generation state / exact physical DA eject 已抽至 `EDPEjectCoordinator.swift`：duplicate waiter fanout、automount suppression 生命周期、original USB generation disappearance success、exact `registryEntryID` whole-unmount/eject 均不再由 daemon controller 直接持有；S24-S30 及全 S01-S35/property/fast/system/virtual 全绿；runtime 降至 4107 行。
- [x] startup-recovery / shutdown state 已抽至 `EDPServiceLifecycleState.swift`：startup gate、shutdown requested/in-flight、coalesced completion fanout、等待 active eject 后才允许 teardown 统一由 owner-queue state 管理；实际 `unmountAllAsync` 与资源释放仍由 controller 执行；S18/S29 及全 S01-S35/property/fast/system/virtual 全绿；runtime 降至 4095 行。
- [x] failed-eject recovery 已抽至 `EDPRecoveryCoordinator.swift`：解除 eject suppression、原 whole-USB generation revalidation、单次 raw reacquire、boot policy restore 与原错误 fanout 形成独立恢复边界；controller 仅提供 probe/restore/activity 回调；全 S01-S35/property/fast/system/virtual 全绿。
- [x] device discovery 已抽至 `EDPDeviceDiscoveryController.swift`：`discoverEDPDisks` 调用、metadata reader、scan diagnostics/count/timestamp 不再属于 daemon controller；controller 仅保留当前 `connectedDisks` 业务状态。discovery seam、S01-S35/property/fast/system/virtual 全绿；runtime 降至 4086 行。
- [x] XPC adapter 已抽至 `EDPXPCService.swift`：reply boxing、trusted peer acceptance、XPC protocol→controller 调用转换不再属于 runtime；service regression 直接实例化场景及 S01-S35/property/fast/system/virtual 全绿。
- [x] bounded activity retention 已抽至 `EDPActivityStore.swift`：200 条 activity ring buffer 不再是 controller 内嵌可变数组；snapshot 仅消费 store snapshot，system/virtual/fast 全绿。
- [x] daemon/doctor/CLI `@main` 已抽至 `EDPServiceMain.swift`：listener bootstrap、signal handler、doctor/status/list/authorize/revoke/cleanup/daemon 入口与 mount/runtime orchestration 分离；主 runtime 降至 3688 行，system/virtual/fast 与 diff-check 全绿。
- [x] 纯 model/key/helper 抽取已按小步完成：lifecycle model、runtime support/state、mount support、raw primitives、activity/service lifecycle state 均已独立，未保留双路径 fallback。
- [x] 抽 `EDPRawAccessController` orchestration（single-flight + EBUSY exact-generation recovery + lease state）。
- [x] 抽 auto-mount policy/manual suppression。
- [x] 抽 shutdown/recovery orchestration：startup/shutdown state 由 `EDPServiceLifecycleState` 管理，eject wait 与 teardown gate 保持 owner-queue 语义。
- [x] 抽 recovery orchestration：failed-eject generation revalidation/raw reacquire/boot-policy restore 已进入 `EDPRecoveryCoordinator`。
- [x] 收窄 service-facing controller：discovery/activity/XPC adapter/service entrypoint 已分别拆至 `EDPDeviceDiscoveryController`、`EDPActivityStore`、`EDPXPCService`、`EDPServiceMain`；顶层 orchestration 已正式收口为 `EDPServiceController`，mount/session ownership 收口为 `EDPMountCoordinator`，旧 `EDPDaemonController` / `MountManager` 命名由 system ratchet 禁止回流；`EDPVaultRuntime.swift` 约 3709 行。
- [x] 每步 S01-S35/property/fast/system/virtual 不回退；最新本机 fast/system/virtual 与 320000-step property 全绿。
- [x] Phase B storage smoke/release PASS：GitHub Actions run `33609861193` / job `100182211669` 在 `7b42c99` 上完整通过 M01、M02/M04-M09、M03、M10 5/5、M12、M14、production Swift6/C17 strict，最终 `RESULT=DRIVE_STORAGE_E2E_OK`。
- [x] run `33598075171` 在 `f29e710` 上证明 crashed-transport D-state 已消失：storage 不再触发 30 分钟不可中断挂死，而是在约 3 分钟内正常 bounded failure；native/fast/virtual 均 PASS。剩余失败前移到普通 M02 remount publication teardown。
- [x] run `33598617878` 在 `44304f3` 上确认 M02 post-KILL 真实状态：原 `diskimagesiod` PID 7065 已不存在，但 `hdiutil info -plist` 仍持续返回同一 exact backing、同一 PID、`devices=none` 的 owner record；没有 owner respawn，也不是 SIGKILL 失败，属于 macOS 26 DiskImages2 metadata-only stale tombstone。UI/native/fast/virtual 同轮全部 PASS。
- [x] dead-owner tombstone retirement 已按最窄条件实现：仅 `devicePaths.isEmpty`、exact owner snapshot 二次采样完全相同、记录 PID 两次均无 executable process 时允许视为已退役；任何 PID/UID/entity 变化或 live owner 均 fail-closed。生产 `EDPDiskImages2Publisher` 与 storage harness 同步该合同，并新增 deterministic negative matrix（PID/UID/entity/live-owner 变化均拒绝）。
- [x] 连续两轮 CI M14 暴露旧 storage teardown 与生产不一致：测试曾使用 `hdiutil detach → diskutil eject`；已改为 DA eject + exact current-user `diskimagesiod` owner recovery，保持 exact backing / residue=0 fail-closed。
- [x] M12 后续 CI 暴露 `ps command=` 进程身份判断不等价于生产 executable-path 校验；storage helper 已改用 `proc_pidpath()`，TERM/KILL 前均重新验证 exact `diskimagesiod` PID/path。
- [x] 进一步定位 owner recovery：DA eject 后 exact DiskImages2 owner 可继续存在且 `system-entities` 可能为空、只剩 partition 子实体或保持原 synthetic entity；storage test 已同步生产 `parsePublication` 合同，只允许 entity 全部匹配 synthetic `/dev/diskN[sM...]`，并在 TERM 后要求 exact PID + entity snapshot 不变才允许 KILL；任何 owner/entity identity 漂移仍 fail-closed。
- [x] M12 transport-crash 多轮 CI 已证明 live upper filesystem + dead lower transport 不能在 macOS 26 上走同步 teardown：ordinary DA unmount 会 callback timeout，`unmount(2, MNT_FORCE)` 可直接进入不可中断 D-state；因此该组合不再尝试“强行恢复”，产品必须 fail-closed。
- [x] CI native monorepo ratchet 已随 automation state 抽取更新；native/fast/virtual 在 run `33591256755` 已 PASS。
- [x] GitHub macOS runner 实证 `hitches-frame-lifetimes` schema 存在但 raw rows=0；UI gate 现优先使用完整 frame-lifetime 表，空表时回退同一 Animation Hitches trace 的稀疏 `hitches` 事件表，并继续显式按 `33_000_000ns` 过滤；本机仍不执行 UI 性能段。
- [x] run `33595043724` 进一步实证 `unmount(2, MNT_FORCE)` 在 dead transport + live ExFAT mount 下进入内核后超过 26 分钟不返回，直到 30 分钟 CI 上限取消；该危险 helper 模式已彻底删除。生产 `EDPTransportSession` 和 `EDPMountCoordinator` 均新增 transport-liveness fail-closed gate：transport 已退出且 VFS/user filesystem 仍 mounted 时禁止进入同步 unmount syscall，并保留 teardown failure/session 诊断。
- [x] deterministic transport lifecycle 新增 exited-transport + mounted-VFS 用例，锁定“不调用 unmount、不 SIGTERM/SIGKILL、不 host reset”；storage M12 改为真实验证可安全边界：先正常卸载并 quiesce upper filesystem，再 crash lower transport，随后 exact bridge cleanup → DiskImages2 publication teardown → remount/persistence 验证。
- [x] Phase B commits 已分步完成；run `33613200810` / HEAD `65cca1a` 上 native/fast/virtual 全部 PASS，storage M01-M14 主步骤完整 PASS；该 run 的唯一失败是首版 xctrace watchdog 20s 误杀 GitHub runner 的正常 Instruments 冷启动，不是 33 ms hitch 回归。watchdog 已收紧为 record 60s / list+export 30s，8s trace window、20 toggles、33 ms 阈值均未改变，等待下一固定 HEAD CI 复核。

## Phase C — App/UI 文件职责拆分

状态：IMPLEMENTATION DONE（等待固定 HEAD CI 复核）

- [x] App shell / native split controller 已独立到 `App/Shell/EDPMainWindow.swift`，保持原 `NSSplitViewController`、sidebar collapse behavior、geometry/accessibility 合同。
- [x] ViewModel 已独立到 `App/Model/EDPVaultViewModel.swift`；XPC connection generation、service start/stop/restart single-flight、snapshot、mount/eject/credential/default-policy orchestration 原样保留。
- [x] Sidebar 已独立到 `App/Sidebar/EDPSidebarView.swift`；section enum/list selection 不再与 split controller 混在同一文件。
- [x] Overview / Devices / Activity / Settings 已分别拆到 `App/Pages/EDPOverviewView.swift`、`EDPDevicesView.swift`、`EDPActivityView.swift`、`EDPSettingsView.swift`。
- [x] Menu bar 已拆到 `App/MenuBar/EDPMenuBarView.swift`；service controls、partition rows、仅退出界面/完全退出仍使用原交互语义。
- [x] macFUSE/App service support 已拆到 `App/Service/EDPAppServiceSupport.swift`；XPC smoke helper 已拆到 `App/Service/EDPXPCSmokeSupport.swift`，CLI smoke 与页面实现边界清晰。
- [x] `EDPUSBVaultApp.swift` 已由约 3810 行降至约 476 行，只保留 App/CLI entrypoint 与 raw-FD broker dispatch；system ratchet 禁止 ViewModel/pages/sidebar/menu/support 实现回流。
- [x] Liquid Glass、菜单层级、仅退出界面/完全退出语义未改变；本机 Swift6 typecheck、system、fast、virtual、S01-S35/320000-step property、production installer、`git diff --check` 全部 PASS。
- [ ] GitHub Actions UI gate 在 Phase C exact-head 上 PASS；本机继续不执行 UI performance/xctrace。
- [ ] Phase C commits/push。

## Phase D — 发布可靠性与 recovery 可观测性

状态：TODO

### D1 Counters

- [ ] `rawBusyRecoveryCount`
- [ ] `forcedWholeUnmountCount`
- [ ] `fskitAgentRecoveryCount`
- [ ] `diskImagesAttachRecoveryCount`
- [ ] `diskImagesDetachRecoveryCount`
- [ ] `mountRetryCount`
- [ ] `ejectAlreadyAbsentSuccessCount`
- [ ] diagnostics redaction/system ratchet/tests。

### D2 外部/私有依赖

- [ ] `hdiutil` 正常路径/recovery 路径分类。
- [ ] Private DiskImages2 helper 边界复核。
- [ ] `pluginkit` 使用边界复核。
- [ ] agent reset 只允许明确 recovery 条件，保持 global FSKit fail-closed。

### D3 物理发布矩阵

- [ ] ordinary USB physical negative — BLOCKED until fixture available。
- [ ] legacyNoPassword physical negative — BLOCKED until fixture available。
- [ ] currentNoPassword physical negative — BLOCKED until fixture available。
- [ ] unrecognizedEDP physical negative — BLOCKED until fixture available。
- [x] standardEncrypted SanDisk positive/capability/safe-eject/replug 已完成一轮最终收口。

### D4 Exact-head reboot

- [ ] exact-head Clean.pkg build/verify。
- [ ] install。
- [ ] reboot。
- [ ] single-App FDA retained access。
- [ ] policy/credential persistence。
- [ ] safe eject residue/U-state=0。

## Phase E — 文档、测试矩阵与 Release Checklist

状态：TODO

- [ ] 重写 `Apps/Drive/docs/STATUS.md` 为当前事实真源。
- [ ] 新建 `Apps/Drive/docs/ARCHITECTURE.md`。
- [ ] 新建 `Apps/Drive/docs/TESTING.md`。
- [ ] 新建 `Apps/Drive/docs/RELEASE-CHECKLIST.md`。
- [ ] 标记/归档失效 handoff/tracker 入口。
- [ ] 清理旧 tracker 中已实现但仍 `[ ]` 的假技术债。
- [ ] 文档与 Makefile/CI targets 一致。

## Phase F — NTFS RW ADR

状态：TODO

- [ ] 收集真实介质 RW 需求。
- [ ] 明确 Apple native NTFS RO 是否可接受。
- [ ] 如不可接受，研究独立 NTFS RW provider 约束，不恢复 ntfs-3g 旧路径。
- [ ] 输出 ADR：A native RO / B 独立 RW provider / C 介质格式规范化。
- [ ] 若选择 B，另建独立实施计划，本计划不直接实现。

## 变更日志

### 2026-09-01 20:37 — UI performance evidence moved to GitHub Actions only

- 用户明确要求不再使用本机桌面作为 UI 性能基准；本机负载/WindowServer 状态不是静态变量，不能驱动 sidebar 性能结论。
- 历史 known-good `fff906c` 在当前本机亦可出现 66–75 ms，证明本机 xctrace 数值不是当前代码独有回归；此前关闭第二个已安装 Drive UI 后又可回落到 16.667–25 ms，进一步证明 compositor 环境污染。
- 所有实验性 production UI 参数改动均已回退；不以固定内容宽度、LazyVStack、live-resize redraw policy 等未稳定方案改变产品视觉。
- `run-ui.sh` 保留 deterministic preview/page/geometry/accessibility 检查；Animation Hitches 只在 `GITHUB_ACTIONS=true` 执行。本机调用明确输出 `RESULT=DRIVE_UI_PERF_CI_ONLY_SKIPPED_LOCALLY` 后结束。
- `ParseAnimationHitches.py` 的 `THRESHOLD_NS = 33_000_000`、toggle 数量和 trace window 均保持不变；system ratchet 锁定 CI-only policy，等待 GitHub Actions 作为 Phase A 最终性能证据。

### 2026-09-01 19:29 — Plan baseline and UI performance failure reproduced

- fetch 后确认 `HEAD == origin/codex/ui-macos26-liquid-glass == 3463295b1e6f86a315075732543ef3f53c510d18`，工作树 clean。
- 新计划以真实盘最终收口结果为不可回退基线，不重复 FDA、DADiskClaim、普通 unmount 等已排除实验。
- exact-head `make drive-test-ui`：preview/page/geometry/accessibility 全 PASS；Animation Hitches 失败：27 sampled frames，max 41.666 ms，1 frame >33 ms。
- 该结果与此前同 HEAD 66.666 ms / 2 frames 的失败共同证明 sidebar hitch 具有波动性；Phase A 从 trace attribution 开始，不调整门槛。
