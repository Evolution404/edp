# EDP UI 与 Finder 复制首写延迟进度追踪

计划：`docs/PLAN-2026-08-29-ui-and-copy-performance.md`
基线 HEAD：`4800231839d10932f1033909838fedfa97e5c935`

## 当前状态

- Phase A：完成
- Phase B：代码完成，已本地 Release build/安装，待用户视觉验收
- Phase C：代码完成，已 Swift 6 `-warnings-as-errors` 编译，待本地安装交互验收
- Phase D：完成调用链归因与真实 fsync 延迟基线；当前继续补 A/B 观测
- Phase E：进行中，已完成 lightweight sync / final durability barrier 第一版代码，待编译与真实盘验证
- Phase F：未开始
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
- 当前这些性能修改尚未提交；下一步先跑完整 Drive 本地编译 gate，再形成独立性能 commit。真实盘 A/B 需要把候选 runtime 安装到受保护的 `/Library/Application Support/EDP Drive/bin` 后进行。

## 下一步立即执行

1. 跑 native-core golden、Swift 6 `-warnings-as-errors`、macFUSE Local transport build，修正任何同步接口回归。
2. 给 FLUSH / FSYNC / final durability 增加低噪声计数/耗时观测，确认 Finder 首写阶段实际请求分布。
3. 安装性能候选版并用当前 Lexar 真实交换区做相同 fsync probe 和约 600 MB Finder 复制 A/B。
4. 回归 TextEdit 原子保存、多文件复制删除、交换区/保密区卸载重挂、安全推出、Service Stop/Start/Restart。
5. 性能修复独立 commit + push，检查 exact-head Drive CI，并实时更新本文件/HANDOFF。
