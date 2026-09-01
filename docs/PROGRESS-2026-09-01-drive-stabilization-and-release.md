# EDP Drive 稳定化、结构收口与发布准备 — 实时进度

日期：2026-09-01
分支：`codex/ui-macos26-liquid-glass`
计划：`docs/PLAN-2026-09-01-drive-stabilization-and-release.md`
计划基线：`3463295b1e6f86a315075732543ef3f53c510d18`

> 只记录实际完成并有证据的结果。未执行、无最终 marker、缺少真实介质的项目保持 TODO/BLOCKED，不得伪记 PASS。

## 总览

| Phase | 内容 | 状态 |
|---|---|---|
| A | Sidebar 33 ms 性能收口 | IN PROGRESS |
| B | Runtime 职责拆分 | TODO |
| C | App/UI 文件职责拆分 | TODO |
| D | 发布可靠性与 recovery 可观测性 | TODO |
| E | 文档、测试矩阵、Release Checklist 收口 | TODO |
| F | NTFS RW 产品/架构 ADR | TODO |

## 当前不可回退基线

- [x] 标准 EDP 五因素身份保持：VID/PID/LBA4 onlyId/capacity/LBA11 metadataDeviceID。
- [x] single-App FDA；不授予 service 单独 FDA。
- [x] EBUSY exact-generation force-whole + single raw retry 已由 S31-S35 锁定。
- [x] physical eject generation hardening / duplicate eject single-flight / shutdown ordering 已锁定。
- [x] 真实 SanDisk type1 FAT16 RO、type2/type4 Apple NTFS RO capability-aware 验收完成。
- [x] 产品 XPC safe eject 实机 PASS，BadArgument 未复现。
- [x] safe eject 终态 EDP mount/backing/transport residue=0，Finder/UVFS/service 无 U-state。
- [x] fresh physical replug retained raw access PASS，type2/type4 credential persistence PASS。
- [x] 当前分支起点 clean 且 `HEAD == origin/codex/ui-macos26-liquid-glass == 3463295b1e6f86a315075732543ef3f53c510d18`。

## Phase A — Sidebar 33 ms 性能收口

状态：IN PROGRESS

### A1 基线

- [x] exact-head 复跑 `make drive-test-ui`。
- [x] preview scenarios PASS。
- [x] page rendering PASS。
- [x] 900×680 sidebar 20 toggles geometry PASS。
- [x] accessibility structure PASS。
- [ ] Animation Hitches gate PASS。

2026-09-01 19:29 基线：

```text
UI_HITCH_FRAME_COUNT=27
UI_HITCH_MAX_MS=41.666
UI_HITCH_COUNT_GT33MS=1
```

此前同一代码已出现 `66.666ms / 2 frames >33ms`，因此记录为波动型性能缺陷，不按固定冷启动单帧处理。

### A2 定位

- [ ] 审查现有 hitch-only runner / trace window / automation toggle timing。
- [ ] 增加或复用 signpost/epoch，把 toggle 与主线程 layout/render hotspot 对齐。
- [ ] 导出 Time Profiler / Animation Hitches 相关数据，定位 >33ms 帧归因。
- [ ] 验证 `NSHostingController` live-resize invalidation。
- [ ] 验证 backdrop/glass material 合成开销。
- [ ] 验证 snapshot/@ObservedObject refresh 与 sidebar animation 是否重叠。
- [ ] 验证多重 implicit animation / hover / selection 是否叠加。

### A3 修复与验收

- [ ] 根因修复，不降低 33 ms 门槛。
- [ ] `make drive-test-ui` 连续 #1 PASS。
- [ ] `make drive-test-ui` 连续 #2 PASS。
- [ ] `make drive-test-ui` 连续 #3 PASS。
- [ ] `make drive-test-fast` PASS。
- [ ] `make drive-test-system` PASS。
- [ ] `git diff --check` PASS。
- [ ] Phase A commit/push。

## Phase B — Runtime 职责拆分

状态：TODO

- [ ] 抽纯 model/key/helper。
- [ ] 抽 `EDPRawAccessController` 或等价模块。
- [ ] 抽 auto-mount policy/manual suppression。
- [ ] 抽 eject/shutdown orchestration。
- [ ] 抽 recovery orchestration。
- [ ] 收窄 service-facing controller。
- [ ] 每步 S01-S35/property/fast/system/virtual 不回退。
- [ ] Phase B storage smoke PASS。
- [ ] Phase B commits/push。

