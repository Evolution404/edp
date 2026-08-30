# EDP Drive UI 全量重设计计划（2026-08-30）

## 1. 目标

在**不改变已经验收通过的原生侧栏动画架构、不削弱任何现有功能、不改动 raw-device / XPC / mount / credential 语义**的前提下，对 EDP Drive 主窗口和菜单栏下拉窗口做一次完整的信息架构与视觉重设计。

本计划的视觉方向已经由用户审核通过：

- macOS 26 原生感；
- Liquid Glass 作为层级材料，而不是满屏玻璃卡片；
- 高级、克制、专业，接近 Apple 自己做的磁盘/安全工具；
- 浅色界面为主要验收基准，同时必须完整支持 Dark Mode；
- 侧栏一级功能避免重复，不再把“挂载”“安全”分别做一级导航；
- 菜单栏下拉是 Mini Control Center，承担 80% 高频操作；
- 设备详情直接展示新的五因素身份中的关键字段：VID/PID、LBA4 onlyId、整盘容量、LBA11 deviceId。

本计划是 UI 实现的**文字版设计规范和验收源**。即使聊天中的效果图不可访问，也必须能够完全按照本文恢复设计。

---

## 2. 绝对不可回退的技术基线

实施 UI 时必须保留以下已经通过实机与 Instruments 验证的结构。

### 2.1 原生 split container

当前主容器必须继续使用：

```text
EDPMainView
  -> EDPNativeSplitView (NSViewControllerRepresentable)
  -> EDPNativeSplitViewController : NSSplitViewController
     -> sidebar NSHostingController<EDPNativeSidebarView>
     -> detail  NSHostingController<EDPNativeDetailView>
```

关键配置：

```swift
minimumThicknessForInlineSidebars = 0
sidebarItem.minimumThickness = 180
sidebarItem.maximumThickness = 220
sidebarItem.canCollapse = true
sidebarItem.canCollapseFromWindowResize = false
sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
```

不得重新改回：

- `NavigationSplitView` 作为主容器；
- 自绘 overlay sidebar；
- `.prominentDetail`；
- 自定义 `columnVisibility + withAnimation` 侧栏开合；
- toolbar priority hack；
- 通过放大最小窗口宽度规避问题。

原因：SwiftUI `NavigationSplitView` 在 macOS 26 的展开几何会出现主内容先位移再回弹；系统 sidebar toolbar 还可能出现 `»`。当前 `NSSplitViewController` 版本已经验证：900px 窗口下 sidebar 与 detail 单调同步变化，无 overshoot、无回弹、无 overflow。

### 2.2 sidebar toggle

保留当前 toolbar 里的自定义 toggle：

- 动作调用 `EDPNativeSplitBridge.toggleSidebar()`；
- 最终由 `NSSplitViewController.toggleSidebar(nil)` 执行；
- `.focusEffectDisabled()` 必须保留，防止点击后出现蓝色 focus ring；
- 不得重新启用 SwiftUI 自动 sidebar toggle。

### 2.3 最小窗口

主窗口继续支持约：

```text
minWidth = 900
minHeight = 620
```

验收必须在 **900×680** 进行，不能只在宽窗口看起来正常。

---

## 3. 设计语言

### 3.1 Liquid Glass 使用原则

Glass 只用于：

- 原生 sidebar；
- toolbar / floating control；
- compact status pill；
- 菜单栏 Mini Control Center；
- 少量关键操作区；
- 必要的 hero / identity surface。

不要用于：

- 每一条活动记录；
- 每一行设备属性；
- 每一个设置 section；
- 每一个分区都套多层玻璃；
- 大面积高饱和彩色背景。

目标：**玻璃负责空间层级，留白负责内容层级。**

### 3.2 色彩

- 使用系统动态色与 `EDPDesignSystem` 语义颜色；
- 绿色只表示成功/已连接/已就绪；
- 蓝色只表示当前选中、主要动作、活动中的系统状态；
- 红色仅用于 destructive/error；
- 紫色可用于保密区，但必须低饱和；
- 禁止硬编码纯白/纯黑作为主要 surface；
- Dark Mode 必须自动适配。

### 3.3 形态

- 大容器圆角：约 18–24；
- 紧凑 row/container：约 10–14；
- 状态 pill：胶囊；
- 阴影非常轻；
- divider 比卡片边框更常用；
- 页面要有明显留白，不堆密集表单。

### 3.4 动画

- sidebar 动画完全交给原生 AppKit；
- 页面切换只允许短淡入/淡出（约 120–160ms）；
- 数值可使用 `contentTransition(.numericText())`；
- 不使用 `.bounce` 作为常态反馈；
- 不使用裸 `withAnimation {}` 驱动 sidebar；
- Reduce Motion 时所有非必要运动降级为淡入淡出；
- Reduce Transparency 时 glass surface 使用语义实色背景。

