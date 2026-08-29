# EDP UI 与 Finder 复制首写延迟进度追踪

计划：`docs/PLAN-2026-08-29-ui-and-copy-performance.md`
基线 HEAD：`4800231839d10932f1033909838fedfa97e5c935`

## 当前状态

- Phase A：完成
- Phase B：代码完成，已本地 Release build/安装，待用户视觉验收
- Phase C：代码完成，已 Swift 6 `-warnings-as-errors` 编译，待本地安装交互验收
- Phase D：完成，已用 Direct MFMount Local fixture 精确验证 FUSE write/fsync/flush 行为并加入汇总 instrumentation
- Phase E：进行中，sync 分层、fixture 验证与本地编译/golden 已完成；真实盘 A/B 前发现并修复 cold-start fd3 继承 blocker
- Phase F：待安装候选 App/runtime 后开始真实 Lexar A/B
- Phase G：未开始

## 已确认事实

### 2026-08-29 20:24 前

- `main == origin/main == 4800231839d10932f1033909838fedfa97e5c935`。
- exact-head EDP Studio run `33251360186` success。
- 工作树已有未提交 UI WIP：Studio Inspector、Drive MenuBarExtra 和两条 CI ratchet。
- Studio 磁盘地图 160% 横向滚动已经可以看到保密区尾部，不再作为待修问题。
- Studio Inspector 当前目标已从 SwiftUI `.ultraThinMaterial` 改为原生 `NSVisualEffectView(.sidebar)`，外层 HSplitView 保持透明。
- Drive 当前 WIP 已从 `.menuBarExtraStyle(.menu)` 转向 `.window`，通过内部 route 层级避免 AppKit 级联菜单 hover 丢失。
- 真实 Lexar 标准加密盘当前：
  - `/dev/disk28` -> `/Volumes/交换区`，Apple exFAT FSKit；
  - `/dev/disk30` -> `/Volumes/保密区`，Apple exFAT FSKit；
  - hidden block transports 为 macFUSE Local；
  - Service 与两个 transport process 均稳定运行。
- 复制首写初步根因：Direct MFMount transport 当前对 `FUSE_FLUSH` 和 `FUSE_FSYNC` 都执行 `fsync()`，而 EDP adapter 的 `fsync()` 最终进入 `edp_rw_sync()`，执行 raw fd `fsync + F_FULLFSYNC`。
- 真实文件系统级临时测试：
  - 本机 APFS 4 KiB + fsync：约 0 ms median；
  - EDP 交换区 4 KiB + fsync：约 54 ms median；
  - 本机 APFS 8 MiB + fsync：约 10 ms median；
  - EDP 交换区 8 MiB + fsync：约 91 ms median。
- 所有真实盘测试仅使用挂载文件系统临时文件并删除；未进行 raw-sector 写入。

## 2026-08-29 20:30 UI 阶段推进

- Studio Inspector 已改为 `NSVisualEffectView(material: .sidebar, blendingMode: .behindWindow)`；移除 `.ultraThinMaterial` 灰色底层，保留透明 HSplitView column、圆角、轻描边和阴影。
- 新 Studio Release build 已成功，并已替换启动 `/Applications/EDP Studio.app` 供视觉验收。
- Drive 菜单栏已改为同一 `.menuBarExtraStyle(.window)` 内的三层并排层级：根级 -> 设备级 -> 分区级；所有 panel 处于同一个 popover 生命周期，鼠标横移不会跨 AppKit 子菜单窗口。
- Drive 多级 UI 使用 `selectedDeviceID` / `selectedPartitionType` 管理层级，设备拔出或分区消失会清除失效选择。
- Drive UI 已通过 Swift 6 `-warnings-as-errors` 独立编译。
- CI ratchet 已同步更新：继续禁止 `Menu(...)` 和 `.menuBarExtraStyle(.menu)`，要求 `.window` + 同窗多级选择状态；Studio 要求原生 sidebar visual effect 且禁止 `.ultraThinMaterial`/`.background(.background)` 回退。

## 2026-08-29 20:33 同步语义第一版

