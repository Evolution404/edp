# EDP Drive 异步生命周期最终收口与授权验收交接

日期：2026-08-31
分支：`codex/ui-macos26-liquid-glass`
项目根目录：`/Users/zhangyuxi/edp`
上一个完整功能提交：`eefd24093a3b`（Phase F model/property tests）
主计划：`docs/PLAN-2026-08-30-async-lifecycle-hardening.md`
实时跟踪：`docs/PROGRESS-2026-08-30-async-lifecycle-hardening.md`

> 本文是下一位 AI 的直接执行说明。不要新建 worktree，不要 reset、stash、checkout 覆盖或丢弃当前未提交 Phase G WIP。先读取本文、主计划、实时 tracker 和当前 `git diff`，再继续。

## 1. 当前架构基线

Phase A–F 已完成并已推送。已确认的核心约束：

- FSKit mount 只有异步状态机路径；旧同步 mount 已删除。
- Disk Arbitration 为 callback async API，不允许 semaphore 同步化。
- BlockPublisher / DiskImages2 publication 为 cancellable async operation。
- transport teardown 为 async state progression：graceful → TERM → KILL → bounded host recovery。
- mount / unmount / eject / shutdown 为 async single-path lifecycle。
- duplicate mount single-flight；completion exactly-once。
- cancellation 优先于 retry/recovery。
- lifecycle failure 使用 typed taxonomy，不允许 controller/recovery policy 依赖用户错误文本做决策。
- 8s/15s 等 lifecycle timeout 已改用 monotonic injectable scheduler。
- deterministic model/property gate 固定 seed `0xed505a1720260831`，10,000 sequences × 32 steps = 320,000 events。
- property test 已实际发现并修复 terminal overwrite 与 in-flight publication cancellation 两类状态机 bug。

已推送阶段提交：

- `6ebbf02` — async lifecycle / Disk Arbitration
- `130b385` — async BlockPublisher / DiskImages2
- `393e0f4` — typed lifecycle failures
- `b49e1f9` — monotonic lifecycle scheduler
- `eefd240` — deterministic lifecycle model/property invariants

## 2. 当前未提交 WIP：Phase G structured lifecycle journal

当前工作树故意保留 Phase G WIP，不得丢弃。

涉及：

- `Apps/Drive/product/EDPLifecycleJournal.swift`（新文件）
- `Apps/Drive/product/EDPVaultRuntime.swift`
- `Apps/Drive/Tests/run-service-lifecycle.sh`
- `Apps/Drive/Tests/run-storage.sh`
- `Apps/Drive/installer/build-native-installer.sh`
- `Apps/Drive/installer/build-clean-installer.sh`
- `docs/PROGRESS-2026-08-30-async-lifecycle-hardening.md`

当前 journal 已实现：

- 默认 256 条 bounded ring buffer；
- `operationID`；
- operation；
- deviceID；
- partitionType；
- state/event；
- attempt/recoveryBudget；
- monotonic `elapsedMs`；
- `ownedResources`；
- typed `diagnosticCode`；
- protocol 已增加 `lifecycleJournalSnapshot()`；
- MountManager 已开始接入 mount request / single-flight / cancel / terminal 等事件；
- scheduler + journal 新源文件已经开始加入 service/installer/storage 编译清单。

### Phase G 尚未完成

下一位 AI 必须继续完成，而不是重新设计：

1. 把 mount 主链所有关键 transition 接全：
   - bridge launch/wait/ready/failure；
   - cleanup；
   - host recovery；
   - publication start/complete/failure/cancel；
   - filesystem mount start/complete/failure；
   - terminal success/failure。
2. 接入 unmount：request、waiting-for-mount-drain、user FS teardown、publication teardown、transport teardown、terminal。
3. 接入 eject：request、cancel active mounts、drain、session teardown、physical eject handoff/terminal。
4. 接入 shutdown：request/coalesced、cancel active mounts、drain、session teardown、terminal。
5. `diagnosticsData()` 增加 `lifecycleJournal` JSON 数组。
6. 不在 journal 中增加 password、credential、key、raw sector/plaintext、完整 helper stderr、完整 raw path 等敏感字段。
7. `state/event/ownedResources/diagnosticCode` 使用稳定机器可读值；错误只记录 typed diagnostic code，不记录未经审查的 detail。
8. 新增 contract test：
   - ring buffer capacity 确实截断旧记录；
   - sequence 单调；
   - elapsed monotonic；
   - operationID 同一 operation 一致；
   - diagnostics export 可 JSON 序列化；
   - 输出中不出现注入的 password/key/raw plaintext sentinel。
