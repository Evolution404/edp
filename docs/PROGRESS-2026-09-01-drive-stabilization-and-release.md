# EDP Drive 稳定化、结构收口与发布准备 — 实时进度

日期：2026-09-01
分支：`codex/ui-macos26-liquid-glass`
计划：`docs/PLAN-2026-09-01-drive-stabilization-and-release.md`
计划基线：`3463295b1e6f86a315075732543ef3f53c510d18`

> 只记录实际完成并有证据的结果。未执行、无最终 marker、缺少真实介质的项目保持 TODO/BLOCKED，不得伪记 PASS。

## 总览

| Phase | 内容 | 状态 |
|---|---|---|
| A | Sidebar 33 ms 性能收口 | DONE |
| B | Runtime 职责拆分 | DONE |
| C | App/UI 文件职责拆分 | DONE |
| D | 发布可靠性与 recovery 可观测性 | IN PROGRESS（D1/D2 DONE；D3/D4 pending） |
| E | 文档、测试矩阵、Release Checklist 收口 | DONE |
| F | NTFS RW 产品/架构 ADR | DONE |

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

状态：DONE

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

状态：DONE

- [x] App shell / native split controller 已独立到 `App/Shell/EDPMainWindow.swift`，保持原 `NSSplitViewController`、sidebar collapse behavior、geometry/accessibility 合同。
- [x] ViewModel 已独立到 `App/Model/EDPVaultViewModel.swift`；XPC connection generation、service start/stop/restart single-flight、snapshot、mount/eject/credential/default-policy orchestration 原样保留。
- [x] Sidebar 已独立到 `App/Sidebar/EDPSidebarView.swift`；section enum/list selection 不再与 split controller 混在同一文件。
- [x] Overview / Devices / Activity / Settings 已分别拆到 `App/Pages/EDPOverviewView.swift`、`EDPDevicesView.swift`、`EDPActivityView.swift`、`EDPSettingsView.swift`。
- [x] Menu bar 已拆到 `App/MenuBar/EDPMenuBarView.swift`；service controls、partition rows、仅退出界面/完全退出仍使用原交互语义。
- [x] macFUSE/App service support 已拆到 `App/Service/EDPAppServiceSupport.swift`；XPC smoke helper 已拆到 `App/Service/EDPXPCSmokeSupport.swift`，CLI smoke 与页面实现边界清晰。
- [x] `EDPUSBVaultApp.swift` 已由约 3810 行降至约 476 行，只保留 App/CLI entrypoint 与 raw-FD broker dispatch；system ratchet 禁止 ViewModel/pages/sidebar/menu/support 实现回流。
- [x] Liquid Glass、菜单层级、仅退出界面/完全退出语义未改变；本机 Swift6 typecheck、system、fast、virtual、S01-S35/320000-step property、production installer、`git diff --check` 全部 PASS。
- [x] GitHub Actions UI gate 已在 Phase C `b6015ff` / run `33625866975` PASS；preview/page/20-toggle/accessibility 全绿，`UI_HITCH_COUNT_GT33MS=0`、`RESULT=DRIVE_UI_ANIMATION_HITCHES_ZERO`。后续 `f4862b3` / run `33635957296` 的 UI 仍在 `xctrace record` 阶段被 90s watchdog 截断，尚未进入 hitch 解析；该失败不是 33ms 回归。历史正常 record 约 66–75s，而该次超过 90s，故 CI-only record watchdog 调整为 bounded 120s；8s trace、20 toggles、33ms 阈值不变。本机继续不执行 UI performance/xctrace。
- [x] Phase C exact-head storage 最终复核：`f4862b3` / run `33635957296` 的 storage job `100266771918` 完整 PASS：M01、M02/M04-M09、M03、M10 5/5、M12、M14、failure contracts、production Swift6/C17 strict 均绿，最终 `RESULT=DRIVE_STORAGE_E2E_OK`。stable-dead-owner tombstone 后专用 adapter/bridge recovery 已消除 30 分钟挂死，普通 teardown 顺序未改变。
- [x] Phase C 最终 fixed-head：`dded9d4` / run `33684536121` 五个核心 jobs 全部 PASS；UI `UI_HITCH_COUNT_GT33MS=0`、storage M01-M14 / production strict 全绿。Phase C 正式关闭。

## Phase D — 发布可靠性与 recovery 可观测性

状态：IN PROGRESS

### D1 Counters

