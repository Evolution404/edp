# EDP Drive 异步生命周期收口 — 实时进度

日期：2026-08-30
分支：`codex/ui-macos26-liquid-glass`
计划：`docs/PLAN-2026-08-30-async-lifecycle-hardening.md`
初始基线：`44eaa151408ae91af8987bf7155f51b88c6bf13a`

> 本文件随每个阶段实时更新。只记录实际完成并有证据的结果；超时、未返回最终 marker、未安装等情况不得写成 PASS。

## 总览

| Phase | 内容 | 状态 |
|---|---|---|
| A | 基线、计划、架构 ratchet | DONE |
| B | Disk Arbitration async | DONE |
| C | BlockPublisher / DiskImages2 async | DONE* |
| D | Typed lifecycle errors | DONE |
| E | Virtual clock / scheduler | DONE |
| F | Deterministic model/property tests | DONE |
| G | Structured lifecycle journal | DONE |
| H | 全量/安装态/真盘验收 | PARTIAL（仅独立 UI performance gate） |

## 进入本计划前已确认完成

- FSKit mount 只保留异步状态机实现；旧同步 mount 已删除。
- transport teardown 只走 `stopAsync()`。
- controller/XPC mount/unmount/eject/shutdown 已 async。
- duplicate mount single-flight。
- cancellation 优先于 recovery/retry。
- terminal state late callback idempotence。
- S13-S18 已加入并通过。
- service UI start/stop/restart 使用显式 lifecycle state。
- `ThrottleInterval=1` 已加入两个 service plist。
- macFUSE runtime code-sign verification 已从 `/usr/bin/codesign` 改为 Security.framework。
- App 正常服务状态路径已移除 `/bin/launchctl`。
- VFS unmount 已从 `/sbin/umount` 改为 `unmount(2)`。
- macFUSE enablement 已移出 MainActor 固定 sleep 路径。
- 最近一轮 `make drive-test-ui`：max hitch 8.333ms，0 个 >33ms，PASS。
- storage smoke 已完整 PASS 两次。
- release storage 本地执行产生 M10 adapter/attach 50/50，执行到 M12/M14，结束后无挂载/image/process residue；因单次工具 300s 上限没有获得最终 `RESULT=DRIVE_STORAGE_E2E_OK`，因此 release gate 仍记为未完整返回。
- 最新 native installer 已成功构建为 `artifacts/EDP-Drive-0.6.0-Native.pkg`。
- 当前 shell 无非交互 sudo，无法无人值守安装最新包并跑 installed `service-cycle`；不得使用历史密码或触发不可控密码流程。

## Phase A — 基线、计划、架构 ratchet

### A1 计划与 tracker

- [x] 新建完整计划：`docs/PLAN-2026-08-30-async-lifecycle-hardening.md`
- [x] 新建实时 tracker：本文件
- [x] 提交并 push 计划/跟踪文件

### A2 当前工作树审计

进入计划时已有 22 个 WIP 文件；这些修改来自前一轮异步状态机、服务生命周期、storage/UI/system hardening，不重置、不丢弃。

待执行：

- [x] `git diff --check` PASS
- [x] `make drive-test-fast` PASS，`RESULT=DRIVE_FAST_OK`
- [x] `make drive-test-system` PASS，`RESULT=DRIVE_SYSTEM_OK`
- [x] system ratchet 已覆盖 async-only / no launchctl / no codesign / no umount，`RESULT=DRIVE_SYSTEM_NATIVE_RUNTIME_CONTROL_OK`
- [x] 完成 Phase A commit/push

## Phase B — Disk Arbitration async

状态：DONE

目标：删除生产 `DAOperationBox + DispatchSemaphore.wait()` 同步化路径，把 DA callback 直接转成 async lifecycle event。

验收项：

- [x] async protocol/API：`unmountWholeAsync` / `unmountAsync` / `mountAsync` / `mountNobrowseAsync` / `ejectAsync`
- [x] timeout/late callback once-only：`EDPDiskArbitrationCompletionGate`
- [x] production 无 DA semaphore wait；同步 adapter 仅存在于 `EDP_REGRESSION_TESTS`
- [x] mount/unmount/eject/Finder staging/physical eject 调用点全部迁移
- [x] raw-access acquire 顺带改成 per-device single-flight async，避免 controller 等 DA unmount
- [x] persisted-session recovery 改 async，startup reconcile 等 recovery completion 后才启动
- [x] S19：callback-first / timeout-first late callback / duplicate callback once-only
- [x] service lifecycle C01-C08、D01-D13、S01-S19、M11 PASS
- [x] `make drive-test-system` PASS，含 `RESULT=DRIVE_SYSTEM_ASYNC_DISK_ARBITRATION_OK`
- [x] `make drive-test-virtual-usb` PASS
- [x] `make drive-test-storage-smoke` PASS，M10 5/5，FD 9/9，M12/M13/M14 PASS
- [x] `git diff --check` PASS
- [x] commit/push：`6ebbf02 refactor(drive): harden asynchronous lifecycle boundaries`

## Phase C — BlockPublisher / DiskImages2 async

状态：DONE*（代码/hardware-free gate 完成；本机 storage ×2 因 root-owned 历史 orphan 污染环境待管理员清理后补验，不伪记 PASS）

验收项：

- [x] async publication protocol：`publishWritableImageAsync` + cancellable operation ownership
- [x] async bounded helper process：normal / timeout / TERM / KILL / cancel / once-only completion
- [x] scratch cleanup 无 production `Thread.sleep`
- [x] exact backing/owner revalidation；BSD 消失不再等价于 DiskImages2 owner 已退出
- [x] cancellation priority；cancel-before-launch 与 publication-wins race 均有明确资源回收语义
- [x] publication late callback once-only；S20 覆盖 async process timeout/cancel/once-only
- [x] 独立 `run-block-publisher.sh` 已接入 `drive-test-fast`；`RESULT=DRIVE_BLOCK_PUBLISHER_OK`
- [x] macFUSE scratch parser/baseline async contract 实际编译执行；`RESULT=MACFUSE_SCRATCH_CLEANUP_CONTRACT_OK`
- [x] policy persistence race 同期修复：store load-modify-save 串行化、PID+UUID temp file；lifecycle harness direct run 20/20 PASS
- [x] storage harness 加固：phased mode、profile marker、phase-start leak gate、synthetic BSD settle/revalidation、bounded hdiutil attach、erase timeout result-state recovery、owner-only publication detection
- [ ] storage smoke ×2 PASS：本机存在 root-owned 4KiB macFUSE scratch orphan 与 owner-only DiskImages2 publication，普通用户不可安全回收；待一次管理员清理后补验
- [ ] installed service-cycle：同上，待管理员安装 clean combined installer 后执行
- [x] commit/push：`130b385 refactor(drive): make block publication lifecycle asynchronous`

## Phase D — Typed lifecycle errors

状态：DONE

验收项：

- [x] typed lifecycle error enum：`EDPLifecycleFailureCode` + `EDPLifecycleFailure`
- [x] recovery policy 不依赖上层字符串匹配；bridge/raw helper 文本只允许在最底层 adapter 解析一次
- [x] raw/bridge/publication/filesystem/teardown/cancel/invalid-transition error 分类
- [x] MountManager 暴露 typed `lastFailureCode`，controller transient retry 直接按 `.bridgeExtensionUnavailable` 决策
- [x] S11-S21 PASS；S21 专门锁定 typed error taxonomy
- [x] `make drive-test-fast` PASS
- [x] `make drive-test-system` PASS，含 `RESULT=DRIVE_SYSTEM_TYPED_LIFECYCLE_ERRORS_OK`
- [x] `make drive-test-virtual-usb` PASS
- [x] commit/push：`393e0f4 refactor(drive): type lifecycle failure decisions`

## Phase E — Virtual clock / scheduler

状态：DONE

验收项：

- [x] production monotonic scheduler：`EDPLifecycleScheduling` + `EDPDispatchLifecycleScheduler`，基于 `DispatchTime.uptimeNanoseconds`
- [x] deterministic test scheduler：transport fast validator 与 service lifecycle S22 使用 manual scheduler/`advance()`
- [x] bridge 8s、transport stop 各阶段、unmount/eject/shutdown drain 15s timeout 全部注入 scheduler；不再使用 `Date()` 决策 lifecycle deadline
- [x] timeout/cancel same-tick：S22 验证同 deadline 确定顺序、cancel terminal sticky、late recovery 不可复活
- [x] transport validator 输出 `RESULT=TRANSPORT_LIFECYCLE_VIRTUAL_CLOCK_OK`
- [x] system ratchet 输出 `RESULT=DRIVE_SYSTEM_VIRTUAL_CLOCK_LIFECYCLE_OK`
- [x] `make drive-test-fast` / service lifecycle / system PASS；native installer 实际构建 PASS
- [x] commit/push：`b49e1f9 refactor(drive): inject monotonic lifecycle scheduler`

## Phase F — Deterministic model/property tests

状态：DONE

验收项：

