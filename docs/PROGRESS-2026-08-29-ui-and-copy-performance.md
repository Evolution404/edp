# EDP UI 与 Finder 复制首写延迟进度追踪

计划：`docs/PLAN-2026-08-29-ui-and-copy-performance.md`
基线 HEAD：`4800231839d10932f1033909838fedfa97e5c935`

## 当前状态

- Phase A：完成
- Phase B：代码完成，已本地 Release build/安装，待用户视觉验收
- Phase C：代码完成，已 Swift 6 `-warnings-as-errors` 编译，待本地安装交互验收
- Phase D：完成，已用 Direct MFMount Local fixture 精确验证 FUSE write/fsync/flush 行为并加入汇总 instrumentation
- Phase E：完成，regular sync / final durability 分层与 dirty-generation fsync 去重均已提交并通过 exact-head CI
- Phase F：大部分完成；真实复制/TextEdit/多文件/cold-start 已通过，第二轮 Service Restart 暴露失败清理卡死，当前等待 lifecycle hardening + 重启后最终复验
- Phase G：完成第一轮研究，已形成 Finder 约 3 秒进度机制诊断文档；结论为系统 Finder/ExFAT UI 稳定窗口，不是 EDP 首写阻塞
- Phase H：完成第一轮公开资料研究，已形成 EDP metadata 研究文档；公开资料确认三区域/标签模型，但未找到 LBA/EDPF/type/SM4 字节级公开格式
- Phase I：进行中，生命周期 hardening 已编码并通过本地 validator，待提交/CI/HANDOFF 收口

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
- fd3 修复提交：`082fdfbd6b36c5e6e8f27cd9e05de10673dd65bf`。候选 Native.pkg 已安装到真实机器，App、embedded Service、macFUSE Local runtime 和 console-exec 与候选 payload SHA-256 完全一致。
- 实机 cold-start 验证通过：Service 重新启动后 `privilegedAccessReady=true`，type 2 交换区和 type 4 保密区均自动挂载为可写 ExFAT，不再出现 `EDP_DIRECT_INVALID_INHERITED_RAW_FD`。
- 第一版 sync 分层实机 A/B：4 KiB fsync median 约 47.8 ms，8 MiB fsync median 约 93.4 ms，与旧版约 54 ms / 91 ms 接近；说明普通 raw USB `fsync` 本身仍是主要延迟，而不仅是 `F_FULLFSYNC`。
- 真实交换区 600 MiB 普通文件系统复制基线：629,145,600 bytes / 12.093 s = 约 52.0 MB/s，源/目标 SHA-256 一致，临时目标已删除。
- 基于 fixture 精确行为，新增加 dirty-generation fsync 去重：每次成功 `FUSE_WRITE` 增加 generation；`FUSE_FSYNC` 仅在 generation 尚未同步时执行物理 fsync；没有新 WRITE 的重复 FSYNC 直接 success。
- Direct MFMount Local fixture 已验证：3 次上层 `fsync()` -> 6 次 `FUSE_FSYNC` request，但新逻辑为 `physical_fsync=3`、`skipped_fsync=3`、`flush=0`，准确消除 macFUSE Local 的重复同步放大。

## 2026-08-29 21:00-21:17 真实复制与 Finder 对照

- dirty-generation 去重提交 `63b003a997889e50b6032bf761450bfa841ad305`；exact-head EDP Drive CI run `33254052414` success。
- 第二版候选 runtime 已安装；cold-start 后 type 2/type 4 均自动挂载成功，fd3 blocker 修复保持稳定。
- 去重版真实 fsync：4 KiB median 约 49.1 ms，8 MiB median 约 105.7 ms；单次 fsync 没有继续下降，说明 Apple ExFAT 在相邻 FUSE_FSYNC 之间可能继续产生 metadata/block WRITE，第二次并非总可跳过。
- 600 MiB 普通文件复制约 10.980 s / 57.30 MB/s，较第一版约 52.02 MB/s 有约 10% 改善；SHA-256 一致。
- Finder 真实 `~/Downloads/ChatGPT.dmg`（600,747,074 bytes）复制到交换区：目标目录项约 0.269 s 出现，约 0.885 s 已开始实际 allocated/write，Finder UI 首次明显状态切换约 2.908 s，总时间约 5.369 s，SHA-256 一致。
- 建立完全绕过 EDP/macFUSE/USB 的本机 8 GiB ExFAT DiskImages2 对照，复制 6.5 GiB Ubuntu ISO：Finder UI 首次状态切换约 2.979 s。
- 同一 6.5 GiB ISO -> EDP 交换区：Finder UI 首次状态切换约 3.296 s，总时间约 70.211 s，持续吞吐约 92.85 MB/s，SHA-256 一致。
- 因此约 3 秒的“来回折返/不确定进度”被定性为 Finder 对 ExFAT 复制的 UI/progress stabilization 行为，而不是 EDP 在 3 秒后才开始 I/O。EDP 实际写入 <1 s 即已开始。
- TextEdit 真实 UI open -> edit -> Save -> close：PASS，原子保存内容正确。
- Finder 32 文件批量复制与删除：PASS；抽样 hash PASS；测试 Trash 项已清理。
- 所有大文件/临时 ExFAT 控制镜像均已清理；真实 U 盘没有 raw-sector 写入。