- [x] `rawBusyRecoveryCount`
- [x] `forcedWholeUnmountCount`
- [x] `fskitAgentRecoveryCount`
- [x] `diskImagesAttachRecoveryCount`
- [x] `diskImagesDetachRecoveryCount`
- [x] `mountRetryCount`
- [x] `ejectAlreadyAbsentSuccessCount`
- [x] diagnostics 仅输出 7 个 UInt64；schema 禁止 deviceID/path/password/credential/secret/key 字段；system ratchet + 1000-way concurrent metrics contract test PASS。
- [x] D1 最终 fixed-head：`dded9d4` / run `33684536121` native、fast、virtual、UI/system、storage 全部 PASS；UI `>33ms=0`，storage M01-M14 / production strict 全绿。D1 正式关闭。

### D2 外部/私有依赖

- [x] `hdiutil` 路径已分类：正式 DiskImages2 publish 仅走 exact `diskimages2-attach --writable-noautomount`；`hdiutil info -plist` 仅作 bounded identity/recovery metadata，`hdiutil detach -force` 仅存在 macFUSE scratch-orphan recovery。production preinstall 的全部 hdiutil info/detach 已统一通过 bounded TERM→KILL wrapper，system ratchet 禁止直接 unbounded hdiutil。
- [x] Private DiskImages2 helper 边界已复核：`EDPConsoleExec.c` 仅精确 allowlist `/Library/Application Support/EDP Drive/bin/diskimages2-attach` 一处；publisher 固定 helper path/arguments，不能执行任意 helper，raw-FD inheritance 仍仅允许两个 mfmount transport。
- [x] `pluginkit` 使用边界已复核：仅 foreground App 的 macFUSE enablement/support 路径可调用；daemon runtime、mount lifecycle、block publisher 均由 system negative ratchet 禁止 PluginKit。`runUserTool` 已改为 async 8s bounded、typed error、Task cancellation，并以 deterministic success/nonzero/timeout/cancel 测试实证。
- [x] agent reset fail-closed：App enablement 在任何 FSKit mount 活跃时跳过 `fskit_agent/extensionkitservice` reset；daemon recovery 继续使用 `MNT_EXT_FSKIT` 全局 guard + exact console user；installer stale-agent recovery 继续只允许 no-mount exact process identity。
- [x] D2 fixed-head CI：`9fd1d4c` / run `33686611853` 的 native、fast、virtual、UI/system、storage 全部 PASS；storage M01-M14 在 7m38s 内完成，D2 正式关闭。

### D3 物理发布矩阵

- [ ] ordinary USB physical negative — BLOCKED until fixture available。
- [ ] legacyNoPassword physical negative — BLOCKED until fixture available。
- [ ] currentNoPassword physical negative — BLOCKED until fixture available。
- [ ] unrecognizedEDP physical negative — BLOCKED until fixture available。
- [x] standardEncrypted SanDisk positive/capability/safe-eject/replug 已完成一轮最终收口。

### D4 Exact-head reboot

