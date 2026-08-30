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
| B | Disk Arbitration async | TODO |
| C | BlockPublisher / DiskImages2 async | TODO |
| D | Typed lifecycle errors | TODO |
| E | Virtual clock / scheduler | TODO |
| F | Deterministic model/property tests | TODO |
| G | Structured lifecycle journal | TODO |
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

状态：TODO

目标：删除生产 `DAOperationBox + DispatchSemaphore.wait()` 同步化路径，把 DA callback 直接转成 async lifecycle event。

验收项：

- [ ] async protocol/API
- [ ] timeout/late callback once-only
- [ ] production 无 DA semaphore wait
- [ ] mount/unmount/eject 调用点迁移
- [ ] 边界测试
- [ ] fast/system/virtual-usb PASS
- [ ] storage smoke PASS
- [ ] commit/push

## Phase C — BlockPublisher / DiskImages2 async

状态：TODO

验收项：

- [ ] async publication protocol
- [ ] async bounded helper process
- [ ] scratch cleanup 无 `Thread.sleep`
- [ ] exact backing/owner revalidation
- [ ] cancellation priority
- [ ] publication late callback once-only
- [ ] storage smoke ×2 PASS
- [ ] commit/push

## Phase D — Typed lifecycle errors

状态：TODO

验收项：

- [ ] typed lifecycle error enum
- [ ] recovery policy 不依赖上层字符串匹配
- [ ] raw/bridge/publication/filesystem/teardown error 分类
- [ ] S11-S18 迁移后 PASS
- [ ] commit/push

## Phase E — Virtual clock / scheduler

状态：TODO

验收项：

- [ ] production scheduler
- [ ] deterministic test scheduler
- [ ] bridge/transport/drain timeout 注入
- [ ] timeout/cancel same-tick tests
- [ ] commit/push

## Phase F — Deterministic model/property tests

状态：TODO

验收项：

- [ ] 固定 seed event generator
- [ ] >=10,000 sequence
- [ ] terminal/completion/recovery/retry/resource invariants
- [ ] failure trace 可复现
- [ ] commit/push

## Phase G — Structured lifecycle journal

状态：TODO

验收项：

- [ ] bounded ring buffer
- [ ] operationID/device/partition/state/event/attempt/recoveryBudget/elapsed/error code
- [ ] 不记录密码/密钥/plaintext
- [ ] diagnostics export
- [ ] commit/push

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

当前 blocker：无非交互管理员授权，暂不能安装。

### Physical EDP USB

- [ ] 等用户插入标准加密 EDP U 盘后再执行
- [ ] 五因素重新识别
- [ ] Exchange ExFAT RW filesystem-level test
- [ ] mount/unmount >=5
- [ ] teardown residue=0
- [ ] 严禁 format/erase/raw write

## 变更日志

### 2026-08-30 23:49

- 创建本轮完整实施计划与实时 tracker。
- 明确本轮不再继续增加同步 fallback；后续以 async callback/state-event 为唯一产品路径。
- Phase A 基线验证完成：`git diff --check`、`make drive-test-fast`、`make drive-test-system` 全部 PASS。