- [x] 固定 seed event generator：`0xed505a1720260831`，每个 sequence 派生独立可重放 seed
- [x] 10,000 sequences × 32 steps = 320,000 lifecycle events
- [x] terminal sticky / DA completion exactly-once / recovery budget <=1 / retry <=1 / cancel 后不 launch/publish/recover / publication ownership invariants
- [x] failure trace 可复现：输出 fixed seed、sequence index、sequenceSeed、逐步 event/action/state/budget/resource trace
- [x] 模型首次运行实际发现并修复：late `stageFailed` 可覆盖 failed/mounted terminal；terminal failure 时 in-flight publication token 未显式 cancel
- [x] 最终覆盖：mounted=952、failed=9048、retry=1013、recovery=1013、cancel=5765、publish=3270、filesystem=1740
- [x] `RESULT=DRIVE_LIFECYCLE_MODEL_PROPERTIES_OK`
- [x] commit/push：`eefd240 test(drive): model lifecycle state invariants`

## Phase G — Structured lifecycle journal

状态：DONE

验收项：

- [x] 新增 `EDPLifecycleJournal.swift`，默认 256 条 bounded ring buffer
- [x] schema 已含 operationID/device/partition/state/event/attempt/recoveryBudget/elapsedMs/ownedResources/diagnosticCode
- [x] journal API 不提供 password/key/raw plaintext/helper stderr 字段
- [x] MountManager protocol 已增加 `lifecycleJournalSnapshot()`，mount request/single-flight/cancel/terminal 已开始接入
- [x] journal 源文件已开始加入 service/installer/storage 构建清单
- [x] bridge/publication/filesystem/cleanup/recovery 全 transition 接全
- [x] unmount/eject/shutdown structured events 接入；eject terminal 延伸到 physical Disk Arbitration handoff，shutdown 重复请求记录 coalesced event
- [x] `diagnosticsData()` export `lifecycleJournal`
- [x] S23 bounded/redaction/sequence/elapsed/operationID/JSON diagnostics contract tests
- [x] system journal ratchet，禁止无界 journal 与 password/credential/plaintext/stderr/rawPath 等敏感 schema 字段
- [x] `make drive-test-fast` / service lifecycle / `make drive-test-system` / `make drive-test-virtual-usb` + `git diff --check` PASS
- [x] commit/push：`d3e4845 feat(drive): add bounded lifecycle diagnostics journal`

完整后续执行说明：`docs/HANDOFF-2026-08-31-async-lifecycle-finalization.md`

## Phase H — 最终验收

状态：PARTIAL（安装态与真实盘收口 DONE；仅独立 sidebar animation 33ms performance gate 未通过）

### Hardware-free

- [x] fast
- [x] virtual-usb
- [x] system
- [ ] UI：功能/结构/accessibility PASS；2026-09-01 17:25 exact-head 复跑 sidebar animation performance gate：`UI_HITCH_MAX_MS=66.666`、`UI_HITCH_COUNT_GT33MS=2`，仍未通过；和本轮 raw/eject lifecycle 修改无代码路径交叉，未降低 33ms 门槛
- [x] storage smoke #1
- [x] storage smoke #2
- [x] release storage final marker（2026-09-01 eject generation hardening exact-source：M10 5/5，`RESULT=DRIVE_STORAGE_E2E_OK`）
- [x] bash -n
- [x] plutil -lint
- [x] git diff --check
- [x] installer build/verify

### Installed service-cycle

- [x] 最新 package 已安装
- [x] 8 cycles
- [x] 每次 start <= 3000ms
- [x] minimum runtime=1
- [x] daemon count=1
- [x] 无 progressive slowdown

安装态已验证 `13ad0b4` Clean.pkg：安装前重新枚举 synthetic/storage-test publication=0、4KiB scratch=0、EDP mount=0、external physical=0；安装成功后 App 显式启动恢复 `desired-running=1`，daemon `state=running`、minimum runtime=1、process count=1。正式 8-cycle 单进程 monotonic 结果：46 / 1077 / 1066 / 1062 / 1074 / 1058 / 1054 / 1060 ms；cycle 1 作为 warmup，仅对 cycle 2...8 steady-state 判断趋势，FIRST_AVG=1068.3ms、LAST_AVG=1057.3ms、slope=-2.8ms/cycle，`RESULT=SERVICE_RESTART_CYCLE_OK`。

### Physical EDP USB

- [x] 标准加密 SanDisk EDP 真实盘重新插入并按 fresh generation 枚举；五因素一致：VID:PID=`0781:5591`、onlyID=`2387350191`、capacity=`123010547712`、metadata deviceID=`disk&ven_sandisk&prod_ultra_usb_3.0&rev_1.00`
- [x] exact-head 安装后两次 fresh physical reinsert 均 `RESULT=FDA_RETAINED_RAW_ACCESS_READY`，`privilegedAccessReady=true`；未要求或新增 `com.edp.drive.service` 单独 FDA
- [x] 两次 fresh insert 均未实际出现 raw `EBUSY`，Disk Arbitration 只记录正常 pre-open whole-unmount `options=0x00000001`，因此不虚构 physical EBUSY recovery 被触发；S31–S35/system deterministic gate 已证明 `EBUSY -> exact-generation Whole|Force -> 单次 retry` 逻辑
- [x] type1 FAT16 read-only：两轮 mount -> unmount -> remount -> unmount PASS，无 filesystem write
- [x] type2 Apple NTFS read-only：两轮 mount -> unmount -> remount -> unmount PASS；`autoMount=true` 策略在 fresh reinsert 后自动恢复挂载
- [x] type4 凭据由用户在 App UI 验证并保存；Apple NTFS read-only 两轮 mount -> unmount -> remount -> unmount PASS，密码未进入 shell/log
- [x] device policy round-trip/restore PASS
- [x] 产品 XPC safe eject 连续两次 PASS；不再出现 `Disk Arbitration refused ... status=-119930877` / `kDAReturnBadArgument`
- [x] 最终 safe-eject 后 EDP physical media 从系统消失；EDP/macFUSE mount=0、`.edp-block-*`=0、transport process=0；Finder/UVFS/service 无 U-state
- [x] 全程未 format / erase / repartition / raw test write；真实盘仅执行识别、raw lease、filesystem read-only mount/unmount 与产品 safe eject

## 变更日志

### 2026-09-01 17:25 — Exact-head real-device finalization PASS; only unrelated UI perf gate remains

- 从远端 exact HEAD `b9883503f43602f499139cf72895834c8ba5954e` 重新执行 `make drive-test-fast`、`make drive-test-virtual-usb`、`make drive-test-system` 与 `git diff --check`，S31–S35、10,000×32 deterministic model、raw validation/EBUSY recovery system ratchet 全部 PASS。
- 从 exact HEAD 重新构建并 verifier PASS 的 `Apps/Drive/artifacts/EDP-Drive-0.6.0-arm64-Clean.pkg` SHA-256=`ed2ad5aa41b745f08f2f06906d1786fb32c756444bc34dfc7623c400f1b51f3f`；在 SN750 作为无关 FSKit 外盘存在、EDP 用户文件系统未挂载的受控现场完成 upgrade install，App/service/runtime strict codesign、LaunchDaemon/XPC/FSKit enablement 正常。
- 第一次 fresh reinsert 将 EDP 重新枚举为 `disk30`；五因素一致，`verify-fda-device 0781:5591` 返回 `RESULT=FDA_RETAINED_RAW_ACCESS_READY`。该轮 DA 只出现 `options=0x00000001` 的正常 whole-unmount，没有 `0x00080001` force request，因此本次未触发 EBUSY recovery，不把它误记为 recovery activation PASS。
- type1 FAT16 read-only 与 type2 Apple NTFS read-only 各完成两轮 capability-aware mount/unmount/remount；用户随后只在 App UI 保存 type4 真实密码，type4 Apple NTFS read-only 同样完成两轮，无密码进入命令行/日志、无真实盘 filesystem marker/raw write。
- 第一次产品 XPC safe eject 返回 `RESULT=SAFE_EJECT_SUPPRESSION_OK`，EDP physical generation 消失，EDP/macFUSE/backing/transport residue=0，Finder/UVFS/service 无 U-state，日志无 `-119930877/BadArgument`。
- 第二次 fresh reinsert 再次 `RESULT=FDA_RETAINED_RAW_ACCESS_READY`，type2/type4 credential 均保留且 type2 autoMount 正常；本轮仍只有正常 whole-unmount、无 EBUSY/force。随后第二次产品 XPC safe eject 再次 PASS，最终系统只剩无关 SN750，EDP residue=0、无 U-state、无 BadArgument。
- 真实盘 EBUSY/safe-eject/capability-aware/FDA-retention 收口至此完成。独立 `make drive-test-ui` 同一 exact source 复跑功能/结构/accessibility 全 PASS，但 sidebar animation performance 为 `UI_HITCH_MAX_MS=66.666`、`UI_HITCH_COUNT_GT33MS=2`，保留 33ms 硬门槛，作为本计划唯一未完成项。

### 2026-09-01 13:50 — Installer scratch recovery no longer blocked by unrelated FSKit mounts