- [!] 原 `f734f43` / SHA-256 `62f685f3fe69006f165cf649e49acb8d2bb9dc7e31e85033e01bf5416e7dedda` 候选已**永久作废**：底层 `build-clean-installer.sh` 默认 ad-hoc `-` 签名虽能通过普通 `codesign --verify`，但 designated requirement 仅为 cdhash，clean first-install 中被 privileged XPC signer boundary 正确拒绝。
- [x] 发布流程缺口已补门禁：正式候选只能走 `build-self-signed-installer.sh` / `make drive-release-installer`；固定 identity=`EDP Project Code Signing`、certificate root=`040b5488fb2b6c02b0786e76b674cb4460658ca2`、self-signed installer-managed LaunchDaemon mode；`EDP_REQUIRE_RELEASE_SIGNING=1` 会拒绝 ad-hoc 包，system ratchet `DRIVE_SYSTEM_RELEASE_SIGNING_GATE_OK` PASS。
- [x] final exact release HEAD=`51a6c9c1e75e3d2dd2695c5c082a7717a010f12d`；certificate-backed Clean.pkg SHA-256=`bf4435769052ff4a8798a34d50ce406415cc4f69eb0ed6f8965cd340ac9059b7`；strict verifier 输出 `STABLE_SELF_SIGNED_RELEASE_IDENTITY`、`SELF_SIGNED_RELEASE_SERVICE_MODE_OK`、`EDP_CLEAN_INSTALLER_VERIFIED`。
- [x] exact-head CI run `33717175105`：native、fast、virtual、UI-system、storage 全部 PASS；storage M01-M14 6m02s，UI 33ms gate 未放宽。
- [x] factory-first-install：preflight、user-cleanup、privileged factory cleanup、`verify-clean`、安装前 reboot、reboot 后 `verify-clean`、signed install、`verify-installed` / privileged XPC 全部 PASS。
- [x] single-App FDA：仅 EDP Drive App 授权一次；Lexar `21c4:0cd1` / onlyID `3164177653` / capacity `124736503808` / metadata deviceID `disk&ven_lexar&prod_usb_flash_drive` 随后 `privilegedAccessReady=true`。App restart、service stop/start/restart、物理拔插后均不需要再次管理员/FDA授权。
- [x] policy/credential persistence：type2/type4 密码仅在 UI 验证保存；credential checkpoint、policy round-trip/restore 在拔插前后 PASS；三分区 autoMount 均保持 false。
- [x] 实盘三分区：type1 FAT16 RO remount PASS；type2/type4 RW marker persistence/remount/hash/delete PASS；测试后全部显式卸载，无测试 marker 残留。
- [x] safe eject / physical reinsert：XPC safe eject PASS，逻辑推出后 raw lease 释放且分区 unavailable；物理拔插后同一五因素 identity、FDA、凭据、策略均恢复。第一次 reinsert BSD 名仍为 disk26。
- [x] service lifecycle：health、graceful stop、on-demand start、restart PASS；8-cycle warmup=74ms，稳态 1049–1072ms，first avg=1064.0ms，last avg=1060.3ms，slope=-0.2ms/cycle，每轮只有一个 daemon。
- [x] mandatory post-install reboot 已执行：boot time=2026-09-03 14:51:53；物理盘从 reboot 前 `disk26` 变为 reboot 后 `disk6`，stable five-factor ID 不变；FDA retained、credential、policy、type1 RO、type2/type4 RW persistence 全部再次 PASS，无重复授权。
- [!] final safe eject 当下达到 residue=0 / U-state=0，但随后在 USB 仍物理插入时重启 foreground App，旧 `51a6c9c` service 重新扫描并把同一 generation 恢复为 `privilegedAccessReady=true`。因此 `51a6c9c` / SHA-256 `bf443576...9059b7` 候选**作废**，D4 暂未关闭。
- [x] 根因与修复：旧 `EDPEjectCoordinator.finishWaiters()` 在 eject success 后立即释放 in-flight suppression；下一次 reconcile 可重新申请 raw lease。现改为 stable device ID + USB registry generation 的持久 logical-eject tombstone `/var/db/com.edp.drive/logical-eject-suppressions.json`；App reconcile/service restart 同 generation 均保持抑制，仅物理 disappearance 或新 USB generation 释放；physical-eject failure 先原子回滚 tombstone 再执行 raw recovery。
- [x] 第一阶段新增 S36/S37：App reconcile 不重获、service restart 持久抑制；`ddf510b` 五个核心 GitHub Actions jobs 全绿，但后续代码审查发现 tombstone 解除仍错误信任 discovery absence / generation change，`ddf510b` rebuilt package SHA-256 `2bcfff76ee1f17f60e5ce7288b33eaf475f695819afa7145d845118596f4e4a7` 在物理复测前即作废。
- [x] 第二阶段将 exact persisted `usbRegistryEntryID` 收口为 tombstone 唯一解除 authority：原 generation 仍存在时，即使 discovery/metadata 暂时遗漏设备也继续抑制；若 replacement generation 与原 generation 并存，则 stable identity ambiguity 全路径 fail-closed，不保留 raw lease、不允许 replacement automount/raw reacquire。新增 S38/S39/S40：discovery omission 不解除、replacement overlap fail-closed、仅 original registry disappearance 后放行新 generation；S01-S40、10000 sequences/320000 steps、fast/system/virtual 全绿，`RESULT=DRIVE_SYSTEM_SAFE_EJECT_SUPPRESSION_OK` PASS。
- [x] 第二阶段 exact-head=`f7d7dde3f0bf5d82e5f348627b1e0836228bbdae`，GitHub Actions run `33734920686` 五个核心 jobs 全绿；certificate-backed package SHA-256=`7a9d7f745eceda43b6d3707f6b7b6c02a8ffd2f9de6f12341f93b9a680f1ca04` strict verifier PASS。实盘 safe eject → foreground App restart → privileged service complete stop/start 全部保持 `privilegedAccessReady=false`，原 restart blocker 已关闭。
- [!] 同一 `f7d7dde` 包在随后真实拔出/重插时暴露新的 release blocker：Lexar 仍按五因素 identity 正确识别为 `disk6`，type2/type4 credential/policy 保持，但 raw reopen 持续 `EDP_RAW_LEASE_OPEN_FAILED:16`。forced whole unmount、manual raw refresh、service restart 均不能恢复；管理员级 `lsof` 直接确认 `fskitd` 持有 `/dev/rdisk6s1`，导致 whole `/dev/rdisk6` `O_RDWR` 竞争失败。因此 `f7d7dde` / `7a9d...` 候选作废。
- [x] 第三阶段修复采用 Disk Arbitration 官方 early ownership 机制而非全局杀 FSKit：注册 `DARegisterDiskPeekCallback`，在 automatic filesystem probing 前复用现有 LBA0/4/7/11/12 + 五因素分类；只有完整验证的 `standardEncrypted` whole USB 执行 `DADiskClaim`，metadata failure / ordinary / legacyNoPassword / currentNoPassword / unrecognizedEDP 均 fail-open 交给 macOS。`54c048f39ddab9bd22e1cc01bd7d7276a75d3a0f` exact-head CI run `33745043903` 五核心 jobs 全绿；signed package SHA-256=`cbb9b83bf25b60971e79136123b3700548f83e79b7610e399dae708d6ad13a8b`。fresh physical replug 实证 `DA_CLAIMED=true`、仅 `edp-drive-service` 持有 `/dev/rdisk6`、无 `fskitd` `/dev/rdisk6s1` holder、`privilegedAccessReady=true`，且 `rawBusyRecoveryCount=0` / `forcedWholeUnmountCount=0`，S41 prevention path 物理 PASS。
- [!] 同一 `54c048f` 实盘继续执行 foreground App restart 时 claim 保持；但真正 privileged-service graceful stop → on-demand start 会销毁原 Disk Arbitration session，空窗中 `fskitd` 立即重新持有 `/dev/rdisk6s1`，新 service `DA_CLAIMED=false` / `privilegedAccessReady=false` / `EDP_RAW_LEASE_OPEN_FAILED:16`。因此 `54c048f` / `cbb9...` 候选仍作废。
- [x] 第四阶段本地 hardening 将日常 UI Stop/Start/Restart 改为同一 privileged process 内的 runtime pause/resume/restart：pause 完整释放 user mount/transport/raw lease，但保留 DA session/claim；resume/restart 在同一 owner 下 reconcile/reacquire。新增 S42/S43，S01-S43、10000 sequences/320000 steps、fast/virtual/system、原生 Swift `-warnings-as-errors` build 全绿；system ratchet `DRIVE_SYSTEM_CLAIM_CONTINUOUS_RUNTIME_CONTROL_OK` PASS。Complete Quit 仍是真 process shutdown，但顺序固定为 idempotent resume → snapshot → safe-eject all connected EDP → graceful shutdown，并新增 `DRIVE_SYSTEM_FULL_EXIT_SAFE_EJECT_ORDER_OK` ratchet。
- [x] 第四阶段 release code/package HEAD=`9b5a8595203cf88ff726f9aa08bc62b8c25a8d29` 已 commit/push；exact-head GitHub Actions run `33748594918` 五核心 jobs 5/5 PASS（含 storage M01-M14 与 CI-only UI/system gate）；self-signed Clean.pkg SHA-256=`43659c5fd37cc3cdb5546ab14b71782ea339bd6899209a59570bd119e0e9e264` strict verifier PASS 并已安装。实盘 fresh insertion 为 `disk27`：五因素 identity 完全一致、`DA_CLAIMED=true`、root `lsof` 仅 `edp-drive-service` 持有 `/dev/rdisk27`、无 `fskitd` `/dev/rdisk27s1` holder、`privilegedAccessReady=true`、`rawBusyRecoveryCount=0`。Pause/Resume/Restart 全程 service PID=`34883`、claim 连续，Pause 释放 raw，Resume/Restart 约 2 秒内自动恢复 raw ready，无 EBUSY；foreground App restart 亦保持 claim/raw ready。safe eject PASS，逻辑推出后 App restart/runtime restart 均不 reacquire；真实物理拔出后 IOKit 与 `/dev/disk27` 均消失，再插入自动恢复 early claim/raw ready 且无 fskitd child holder。Complete-Quit end-state 也实证 PASS：safe eject + graceful shutdown + foreground App termination 后 App/service 均不存在，再打开 App 后 service 恢复但仍物理插着的逻辑推出 Lexar 保持 `privilegedAccessReady=false`。当前唯一剩余 release gate：对已安装的 exact-head `9b5a859` 执行 mandatory reboot，并完成 post-reboot health / five-factor identity / retained raw / credential-policy / final safe-eject audit。

