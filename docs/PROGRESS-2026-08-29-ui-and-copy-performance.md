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

## 2026-08-29 21:48 重启后最终验收继续

- Mac 重启后旧 root Service `E` state 已彻底清除：launchd 初始 `state = not running`、`runs = 0`，无任何 EDP hidden/user mounts 或 transport process。
- 仓库基线 `7a4cc01c69f86d25428003b062d57449b6c274d3 == origin/main`，exact-head Drive CI run `33255649709` success。
- 从 exact-head 重新构建固定签名 clean combined installer，完整 `verify-clean-installer.sh` 通过；App/Service designated requirement 仍固定 certificate root `040b5488fb2b6c02b0786e76b674cb4460658ca2`。
- 安装最终候选后首次 Service 扫描识别真实 Lexar `disk6` 为 `standardEncrypted`，raw access `privilegedAccessReady=true`，但 type 2/type 4 自动挂载均失败：
  - type 2：macFUSE `File system extension not found`；
  - type 4：macFUSE `File system extension not enabled`。
- 根因进一步收敛：组合安装包重新安装 macFUSE 5.3.3 后，当前用户的 `~/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist` 被重写，只剩 Apple FSKit module；此时 UI App 尚未运行，root Service 先自动挂载并将失败写入 `failedMounts`，而产品策略 `automaticMountRetry=false` 会锁存该失败。
- 启动 EDP Drive UI 后，现有 `ensureMacFUSELocalEnablement()` 能正确恢复 `io.macfuse.app.fsmodule.macfuse` 与 `io.macfuse.app.fsmodule.macfuse-local` 到 PluginKit + FSKit enabled settings；但旧 Service 不会自动清除失败锁存，因此仍保持 unmounted。
- UI 恢复 enablement 后，使用 XPC 手动挂载 smoke 验证 type 2/type 4 均立即成功，分别挂载为可写 ExFAT `/Volumes/交换区`、`/Volumes/保密区`；说明底层 transport/crypto/raw-fd 路径健康，缺口仅是 enablement 恢复后的 bounded retry。
- 已实现最小自动恢复设计：新增 `retryTransientAutomaticMounts` XPC，只清除当前连接设备、global/partition autoMount 开启、未被用户 manual-unmount suppression 的 type 2/4，并且仅当失败文本包含 `File system extension not found` 或 `File system extension not enabled` 时清锁；密码错误、raw access 错误、其他 mount 错误绝不自动重试。
- EDP Drive UI 在 `ensureMacFUSELocalEnablement()` 成功且 runtime ready 后只触发一次 transient retry；Service 随后走既有 `reconcile()`，不引入周期自动重试。
- 新协议/Service/UI 已通过 Swift 6 `-warnings-as-errors` 完整编译，CI ratchet 已加入 transient retry 边界约束。
- `02e9ad883f9b4219c4d38a7d52e96fb4ceb933a8` 已提交/push，exact-head Drive CI run `33256361893` success。
- 真实安装复现表明失败窗口不仅来自 `enabledModules.plist`：即使该 plist 已包含 macFUSE IDs，macFUSE 组合安装后的 ExtensionKit/FSKit 注册仍可能尚未稳定，Service 仍可先得到 `not found/not enabled`；因此 bounded transient retry 仍必要。
- 初次启动 UI 未自动恢复是因为用户此前持久化 `com.edp.drive.service.desired-running=false`；这是正确的“用户明确停止”语义，App 不应绕过该意图偷偷连接 Service。
- 将该 preference 恢复为 true（等价于用户点击“启动”的第一步）并重新打开已安装 `02e9ad8` UI 后，真实 Lexar 在约 10 s 内无需手工 mount 即恢复 type 2/type 4，可写 ExFAT 两区均 mounted，`failedMounts` 清空；证明 transient retry 核心逻辑实机 PASS。
- follow-up 已把同一 retry 接入 `startService()` health-check success 路径；因此“用户曾 Stop -> 后续显式 Start”也能在尊重用户意图的前提下恢复 transient FSKit 自动挂载失败。

## 2026-08-29 22:18 后 UI 合并与 XPC 生命周期继续验收