9. `run-system.sh` 增加 journal ratchet，禁止无界数组和敏感字段。
10. Phase G 完成后：fast + service-lifecycle + system + virtual-usb + `git diff --check`，独立 commit/push。

建议 Phase G commit：

`feat(drive): add bounded lifecycle diagnostics journal`

## 3. 用户现在可以授权：授权窗口只做一次

用户已经明确表示现在可以授权。授权相关工作应在 Phase G 完成并构建最新 Clean.pkg 后一次性处理，避免安装旧代码后又重复授权。

### 3.1 授权前硬性安全检查

**绝对不要复用历史 diskN/PID。** 此前曾观察到 `disk26/disk27/disk29`、某些 `diskimagesiod` PID 等测试 orphan，但 BSD 名和 PID 会复用，只能当历史线索。

每次 root 操作前必须重新发现并证明：

1. `diskutil list external physical`：确认当前是否存在真实外接物理盘。
2. 如果存在任何真实 USB：
   - 不对其执行 format / erase / raw write；
   - 不把其 diskN 纳入测试 orphan 清理；
   - 所有 synthetic cleanup 必须独立证明 identity。
3. 对候选 macFUSE scratch：必须同时证明：
   - synthetic/virtual；
   - 典型 4KiB scratch 形态；
   - backing 位于系统 temporary scratch 路径；
   - 当前没有合法 mount 使用它；
   - owner 与候选 helper 对应。
4. 对候选 DiskImages2 orphan：必须证明：
   - exact backing 指向 EDP storage test / `.edp-block-*` synthetic backing；
   - 当前无合法 mounted EDP session 依赖；
   - owner PID/executable 与 exact publication 对应。
5. 任一 identity 不一致：跳过，不做宽泛 `killall` / `pkill` / whole-disk cleanup。

### 3.2 一次授权应完成的动作

授权脚本必须先二次 revalidate，再执行：

1. 清理**仅已严格证明**的 root-owned synthetic orphan。
2. 清理旧 `/Applications/EDP Drive.app` 与旧 EDP service/runtime 安装残留（按项目现有 clean installer/preinstall 语义，不删除源码/用户文件）。
3. 安装最新构建并已通过 verifier 的：
   - `artifacts/EDP-Drive-0.6.0-arm64-Clean.pkg`
4. 重载/启动最新版服务。
5. 不把用户密码写入脚本、日志、仓库或聊天；使用 macOS 系统授权 UI。

**不要再安装 `EDP-Drive-0.6.0-Native.pkg` 作为最终 clean-install 验收包。** Native.pkg 是内部/native package；正式干净安装验收使用 Clean combined installer（包含预期 macFUSE 组件）。

## 4. Phase H：授权后的最终验收顺序

### H1. 先做 hardware-free exact-head gate

Phase G commit 后重新执行：

1. `make drive-test-fast`
2. `make drive-test-virtual-usb`
3. `make drive-test-system`
4. `make drive-test-ui`
5. `bash -n` 所有改动 shell scripts
6. `plutil -lint` 两个 service plist 及相关 plist
7. `git diff --check`
8. 构建 latest Clean.pkg
9. `Apps/Drive/scripts/verify-clean-installer.sh artifacts/EDP-Drive-0.6.0-arm64-Clean.pkg`

必须保存最终 marker；任何 timeout 不算 PASS。

### H2. 一次管理员授权：cleanup + clean install

按第 3 节执行。安装完成后重新检查：

- `/Applications/EDP Drive.app` 是最新构建；
- service executable/version 与包一致；
- 只有一个目标 daemon；
- launchd/service plist `ThrottleInterval=1`；
- 无旧 EDP helper/runtime 混用。

### H3. installed service-cycle

无物理 USB 或保持物理 USB 完全不参与测试的前提下：

- 运行 8 次 stop/start cycle；
- 每次 start <= 3000ms；
- 每轮 daemon count = 1；
- 不出现随循环次数增加的 progressive slowdown；
- stop 后无 EDP mount/session/process residue；
- 必须获得 `RESULT=SERVICE_RESTART_CYCLE_OK`（或项目当前同义正式 marker）。

如某一轮失败，记录每轮 latency，而不是只重试到成功。

### H4. storage smoke 两轮