## 2026-08-29 21:13 后第二轮 Restart 生命周期问题

- 第一轮 Service Stop -> on-demand Start -> type 2/type 4 自动恢复已经 PASS。
- 第二轮 restart-equivalent 暴露异常：Service PID `44397` controller queue 失去 XPC 响应；交换区曾正常挂载，保密区 transport process 启动但未形成 hidden mount；`--xpc-snapshot` / `--xpc-graceful-stop` 均 timeout。
- 安全恢复过程中：交换区通过 Finder eject 正常完成文件系统推出；其 hidden macFUSE mount 正常解除；exchange transport 正常退出；secure transport 从未形成 VFS mount，SIGTERM 无响应后才执行 SIGKILL。
- 当前没有任何 `/Volumes/交换区`、`/Volumes/保密区` 或 `.edp-block-*` mount，也没有 EDP transport process。
- root Service 自身在请求 SIGKILL 后仍停留于 `ps` state `E` / launchd PID `44397`，属于 OS/process teardown 已卡死状态；由于所有用户卷/transport 已安全清空，不存在当前数据一致性风险，但最终实机 Restart/Safe Eject 验收需要系统重启后继续。
- 代码级 hardening 已实施：
  - `hdiutil info/detach` 改为 bounded process，8 s hard timeout；
  - writable DiskImages2 attach 改为 bounded process，15 s hard timeout；
  - bounded runner 使用临时文件承载 stdout/stderr，避免 Pipe 满造成父子互等；
  - transport stop 只有在确认 hidden VFS mount 已消失后才允许 `SIGTERM -> 2 s grace -> SIGKILL -> 1 s verify`；mount 仍存在时 fail closed，绝不 kill transport。
- 新增 `ValidateTransportLifecycle.swift`，纯内存覆盖 already-exited、TERM exit、TERM->KILL、mounted fail-closed 四种状态；本地结果 `RESULT=TRANSPORT_LIFECYCLE_HARDENING_OK`。
- 完整 Drive daemon Swift 6 `-warnings-as-errors` 编译通过。
- lifecycle hardening 已提交为 `70ea958d116b2f216f497cdd1b91e6c0198720aa`；exact-head EDP Drive CI run `33255506939` success。

## 2026-08-29 Finder Progress 研究

- 新文档：`Apps/Drive/docs/diagnostics/2026-08-29-finder-progress-estimation.md`。
- Apple Foundation `Progress` 公开语义确认：file progress 以 bytes 为 unit；缺少合理 total/completed 时可处于 indeterminate；throughput / estimatedTimeRemaining 是独立可选信息。
- Apple 没有公开 Finder 内部“等待 3 秒”的固定阈值/算法；精确约 3 秒来自本机受控 A/B，必须标注为实测，不得写成 Apple 官方规则。
- Finder Sync 公开 API 仅覆盖 monitored folders、badge、context menu、toolbar 等，没有接口覆盖 Finder 自己的 file-copy progress。
- File Provider progress 属于 provider upload/download 模型，不适合真实本地 EDP block volume。
- 当前没有找到受支持的 FSKit/mount 属性能强迫 Finder 从第一帧显示 determinate percentage。
- 若未来必须“立即百分比”，可由 EDP 自己成为 copy operation owner，已知 source bytes 后自行发布 `Progress` 并显示 UI；这会变成 EDP 自有复制流程，不是修改 Finder 内置复制行为。

## 2026-08-29 EDP Metadata 公开资料研究

- 新文档：`Apps/Drive/docs/diagnostics/2026-08-29-edp-metadata-public-research.md`。
- 北信源专利 CN105141614A/B 直接确认：加密标签移动存储设备划分为“启动区、交互区、保密区”，通过密码控制交互/保密区访问。
- 政府采购技术要求公开使用“启动区、交换区、保密区”术语，并描述三区/双区组合；与项目产品 UI/真实盘模型高度一致。
- 北信源招股资料确认专用安全 U 盘、芯片级移动存储数据安全、USB 标签认证及底层数据存储转换/解码分析/信息重构产品路线。
- 公司历年公开报告确认“北信源移动存储管理系统及安全U盘2.16.0”是长期产品，并列有“快速识别移动存储设备的方法和装置”等相关专利。
- 当前未找到公开资料直接披露 type 1/2/4、LBA4/LBA7/LBA11/LBA12、`EDPF` record、CRC 字段、key derivation 或 SM4 block mapping；这些继续只以真实盘 capture + golden validator 为权威证据。

## 下一步立即执行

1. lifecycle hardening local gates / 独立 commit / exact-head CI 已完成；保留 reboot 后真实盘复验作为最终硬 gate。
2. 将 Finder progress / EDP metadata 两份研究文档与计划/进度状态形成独立 docs commit。
3. 更新 `docs/HANDOFF-2026-08-29.md` 与 Drive STATUS，明确约 3 秒 Finder 行为结论与 root Service 当前 E-state blocker。
4. 当前 Mac 需要重启才能清除已 SIGKILL 但仍停留 E-state 的 root Service；重启后继续 type 2/type 4 自动挂载、第二轮 Stop/Start/Restart、安全推出整盘、App restart 最终验收。
5. 最终 exact-head CI 全绿、工作树干净、`main == origin/main` 后收口。
