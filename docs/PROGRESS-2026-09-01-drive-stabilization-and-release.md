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

状态：CI VERIFY

### A1 基线

- [x] exact-head 复跑 `make drive-test-ui`。
- [x] preview scenarios PASS。
- [x] page rendering PASS。
- [x] 900×680 sidebar 20 toggles geometry PASS。
- [x] accessibility structure PASS。
- [ ] GitHub Actions Animation Hitches 33 ms gate PASS。
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
- [x] Xcode 26 TOC 已确认完整帧表为 `hitches-frame-lifetimes`；旧 `hitches` 表只包含已判定 hitch 事件。33 ms gate 已切换到完整 frame lifetime 表，阈值仍为 `33_000_000ns`。
- [x] Xcode 26 raw export 规则已核实：frame lifetime 的 start/duration 是 row 第 1/2 列匿名 typed element，不是 `<start-time>/<duration>` 标签；parser 已按 schema 列序读取，并兼容 raw ns、s/ms/µs/ns fmt 与 ref 复用。
- [ ] GitHub Actions `make drive-test-ui` 33 ms gate PASS。

## Phase B — Runtime 职责拆分

状态：IN PROGRESS

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
- [ ] 继续抽纯 model/key/helper。
- [x] 抽 `EDPRawAccessController` orchestration（single-flight + EBUSY exact-generation recovery + lease state）。
- [x] 抽 auto-mount policy/manual suppression。
- [ ] 抽 shutdown/recovery orchestration。
- [ ] 抽 recovery orchestration。
- [ ] 收窄 service-facing controller。
- [ ] 每步 S01-S35/property/fast/system/virtual 不回退。
- [ ] Phase B storage smoke PASS。
- [x] 连续两轮 CI M14 暴露旧 storage teardown 与生产不一致：测试曾使用 `hdiutil detach → diskutil eject`；已改为 DA eject + exact current-user `diskimagesiod` owner recovery，保持 exact backing / residue=0 fail-closed。
- [x] M12 后续 CI 暴露 `ps command=` 进程身份判断不等价于生产 executable-path 校验；storage helper 已改用 `proc_pidpath()`，TERM/KILL 前均重新验证 exact `diskimagesiod` PID/path。
- [x] 进一步定位 owner recovery：DA eject 后 exact DiskImages2 owner 可继续存在且 `system-entities` 可能为空、只剩 partition 子实体或保持原 synthetic entity；storage test 已同步生产 `parsePublication` 合同，只允许 entity 全部匹配 synthetic `/dev/diskN[sM...]`，并在 TERM 后要求 exact PID + entity snapshot 不变才允许 KILL；任何 owner/entity identity 漂移仍 fail-closed。
- [x] M12 transport-crash teardown 顺序已修正为与已建立生产会话一致：先 bounded native user filesystem unmount + quiescence，再 unpublish DiskImages2，最后清理 crashed transport bridge；禁止在 upper filesystem 仍持有 synthetic device 时直接杀 owner。
- [x] CI native monorepo ratchet 已随 automation state 抽取更新；UI frame-lifetime parser 在 0 可解析样本时输出 raw row typed-column 诊断，仍 fail-closed 且 33 ms 阈值不变。
- [ ] Phase B commits/push。

## Phase C — App/UI 文件职责拆分

状态：TODO

- [ ] App shell / native split controller 独立文件。
- [ ] ViewModel 独立文件。
- [ ] Sidebar 独立文件。
- [ ] Overview / Devices / Activity / Settings 页面拆分。
- [ ] Menu bar / Service controls 拆分。
- [ ] CLI smoke/UI automation helper 与页面实现边界清晰。
- [ ] Liquid Glass、菜单层级、仅退出界面/完全退出语义不变。
- [ ] UI gate 保持连续 PASS。
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
