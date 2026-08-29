# EDP UI 与 Finder 复制首写延迟进度追踪

计划：`docs/PLAN-2026-08-29-ui-and-copy-performance.md`
基线 HEAD：`4800231839d10932f1033909838fedfa97e5c935`

## 当前状态

- Phase A：完成
- Phase B：代码完成，已本地 Release build/安装，待用户视觉验收
- Phase C：代码完成，已 Swift 6 `-warnings-as-errors` 编译，待本地安装交互验收
- Phase D：进行中，已完成调用链归因，下一步加精确 instrumentation / A/B
- Phase E：未开始
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

## 下一步立即执行

1. 形成并 push 独立 UI commit，检查 Drive/Studio exact-head CI。
2. 对 `FUSE_FLUSH` / `FUSE_FSYNC` / final shutdown 的调用链建立精确计数和耗时诊断。
3. 实现 lightweight sync 与 final durability barrier 分层。
4. 设计并实现 lightweight sync 与 final durability barrier 分层。
5. 真实 U 盘做 Finder 复制 A/B、文本保存、卸载/重挂、安全推出回归。
6. 分阶段 push、等 exact-head CI 全绿，实时更新本文件。
