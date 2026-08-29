# EDP UI 与 Finder 复制首写延迟收口计划

日期：2026-08-29
分支：`main`
基线：`4800231839d10932f1033909838fedfa97e5c935`

## 目标

本轮只收口两个已暴露的产品问题，不做架构迁移：

1. EDP Studio 右侧检查器必须与左侧系统 Sidebar 属于同一视觉语言：悬浮、圆角、真实 behind-window 毛玻璃；禁止用灰色 SwiftUI 背景把毛玻璃压成实体面板。
2. EDP Drive 菜单栏恢复清晰的多级设备/分区层级，但不能恢复 AppKit 级联 `Menu(...)` 的鼠标横移易关闭问题。
3. 解决 Finder 向交换区/保密区复制文件时，在真正显示确定进度条前反复出现不确定进度、首写启动慢的问题，同时保持正常 fsync、卸载、完全退出、安全推出时的数据完整性语义。

## 执行状态（2026-08-29 21:40 更新）

- Phase A：完成。
- Phase B：Studio native sidebar material 代码/安装/CI 已完成，仍待用户最终视觉确认。
- Phase C：Drive 同窗多级菜单代码/编译/CI 已完成，仍待用户最终交互确认。
- Phase D：完成；Direct MFMount fixture 已精确量化 write/fsync/flush。
- Phase E：完成；regular sync / final durability 和 dirty-generation fsync dedupe 已提交并通过 CI。
- Phase F：大部分真实标准盘功能/性能已通过；第二轮 Restart 暴露 failure-path wedge，当前所有用户卷/transport 已安全清空，root Service 处于 OS process state `E`，需 reboot 后用 lifecycle hardening 继续最终验收。
- Phase G：第一轮研究完成，结论与数据已写入 `Apps/Drive/docs/diagnostics/2026-08-29-finder-progress-estimation.md`。
- Phase H：第一轮研究完成，结论与来源已写入 `Apps/Drive/docs/diagnostics/2026-08-29-edp-metadata-public-research.md`。
- Phase I：进行中；lifecycle hardening `70ea958` exact-head Drive CI `33255506939` 已通过，当前进行 research docs / HANDOFF / STATUS 收口，实机最终 gate 等 reboot 后继续。

## 不可破坏约束

- 不新增 worktree，不切离当前 `main`。
- 不恢复 Tauri/Rust production runtime、FUSE-T、ntfs-3g、macFUSE kernel backend、DriverKit、自研文件系统。
- 不修改 TCC、AuthorizationDB、DefaultKeychain/SearchList，不更换签名证书。
- 真实 EDP U 盘禁止 raw-sector 写入、格式化、分区、擦除。
- 性能验收只允许通过已挂载文件系统创建临时测试文件并删除。
- 密码只走 App UI / Keychain，不进入命令行、日志或仓库。
- 磁盘地图完整横向滚动能力必须保持，不能为了 Inspector 外观重新使用 overlay `.inspector(...)`。

## 已确认基线

### Studio

- `HSplitView` 已解决 Inspector 遮挡磁盘地图横向内容的问题。
- 磁盘地图真实 scroll extent 已修复，160% 缩放时可滚到保密区尾部。
- 当前待修复：右侧检查器仍与左侧 Sidebar 视觉不一致；`.ultraThinMaterial` 叠加 Liquid Glass 会产生灰板感。

### Drive 菜单栏

- 单层菜单稳定，但层级信息过度摊平，视觉与操作体验差。
- 历史 AppKit 级联 `Menu(...)` 会因为父菜单到子菜单的鼠标轨迹/hover 切换而频繁消失，不能原样恢复。
- 当前工作区已有基于 `.menuBarExtraStyle(.window)` 的自定义层级 WIP，需要收口成稳定的同一浮层多级导航，而不是系统级联菜单。

### Finder 复制

当前真实 Lexar 标准加密盘挂载链：

`Finder -> Apple exFAT FSKit -> DiskImages2 -> macFUSE Local -> EDP block translator -> retained /dev/rdisk fd`

已确认：

- 交换区、保密区均为 Apple exFAT FSKit 正常挂载。
- EDP Service、macFUSE Local transport 均稳定运行。
- 当前 `FUSE_FLUSH` 和 `FUSE_FSYNC` 都调用同一个 `fsync()` shim。
- `edp_rw_sync()` 最终执行 `fsync(raw fd)` 后继续执行 `F_FULLFSYNC(raw fd)`。
- 真实交换区临时文件测试：
  - 4 KiB + fsync：中位约 54 ms。
  - 8 MiB + fsync：中位约 91 ms。
  - 本机 APFS 同类测试接近 0-10 ms。
