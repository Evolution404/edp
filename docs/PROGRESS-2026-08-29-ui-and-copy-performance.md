# EDP UI 与 Finder 复制首写延迟进度追踪

计划：`docs/PLAN-2026-08-29-ui-and-copy-performance.md`
基线 HEAD：`4800231839d10932f1033909838fedfa97e5c935`

## 当前状态

- Phase A：进行中
- Phase B：进行中（Studio Inspector 新材质 WIP 已在工作树）
- Phase C：进行中（Drive 稳定多级 popover WIP 已在工作树）
- Phase D：已完成初步归因，待精确 instrumentation / A/B
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

## 下一步立即执行

1. 完成 Phase A 源代码同步语义表和 UI ratchet 检查。
2. 收口并实机安装 Studio Inspector / Drive 多级 popover，先形成独立 UI commit。
3. 对 `FUSE_FLUSH` / `FUSE_FSYNC` / final shutdown 的调用链建立精确计数和耗时诊断。
4. 设计并实现 lightweight sync 与 final durability barrier 分层。
5. 真实 U 盘做 Finder 复制 A/B、文本保存、卸载/重挂、安全推出回归。
6. 分阶段 push、等 exact-head CI 全绿，实时更新本文件。