- exact-head upgrade 验证时，系统同时挂载无关外接盘 `/Volumes/SN750-500GB`（ExFAT/FSKit），且此前 synthetic run 留有一个 exact 4 KiB macFUSE scratch `/dev/disk27`（8×512、root owner、标准 UUID dmg、live `diskimages-helper`）。旧 preinstall 在 scratch direct-detach 前用全局 `mount | grep fskit` 直接拒绝安装，导致 package script 97.75% 失败。
- 根因是安全门位置过早：live exact scratch 可独立 `hdiutil detach`，不需要重启 `fskit_agent`，因此不应被与 EDP 无关的 FSKit 卷阻断。真正可能影响其他 FSKit 卷的只有 stale-helper recovery 中的 `fskit_agent` recycle。
- 修复：删除 direct-detach 前的全局 FSKit mount 拒绝；保留 `recover_stale_console_fskit_agent()` 内已有的全局 FSKit mount fail-closed。也就是说 live-helper scratch 允许在无关 FSKit 卷存在时精确回收；只有 stale helper 且必须 recycle agent 时才要求全局无 FSKit mount。
- system 新 marker `RESULT=DRIVE_SYSTEM_INSTALLER_UNRELATED_FSKIT_MOUNT_OK`，锁定：全局 `fskit` mount 检查仅保留一处、direct scratch detach 必须位于 stale agent recovery 之前、旧的过宽拒绝文本不得回归。`bash -n`、`run-system.sh`、Clean.pkg build/verifier PASS。

### 2026-09-01 13:31 — Physical eject stale-BSD race / generation reuse / concurrent lifecycle hardening

- 真实用户现场复现：点击安全推出后 UI 弹 `Disk Arbitration refused disk4: status=-119930877`。该值为 `0xF8DA0003 = kDAReturnBadArgument`。Disk Arbitration 日志证明 physical `/dev/disk4` 已先 `removed`，随后 EDP 继续完成 synthetic `/dev/disk6` 与 `/dev/disk5` teardown；旧代码最终仍使用缓存 `bsdName=disk4` 发 `DADiskEject`，把“设备已经成功离开系统”误报成操作失败。
- 正式 physical DA 操作不再只绑定易复用的 `diskN`。`unmountWholeAsync/ejectAsync` 新增可选 exact whole-media `registryEntryID`，在发 DA request 前通过 `DADiskCopyIOMedia + IORegistryEntryGetRegistryEntryID` 复核当前 BSD generation；原盘消失或同名 `diskN` 已被替换时不允许触碰 replacement device。
- controller 的 physical eject 改为 generation-aware idempotence：synthetic teardown 期间原 USB `usbRegistryEntryID` 已消失时直接 terminal success；DA callback 返回 error 后若重新枚举证明原 USB generation 已消失，同样归一化为 success；只有原 generation 仍存在时保留真实 DA failure。绝不全局吞 `BadArgument/NotFound`。
- duplicate eject 改成 single-flight completion fanout，重复点击只共享一次 teardown/physical eject；成功和失败均向所有等待者返回同一个 terminal result，不再弹“eject is already in progress”。
- graceful shutdown 与 physical eject 交错时，shutdown 先 quiesce/reject 新工作并等待所有 in-flight eject terminal，再执行 `unmountAll -> raw lease release -> service exit`，防止 daemon 在 DA callback 前退出。
- synthetic DiskImages2 publisher 仍以 exact backing-path metadata 为 identity；其 DA API 显式传 `expectedRegistryEntryID:nil`，不把 physical IOKit generation 规则错误套用到 DiskImages2 synthetic publication。
- 新增 deterministic lifecycle S24–S30：physical disappearance during teardown、diskN replacement generation、live-generation DA failure、late DA error after disappearance、duplicate eject success fanout、shutdown waits eject、duplicate eject failure fanout。全部 PASS；10,000×32 lifecycle model 仍 PASS。
- system 新 marker `RESULT=DRIVE_SYSTEM_PHYSICAL_EJECT_GENERATION_RATCHET_OK`，锁定 registry-generation 绑定、disappearance idempotence、duplicate-eject single-flight 与 shutdown/eject ordering。
- hardware-free：`drive-test-fast`、`drive-test-system`、`drive-test-virtual-usb` 全 PASS。fresh release storage workdir 完成 prepare/core/M10 5/5/recovery/contracts/final：`M10_FD_BASELINE=9`、`M10_FD_MAX=9`、无 mount/device/process/FD leak，最终 `RESULT=DRIVE_STORAGE_E2E_OK`。Clean.pkg 构建与 verifier PASS。
- UI 功能/结构/accessibility 仍 PASS，但当前 sidebar animation performance gate 独立出现 91–116ms hitch；该问题不属于 eject lifecycle 路径，保持未通过状态，未降低门槛。

### 2026-09-01 08:05 — Native-FS quiescence build/install and installed-runtime PASS

- storage release PASS 后提交验收记录，package build HEAD 为 `73e11288f4646c6ed4bb0a86fbbe8a70b2f1830f`（产品代码仍为 `fec8de129db337695b8084ab1c9443053bcd87b9`）。
- 重建 `Apps/Drive/artifacts/EDP-Drive-0.6.0-arm64-Clean.pkg` 并通过 clean-installer verifier；SHA-256=`5dd3895bf3bd4065cbaa1edc5427417ac5d4687b13338cdabaeba5f0426a2e46`。
- 在无 external physical USB、无活动 EDP mount 的现场通过 acceptance 管理员路径完成 upgrade install；`verify-installed` PASS，App/service/runtime codesign、LaunchDaemon、XPC roundtrip/snapshot 均正常。
- 重启 App 后 FSKit enablement 稳定：`io.macfuse.app.fsmodule.macfuse` 与 `io.macfuse.app.fsmodule.macfuse-local` 均在 enabledModules，PluginKit 两者均为 `+`；service health PASS。
- installed `service-cycle` 8/8 PASS：`48 / 1055 / 1061 / 1085 / 1062 / 1065 / 1060 / 1061 ms`，FIRST_AVG=1067.0ms、LAST_AVG=1062.0ms、slope=-0.1ms/cycle，每轮单 daemon；结束后 App/service 正常、Finder 为 `S`、无 UVFSService 残留。
- 当前无 external physical USB；下一 gate 为重新插入同一标准加密 EDP U 盘，复核 retained FDA + 五因素身份，并重点验证 type1/type2/type4 最终 unmount/pre-unpublish quiescence/safe eject。

### 2026-09-01 07:56 — Native-FS pre-unpublish quiescence synthetic release PASS

- 重启后以 exact code HEAD `fec8de129db337695b8084ab1c9443053bcd87b9`、无 external physical USB、无历史 U-state 的干净基线，使用全新 synthetic workdir 执行 canonical release storage 5-loop。
- `prepare` PASS；`core` 全部通过：M01 FAT16 read-only、M02/M04-M09 Exchange I/O/持久化、M03 Secure stage1 -> native unmount -> upper-FS quiescence -> DiskImages2 detach -> remount/hash 均 PASS。core 后 Finder 为正常 `S`，无 UVFSService 残留。
- `stress` M10 5/5 PASS，`M10_FD_BASELINE=9`、`M10_FD_MAX=9`，无 mount/device/process/FD leak；M10 后 Finder 仍为正常 `S`，无 UVFSService U-state 或 test mount residue。
- `recovery` M12/M14 PASS；`contracts` M13 durability failure propagation + production Swift 6/C17 strict build PASS；`final` 返回 `RESULT=DRIVE_STORAGE_E2E_OK`。
- 该结果实证前一轮根因修复有效：native filesystem unmount 后必须先保留 DiskImages2 IOMedia 进入 3 秒 upper-FS/UVFS/LIFS deactivate quiescence，之后才允许 publication detach；publication + transport 全部退出后再执行现有 generation quiescence。

### 2026-09-01 05:26 — Exact-head installer ready; unrelated concurrent storage run polluted current kernel state

- 提交 `fbab2ea9eb96f880aea12a0ada24eb77b864a625` 后重新构建 exact-head Clean.pkg，`verify-clean-installer.sh` 全部 PASS；SHA-256=`ca5f34c1c82ed19decacddf619aa50b048769edc923fd0989862831dff04525f`。
- 另一个由 DevSpace 父进程独立启动的 `edp-storage-e2e.release-65fbd4e-fresh.*` run 最终父 bash 自行退出，但遗留一个 orphan fixture adapter 与 `diskimagesiod` U-state；未主动 kill/detach 该并发会话。随后连只读 `diskutil list external physical` 都无法在 30s 内返回，证明当前内核现场已污染，不能继续安装态/真实盘验收。
- 下一步：重启后不再重建 package，先确认无 external physical / U-state，再直接安装上述 exact-head package；随后重新插入标准加密 SanDisk，复测 type1/type2/type4 capability-aware mount/remount/unmount、safe eject、拔插 FDA retention。

### 2026-09-01 05:19 — Storage harness aligned to direct Disk Arbitration; canonical 5-loop release PASS