- Finder 复制开始前会进行 create/open/metadata/xattr/flush/fsync 等准备请求，因此把普通 `FLUSH` 也升级成物理 `F_FULLFSYNC` 很可能造成多轮 50-100 ms barrier，表现为进度条反复折返后才进入确定复制阶段。

## Phase A — 固化基线与诊断护栏

- [ ] 记录当前 HEAD、工作树、exact-head CI。
- [ ] 保留当前 Studio/Drive UI WIP，不覆盖、不回退。
- [ ] 增加/确认 CI ratchet：
  - Studio 禁止 `.inspector(...)` 和灰色不透明 Inspector 背景。
  - Drive 禁止恢复系统级联 `Menu(...)`。
  - Drive 要求 `.menuBarExtraStyle(.window)` 和稳定层级路由实现。
- [ ] 对复制路径建立同步语义表：WRITE / FLUSH / FSYNC / close / unmount / eject / process exit 各自的 durability 要求。

完成标准：后续修改有明确可回归的源代码约束。

## Phase B — EDP Studio Inspector 视觉收口

目标：右侧 Inspector 与左侧系统 Sidebar 同类效果，而不是“灰色面板 + 毛玻璃”。

- [ ] 外层 HSplitView column 保持透明。
- [ ] Inspector 内容四周留悬浮间距，与窗口边缘脱离。
- [ ] 使用 AppKit `NSVisualEffectView(material: .sidebar, blendingMode: .behindWindow)` 作为真实 sidebar 毛玻璃材质。
- [ ] 移除 `.background(.background)`、`.ultraThinMaterial` 等会形成灰底的 SwiftUI 背景。
- [ ] 保留圆角、轻描边、轻阴影；避免二次材质叠加。
- [ ] 实机确认：左/右侧栏在亮色和暗色模式下均有一致的透背景层次，右栏不遮挡主内容。

完成标准：用户视觉验收 + Release build + Studio CI。

## Phase C — EDP Drive 稳定多级菜单

目标：恢复“设备 -> 分区 -> 操作”的多级结构，同时彻底避开系统级联菜单 hover 丢失。

- [ ] `MenuBarExtra` 使用 `.window`，所有层级保持在同一个 popover/window 生命周期内。
- [ ] 根级：后台服务、自动挂载、设备列表、刷新、退出。
- [ ] 设备级：启动区/交换区/保密区、安全推出整盘。
- [ ] 分区级：挂载 / 在 Finder 中显示 / 卸载等当前状态允许的动作。
- [ ] 采用稳定的页内层级/同窗级联导航，不使用 SwiftUI/AppKit `Menu(...)` 子菜单。
- [ ] 设备拔出时自动清理失效 route，不留下空白页面。
- [ ] 保持“仅退出界面”“完全退出”现有语义。
- [ ] 实机连续操作验证：快速移动鼠标、反复进入/返回层级时浮层不能错误关闭。

完成标准：Drive Release build + 实机交互验收 + Drive CI。

## Phase D — Finder 首写延迟精确归因

- [ ] 阅读并标注 Direct MFMount transport 的 FUSE opcode 处理路径。
- [ ] 明确：
  - `FUSE_WRITE`：只负责写入数据；
  - `FUSE_FLUSH`：close-path flush，不应无条件等价于 durability barrier；
  - `FUSE_FSYNC`：需要文件系统要求的同步语义；
  - final unmount/eject/完全退出：必须有最终强 durability barrier。
- [ ] 增加仅测试/诊断用的同步计数与耗时观察方式，不把高频日志带入正式热路径。
- [ ] 在真实挂载文件系统上重复小文件、大文件起写测试，记录首个确定进度出现前的延迟。

完成标准：确认主要等待发生在何种 FUSE 同步请求，而不是猜测 SM4、exFAT 或 USB 带宽。

## Phase E — 分层同步语义修复

设计目标：普通 close/flush 不触发最重的物理 barrier；真正要求 durability 的路径仍保持安全。

预期方向：

- [ ] `FUSE_FLUSH` 不再无条件执行 `F_FULLFSYNC`。
- [ ] `FUSE_FSYNC` 至少保持 `fsync` 语义；是否执行 `F_FULLFSYNC` 依据实际 macOS/FSKit 行为和 A/B 结果决定。
- [ ] 将“普通同步”和“最终强制落盘”拆成不同接口，例如：
  - lightweight sync：`fsync` 或适合 raw device 的常规同步；
  - durability barrier：`fsync + F_FULLFSYNC`。
