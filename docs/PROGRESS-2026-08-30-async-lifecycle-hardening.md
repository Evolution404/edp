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
| H | 全量/安装态/真盘验收 | TODO |

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
- [ ] commit/push

完整后续执行说明：`docs/HANDOFF-2026-08-31-async-lifecycle-finalization.md`

## Phase H — 最终验收

状态：TODO

### Hardware-free

- [ ] fast
- [ ] virtual-usb
- [ ] system
- [ ] UI
- [ ] storage smoke #1
- [ ] storage smoke #2
- [ ] release storage final marker
- [ ] bash -n
- [ ] plutil -lint
- [ ] git diff --check
- [ ] installer build/verify

### Installed service-cycle

- [ ] 最新 package 已安装
- [ ] 8 cycles
- [ ] 每次 start <= 3000ms
- [ ] minimum runtime=1
- [ ] daemon count=1
- [ ] 无 progressive slowdown

当前状态：用户已明确表示现在可以管理员授权。不要立刻安装旧包；先完成 Phase G、构建并验证 exact-head Clean.pkg，然后把 synthetic orphan revalidation/cleanup + clean install 合并为一次系统授权。历史 diskN/PID 不得直接复用，授权前必须重新发现并证明 identity。

### Physical EDP USB

- [ ] 等用户插入标准加密 EDP U 盘后再执行
- [ ] 五因素重新识别
- [ ] Exchange ExFAT RW filesystem-level test
- [ ] mount/unmount >=5
- [ ] teardown residue=0
- [ ] 严禁 format/erase/raw write

## 变更日志

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