- 重启后的干净无盘基线以 HEAD `65fbd4e63fb3d42fdfc4f7e462abdcb1b96f692c` 复跑 synthetic release。最初 M10 暴露测试 harness 仍使用 `/usr/sbin/diskutil mount`：DiskImages2/bridge 已正常 publication，但 `diskutil` 同步前端在 final reply 阶段 20s bounded timeout；正式产品并不走这条同步 CLI。
- 新增 `Tests/Storage/DiskArbitrationMountHelper.c`，C17 `-Wall -Wextra -Werror`：直接使用 Disk Arbitration callback 做普通 mount、`rdonly` custom mountpoint、unmount，并仅通过 `getmntinfo(MNT_NOWAIT)` 验证 exact `/dev/diskN` mount table 状态。storage `mount_native`、boot FAT16 read-only mount、`unmount_path` 全部迁移到该 helper；M10 不再执行 `diskutil mount` 或 `/sbin/umount`。
- 随后 M10 又暴露 hdiutil snapshot 文件 TOCTOU：`capture_hdiutil_info()` 对固定目标先 truncate，再由相邻 exact-identity reader 解析，可能在一个 reader 已 lint PASS 后被另一个 capture 截断，形成 partial XML。现改为每次 capture 写独立 `mktemp` candidate，`plutil -lint` 通过后才原子 `mv` 发布完整 snapshot；system ratchet 锁定 atomic snapshot contract。
- 在同一 prepared synthetic workdir 重新执行：core PASS；M10 canonical 5/5 PASS，`M10_FD_BASELINE=9`、`M10_FD_MAX=9`；M12 crash recovery、M14 concurrent type1/2/4、M13 durability failure propagation、production Swift6/C17 strict build 全 PASS；final 返回 `RESULT=DRIVE_STORAGE_E2E_OK` 并删除 workdir。
- system gate新增 `RESULT=DRIVE_SYSTEM_STORAGE_DIRECT_DA_MOUNT_OK` 与 `RESULT=DRIVE_SYSTEM_STORAGE_ATOMIC_HDIUTIL_SNAPSHOT_OK`，同时保持 metadata-only publication teardown / remount quiescence / FAT16 FSKit read-only ratchet。
- 收尾时发现另一个由 DevSpace 父进程单独启动的 `edp-storage-e2e.release-65fbd4e-fresh.*` 并发 run；它不是本次 phased workdir，且已出现独立 `diskimagesiod` U-state。未对该并发 run 做 kill/detach/清理，避免破坏其他会话；安装/真实盘复测必须等该现场退出并重启后进行。

### 2026-08-31 23:31 — Real-device NTFS teardown exposed backing-path stat U-state; metadata-only teardown implemented

- 插入唯一真实标准加密 SanDisk EDP U 盘后，XPC snapshot 五因素与 retained FDA 实证通过：physical=`disk26`（仅作为当次枚举记录，不作为后续授权依据）、VID:PID=`0781:5591`、LBA4 onlyID=`2387350191`、capacity=`123010547712`、LBA11 metadata deviceID=`disk&ven_sandisk&prod_ultra_usb_3.0&rev_1.00`，`privilegedAccessReady=true`。type1 FAT16 read-only 挂载/卸载已完整 PASS，无 Finder U-state。
- 用户在 UI 中保存 type2/type4 真实密码后 `credential-checkpoint` PASS，policy round-trip PASS。真实 type2/type4 均由 Apple native NTFS 以 `NTFS (read-only; Finder erasable)` / `readOnly=true` 挂载，因此旧 acceptance 的“三分区一律写 marker”假设与当前 production policy 冲突。
- `first-install-acceptance.sh` 改为 capability-aware：mount/unmount terminal state 与 exact mountPoint 均由 production XPC snapshot 判定，不再硬编码 `/Volumes/启动区|交换区|保密区`；type1 强制 read-only；任意 `readOnly=true` 分区只做 mount -> unmount -> remount -> filesystem/readOnly 一致性验证，只有 `readOnly=false` 才执行临时 marker/hash persistence 写测试。`safe-eject` 同样改为 snapshot-based mount residue 验证。文档与 system ratchet 同步更新。
- 新 acceptance 实测：type1 两次 read-only mount/unmount PASS；type2 NTFS 两次 read-only mount/unmount PASS；type4 第二次 mount 成功，但最后一次 unmount CLI 90s timeout。系统日志证明 native NTFS `disk28` 已完成 unmount/eject，随后 DiskImages2 owner 退出阶段延迟；Finder 始终正常，但 root `edp-drive-service` 进入 `U`，snapshot 随后 timeout，type4 transport 仍存活。
- 根因直接落到 `EDPBlockDevicePublisher.parsePublication()`：bounded `hdiutil info -plist` 返回 exact publication 后，代码仍同步 `stat("/Volumes/.edp-block-.../volume.raw")` 并 `stat(/dev/diskN)`。真实 NTFS teardown 正处于 macFUSE/FSKit generation 退出窗口，这个 backing-path `stat()` 会把 privileged service 自身拖入不可中断等待，复现了此前 synthetic harness 已发现的同类危险 syscall。
- 修复：DiskImages2 teardown identity 完全改为 metadata-only。`parsePublication()` 仅使用 exact standardized `image-path`、owner UID/mode、`diskimages2=true`、`autodiskmount=false`、unencrypted、hdid PID 与严格 `/dev/disk...` system-entity string；在任何 recovery signal 前继续通过 `processExecutablePath(pid)==/usr/libexec/diskimagesiod` 与第二次 exact metadata snapshot 复核。不再 stat macFUSE backing path 或 synthetic BSD node。
- 新 system marker `RESULT=DRIVE_SYSTEM_PUBLICATION_METADATA_ONLY_TEARDOWN_OK` 禁止该同步 stat 回归；同时新增 `RESULT=DRIVE_SYSTEM_REAL_DEVICE_CAPABILITY_ACCEPTANCE_OK`。`make drive-test-fast`、`make drive-test-system`、`make drive-test-virtual-usb`、`git diff --check` 全绿。当前已安装旧 service 仍处 U-state，必须重启后以新二进制重新执行 storage 5-loop 与真实 type4 teardown。
- 修复提交 `419d83fe7250c461c4f8b0034ca9e4320ff24510` 后已构建并 verifier PASS 的 exact-head `Apps/Drive/artifacts/EDP-Drive-0.6.0-arm64-Clean.pkg`，SHA-256=`9b0c7ab91d4a95f5d44d302f80d221f8271fdc940870e31dee506dfa1848d1ab`。该包尚未覆盖安装到当前 U-state 旧 service；重启清场、synthetic 5-loop PASS 后再安装并进行真实盘复验。

### 2026-08-31 23:10 — FDA granted; service acceptance foreground isolation fixed

- 用户已在系统设置中完成 EDP Drive Full Disk Access 授权；当前仍无 external physical USB，因此只记录“FDA 已授权”，raw access 是否真正 retained 必须等真实标准加密 EDP U 盘插入后由 `verify-fda-device` 的 `privilegedAccessReady=true` 实证。
- FDA 后执行 acceptance `service-restart` 时首次出现假 FAIL：daemon 已正常 graceful exit，但正在运行的 EDP Drive UI 每 2 秒 refresh，且其内存 `serviceDesiredRunning=true`，随后重新建立 privileged XPC，使 launchd 按需再次拉起 daemon；这不是 `KeepAlive`，也不是产品 UI 的 Stop 状态机失效，而是 out-of-process acceptance CLI 与 live UI desired state 不同步。
- `first-install-acceptance.sh` 新增 `stop_foreground_ui_for_service_gate()`：service-stop/service-cycle 在断言 daemon 稳定停止前，仅终止 exact `/Applications/EDP Drive.app/Contents/MacOS/EDP Drive` 前台进程，避免 UI polling 干扰硬件无关 service lifecycle gate；不使用宽泛 kill，也不改产品 stop/restart 状态机。
- 修正后 `bash -n`、`Tests/run-system.sh` PASS；installed `service-restart` 完整通过 `FOREGROUND_UI_ISOLATED_FOR_SERVICE_GATE -> SERVICE_GRACEFUL_STOP_OK -> SERVICE_ON_DEMAND_START_OK -> SERVICE_GRACEFUL_RESTART_OK`，随后 `restart-app` / `service-health` 继续 PASS。

### 2026-08-31 23:06 — Exact-head Clean.pkg installed and installed-runtime acceptance PASS

- 从 clean baseline 重启后再次确认 `FACTORY_CLEAN_BASELINE_VERIFIED`，exact package `artifacts/EDP-Drive-0.6.0-arm64-Clean.pkg` SHA-256 仍为 `e6e223f5124d8cf8f85b86e9bbc81929856c350634dad6af6c723861d68f5386`，未发生构建产物漂移。
- 使用 acceptance installer 安装该 exact package；安装完成后 `verify-installed` PASS：App/embedded service/macFUSE Local runtime 存在且 strict codesign 验证通过，LaunchDaemon 已加载，XPC roundtrip/snapshot 正常，service version=0.6.0，当前无 external physical USB。
- 首次启动 `EDP Drive` 后 console-user FSKit enablement 稳定收敛：`enabledModules.plist` 同时包含 `io.macfuse.app.fsmodule.macfuse` 与 `io.macfuse.app.fsmodule.macfuse-local`，PluginKit 两者均为 `+`；service `state=running`、`minimum runtime=1`。
- installed `service-cycle` 8/8 PASS：启动延迟 `10 / 1070 / 1092 / 1060 / 1053 / 1052 / 1053 / 1050 ms`；warmup 后 FIRST_AVG=1074.0ms、LAST_AVG=1051.7ms、slope=-5.2ms/cycle，无启动时间递增趋势且每轮仅一个 daemon，最终 `RESULT=SERVICE_RESTART_CYCLE_OK`。
- canonical FDA 页面已通过 `open-fda` 打开并定位 EDP Drive；当前无真实 USB，FDA retained raw access 必须等标准加密 EDP U 盘插入后通过 `verify-fda-device` 的 `privilegedAccessReady=true` 实证，不能仅凭 TCC UI 推断。

### 2026-08-31 22:58 — Exact-head Clean.pkg built, verified, and clean baseline ready