- [ ] final transport shutdown、unmount、safe eject、完全退出仍执行强 barrier。
- [ ] 不改变加密块映射、sector geometry、key derivation、raw lease 生命周期。

完成标准：Finder 首写明显加快，同时功能/安全回归全绿。

## Phase F — 真实 U 盘 A/B 与安全回归

仅通过挂载文件系统写临时文件：

- [ ] 4 KiB、8 MiB fsync 延迟 A/B。
- [ ] 约 600 MiB 单文件 Finder 复制：观察确定进度条出现时间和平均吞吐。
- [ ] 文件 hash/size 校验后删除测试文件。
- [ ] 多文件复制/删除。
- [ ] 文本编辑原子保存。
- [ ] 交换区卸载/重挂。
- [ ] 保密区卸载/重挂。
- [ ] 安全推出整盘。
- [ ] Service Stop / Start / Restart。
- [ ] App restart，确认不新增管理员/Touch ID 请求。

完成标准：性能改善且无数据损坏、无挂载生命周期回归。

## Phase G — Finder 约 3 秒进度估算机制研究

目标：解释 Finder 为什么复制已开始后仍会持续约 3 秒显示不确定进度，并判断是否能由 EDP Drive 让 Finder 更早直接显示确定百分比。

- [ ] 用真实 EDP ExFAT 与本机纯 ExFAT 对照，分别记录目标文件出现、首个 allocated bytes、Finder UI 首次状态切换时间。
- [ ] 联网检索 Apple 官方文档、Developer 文档、Darwin / Foundation 公开接口及可信工程资料，确认 Finder 文件复制进度来源、NSProgress/copyfile 估算与不确定进度展示机制。
- [ ] 判断约 3 秒窗口是否由 Finder 自身的 ETA/throughput smoothing 或文件系统预扫描决定，而不是 EDP transport 阻塞。
- [ ] 评估可行方案：
  - 是否存在受支持的文件系统/FSKit 属性让 Finder 一开始就知道 totalUnitCount；
  - 是否能通过 Finder 扩展、File Provider、Progress API 或 copy engine 影响系统 Finder 的复制进度；
  - 如果不能，明确“不应通过伪造 I/O/缓存语义来骗 Finder”的边界。
- [ ] 形成诊断结论并写入 docs；如无受支持接口，明确只能优化实际首写/吞吐，不能强制系统 Finder 立即显示百分比。

完成标准：有本机 A/B 数据 + 公开资料依据 + 可执行/不可执行结论。

## Phase H — EDP 元数据格式公开资料研究

目标：联网检索公开存在的 EDP U 盘格式、专利、驱动、逆向/取证资料，与项目实测结构交叉验证，提高对盘上协议的理解，但不以网络资料覆盖真实盘证据。

- [ ] 检索关键词：`EDP U盘`、`EDP加密U盘`、`EDPF`、`LBA11`、`LBA12`、交换区/保密区、相关厂商/控制器、专利及驱动资料。
- [ ] 优先官方文档、专利、厂商资料、学术/取证论文；论坛/博客只作线索。
- [ ] 对照当前已验证结构：LBA4 serial marker、LBA7 `EDPF` layout、LBA11 identity、LBA12 volume table / partition types 1/2/4、密码/key CRC、SM4 logical block mapping。
- [ ] 区分“公开资料直接确认”“从源码/真实盘实测确认”“仍属推断”三类证据。
- [ ] 不因为网络资料修改 media classifier 或 raw 写入逻辑，除非有真实盘 fixture + golden tests 共同证明。
- [ ] 形成独立诊断文档，列出来源、匹配项、冲突项和未知字段。

完成标准：新增一份可引用的 EDP metadata research 文档，并把可靠结论回填 HANDOFF/STATUS。

## Phase I — 提交、CI 与交接

- [ ] UI 修改独立小提交。
- [ ] 同步/复制性能修改独立小提交。
- [ ] 生命周期修复独立小提交。
- [ ] Finder 进度研究与 EDP metadata 研究文档独立提交。
- [ ] 每个提交 push 后检查 exact-head GitHub Actions。
- [ ] 更新 `docs/HANDOFF-2026-08-29.md` 和必要的 Drive STATUS。
- [ ] 工作树最终干净，`main == origin/main`。

## 预期最终结果

- Studio 右 Inspector 与左 Sidebar 同类悬浮毛玻璃，不再有灰色实底。
- Drive 菜单栏恢复清晰多级结构，同时不存在系统级联菜单的 hover 易关闭问题。
- Finder 向交换区/保密区复制大文件时更快进入确定进度状态，避免启动前多轮物理 full-sync；安全卸载和最终落盘语义保持不变。
