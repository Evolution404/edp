# EDP Drive 异步生命周期与边界收口计划

日期：2026-08-30
分支：`codex/ui-macos26-liquid-glass`
基线：`44eaa151408ae91af8987bf7155f51b88c6bf13a`

## 1. 目标

把 EDP Drive 的挂载、卸载、推出、后台服务关闭与异常恢复从“部分异步 + 局部同步等待”彻底收口为可验证的异步资源生命周期系统，减少阻塞、竞态、重复恢复和边界异常。

本轮重点完成四条主线：

1. Disk Arbitration 全异步化；
2. Block publication / DiskImages2 / macFUSE scratch cleanup 全异步化；
3. lifecycle error 从字符串匹配收紧为 typed error；
4. 引入可注入 clock/scheduler 与 model/property 风格状态机测试。

同时清理已确认无价值的同步 fallback、旧 dead code 和高频系统 CLI 热路径，并保持硬件安全边界不变。

## 2. 不可破坏的硬约束

### 2.1 真实 U 盘安全

- 不对真实物理 EDP U 盘执行格式化、分区、擦除或 raw write。
- 所有 destructive filesystem preparation 必须只作用于已证明的 synthetic/virtual fixture。
- 不假设固定 `diskN`；任何真实设备测试必须重新发现 VID/PID/LBA4 onlyId/capacity/LBA11 metadataDeviceID。
- 物理 raw 路径只允许现有 FDA daemon / retained fd 权限模型。

### 2.2 生命周期约束

- 一个 partition 同时最多一个 mount resource owner。
- duplicate mount 必须 single-flight，多个调用共享一个最终 completion。
- completion 每个 operation 最多调用一次。
- host recovery 每个 mount request 最多一次。
- recover 后最多 retry 一次。
- cancellation 优先于 recovery/retry。
- terminal state 不可逆，迟到 callback 不得改写 terminal result。
- shutdown 后禁止新 mount。
- eject 前必须确认该 device 的 mount operation/session 全部 drain。
- raw lease 只有在依赖它的 lifecycle 全部结束后才能释放。

### 2.3 兼容性与发布约束

- 不削弱当前五因素物理设备身份：VID + PID + LBA4 numeric onlyId + capacity + LBA11 metadataDeviceID。
- 不恢复 `authopen`、Tauri、FUSE-T 或物理 `diskNs1` 假设。
- self-signed installer 当前仍需要 installer-managed LaunchDaemon；本轮不强行删除，但代码命名/文档要避免把它与旧废弃实现混淆。
- `ThrottleInterval=1`、无 `KeepAlive`、无 `RunAtLoad` 必须保持。

## 3. 当前已完成基线

进入本计划前已经完成：

- FSKit mount 唯一异步状态机；旧同步 mount 物理删除；
- transport teardown 只走 `stopAsync()`；
- mount/unmount/eject/shutdown controller/XPC 路径 async；
- duplicate mount single-flight；
- cancellation priority；
- terminal-state late callback idempotence；
- S13-S18 生命周期边界测试；
- service UI start/stop/restart 显式 lifecycle state；
- macFUSE enablement 移出 MainActor；
- macFUSE code-sign verification 改 Security.framework；
- App 正常服务状态路径移除 `launchctl`；
- VFS unmount 改 `unmount(2)`；
- service plist `ThrottleInterval=1`；
- 两次 storage smoke PASS；
- UI gate 最近一次 PASS，hitch max 8.333 ms，0 个 >33 ms；
- release storage 本地执行达到 M10 50/50、M12、M14，无残留，但工具 300s 窗口未返回最终 marker。

## 4. Phase A — 建立实施基线与架构 ratchet

### 4.1 工作

- 固化本计划和实时 tracker。
- 审查当前 22 个 WIP 文件，禁止无关改动混入新阶段。
- 增强 `run-system.sh` 架构 ratchet：
  - 禁止生产 mount/unmount/eject/shutdown 同步 fallback；
  - 禁止重新引入 runtime `waitUntil/usleep`；
  - 禁止 App 正常路径重新引入 `launchctl`；
  - 禁止 macFUSE runtime verification 重新调用 `/usr/bin/codesign`；
  - 禁止 native VFS unmount 重新调用 `/sbin/umount`。