## Phase E — 文档、测试矩阵与 Release Checklist

状态：DONE

- [x] 重写 `Apps/Drive/docs/STATUS.md` 为当前事实真源，纠正旧 `/sbin/umount`、type1 默认自动挂载、production 完全不用 hdiutil 等已失效描述。
- [x] 新建 `Apps/Drive/docs/ARCHITECTURE.md`，固化 single-App FDA、runtime ownership、raw EBUSY、DiskImages2 tombstone、safe-eject 与 fail-closed 架构。
- [x] 新建 `Apps/Drive/docs/TESTING.md`，明确 fast/virtual/storage/system/UI/installed/physical 各层证据权限及 GitHub Actions responsibility split。
- [x] 新建 `Apps/Drive/docs/RELEASE-CHECKLIST.md`，固化 exact-head package/CI/install/FDA/reboot/physical/safe-eject 发布门禁。
- [x] 新建 `Apps/Drive/docs/HISTORICAL.md`；旧 2026-08 Drive plans/tracker 与 `HANDOFF-2026-08-29.md`、`HANDOFF-2026-09-01-real-device-ebusy-finalization.md` 已明确标记 HISTORICAL/superseded，不删除历史证据。
- [x] 旧 tracker 未勾选项不再作为当前技术债入口；当前总览已按 A/B/C DONE、D1/D2 DONE、D3/D4 pending 重写。
- [x] 文档与 Makefile/CI targets 本机一致性验证完成：新增 `DRIVE_SYSTEM_CURRENT_DOCS_OK` ratchet；`git diff --check`、system、fast、virtual、S01-S35/320000-step property 全部 PASS。
- [x] Phase E fixed-head CI：`b3de761` / run `33701172126` 的 native、fast、virtual、UI-system、storage 全部 PASS；UI `UI_HITCH_COUNT_GT33MS=0` / `UI_HITCH_MAX_MS=0.000`，storage M01-M14 5m53s 正常完成。Phase E 正式关闭。