- 当前 HEAD `b4724f4cc82a4c2bfff47b1e3b992dce6b760b49` 仅比 storage code HEAD `b8ddfd3` 多最终验收记录；补跑 `make drive-test-ui` PASS，`UI_HITCH_MAX_MS=16.667`、`UI_HITCH_COUNT_GT33MS=0`，并完成全部 Drive shell `bash -n`、两个 service plist `plutil -lint`、`git diff --check`。
- 使用项目固定 self-signed wrapper `installer/build-self-signed-installer.sh artifacts` 构建 `Apps/Drive/artifacts/EDP-Drive-0.6.0-arm64-Clean.pkg`；内部 App/service/runtime 均使用固定 `EDP Project Code Signing`，组合包包含官方 macFUSE 5.3.3 组件。
- `scripts/verify-clean-installer.sh` 全部 contract PASS，包括 single Drive App + embedded service、legacy on-demand LaunchDaemon、ThrottleInterval=1、macFUSE-only transport、无 ntfs-3g/authopen runtime、FDA raw-fd3 path。
- exact package SHA-256：`e6e223f5124d8cf8f85b86e9bbc81929856c350634dad6af6c723861d68f5386`；生成的 `.sha256` 文件与现场重新计算一致。
- first-install acceptance `preflight` / `user-cleanup` PASS；管理员 clean stage 仅在重新验证 external physical=0、macFUSE/EDP mount=0、用户 keychain safe 后执行，旧 `/Applications/EDP Drive.app`、旧 product runtime、macFUSE 与 service 已清理。
- `first-install-acceptance.sh verify-clean` 返回 `RESULT=FACTORY_CLEAN_BASELINE_VERIFIED`，并明确 `NEXT=REBOOT_MAC_BEFORE_INSTALL`。临时 GUI authorization launchd job 已立即移除，避免重复授权/重复清理。

### 2026-08-31 22:44 — Exact-head canonical 5-loop storage release PASS

- 重启后以 exact HEAD `b8ddfd3d024ac54afbb0d6bbc045da2149342d63`、无 external physical USB、无历史 U-state / storage process 的干净基线执行 canonical release storage；为规避外层 300s 工具生命周期限制，使用 runner 原生 `prepare -> core -> stress -> recovery -> contracts -> final` phased mode，共用同一 synthetic workdir，验收语义与 `all` 完全一致。
- `prepare` PASS：C17/Swift 6 strict tools 构建完成，boot FAT16 + Exchange ExFAT + Secure ExFAT sparse combined fixture 准备完成。
- `core` PASS：M01 新 DA/FSKit FAT16 read-only 路径完整通过，transport 层 EROFS 正确；M02/M03 持久化、M04 Finder atomic save、M05 multi-delete、M06 rename overwrite、M07 Unicode、M08 128MiB sequential、M09 2500 fixed-seed random I/O 全部 PASS。
- `stress` PASS：M10 canonical 5/5 完整 mount/attach/filesystem/unmount/eject/transport teardown，`M10_FD_BASELINE=9`、`M10_FD_MAX=9`，无 mount/device/process/FD leak；这是此前重复触发 nested FSKit U-state 的核心回归门槛。
- M10 后只读 `ps` 验证 Finder 为正常 `S`，所有 `diskimagesiod` 为 `S/Ss`，无 `UVFSService`/storage process U-state。
- `recovery` PASS：M12 transport crash bounded cleanup/remount、M14 type1/2/4 concurrent sessions independent。
- `contracts` PASS：M13 fsync/final durability EIO 正确传播、production Swift6/C17 strict build PASS。
- `final` 返回 `RESULT=DRIVE_STORAGE_E2E_OK`；final residue gate 通过并删除 synthetic workdir。收尾再次确认 Finder 正常、无 UVFS/adapter/storage process U-state，Git 工作区无测试残留。

### 2026-08-31 22:22 — Boot FAT16 moved from legacy mount_msdos to Disk Arbitration / FSKit

- `80d1dd7` 重启后 canonical release storage 在 M01 暴露独立问题：hidden bridge 正常 `local,nobrowse`、`readonly=1`、source=`/dev/disk22`，DiskImages2 成功发布 `disk23`，且 `disk23` 的 `msdos_fskit` probe/stage 均成功；随后测试直接调用 `/sbin/mount_msdos`，触发 `kmutil load ... msdosfs.kext` 的 legacy kext 路径并立即失败，cleanup 后对应 `diskimagesiod` 进入不可中断 `U` state。
- 正式产品原 `mountFATReadOnly()` 也仍使用同一 `/sbin/mount_msdos -o rdonly` 路径，因此该问题不是测试专属。macOS 26 已由 Disk Arbitration staged `com.apple.fskit.msdos` 后，不应再绕过 DA 强制进入 legacy msdosfs.kext。
- `EDPDiskArbitrationController` 新增 `mountReadOnlyAsync(_:at:)`：通过 `DADiskMountWithArguments` 传 `rdonly`，回调后用 NOWAIT mount table 校验 exact mountpoint 与 read-only flag；全程 callback-driven，不引入同步 wait/sleep。
- boot mountpoint 预先以 0755 创建并 `chown` 给 console user；`mount_msdos(8)` 文档说明默认 owner/group/mask 取自 mountpoint，因此改用 DA 后仍保留原 Finder 权限语义。
- `MountManager.mountResolvedFilesystemAsync()` 的 FAT16 boot 分支改为异步 DA/FSKit，删除正式执行路径中的 `EDPNativeBoundedProcess.run(/sbin/mount_msdos)`。
- storage M01 同步改为 `diskutil mount readOnly -mountPoint ...`；`diskutil(8)` 明确说明该形式等价于通过 Disk Arbitration 将 `rdonly` 作为 `mount -o` 参数传给 filesystem implementation，不再直接调用 `/sbin/mount_msdos`。
- system ratchet 新增 `RESULT=DRIVE_SYSTEM_FAT16_FSKIT_READONLY_OK`，要求 product `mountReadOnlyAsync` / `rdonly` 存在并禁止 product/storage 重新执行 legacy `mount_msdos`。
- hardware-free 复验：`make drive-test-fast`、`make drive-test-system`、`make drive-test-virtual-usb`、`git diff --check` 全绿；generation/quiescence 与 local bridge ratchet 同时保持 PASS。当前 M01 失败现场遗留一个 `diskimagesiod` U-state，需重启后再跑 canonical 5-loop。

### 2026-08-31 21:38 — Nested FSKit remount deadlock: exact teardown + generation quiescence

- 删除 `diskutil info` 后长循环仍在后续轮次复现系统级 `U`：父 `run-storage.sh` 的采样最终停在普通 `stat()`，同一时刻 ExFAT `UVFSService` 与 Finder 也进入 `U`。因此前一版只消除了一个 `statfs()` 触发器，没有解决嵌套 FSKit 生命周期根因。
- `EDPBlockDevicePublisher.unpublishAsync()` 不再把 Disk Arbitration eject callback 当成 teardown terminal；eject 后必须按 exact `volume.raw` backing 重新确认 DiskImages2 publication 真正消失，必要时只对重新验证的 exact owner 做 bounded recovery。
- `MountManager` 新增 per-session generation quiescence gate：native filesystem、DiskImages2 publication、transport teardown 都完成后进入 3 秒 monotonic stabilization window；同一 `deviceID + partitionType` 的立即 remount 保持 single-flight 排队，旧 generation timer 无权释放新 generation barrier。
- 每个 mount operation / retry 的隐藏 bridge 路径加入 operation UUID generation + attempt，不再快速复用同一 `.edp-block-*` backing identity。
- mount failure cleanup/retry 同样经过 quiescence barrier，避免 recovery retry 绕过正常 unmount 的代际隔离。
- storage harness 保留真实文件 `stat`/读写验证，但在 exact teardown 后按产品语义等待 3 秒再 remount；canonical release 仍只跑 5 cycle。
- 初版同时尝试将隐藏 macFUSE bridge 从 `local,nobrowse` 改为仅 `nobrowse`。重启后的 M01 立即暴露只读 raw-file VFS 回归：`pwrite()` 先被接受、错误延迟到 close，证明改变 `MNT_LOCAL` 会改变既有 bridge 语义且不是安全的 deadlock 修复。该部分已撤回；bridge 保持 `local,nobrowse`，生命周期隔离独立承担 remount 安全性。
- 新增 virtual-clock generation regression `RESULT=REMOUNT_QUIESCENCE_GENERATION_OK` 和 system `RESULT=DRIVE_SYSTEM_REMOUNT_QUIESCENCE_OK`；system 同时锁定既有 `local,nobrowse` transport contract。
- hardware-free 验证：`make drive-test-fast` PASS、`make drive-test-system` PASS、`make drive-test-virtual-usb` PASS、transport backend C17/Swift build PASS、`bash -n` / `git diff --check` PASS。storage 需在撤回 nonlocal bridge 后重新从干净重启基线验证 canonical 5-loop。

### 2026-08-31 21:11 — Canonical storage release reduced to 5 lifecycle cycles

- 用户确认常规本机 release storage 不需要 50-loop，5 个完整 lifecycle cycle 足够作为发布硬门槛；更长 soak 仅按需显式启用。
- `drive-test-storage` 现明确传入 `EDP_STORAGE_LOOP_COUNT=5`；release profile 默认 5，允许 5–100 的显式 override，避免把长稳测试与常规发布验证绑定。
- Makefile help、Tests README、system ratchet、handoff/plan 验收标准同步改为 canonical release 5-loop；system ratchet 锁定 release target 和 runner 默认值，防止后续无意恢复 50-loop。