## Phase C — App/UI 文件职责拆分

状态：TODO

- [ ] App shell / native split controller 独立文件。
- [ ] ViewModel 独立文件。
- [ ] Sidebar 独立文件。
- [ ] Overview / Devices / Activity / Settings 页面拆分。
- [ ] Menu bar / Service controls 拆分。
- [ ] CLI smoke/UI automation helper 与页面实现边界清晰。
- [ ] Liquid Glass、菜单层级、仅退出界面/完全退出语义不变。
- [ ] UI gate 保持连续 PASS。
- [ ] Phase C commits/push。

## Phase D — 发布可靠性与 recovery 可观测性

状态：TODO

### D1 Counters

- [ ] `rawBusyRecoveryCount`
- [ ] `forcedWholeUnmountCount`
- [ ] `fskitAgentRecoveryCount`
- [ ] `diskImagesAttachRecoveryCount`
- [ ] `diskImagesDetachRecoveryCount`
- [ ] `mountRetryCount`
- [ ] `ejectAlreadyAbsentSuccessCount`
- [ ] diagnostics redaction/system ratchet/tests。

### D2 外部/私有依赖

- [ ] `hdiutil` 正常路径/recovery 路径分类。
- [ ] Private DiskImages2 helper 边界复核。
- [ ] `pluginkit` 使用边界复核。
- [ ] agent reset 只允许明确 recovery 条件，保持 global FSKit fail-closed。

### D3 物理发布矩阵

- [ ] ordinary USB physical negative — BLOCKED until fixture available。
- [ ] legacyNoPassword physical negative — BLOCKED until fixture available。
- [ ] currentNoPassword physical negative — BLOCKED until fixture available。
- [ ] unrecognizedEDP physical negative — BLOCKED until fixture available。
- [x] standardEncrypted SanDisk positive/capability/safe-eject/replug 已完成一轮最终收口。

### D4 Exact-head reboot

- [ ] exact-head Clean.pkg build/verify。
- [ ] install。
- [ ] reboot。
- [ ] single-App FDA retained access。
- [ ] policy/credential persistence。
- [ ] safe eject residue/U-state=0。

## Phase E — 文档、测试矩阵与 Release Checklist

状态：TODO

- [ ] 重写 `Apps/Drive/docs/STATUS.md` 为当前事实真源。
- [ ] 新建 `Apps/Drive/docs/ARCHITECTURE.md`。
- [ ] 新建 `Apps/Drive/docs/TESTING.md`。
- [ ] 新建 `Apps/Drive/docs/RELEASE-CHECKLIST.md`。
- [ ] 标记/归档失效 handoff/tracker 入口。
- [ ] 清理旧 tracker 中已实现但仍 `[ ]` 的假技术债。
- [ ] 文档与 Makefile/CI targets 一致。

## Phase F — NTFS RW ADR

状态：TODO

- [ ] 收集真实介质 RW 需求。
- [ ] 明确 Apple native NTFS RO 是否可接受。
- [ ] 如不可接受，研究独立 NTFS RW provider 约束，不恢复 ntfs-3g 旧路径。
- [ ] 输出 ADR：A native RO / B 独立 RW provider / C 介质格式规范化。
- [ ] 若选择 B，另建独立实施计划，本计划不直接实现。

## 变更日志

### 2026-09-01 19:29 — Plan baseline and UI performance failure reproduced

- fetch 后确认 `HEAD == origin/codex/ui-macos26-liquid-glass == 3463295b1e6f86a315075732543ef3f53c510d18`，工作树 clean。
- 新计划以真实盘最终收口结果为不可回退基线，不重复 FDA、DADiskClaim、普通 unmount 等已排除实验。
- exact-head `make drive-test-ui`：preview/page/geometry/accessibility 全 PASS；Animation Hitches 失败：27 sampled frames，max 41.666 ms，1 frame >33 ms。
- 该结果与此前同 HEAD 66.666 ms / 2 frames 的失败共同证明 sidebar hitch 具有波动性；Phase A 从 trace attribution 开始，不调整门槛。