### 4.2 验收

- `git diff --check` PASS；
- `make drive-test-fast` PASS；
- `make drive-test-system` PASS。

### 4.3 提交

`docs(drive): plan async lifecycle hardening`

## 5. Phase B — Disk Arbitration 全异步化

### 5.1 问题

当前 `EDPDiskArbitrationController.perform()` 通过 `DispatchSemaphore.wait()` 把 DA callback 重新同步化。即使不占 controller queue，也会阻塞 lifecycle queue，造成：

- mount/unmount/eject 的状态机无法观察中间状态；
- timeout/cancel 与 DA completion 存在隐式竞态；
- 一个慢 DA 操作会占住调用方线程；
- 测试只能看最终结果，不能验证 callback ordering。

### 5.2 设计

新增 async-only DA API：

- `unmountWholeAsync`
- `unmountAsync`
- `mountAsync`
- `mountNobrowseAsync`
- `ejectAsync`

每个操作：

`request -> pending(operationID, deadline) -> callback | timeout | cancelled -> terminal`

要求：

- callback 最多消费一次；
- timeout 后迟到 callback 忽略；
- completion 永不 inline re-enter caller state machine；
- DA queue 只负责系统 callback，不执行上层业务；
- 上层 lifecycle queue 消费 completion event。

同步 adapter 只能存在于 `EDP_REGRESSION_TESTS`，正式 daemon 二进制不存在。

### 5.3 测试

新增/扩展：

- DA success；
- DA dissenter；
- timeout；
- timeout 后 late success；
- duplicate callback；
- cancellation 与 callback 同 tick；
- mount->unmount ordering；
- eject 前所有 partition drain。

### 5.4 验收

- 正式 source 无 `DAOperationBox.semaphore.wait`；
- 生命周期调用点全部 async；
- `drive-test-fast/system/virtual-usb` PASS；
- storage smoke PASS。

### 5.5 提交

`refactor(drive): make disk arbitration lifecycle asynchronous`

## 6. Phase C — BlockPublisher / DiskImages2 / scratch cleanup 异步化

### 6.1 问题

`EDPBlockDevicePublisher` 仍存在同步 `Process + Thread.sleep`：

- `hdiutil info -plist`；
- DiskImages2 publication helper；
- scratch baseline/cleanup；
- publication disappearance polling；
- helper SIGTERM/SIGKILL 等待。

它是当前 mount cleanup 中最大的残余阻塞岛。

### 6.2 设计

把 publisher 改为显式 async protocol：

- `publishWritableImageAsync`
- `unpublishAsync`
- `captureScratchBaselineAsync`
- `cleanupNewOrphansAsync`

把 bounded child process 抽象为异步 process operation：

`launch -> running -> terminate -> forceTerminate -> completed/failed`

要求：

- 不用 `Thread.sleep`；
- deadline 使用 scheduler；
- SIGTERM/SIGKILL 有固定 bounded budget；
- exact backing identity 在 destructive signal 前再次验证；
- cancellation 后不得创建新 publication；
- unpublish 只操作 exact backing + owner tuple；
- 不因 persisted `diskN` 复用触碰无关物理盘。

### 6.3 hdiutil 策略

本阶段不为了“零 CLI”牺牲安全性。若 DiskImages2 私有 helper 目前仍需要 `hdiutil info` 才能获得可靠 owner/backing tuple，可暂时保留 CLI，但：

- 必须在专用 async operation queue；
- 不得阻塞 lifecycle queue；
- 每个调用有 deadline/cancellation；
- 结果解析必须 typed；
- 后续再研究去 CLI 化。

### 6.4 测试