### 2026-08-31 20:29 — Release 50-loop exposed unbounded mount metadata query

- `367de1f` exact-head fast / virtual-usb / system 全绿后启动 release `make drive-test-storage`，M01、M02/M04-M09、M03 均通过并进入 M10 50-loop。
- M10 第 2 轮出现异常长停顿；进程树证明 `diskutil info -plist disk27` 进入 `U`（内核不可中断等待）超过 6 分钟，导致父 `run-storage.sh` 永久阻塞。对应 `disk27` 已由 `hdiutil info` 精确证明为当前 `edp-storage-e2e.M8HIDD/.../m10-2-bridge/volume.raw` 的 DiskImages2 synthetic publication，不涉及 physical USB。
- 根因不是产品状态机，而是 storage harness 的“bounded”漏洞：`mount_native()` 在完成 native mount 后用裸 `diskutil info -plist` 查询 MountPoint；另外 `is_mounted()` / leak/cleanup 仍依赖裸 `/sbin/mount`。这些查询在 FSKit 内核等待时可自身进入 `U`，使外层循环/timeout 失效。
- `DirectMFMountUnmountHelper` 扩展为 `getmntinfo(MNT_NOWAIT)` 只读查询工具：支持 mounted/source/source→mountpoint、read-only/writable、macFUSE 类型、mount-prefix leak、outside macFUSE 检查；保留原 privileged unmount 模式。
- `run-storage.sh` 已删除全部裸 `/usr/sbin/diskutil info` 与 `/sbin/mount` 查询；mountpoint/read-only/writeable/is-mounted/leak 判断全部走 helper。DiskImages2 readiness 改为 exact backing publication + raw 512B 可读，fixture synthetic proof继续要求 exact WORK_DIR backing、CRawDiskImage (`diskimages2=false`)、console-user owner、writable/removable、512B block size。
- system ratchet 新增 helper query mode 存在性，并禁止 storage runner 重新出现裸 `diskutil info` / `/sbin/mount`；`bash -n`、C17 `-Wall -Wextra -Werror`、`make drive-test-system`、`git diff --check` PASS。
- 当前运行中的旧 release 仍卡在重启前已生成的 `diskutil info` U-state；不触发 cleanup trap、不叠加磁盘命令。代码修复提交后需要重启一次清理该内核等待，再从全新枚举重新跑 release 50-loop。

### 2026-08-31 20:12 — Storage teardown / FSKit recovery hardening and smoke 2/2

- 重启后重新枚举：storage process=0、EDP hidden mount=0、EDP DiskImages publication=0、4KiB macFUSE scratch=0、external physical=0；重启前所有 diskN/PID 均作废，未复用历史编号。
- storage fixture teardown 修正为 exact backing authority：BSD node 消失不再等价于 DiskImages2 publication 已退出；synthetic detach 后必须等待 exact backing publication=0，才允许下一次 attach，避免 diskN 立即复用造成 `-69879 Couldn't open disk` 连锁重试。
- `DirectMFMountUnmountHelper` 新增 `--assert-no-fskit-mounts`，用 `getmntinfo + MNT_EXT_FSKIT` 对齐生产 `EDPFSKitHostRecovery` 的安全边界。
- storage adapter 对 `mount(8) returned 69` / FSKit not found/not enabled 只允许一次 host recovery；恢复前必须证明 0 FSKit mount，只重启当前 UID 的精确 `/usr/libexec/fskit_agent`，禁止无限重试。
- installer scratch recovery 修复 stale `hdid-pid`：当 exact 4KiB UUID scratch 仍在、记录 helper PID 已失效且 0 FSKit mount 时，允许精确 console-user `fskit_agent` reset 后再次按 backing/device revalidation；实机 upgrade 已成功把 scratch 清到 0。
- 重启后 canonical `make drive-test-storage-smoke` 改为独立后台运行并轮询最终 marker，避免聊天执行器 300s 上限杀掉父进程。
- smoke #1：exit=0，M01–M14 PASS，M10=5/5，FD 9→9，最终 `RESULT=DRIVE_STORAGE_E2E_OK`；退出后 process/mount/publication/scratch residue=0。
- smoke #2：exit=0，M01–M14 PASS，M10=5/5，FD 9→9，最终 `RESULT=DRIVE_STORAGE_E2E_OK`。
- 静态验证：`bash -n`、C17 `-Wall -Wextra -Werror`、`make drive-test-system`、`git diff --check` 全绿；system 新增 storage exact-publication teardown / bounded FSKit recovery ratchet。

### 2026-08-31 18:55 — Clean-install FSKit enablement bounded stability retry

- storage smoke 首轮在 M01 fail-closed：PluginKit 中 generic/local 两个 macFUSE module 均为 `+`，但当前用户 `enabledModules.plist` 只剩 Apple modules；没有进入 synthetic 写入阶段。
- 关闭并重新显式打开已安装 EDP Drive 后，现有一次性 enablement 立即恢复两个 macFUSE module 到 `enabledModules.plist`，证明 transport/macFUSE 文件本身健康，缺口是首次 clean-install foreground launch 的注册收敛窗口。
- 产品启动 enablement 改为 bounded async stability retry：最多 5 次、每次最多等待 1s；每次写入/注册后同时核对 macFUSE host/appex、PluginKit election、用户 enabledModules，并要求间隔 1s 的第二次检查仍 ready 才接受成功。无 `while true`、无 MainActor blocking sleep。
- 原有 transient automatic-mount retry 边界保持不变：只有 enablement/runtime ready 后才触发，不扩大到 password/raw/其他 mount error。
- 上一轮 storage 工具 300s timeout 后重新只读审计：storage process=0、EDP hidden mount=0、EDP DiskImages publication=0、external physical=0，未把 timeout 误记为 PASS。
- 验证：`make drive-test-system`、`make drive-test-fast`、`make drive-test-virtual-usb`、`make drive-test-ui`、`bash -n`、`git diff --check` 全绿；UI hitch max 25.000ms、0 个 >33ms。

### 2026-08-31 18:24 — Installed service-cycle timing and steady-state acceptance

- `13ad0b4` Clean.pkg 已在无 external physical USB、无 EDP/synthetic residue 的现场成功安装；App/embedded daemon 均为 `EDP Project Code Signing`，service plist `ThrottleInterval=1` 且无 KeepAlive/RunAtLoad。
- 显式打开 App 后实机确认 `desired-running=1`、LaunchDaemon `state=running`、minimum runtime=1、daemon count=1，验证重新打开 App 后 discovery daemon 自动恢复。
- 原 service-cycle 使用两个独立 Python helper 采 monotonic 时间，出现 -10/-1ms 不可能值；改为单个 Python 进程直接包裹 `--xpc-health` 子进程，消除跨进程 monotonic 差值。
- 趋势判断将 cycle 1 明确定义为 warmup：长时间 idle 后首轮可避开 launchd 1s throttle，cycle 2...8 才是 steady-state；仍要求全部 8 轮单独 <=3000ms、daemon count=1。
- 正式复验：46 / 1077 / 1066 / 1062 / 1074 / 1058 / 1054 / 1060ms；steady-state FIRST_AVG=1068.3ms、LAST_AVG=1057.3ms、slope=-2.8ms/cycle；`SERVICE_CYCLE_TREND=PASS`、`RESULT=SERVICE_RESTART_CYCLE_OK`。
- system 新增单进程 monotonic + steady-state warmup ratchet，`bash -n` / `make drive-test-system` / `git diff --check` PASS。

### 2026-08-31 17:16 — Clean installer scratch revalidation index-churn fix

- exact-head `fff906c` Clean.pkg 首次管理员安装按预期进入 fail-closed preinstall；成功开始回收当前重新证明的 4KiB scratch，但清理第一个 publication 后，`hdiutil info` 的 `images[]` 发生重排，旧实现继续使用原 `image_index` 复核下一项，导致对 `disk26` 的复核误判并拒绝安装。
- 根因是把可变 `images[]` 数组下标当成 revalidation identity；不是 pkg verifier、签名、真实 USB 或 filesystem 问题。
- `recover_macfuse_scratch_orphans()` 改为每处理一项后重新枚举，并以 exact UUID backing path + exact `/dev/diskN` + root/4KiB shape + PID/executable 重新查找；detach/TERM/KILL 前均重新验证，不再使用历史下标授权。
- 最终 residue 判定也改为 exact publication identity，不再仅以 `/dev/diskN` 是否仍存在判断，避免 diskN 被系统复用时误伤或误报。
- 现场只读 contract probe：当前 backing A + disk26 精确返回 PID 49668，backing B + disk27 返回 PID 54319；故意将 backing A 与 disk27 交叉组合返回空。
- 验证：`bash -n native-preinstall`、`make drive-test-system`、`git diff --check` PASS；system ratchet 明确禁止恢复旧 `image_index -> hdid-pid` revalidation。

### 2026-08-31 13:45 — Native sidebar cold-hitch sizing feedback fix