在管理员清理后的干净 FSKit/DiskImages 环境执行两个独立 fixture：

- `make drive-test-storage-smoke` 第 1 次，必须返回最终 `RESULT=DRIVE_STORAGE_E2E_OK`；
- 再运行第 2 次，必须再次返回最终 marker；
- 每次结束验证 0 workdir mount / 0 workdir DiskImages publication / 0 adapter process；
- 外部工具 300s 超时不等于 PASS。

storage harness 已加固：

- synthetic identity proof；
- 2 秒 BSD settle + 二次 proof；
- attach bounded retry；
- erase timeout 后按 filesystem result-state 复核；
- owner-only publication 检测；
- hidden macFUSE block bridge 保持既有 `local,nobrowse` VFS 语义；重复 remount 安全性由 exact publication teardown + unique generation + quiescence barrier 保证，不通过改变 bridge VFS 属性规避；
- exact DiskImages2 publication disappearance + transport exit 后执行 3 秒 generation quiescence，才允许同一逻辑分区 remount；
- phased mode/profile marker/leak gate。

不要削弱这些安全保护换取测试通过。

### H5. release storage 5-loop

执行 canonical release profile，M10 固定跑 5 个完整 mount/attach/filesystem/unmount/eject/transport-remount cycle，并必须拿到最终 PASS marker；每轮 teardown 后必须经过与产品一致的 3 秒 remount quiescence，且保留真实 filesystem `stat`/读写验证，禁止通过删除文件访问来规避 FSKit 问题。只看到 M10 5/5 或后续阶段日志，不足以宣称 release PASS。需要额外 soak 时可显式提高 `EDP_STORAGE_LOOP_COUNT`，但不作为常规发布硬门槛。

### H6. 真实 EDP U 盘验收

只有用户明确插入并准备好标准加密 EDP U 盘后才执行。

重新做五因素 identity：

- VID
- PID
- LBA4 numeric onlyId
- whole capacity
- LBA11 metadataDeviceID

只允许标准加密盘进入 EDP 管理链；其他盘交给 macOS。

真实盘安全约束：

- 禁止 format/erase/partition/raw test write；
- raw 层只做识别/读取/正常产品加解密访问；
- filesystem 层可对 Exchange type2 做正常 create/read/write/rename/delete 验收；
- mount/unmount >=5；
- 每次 teardown：user volume=0、`.edp-block-*`=0、DiskImages publication=0、transport process=0。

## 5. 仍建议在最终完成前审查的非阻塞项

这些不是当前授权前 blocker，但如果 Phase G/H 完成后还有时间，继续评估：

1. `edp-raw-metadata` discovery helper 仍是同步子进程边界；长期可改 direct raw lease/pread 或 async helper request。
2. legacy runtime data migration (`/var/db/com.edp.usbvault` 与旧 Keychain service) 是否仍需要；这是数据兼容问题，不要与 installer-managed LaunchDaemon fallback 混淆。
3. “legacy service mode”实际是 self-signed distribution 的 installer-managed LaunchDaemon fallback；如果保留，建议后续重命名，不能盲删。
4. publisher 仍使用 bounded `hdiutil` adapter，这是外部工具边界；不要重新把它改回 lifecycle queue 同步 wait。

## 6. 下一位 AI 的提交纪律

- 继续当前目录和当前分支，不新建 worktree。
- 不 reset/stash/drop 当前 Phase G WIP。
- Phase G 完成后独立 commit/push。
- Phase H 中，如果测试 harness/安装脚本发现真实 bug，可以独立小提交；每个提交后及时 push。
- tracker 每推进一个阶段立即更新；不得把 timeout、部分 marker 或“看起来完成”写成 PASS。
- 所有物理 USB 相关操作 fail-closed。

## 7. 最终完成定义

只有全部满足才把整个计划标记 DONE：

- Phase G journal 完成、测试、commit/push；
- fast / virtual-usb / system / UI exact-head 全绿；
- Clean.pkg exact-head 构建与 verifier PASS；
- 一次授权完成安全 orphan cleanup + clean install；
- installed service-cycle 8/8，start <=3s，无 progressive slowdown；
- storage smoke 两轮都有最终 PASS marker；
- release 5-loop 有最终 PASS marker；
- 如进行真实盘验收，必须遵守非破坏性约束且 teardown residue=0；
- tracker 与仓库 HEAD 一致，工作树只允许明确记录的剩余 WIP，否则应 clean。