- publication success/failure；
- helper timeout；
- helper SIGTERM exit；
- helper SIGKILL exit；
- owner-only publication；
- backing disappeared；
- persisted diskN 被复用；
- cancellation before publish；
- cancellation after publish before filesystem mount；
- cleanup late callback；
- scratch orphan exact-match / mismatch。

### 6.5 验收

- `EDPBlockDevicePublisher.swift` 正式路径无 `Thread.sleep`；
- publisher completion once；
- Disk Arbitration eject success 之后仍必须确认 exact DiskImages2 backing publication 真正消失；
- hidden macFUSE bridge 仅 `nobrowse`，不得携带 `MNT_LOCAL`；
- 同一 sessionKey 的 teardown→remount 必须经过 monotonic generation quiescence，旧 generation callback 不能释放新 generation；
- storage smoke 连续 2 次 PASS；
- canonical release storage 5-loop 获得最终 marker；更长 soak 仅在专项生命周期改动时按需显式提高循环数。

### 6.6 提交

`refactor(drive): make block publication teardown asynchronous`

## 7. Phase D — Typed lifecycle errors

### 7.1 问题

当前 recovery classifier 仍依赖部分字符串：

- `mount(8) returned 69`
- `File system extension not found`
- raw access 字符串 marker

字符串匹配会导致文案变化影响控制流。

### 7.2 设计

引入 `EDPMountLifecycleError`（名称可按实现调整）：

- `.cancelled`
- `.timeout(stage)`
- `.rawAccess(reason)`
- `.credential(reason)`
- `.transportLaunch(reason)`
- `.bridgeActivation(reason)`
- `.fskitUnavailable(reason)`
- `.publication(reason)`
- `.filesystemMount(reason)`
- `.teardown(reason)`
- `.diskArbitration(reason)`
- `.identityChanged`

并定义：

- `isFSKitRecoverable`
- `userFacingDescription`
- `diagnosticCode`

外部工具原始日志只在 adapter 边界一次性解析成 typed error，上层状态机只 switch enum。

### 7.3 测试

- 文案大小写变化不影响 recovery；
- unrelated log 永不 recover；
- bridge mounted override；
- timeout + dead process 不 recover；
- DiskImages2 error 不 recover；
- cancellation 不 recover；
- typed error 可稳定序列化到 diagnostics。

### 7.4 验收

- lifecycle state machine 不直接 `contains("File system extension...")`；
- recovery policy 输入为 typed error；
- S11-S18 迁移后全部 PASS。

### 7.5 提交

`refactor(drive): type lifecycle failures and recovery policy`

## 8. Phase E — 可注入 Clock/Scheduler

### 8.1 设计

引入极薄抽象：

- `now`
- `schedule(after:)`
- `schedule(at:)`

production 使用 monotonic/Dispatch 实现；tests 使用 deterministic virtual clock。

覆盖：

- bridge activation deadline；
- transport graceful/SIGTERM/SIGKILL/recovery deadlines；
- mount cancel drain；
- eject drain；
- shutdown drain；
- service operation timeout。

禁止业务状态机直接依赖 wall-clock `Date()` 来决定 timeout。

### 8.2 测试

可瞬间推进 virtual time 验证：

- timeout 恰好触发；
- completion 在 deadline 前 1 tick；
- completion 与 timeout 同 tick；
- cancellation 与 timeout 同 tick；
- retry budget 不因 scheduler 重放而增加。

### 8.3 验收

- lifecycle unit tests 不需要真实 8s/15s 等待；
- fast/service tests 时长不明显增加；
- 现有 async state invariants 保持。

### 8.4 提交

`test(drive): add deterministic lifecycle clock`

## 9. Phase F — Model/property 状态机测试

### 9.1 目标

不继续无限追加 S19/S20 手工场景，而是自动生成合法/非法事件序列，验证 invariants。

### 9.2 事件集合

包括但不限于：

- start
- attemptLaunched
- bridgeReady
- bridgeFailure(recoverable/nonrecoverable)
- publishComplete
- filesystemMounted
- cancel
- cleanupComplete
- recoveryComplete
- timeout
- lateCallback
- shutdown