---

## 4. 一级信息架构

侧栏最终只有 4 个一级模块：

```text
总览
设备
活动
设置
```

不得增加一级“挂载”“安全”，因为它们与“设备”重复。

推荐图标：

```text
总览  square.grid.2x2
设备  externaldrive
活动  waveform.path.ecg / clock.arrow.circlepath
设置  gearshape
```

默认打开：**总览**。

---

## 5. 总览页设计

### 5.1 页面目的

总览只回答：

1. 当前有什么设备？
2. 是否健康？
3. 最常用操作是什么？

不要把所有管理功能复制进总览。

### 5.2 Device Hero

顶部是一块克制的 hero：

```text
[EDP Drive 图标/设备图]
EDP 工作盘           ● 已连接
Lexar USB Flash Drive
124.74 GB · USB · 21c4:0cd1
```

右侧可放刷新。

设备未连接时使用灰色状态，不用红色报警。

### 5.3 系统状态横排

4 个紧凑 status cells：

- 后台服务：运行中 / 已停止 / 需批准；
- 磁盘访问：已授权 / 需授权；
- macFUSE Local：已就绪 / 需安装；
- 自动挂载：已开启 / 已暂停。

全部正常时保持低饱和，不要形成四块大绿卡。

### 5.4 分区结构图

中部为横向磁盘结构条：

```text
启动区 | 交换区 | 保密区
```

每段显示：

- 名称；
- 容量（若当前 snapshot 可取得；未取得则显示文件系统/状态，不得伪造容量）；
- FAT16 / ExFAT / 加密等；
- 已挂载 / 未挂载 / 只读。

当前数据模型若还没有每分区 size，不要为了效果图硬编码假数据。可先按等宽/语义比例展示，后续测试/模型允许时再接真实 geometry。

### 5.5 快捷操作

只保留高频动作：

- 在 Finder 中显示（有已挂载可显示分区时）；
- 挂载全部（只处理可挂载且凭据可用的分区）；
- 安全推出整盘。

不要把密码、服务重启、删除设备等放在总览。

### 5.6 最近活动

显示最近 3–5 条：

- 交换区已挂载；
- 设备已识别；
- 后台服务已启动；
- 错误事件。

有“查看全部”进入活动页。

---

## 6. 设备页设计

设备页是“管理当前物理 U 盘”的工作中心。

### 6.1 顶部 identity header

显示：

```text
EDP 工作盘                 ● 已连接
Lexar USB Flash Drive
124.74 GB · 21c4:0cd1
```

右侧：

- 安全推出整盘；
- 必要时 `…` 放低频 destructive action。

设备名称仍可编辑，功能不能丢。

### 6.2 子导航

内容区顶部使用 segmented control：

```text
概览 | 分区 | 安全
```

这不是一级 sidebar。

---

## 7. 设备 / 概览

展示真正的设备身份和物理信息。

必须包括：

- 设备名称；
- Media Name；
- VID/PID；
- **LBA4 onlyId**；
- **LBA11 deviceId (`metadataDeviceID`)**；
- Drive 内部稳定 `deviceID`（可放高级/可复制区域）；
- 整盘容量；
- 当前 BSD 名（如 `disk6`，明确只是当前动态名称）；
- 分区数；
- 连接状态；
- Raw/FDA readiness。

### 7.1 五因素身份说明

UI 文案不要让用户误以为 `diskN` 是稳定身份。

建议在高级信息里说明：

```text
设备身份由 VID、PID、LBA4 onlyId、整盘容量和 LBA11 deviceId 共同确定。
```

### 7.2 操作

- 安全推出整盘；
- 未连接历史设备：删除设备记录；
- destructive action 要有确认。

---

## 8. 设备 / 分区

这是原“分区卡片”功能的重新组织。

### 8.1 结构

页面标题：

```text
分区
2 / 3 已挂载
```

右侧：

```text
挂载全部 | 卸载全部（如果产品当前没有批量 API，可由 UI 串行调用现有 API，必须失败可见）
```

### 8.2 分区行

每个分区一个紧凑 panel，而不是巨大表单卡：

```text
[icon] 启动区
       普通启动分区
       FAT16 · 16 MB · 只读

自动挂载 [switch]        Finder   卸载   …
```

交换区：

```text
[icon] 交换区
       受控交换区
       ExFAT · 已挂载
       密码状态：已保存

自动挂载 [switch]        Finder   卸载   …
```

保密区同理。

### 8.3 功能必须保留

- type 1 启动区无密码；
- type 2/4 独立密码；
- 每分区自动挂载；
- 设置/更新密码；
- 删除密码；
- 挂载；
- 卸载；
- Finder；
- filesystem/readOnly 状态；
- lastError inline 展示；
- 挂载按钮在凭据缺失时正确禁用；
- “可用 Finder 抹掉为 ExFAT”的说明如仍适用，放到 `…` / info secondary text，不占主视觉。