## Phase F — NTFS RW ADR

状态：DONE

- [x] 真实需求已拆分：当前必须保证的是 type2/type4 正常 create/edit/delete/remount persistence；该需求不等价于必须保持 NTFS on-disk 格式。
- [x] Apple native NTFS RO 被接受为现有 NTFS 介质的兼容模式；UI/XPC 继续按真实 `readOnly` capability 展示，不做 write probe。
- [x] 独立 NTFS RW provider 的技术/分发约束已审查：若未来自研 FSKit filesystem，需要独立 app extension、`com.apple.developer.fskit.fsmodule` entitlement、完整 NTFS 一致性/恢复/Windows interoperability 测试面；本稳定化分支不引入该生命周期。
- [x] 已输出 `Apps/Drive/docs/ADR-2026-09-03-ntfs-rw.md`，正式选择 A+C：现有 NTFS 走 Apple-native RO；需要跨平台可写的数据卷优先使用 ExFAT；禁止自动格式化/迁移。
- [x] `ntfs-3g` 与 undocumented Apple NTFS write path 均保持禁止；Option B 只有出现“必须保持 NTFS 且必须写入”的硬产品需求时才能作为独立项目重新立项。
- [x] Apple 当前官方文档复核：Disk Utility 将 FAT/ExFAT列为 Windows-compatible 格式，>32GB 推荐 ExFAT；FSKit filesystem 通过 app extension 提供，当前文档仍要求 filesystem module entitlement。
- [x] Phase F fixed-head CI：`f734f43` / run `33711677562` 的 native、fast、virtual、UI-system、storage 全部 PASS；UI `UI_HITCH_MAX_MS=0.000` / `UI_HITCH_COUNT_GT33MS=0`，storage M01/M02/M03/M10×5/M12/M14/failure-contracts/production strict/`DRIVE_STORAGE_E2E_OK` 全绿。Phase F 正式关闭。

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