- `codex/ui-macos26-liquid-glass` 已完成并保持干净，严格线性基于 `main@1942795`；已 fast-forward 合并到 `main` 并 push，合并后 HEAD `a6f1098fca52b9f13a3c1c6cc45109cef5c813c8`。
- UI 分支除了液态玻璃视觉调整，还把正式 `EDPVaultViewModel` 的 NSXPC interruption/invalidation/error/reply callbacks 全部标注为 `@Sendable`，这正好覆盖实机 crash report 中 `EDPVaultViewModel.proxy()` 从 XPC queue 触发 Swift 6 MainActor isolation `SIGTRAP` 的根因。
- 旧安装二进制 `1942795` 的正式 UI 点击“启动”可稳定复现 `EXC_BREAKPOINT/SIGTRAP`，crash stack 为 `EDPVaultViewModel.proxy()` -> `__NSXPCCONNECTION_IS_CALLING_OUT_TO_ERROR_BLOCK__` -> `_swift_task_checkIsolatedSwift`；因此旧包不能继续作为生命周期最终验收候选。
- 同一旧包的 `--xpc-graceful-stop` CLI 也可在 XPC callback 路径触发同类 actor crash；已将 `@main EDPUSBVaultApp.init()` 下全部 CLI XPC error/reply/interruption/invalidation callbacks 同样显式改为 `@Sendable`，避免 smoke harness 自身干扰产品验收。
- 新增 CI ratchet：正式 ViewModel proxy/graceful-shutdown 与 CLI graceful-stop 均必须保留 `@Sendable`，并禁止重新出现未标注的 `remoteObjectProxyWithErrorHandler({ error in`。
- 找到此前“Stop 后约 6 s 又自动复活”的外部触发源：`/private/tmp/EDP Drive UI.app/Contents/MacOS/EDP Drive`（PID 10716）是并行 UI 调试遗留测试 App，每约 2 s 连接 `com.edp.drive.service`。Service 因路径/签名安全边界正确拒绝该 peer，但 launchd 在 peer validation 前已因 `ipc (mach)` demand-launch Service；终止该临时测试进程后不再把此现象归因于产品 KeepAlive。
- 当前旧 Service 的最后一次 teardown 已把所有用户卷/hidden mount 清到 0，但一个旧 secure transport 曾停留为无 mount 的 zombie child；这属于旧二进制异常收尾状态。由于没有挂载文件系统，后续可安全通过新候选安装升级替换。
- 第一次安装 `5285ea8` Native 候选时，PackageKit 已成功替换 App/embedded Service payload，但 postinstall `launchctl bootstrap system /Library/LaunchDaemons/com.edp.drive.service.plist` 返回 `Bootstrap failed: 5: Input/output error`，最终 package result `PKInstallErrorDomain Code=112`。
- 实机根因：旧 Service PID `10746` 在 launchd job 已被 `bootout` 后仍停留 `ps state ?Es`；原 argv 已丢失，`launchctl print system/com.edp.drive.service` 已无 job，但旧内核进程仍未退出，使新 Mach service 无法 bootstrap。旧 installer preinstall 原来对 `bootout` 结果完全忽略，也不等待旧 job/process 真正消失，造成 payload 已覆盖、postinstall 才失败的半安装状态。
- installer 已改为 fail-closed lifecycle：有 `/Volumes/.edp-block-*` active mount 时拒绝升级；bootout 后 bounded wait job 消失；只有确认无 EDP hidden filesystem 后才允许 stale transport/service `TERM -> grace -> KILL`；KILL 后仍有残留则在 payload 覆盖前明确提示重启 macOS 并失败退出。
- `E` state 进程已无法用完整 argv/`pgrep -f` 可靠识别；实机 `ps -o ucomm=` 仍保留 `edp-drive-servic`，因此 preinstall 改用 macOS kernel `ucomm` 检测 service/transport，当前 stuck PID `10746` 已被新检测器准确命中。
- postinstall 新增 bounded `bootstrap_service()` retry；clean combined installer 删除重复内嵌 pre/post scripts，改为与 Native installer 统一复制 `installer/scripts/native-preinstall` / `native-postinstall`。
- 新 installer scripts 已 `bash -n` 全绿；Native package 本地构建/expand 验证确认新 pre/post scripts 确实进入包内，结果 `RESULT=INSTALLER_LIFECYCLE_HARDENING_LOCAL_OK`。

## 2026-08-29 23:15 后最终生命周期复验与 VFS 根因