- exact-head UI gate 在当前高图形负载下暴露首次 native sidebar collapse 冷启动帧 33–75ms；保留 xctrace 后确认超标集中在首两帧，Instruments 指向 expensive render / app update，而后续动画帧稳定在 8.33–16.67ms。
- 根因收口到 `NSSplitViewController` live resize 与两个 SwiftUI `NSHostingController` 默认 sizing feedback 叠加；split controller 已拥有几何约束，因此关闭 sidebar/detail host 的 intrinsic/preferred-size 自动回传，不关闭原生动画、不放宽 33ms 门槛。
- `run-ui.sh` 新增 `sidebarHost.sizingOptions = []` / `detailHost.sizingOptions = []` ratchet。
- 修复后同一 `Animation Hitches` gate：max 25.000ms、0 个 >33ms，`RESULT=DRIVE_UI_OK` PASS。

### 2026-08-31 13:00 — Clean installer owner-only orphan recovery hardening

- 当前系统重新枚举发现 hardware-free storage smoke 中断遗留的 owner-only DiskImages2 publication：exact backing 位于 `edp-storage-e2e.phasec-smoke3/.../volume.raw`，`system-entities=[]`，owner-uid 为 console user，实际 owner process 为 `_diskimagesiod`；同时存在 root-owned 4KiB macFUSE scratch images。
- `native-preinstall` 新增 storage-test owner-only recovery：只接受 `/var/folders/.../T/edp-storage-e2e.*/mounts/*/volume.raw`，要求 DiskImages2=true、autodiskmount=false、unencrypted、owner-mode=0600、无 system entity、console-user owner、无 active bridge mount、无正在运行的 storage regression。
- TERM/KILL 前强制重新读取 `hdiutil info -plist` 并再次核对 exact backing + owner PID/executable，PID/backing 变化即 fail closed；不使用历史 diskN/PID，不触碰任何 removable physical media。
- system 新增 `RESULT=DRIVE_SYSTEM_INSTALLER_TEST_ORPHAN_REVALIDATION_OK`；`bash -n`、system、`git diff --check` PASS。

### 2026-08-31 12:40 — Installed-app discovery lifecycle blocker

- 实机只读诊断确认当前旧安装态 `com.edp.drive.service` 不在运行，且用户偏好 `com.edp.drive.service.desired-running=0`；因此 App 外观看似已打开时没有 discovery daemon 监听 Disk Arbitration/IOKit，真实盘不会进入五因素识别。
- 修复 App 显式启动语义：每次用户重新打开 EDP Drive 都恢复 `serviceDesiredRunning=true` 并重新建立按需 XPC/daemon；本次 UI 会话内“停止”仍可停服务，“完全退出”仍会关闭 daemon，但不会让下一次显式启动永久失去插盘识别能力。
- system 新增 `RESULT=DRIVE_SYSTEM_APP_REOPEN_RESTORES_SERVICE_OK` ratchet；最终行为将在 exact-head Clean.pkg 安装后的 installed service-cycle/真实盘只读识别中复核。

### 2026-08-31 12:38 — Phase G structured lifecycle journal

- 完成 256 条 bounded structured lifecycle journal；schema 固定为 operationID/operation/deviceID/partitionType/state/event/attempt/recoveryBudget/elapsedMs/ownedResources/diagnosticCode。
- mount 已覆盖 request/single-flight/cancel、bridge launch/wait/ready/failure/timeout、publication start/complete/failure/cancel、filesystem mount、cleanup、transport teardown、host recovery 与 terminal。
- unmount/eject/shutdown 已使用独立 operation context；eject terminal 延伸到 controller physical Disk Arbitration handoff，shutdown 重复请求记录 coalesced event。
- `diagnosticsData()` 新增 `lifecycleJournal` JSON 数组，不导出密码、凭据、密钥、raw plaintext、helper stderr 或 raw path。
- 新增 S23：capacity 截断、sequence/elapsed 单调、operationID 一致、JSON 可序列化、credential sentinel 不出现在 diagnostics；system 新增 journal 敏感字段/有界性 ratchet。
- 验证：service lifecycle C01-C08/D01-D13/S01-S23/M11 PASS；10,000×32 property PASS；fast/system/virtual-usb 与 `git diff --check` PASS。

### 2026-08-31 12:02 — Finalization handoff

- 用户已明确表示可以进行管理员授权。
- 新增 `docs/HANDOFF-2026-08-31-async-lifecycle-finalization.md`，完整固化 Phase G 收尾、一次性管理员授权、安全 orphan revalidation、Clean.pkg 安装、8-cycle service restart、storage smoke ×2、release 50-loop 与真实盘非破坏性验收顺序。
- 明确历史 `diskN` / PID 只作线索，不能作为 root cleanup 目标；每次授权前必须重新验证 exact backing / virtual identity / owner / active-mount 状态。
- Phase G 当前为未提交 WIP：journal ring buffer/schema/protocol/build wiring 已开始，尚未完成 diagnostics/export/tests，不得 reset/stash/drop。


### 2026-08-30 23:49

- 创建本轮完整实施计划与实时 tracker。
- 明确本轮不再继续增加同步 fallback；后续以 async callback/state-event 为唯一产品路径。
- Phase A 基线验证完成：`git diff --check`、`make drive-test-fast`、`make drive-test-system` 全部 PASS。

### 2026-08-31 09:57 — Phase D

- 新增 `EDPLifecycleFailureCode` / `EDPLifecycleFailure`，状态机内部不再用裸 `String` 表示失败类别。
- FSKit bridge adapter 将 timeout、mount(8)=69/extension unavailable、普通 bridge exit 分类成稳定 code；recovery policy 只 switch typed code。
- raw helper 的历史 `EDP_RAW_*` machine-readable tag 只在 raw adapter boundary 解析一次；controller 不再依赖错误文本判断 raw/FDA 状态。
- publication、filesystem mount、teardown、cancel、invalid transition 均进入 typed taxonomy；MountManager 保留最近一次 typed mount failure code。
- controller 的 transient automatic retry 改为读取 `.bridgeExtensionUnavailable`，删除 `File system extension not found/enabled` 字符串决策；encrypted mount 回调删除 `EDP_RAW_*` 字符串判断。
- S11 更新为 typed bridge classifier/recovery contract；S13/S14 更新 typed terminal/cancel assertions；新增 S21 `typed_lifecycle_error_taxonomy`。
- system 新增 `RESULT=DRIVE_SYSTEM_TYPED_LIFECYCLE_ERRORS_OK` ratchet，阻止上层重新引入错误字符串决策。
- 验证：service lifecycle C01-C08、D01-D13、S01-S21、M11 PASS；fast/system/virtual-usb 与 `git diff --check` PASS。

### 2026-08-31 09:35 — Phase C

- BlockPublisher/DiskImages2 正式路径已改成 cancellable async operation；删除同步 publication、publisher 内 `Thread.sleep` 与 `waitUntilExit`。
- async child process 使用 termination handler + deadline，覆盖 timeout→TERM→KILL、显式 cancel、completion exactly-once，并修复 fire-and-forget operation 提前释放导致 completion 丢失的 ownership bug。
- MountManager publication 阶段接入 operation cancellation；若 publication 已完成则先 exact unpublish synthetic device，再继续 transport cleanup。
- scratch baseline/orphan cleanup、persisted-session scratch recovery 与 DiskImages2 backing disappearance polling 全部异步化。
- S20 新增 `async_publisher_process_timeout_cancel_once`；独立 publisher/scratch contract 已接入 fast gate。
- service lifecycle 发现并修复 policy persistence 并发竞态：同 PID temp file 冲突已改 PID+UUID，load-modify-save 事务由 recursive lock 串行化；D03/D05/D06/D08/D09 setup 改为先配置默认策略再插入 virtual media。已编译 harness 连续 20/20 PASS。
- hardware-free 验证：fast、system、virtual-usb、UI 均 PASS；UI 最新 max hitch 25ms、0 个 >33ms。
- clean combined installer `artifacts/EDP-Drive-0.6.0-arm64-Clean.pkg` 已构建，`verify-clean-installer.sh` 完整 PASS。
- storage 本机运行暴露并修复多项 harness 边界，但当前系统仍有普通用户无权回收的历史 root-owned scratch/owner-only DiskImages2 orphan；因此 storage ×2 与 installed service-cycle 保持未验收，必须管理员清理后再补，不写成 PASS。

### 2026-08-31 00:14 — Phase B

- Disk Arbitration production API 已完全 callback-based；不再通过 semaphore 把 DA callback 同步化。
- MountManager 的 physical whole-unmount、filesystem mount、Finder staging mount/unmount、DiskImages2 eject、controller physical eject 已迁移到 async chain。
- raw-access acquisition 改为 per-device single-flight async；device identity 在真正 open lease 前重新验证。
- startup persisted-session recovery 改为 async gate，reconcile 仅在 recovery terminal 后启动。
- 新增 S19 once-only completion gate，覆盖 timeout 与 late/duplicate callback 竞态。
- 验证：service lifecycle、system、virtual-usb、storage smoke、`git diff --check` 全部 PASS。

### 2026-09-01 12:30 — Factory-clean baseline and clean-host installer build