### 9.3 永久 invariant

- terminal state 不可逆；
- completion <= 1；
- host recovery <= 1；
- retry <= 1；
- cancellation 后不得进入 mounted；
- shutdown 后不得生成新 session；
- resource owner <= 1；
- retry attempt index 单调递增；
- recovery budget 不可增加；
- invalid event fail closed 或被 terminal idempotence 忽略。

随机测试必须固定 seed 并输出失败序列，可完全复现。

### 9.4 验收

- 至少 10,000 条 deterministic event sequence；
- 失败时打印 seed + event trace；
- CI 可稳定运行。

### 9.5 提交

`test(drive): fuzz async lifecycle invariants deterministically`

## 10. Phase G — 运行态可观测性

### 10.1 Structured lifecycle journal

每个 operation 记录：

- operationID
- deviceID
- partitionType
- state
- event
- attempt
- recoveryBudget
- elapsedMs
- owned resources
- diagnosticCode

要求：

- 有界 ring buffer；
- 不记录密码、密钥、raw plaintext；
- diagnosticsData 可导出；
- UI 诊断可消费，但本阶段不要求大规模 UI 改造。

### 10.2 验收

能从日志直接回答一次失败挂载经历了哪些 state/event，而无需拼接散落 NSLog。

### 10.3 提交

`feat(drive): add bounded lifecycle diagnostics journal`

## 11. Phase H — 安装态与发布验收

### 11.1 Hardware-free

依次运行：

1. `make drive-test-fast`
2. `make drive-test-virtual-usb`
3. `make drive-test-system`
4. `make drive-test-ui`
5. `make drive-test-storage-smoke` ×2
6. release storage 5-loop
7. `git diff --check`
8. `bash -n` 相关脚本
9. `plutil -lint` 相关 plist
10. installer build + verify

### 11.2 Installed service-cycle

在无 physical USB 条件下安装最新包后：

- 8 次 stop/start cycle；
- 每次 start <= 3000ms；
- launchd `minimum runtime = 1`；
- 每轮只有一个 daemon；
- 无 progressive slowdown；
- 最后一轮 stop 后无 mount/session/process residue。

如当前 shell 无非交互管理员授权，不自动触发密码弹窗；记录 blocker，保留安装包。

### 11.3 真实 U 盘最终验收

只有用户插入标准 EDP U 盘后进行：

- 五因素重新识别；
- raw 层不格式化、不擦除、不做测试写；
- Exchange type2 经产品路径 ExFAT RW；
- 正常文件系统 create/read/write/rename/delete；
- mount->unmount 至少 5 次；
- 每次 teardown：user volume=0、`.edp-block-*`=0、DiskImages publication=0、transport process=0；
- physical disk 始终 `Virtual: No`。

## 12. 提交与推送策略

- 每个 Phase 完成后立即更新 `docs/PROGRESS-2026-08-30-async-lifecycle-hardening.md`。
- 每个 Phase 独立 commit；不把多个逻辑阶段压进一个巨大提交。
- 每个 commit 前至少：对应局部 gate + `git diff --check`。
- commit 后及时 push 当前分支。
- 若某 phase 暂时不能完成，先提交已验证的独立子阶段，并在 tracker 写清 blocker，不假装 PASS。

## 13. 最终完成标准

只有同时满足以下条件才标记本计划 DONE：

- DA、BlockPublisher、transport、mount/unmount/eject/shutdown 正式路径全部异步；
- lifecycle control flow 使用 typed errors；
- timeout 使用可注入 scheduler；
- deterministic property tests 覆盖核心 invariants；
- fast / virtual-usb / system / UI / storage smoke 全绿；
- release storage 有最终 PASS marker（本机或 CI）；
- 最新安装包构建成功；
- service-cycle 在可安装环境闭环；
- tracker 与代码 HEAD 一致；
- 所有阶段已 commit 并 push。