- 重启后旧 `10746 ?Es` / `10892 Z` 已全部消失，Service 基线 `not running / runs=0`，无 EDP mount；`main == origin/main == b8014d9`，exact-head Drive CI run `33259442868` success。
- 从 `b8014d9` 重新构建 Native 包并安装：preinstall、payload、postinstall、receipt 全部成功，安装日志不再出现 `Bootstrap failed: 5`；installer lifecycle hardening 实机 PASS。
- 安装后 Service PID `3745` 自动启动，type 2/type 4 均恢复为可写 ExFAT；CLI `--xpc-health` / `--xpc-snapshot` 均 rc=0，最近无新 crash，证明合并后的正式/CLI `@Sendable` XPC callbacks 已消除此前 Swift 6 MainActor `SIGTRAP`。
- 第一轮 `--xpc-graceful-stop` 完整 PASS：Service `not running / exit 0`、用户卷 0、hidden mount 0、transport 0。
- 随后正式 UI 启动并建立可信 XPC，Service PID `4053` demand-launch，type 2/type 4 在约 1 s 内恢复；UI 持续运行无 crash。
- 第二轮 graceful Stop 再次真实复现 lifecycle hang：90 s timeout；Stop 已先成功卸载保密区，最终只剩交换区 user mount + hidden macFUSE，Service PID `4053` 进入 `ps state U`。Finder 可安全推出交换区 user mount，但 hidden macFUSE 的系统 `diskutil unmount force` 同样可以无限阻塞。
- 根因最终确定：`EDPNativeMountTable.unmountPath()` 原来直接在 root Service 线程内执行 `Darwin.unmount(2)`。VFS/FSKit 一旦把该 syscall 放入不可中断内核等待，任何 Swift/Dispatch timeout 都无法救回 Service，因此 controller queue/XPC 一并冻结。
- 修复：新增 `EDPNativeBoundedProcess`，VFS unmount 改由独立 `/sbin/umount` 子进程执行；普通卸载 15 s、forced hidden 卸载 8 s hard timeout，超时后 `TERM -> bounded grace -> SIGKILL -> bounded grace`，parent Service 必须在有限时间内返回错误而非进入 `U` state。
- teardown 同时改为严格 top-down fail-closed：用户文件系统未确认消失 -> 不 detach DiskImages2；published BSD device detach 失败 -> 不拆 hidden transport；hidden mount 未确认消失 -> 不 kill transport。`recoverPersistedSessions()` 同样采用这一安全顺序，删除旧 `try?` fail-open 链。
- 新增 `ValidateBoundedVFS.swift`：正常 `/usr/bin/true` 路径 + 故意 `/bin/sleep 5` timeout 路径；本机 timeout probe 在约 `0.229 s` 返回，结果 `RESULT=BOUNDED_VFS_UNMOUNT_GUARD_OK`。
- 完整 fixed-signing Native product build通过，结果 `RESULT=BOUNDED_VFS_FULL_PRODUCT_BUILD_OK`；CI 新增 ratchet：禁止恢复 `Darwin.unmount(`，强制 `/sbin/umount` bounded helper、top-down teardown 日志和 bounded VFS golden validator。
- `cd5bd49` 已提交/push，exact-head Drive CI run `33260540149` success。重启后旧 `4053 U` 已彻底消失；从 exact-head 重建 Native 包并安装成功，Service PID `2208` 首次启动后 type 2/type 4 在约 1 s 内自动恢复，可写 ExFAT、`privilegedAccessReady=true`。
- `cd5bd49` 实机连续两轮 lifecycle 已 PASS：第一轮 Stop 约 1 s 完成，Service `not running / exit 0`、user/hidden/transport 全部为 0；第二轮 demand Start 后约 8 s 两区恢复，再 Stop 仍约 1 s 完成，无 `U` state、zombie、XPC timeout 或新 crash。
- 正式 UI App restart 已 PASS：UI PID `2872 -> 2936`，Service PID 始终 `2674`，两区挂载持续存在，说明仅退出/重开界面不会重启后台服务或扰动已挂载卷。
- 整盘安全推出前进一步收紧 fail-closed 边界：`EDPVaultManager.unmount(deviceID:partitionType:)` 和 `eject(deviceID:)` 改为 `throws`，只要 session 仍存在就明确失败；controller 的显式卸载、删除凭据前卸载、整盘推出均 `try` 传播，不再出现“底层 teardown 失败但 UI 继续报成功/继续释放 raw fd 或物理 eject”的路径。
- CI 新增 ratchet：整盘 `eject` 必须 `throws`、controller 必须 `try manager.eject`、分区卸载必须 `throws` 并保留 `EDP partition could not be safely unmounted` guard。完整 fixed-signing Native product build已通过，结果 `RESULT=EJECT_FAIL_CLOSED_BUILD_OK`。

## 下一步立即执行

1. 提交/push explicit unmount/eject fail-closed propagation，等待 exact-head Drive CI。
2. 先 graceful Stop 当前健康 Service，安装新 exact-head Native 候选，再 demand Start 并确认 type 2/type 4 恢复。
3. 使用产品 XPC `eject(deviceID:)` 做整盘安全推出；要求 type 2/type 4/hidden transport 全部先清空，再卸载启动区并由 Disk Arbitration eject 物理 `diskN`，失败时必须保持 fail-closed。
4. 安全推出成功后等待用户物理重新插入，验证 `diskN` 变化/重复插拔无需第二次管理员授权且自动挂载恢复。
5. 更新 HANDOFF/STATUS/本 tracker，最终 exact-head CI 全绿、工作树干净、`main == origin/main` 后收口。