- UI 代码已独立提交：`ad37dd18884593afd14abc253feffaebec74d138`；Studio exact-head CI `33252622273` success。
- Drive UI ratchet follow-up：`101ade3c14103776452b051a0f6971b264ed97a3`；Drive exact-head CI `33252662687` success。
- 写入同步路径已开始拆层：
  - `EDPRawWritable.synchronize()` 定义为普通文件系统 sync；
  - 新增 `forceDurability()` 作为 transport close / safe eject 前最终强 barrier；
  - `EDPFileRawDevice.synchronize()` 现在只执行 `fsync`；
  - `EDPFileRawDevice.forceDurability()` 执行 `fsync` 后再 `F_FULLFSYNC`；
  - encrypted/plaintext block device 均向下转发两种同步语义；
  - `edp_rw_close()` 改为最终 `forceDurability()`；
  - Direct MFMount 的 `FUSE_FLUSH` 改为仅成功返回，不再把每个 close-path flush 变成物理介质 barrier；
  - `FUSE_FSYNC` 继续进入普通 `fsync`；transport 关闭时保留最终强 durability。
- 性能候选版已补低噪声观测：移除每个 FUSE 请求的 `DIRECT_OPCODE` 热路径日志，改为 transport 退出时输出 `DIRECT_IO_SUMMARY`（write/fsync/flush 计数和 fsync 累计/最大耗时）；最终强 barrier 输出 `EDP_FINAL_DURABILITY elapsed_us=...`。
- native-core golden 已通过，包含 boot/encrypted block 对 `synchronize()` 与 `forceDurability()` 两条独立转发语义的回归断言；macFUSE Local transport 已用 Swift 6 / C `-Werror` 成功构建。
- 性能修改已提交为 `71922cc2e7d1bc1b6615b35110c639e1d0dfd7f1`，exact-head EDP Drive CI run `33253069407` success。

## 2026-08-29 20:48 后继续推进

- 新建 32 MiB 临时加密 fixture，通过 Direct MFMount + macFUSE Local FSKit 挂载到 `/tmp/edp-direct-sync-fixture/mount`；整个实验未使用真实 U 盘数据。
- fixture 实测 10 次 write+close 与 3 次 write+`fsync()`：`writes=13`、`flush=0`、`fsync=6`。这说明当前 macFUSE Local 下 close 不产生 `FUSE_FLUSH`，而一次用户态 `fsync()` 会产生两次 `FUSE_FSYNC`。
- fixture 延迟：close-only median 约 4.4 ms，显式 fsync median 约 6.5 ms。该 backing 是临时文件，只用于协议语义确认，不代表 USB 物理盘性能。
- 因此根因判断进一步收敛：Finder 首写延迟的关键不是 `FUSE_FLUSH`，而是旧实现把每个 `FUSE_FSYNC` 都升级成 `fsync + F_FULLFSYNC`；新的 regular sync / final durability 分层仍是正确优化方向。
- 准备真实 Lexar A/B 时，XPC diagnostics 暴露 cold-start blocker：Service 冷启动自动挂载 type 2/4 均失败，错误 `EDP_DIRECT_INVALID_INHERITED_RAW_FD`。
- 根因已定位：raw lease 用 `O_CLOEXEC` 打开；冷启动时 retained raw fd 可能正好是 3。`posix_spawn_file_actions_adddup2(3, 3)` 不会可靠清除 CLOEXEC，随后 `edp-console-exec -> execv(transport)` 时 fd3 被关闭。Service 运行久后 raw fd >3 时 `dup2(N,3)` 会清 CLOEXEC，所以此前表现为非稳定复现。
- 已实施双层修复：
  - `spawnConsoleTransport` 遇到 `rawFD == 3` 时先 `F_DUPFD_CLOEXEC` 到高位 staging fd，再通过 spawn file action `dup2(staged,3)`；
  - `EDPConsoleExec.c` 在二次 `execv` 前验证 inherited fd3 为字符设备且具有 EDP metadata，并显式清 `FD_CLOEXEC`。
- fd3 修复已通过 Swift 6 `-warnings-as-errors` Service 编译与 C `-Wall -Wextra -Werror` console-exec 编译；Drive CI ratchet 已加入对应约束。

## 下一步立即执行

1. 提交/push fd3 cold-start 修复并等待 exact-head EDP Drive CI。
2. 构建候选 App/runtime，先验证 Service 冷启动自动挂载不再出现 `EDP_DIRECT_INVALID_INHERITED_RAW_FD`。
3. 安装候选 runtime 后对真实 Lexar 重新挂载交换区/保密区。
4. 复测 Finder 复制进度条启动延迟、实际吞吐和 `DIRECT_IO_SUMMARY`。
5. 回归 TextEdit 原子保存、多文件复制删除、交换区/保密区卸载重挂、安全推出、Service Stop/Start/Restart。
6. exact-head 全绿后更新 HANDOFF/STATUS 并收口工作树。