- 用户已物理拔出真实 U 盘。`first-install-acceptance.sh preflight -> user-cleanup -> factory-first-install -> verify-clean` 完成；实机确认 `/Applications/EDP Drive.app`、`/Library/Filesystems/macfuse.fs`、`/Library/Application Support/EDP Drive`、`com.edp.drive.service` LaunchDaemon 与 `com.edp.drive` FDA 记录均不存在，`RESULT=FACTORY_CLEAN_BASELINE_VERIFIED`。源码仓库和普通用户文件未删除，DefaultKeychain 仍为 login.keychain。
- factory-clean 后暴露打包器隐含依赖：`build-clean-installer.sh` 仍从已安装 `/Library/Filesystems/macfuse.fs/.../MFMount.framework` 编译 transport，导致真正第一次安装基线无法构建发布包。
- Clean installer 现从已校验 SHA-256 的官方 macFUSE 5.3.3 DMG 临时展开 `Core.pkg/Payload`，使用其中 `MFMount.framework` 作为 build-time framework；不安装 macFUSE、不改变 FDA/TCC/用户 FSKit 状态。`build-transport-backends.sh` 将 build-time framework 与固定 runtime rpath 分离，最终 `LC_RPATH=/Library/Filesystems/macfuse.fs/Contents/Frameworks`。
- system 新增 `RESULT=DRIVE_SYSTEM_FACTORY_CLEAN_INSTALLER_BUILD_OK` ratchet；在 App/macFUSE 均不存在的 factory-clean 主机上正式 `build-self-signed-installer.sh` 已成功，输出 `RESULT=MACFUSE_BUILD_FRAMEWORK_EXTRACTED_FROM_SIGNED_DMG`、`RESULT=EDP_CLEAN_COMBINED_INSTALLER_BUILT`。完整 `verify-clean-installer.sh` PASS，包内 transport 无临时构建路径，打包后主机仍保持 APP_ABSENT / MACFUSE_ABSENT / 无 EDP FDA。

### 2026-09-01 08:34 — Full Disk Access 收口为单一 EDP Drive App 身份

- 真实 SanDisk 插入后发现当前安装态 `privilegedAccessReady=false`；TCC 只存在 `com.edp.drive` 的 `SystemPolicyAllFiles` 记录，且 csreq 为稳定 `identifier com.edp.drive + certificate root 040b5488...`，没有 `com.edp.drive.service` FDA 记录。由此确认覆盖升级没有丢主 App FDA，真正问题是 raw `O_RDWR /dev/rdiskN` 在 service 中执行，错误地把 service 变成第二个 FDA 主体。
- 用户明确拒绝为后台 service 单独授权。正式模型改为：只有 `/Applications/EDP Drive.app` / `com.edp.drive` 接受一次 FDA；root service 通过 `socketpair + posix_spawn` 启动同一个 EDP Drive executable 的隐藏 `--raw-fd-broker` 模式，由该 App identity 在 root 上下文完成 whole USB + device-node + LBA4/LBA7 校验并 `O_RDWR` open；fd 仅通过 Unix `SCM_RIGHTS` 回传 service。
- service 收到 fd 后仍执行原有 `st_rdev`、IOKit inventory、VID/PID、capacity、registry identity 与 LBA4/7/11/12 `metadataStillMatches` 精确复核；失败即关闭 fd，五因素设备身份规则没有放宽。
- `edp-console-exec` 已删除 `--probe-raw-device` / `--raw-device` direct-open 能力，只允许消费 service 继承的 fd 3，复核 EDP metadata 后再降权启动白名单 transport；raw open 因而只有 EDP Drive App broker 一个入口。
- 新增共享 `EDPRawValidation.c/.h`，避免 App broker 与 console transport 复制两套 whole-USB/LBA 安全判定；新增 `EDPRawFDBroker.c` 实现 root-only fixed-App-path broker 与 SCM_RIGHTS fd passing。
- Clean/Native installer、UI update、Makefile、service lifecycle、storage strict build 与 GitHub Actions direct build 均已链接 broker core；installer verifier 新 marker `RESULT=FULL_DISK_ACCESS_SINGLE_APP_RAW_FD3_TRANSPORT_PATH_ENFORCED`，system 新 marker `RESULT=DRIVE_SYSTEM_SINGLE_APP_FDA_RAW_BROKER_OK`。
- `factory-first-install` 的 TCC reset target 已从 `com.edp.drive.service` 改为 `com.edp.drive`；UI/acceptance 继续只 reveal `/Applications/EDP Drive.app`，文档明确“只授权 EDP Drive 一次”。
- hardware-free 验证：fast、service lifecycle C01-C08/D01-D13/S01-S23/M11、10,000×32 model、system、virtual-usb、UI 均 PASS；UI max hitch 25ms、0 个 >33ms；Native installer 与 Clean installer 均实际构建成功，Clean verifier PASS。exact-head Clean.pkg SHA-256=`215f6daee8e1fe9993ff4adac8a939a95fa9987a04ca99bcd4822ffe00394451`。
- exact-head `6ff00db` Clean.pkg 已覆盖安装；TCC 全程只有 `com.edp.drive` 一条 `SystemPolicyAllFiles` 记录，没有 `com.edp.drive.service` FDA。首次覆盖安装后旧插盘 generation 上 raw probe 暂时失败，但物理重新插拔后 App broker 立即取得 retained raw fd，canonical `verify-fda-device 0781:5591` 返回 `RESULT=FDA_RETAINED_RAW_ACCESS_READY`。
- 真实 SanDisk 三分区 capability-aware E2E 已 PASS：type1 FAT16、type2 NTFS、type4 NTFS 均完成 mount→unmount→remount→unmount；其中 type4 第二次 teardown 正常，`RESULT=ALL_THREE_PARTITIONS_CAPABILITY_PERSISTENCE_OK`。Finder 保持正常，无 UVFSService / transport 残留。
- 产品 XPC `safe-eject` 返回 `RESULT=XPC_EJECT_SMOKE_OK` 与 `RESULT=SAFE_EJECT_SUPPRESSION_OK`；随后再次物理拔插并重新插入，同一五因素身份重新识别且 `privilegedAccessReady=true`，canonical gate 再次返回 `RESULT=FDA_RETAINED_RAW_ACCESS_READY`，无新增 FDA、无管理员/Touch ID 授权。single-App FDA 模型实机闭环 PASS，后台 `edp-drive-service` 不需要单独授权。

### 2026-09-01 16:58 — 真实盘 EBUSY 根因与 bounded raw recovery

- safe-eject generation hardening 后继续第一次安装/真实盘验收时，fresh SanDisk 插入出现 `privilegedAccessReady=false`。TCC 已明确 `com.edp.drive auth_value=2`，tccd 对实际 root App broker 也返回 allow；由此排除 FDA 丢失。
- raw validation 增加 machine-readable 分阶段诊断：真实现场最终返回 `EDP_RAW_LEASE_OPEN_FAILED:16`，即 `EBUSY`。同时修复旧 adapter 的 `contains(":1")` 前缀误匹配，避免 `1007` metadata validation 被错误归类为 EPERM/FDA。
- 毫秒级 DA 日志证明 macOS `msdos_fskit` probe 在 EDP metadata helper 启动前约 265ms 已失败，并留下 whole IOMedia `Open=Yes`；盘无 mount、无用户态 lsof 句柄、只读五扇区 metadata 正常，因此不是 EDP discovery 并发导致。
- 公开 `DADiskClaim` exact-generation probe 已实证 claim/unclaim 成功，但 claim 持有期间 raw O_RDWR 仍 EBUSY，排除 claim 作为恢复方案。
- 普通 whole-unmount 不能清 EBUSY；对五因素已识别且 registry generation 精确匹配的 EDP whole media 执行 forced whole-unmount 后，同一 FDA App broker 从 raw-open failure exit 77 变为 fd-send-only failure exit 71，随后旧 service 无重新授权/拔插即恢复 `privilegedAccessReady=true`。根因与恢复条件实机闭环。
- 正式实现已提交并 push：`1a639f94418a9c682b540d25bab4b42a505f449f fix(drive): recover raw access from fskit busy state`。新增 `forceUnmountWholeAsync`：公开 Disk Arbitration `Whole|Force` callback API，继续绑定 exact IOMedia registryEntryID。raw acquisition 只在真正 `EBUSY(16)` 时触发一次 force whole-unmount，generation 未变化才只重试一次；第二次仍 EBUSY、DA failure、deviceChanged 或任何非 EBUSY error 均 fail-closed。
- 新增 deterministic S31–S35：EBUSY 单次恢复、重复 EBUSY 有界、replacement generation 拒绝、DA failure fail-closed、非 EBUSY 不触发 force。service lifecycle C01–C08/D01–D13/S01–S35/M11、10,000×32 model、fast、virtual-usb、system、`git diff --check` 全部 PASS；system 新 marker `RESULT=DRIVE_SYSTEM_RAW_VALIDATION_DIAGNOSTICS_OK`、`RESULT=DRIVE_SYSTEM_RAW_EBUSY_RECOVERY_OK`。
- 提交前 WIP Clean.pkg 已构建并完整 verifier PASS，SHA-256=`9fbd47a71edb86246259012fa70248d64c75924afcc3965a0a4ccb39e455bfd5`。此包尚未安装；提交后必须从 exact new HEAD 重打包，不能把该 pre-commit SHA 当最终发布包。
- **未完成硬门槛**：当前 physical generation 的 busy 已经通过人工 force-unmount 清掉，所以当前 `privilegedAccessReady=true` 不能证明产品自动 recovery。下一步必须安装 exact-head 新包后物理拔插一次制造 fresh generation，验证自动 `EBUSY -> exact-generation force whole-unmount -> single retry -> raw ready`；随后完成 capability-aware 三分区、safe eject stale-BadArgument 复测和 residue/U-state 检查。
- 新增交接：`docs/HANDOFF-2026-09-01-real-device-ebusy-finalization.md`。