---

## 9. 设备 / 安全

这里只管理**当前设备的凭据**，以及与当前设备直接相关的安全状态。

### 9.1 分区凭据

两行：

```text
交换区密码   已保存   最近验证 …   更新   删除
保密区密码   已保存   最近验证 …   更新   删除
```

如果模型没有“最近验证时间”，不要伪造；可省略。

### 9.2 全局权限状态

页面下方可只读显示：

- 完全磁盘访问；
- Raw Access；
- macFUSE Local。

真正的修复操作跳转到设置页“系统集成”，避免在两个页面维护两套开关。

---

## 10. 活动页

改为时间线/日志流，不再每条一张大卡。

### 10.1 顶部过滤

```text
全部 | 设备 | 挂载 | 安全 | 错误
```

过滤是内容筛选，不是导航。

### 10.2 时间线

每条包括：

- 时间；
- 语义图标/状态点；
- 主消息；
- 设备/分区辅助信息；
- 错误时红橙低饱和。

禁止对每条活动使用 `.symbolEffect(.bounce)`。

### 10.3 数据边界

当前 runtime 最多保留 200 条活动；UI 只展示已有数据，不擅自改变持久化语义。

---

## 11. 设置页

设置只管理**全局环境**，不再混入单个 U 盘密码。

### 11.1 常规

- 全局自动挂载；
- 登录时启动 EDP Drive。

### 11.2 系统集成

- 完全磁盘访问；
- Raw Access readiness；
- macFUSE Local；
- “打开系统设置”；
- “重新检测权限”；
- 需要时“显示组件”。

### 11.3 后台服务

- 状态；
- 版本；
- 启动；
- 停止；
- 重启；
- 需要系统批准时打开设置。

### 11.4 高级

- 查看诊断；
- 复制诊断；
- 版本/构建信息；
- 其他真正低频设置。

设置页应使用 macOS Settings 风格 grouped rows，避免默认 `Form` 产生开发工具感。

---

## 12. Toolbar

主窗口 toolbar 保持轻量。

### 12.1 左侧

- sidebar toggle（现有原生桥）；

### 12.2 中间/右侧动态内容

总览/设备：

- 当前设备 identity pill；
- 设备 Picker；
- 刷新。

活动/设置：

- 不强制显示设备 Picker；
- 只显示页面真正需要的动作。

### 12.3 禁止

- toolbar item 过多导致 `»`；
- 通过 visibilityPriority 私有/脆弱 hack 解决；
- 恢复 SwiftUI 自动 sidebar toggle。

---

## 13. 菜单栏 Mini Control Center

保持：

```swift
.menuBarExtraStyle(.window)
```

不要改回 `.menu` 或级联 AppKit Menu。

推荐宽度约 380–400px，当前 390px 可作为基线。

### 13.1 Header

```text
EDP Drive      ● 后台服务运行中       [打开主窗口]
```

### 13.2 当前设备 compact card

```text
EDP 工作盘
124.74 GB · 已连接
```

设备可多台时，按设备分组滚动。

### 13.3 三个分区 compact rows

启动区：

```text
启动区  FAT16 · 只读           Finder  卸载
```

交换区：

```text
交换区  ExFAT · 已挂载         Finder  卸载
```

保密区：

```text
保密区  未挂载                         挂载
```

凭据缺失时明确显示“请先在主界面保存密码”，挂载禁用。

### 13.4 全局自动挂载

单独一行 toggle。

### 13.5 后台服务

紧凑按钮：

```text
启动 | 停止 | 重启
```

### 13.6 Footer

保留已经确认的文字：

```text
刷新   仅退出界面   完全退出
```

不得重新加括号解释。

“完全退出”必须继续先通过 product XPC graceful stop service，再退出 UI。

---

## 14. 全功能映射检查表

重构完成前，必须逐项证明以下旧功能没有丢失：

- [ ] 设备列表/设备切换；
- [ ] 设备名称修改；
- [ ] 当前动态 BSD 名显示；
- [ ] VID/PID；
- [ ] LBA4 onlyId；
- [ ] LBA11 metadataDeviceID；
- [ ] 整盘容量；
- [ ] FDA notice；
- [ ] 打开 FDA 设置；
- [ ] 显示组件；
- [ ] 重新检测 Raw Access；
- [ ] type 1/2/4 自动挂载；
- [ ] type 2/4 保存/更新密码；
- [ ] type 2/4 删除密码；
- [ ] 分区挂载；
- [ ] 分区卸载；
- [ ] Finder 显示；
- [ ] filesystem / readOnly / lastError；
- [ ] 整盘安全推出；
- [ ] 删除离线设备记录；
- [ ] 活动日志；
- [ ] 全局自动挂载；
- [ ] 登录时启动；
- [ ] service start/stop/restart；
- [ ] macFUSE Local readiness；
- [ ] diagnostics；
- [ ] 菜单栏打开主窗口；
- [ ] 菜单栏分区操作；
- [ ] 菜单栏刷新；
- [ ] 仅退出界面；
- [ ] 完全退出。

---

## 15. 实施阶段

### Phase UI-A — 信息架构骨架

- 一级 sidebar 改为 4 项；
- 新增总览；
- 设备页 segmented control；
- 保持 native split controller 原样；
- 保证编译绿。

提交建议：

```text
feat(drive): establish redesigned information architecture
```

### Phase UI-B — 总览页

- hero；
- 4 状态；
- 分区结构；
- 快捷操作；
- 最近活动。

### Phase UI-C — 设备三子页

- 概览；
- 分区；
- 安全；
- 接入 onlyId / metadataDeviceID。

### Phase UI-D — 活动 + 设置

- timeline；
- filters；
- grouped settings；
- diagnostics。

### Phase UI-E — 菜单栏 Control Center

- header；
- device/partition compact rows；
- auto-mount；
- service；
- footer。

### Phase UI-F — Accessibility / Dark / performance

- Light/Dark；
- Reduce Motion；
- Reduce Transparency；
- Increased Contrast；
- keyboard/focus；
- VoiceOver labels；
- 900px window；
- Instruments。

### Phase UI-G — CI ratchet 与最终验收

更新 `.github/workflows/drive.yml`，但不要用脆弱的“某一句 UI 文本必须存在”作为主要验收。CI 应优先验证：

- native split controller 仍存在；
- 不出现 `NavigationSplitView` 主容器；
- `.menuBarExtraStyle(.window)`；
- 4 个一级 section；
- onlyId / metadataDeviceID 有 UI；
- Swift 6 warnings-as-errors；
- preview UI smoke。

---

## 16. UI 自动化 preview 场景

必须扩展 `EDP_UI_PREVIEW`，至少可构造：

1. `healthy-one-device`：一台连接、2/3 mounted；
2. `no-device`；
3. `two-devices`；
4. `fda-required`；
5. `service-stopped`；
6. `credential-missing`；
7. `partition-error`；
8. `all-mounted`；
9. `offline-saved-device`。

推荐通过测试目标/编译参数注入，不要给正式生产二进制增加隐蔽环境后门。

---

## 17. UI 验收标准

只有全部满足才算 UI 重构完成。

### 17.1 结构

- [ ] sidebar 只有“总览 / 设备 / 活动 / 设置”；
- [ ] 默认进入总览；
- [ ] “挂载/安全”不作为一级导航；
- [ ] 设备页内部是“概览 / 分区 / 安全”；
- [ ] 菜单栏是 Mini Control Center，而不是级联菜单。

### 17.2 原生侧栏回归

在 900×680：

- [ ] 连续打开/关闭 sidebar 20 次不出现 `»`；
- [ ] 主内容只随 sidebar 单调压缩/恢复；
- [ ] 无“先右移再反弹”；
- [ ] sidebar toggle 无蓝色 focus ring；
- [ ] toolbar 不发生可见跳位。

### 17.3 Instruments

使用 Xcode 26.6：

- [ ] `Animation Hitches` 录制至少 6 次 sidebar toggle，`hitches = 0`；
- [ ] 不存在明显 Long View Body Update；
- [ ] 主要页面滚动无持续 hitch；
- [ ] 菜单栏展开/折叠无持续 hitch。

### 17.4 功能

“全功能映射检查表”全部通过。

### 17.5 视觉

用户人工审核：

- [ ] 总览；
- [ ] 设备/概览；
- [ ] 设备/分区；
- [ ] 设备/安全；
- [ ] 活动；
- [ ] 设置；
- [ ] 菜单栏。

必须在 Light 和 Dark 各验一次。

### 17.6 编译/CI

- [ ] Swift 6 `-warnings-as-errors`；
- [ ] `git diff --check`；
- [ ] Drive CI exact HEAD 全绿；
- [ ] 不改变 raw-device / credential / XPC / mount 核心语义。

---

## 18. 不做的事情

本 UI 任务禁止顺手做：

- 修改 EDP 密码算法；
- 修改 SM4 block translation；
- 修改介质分类；
- 修改五因素身份；
- 修改 installer / FDA 模型；
- 替换 macFUSE Local；
- 引入 Tauri/WebView；
- 把 sidebar 动画重新交回 SwiftUI NavigationSplitView；
- 为了视觉效果删除现有功能。

这些若确有必要，必须另开独立阶段和提交。
