# Finder 复制约 3 秒不确定进度研究

日期：2026-08-29

## 问题

在 Finder 向 EDP 交换区复制文件时，用户可见的复制指示会先处于不确定/来回折返状态，约 3 秒后才切换为更稳定的确定进度。需要回答：

1. 这 3 秒是否由 EDP crypto / macFUSE / USB 写入阻塞造成？
2. 为什么 Finder 要等待约 3 秒？
3. EDP Drive 能否让 Finder 从第一帧就直接显示百分比？

## 本机 A/B 实证

### EDP 交换区：真实 ChatGPT.dmg

源：`~/Downloads/ChatGPT.dmg`，600,747,074 bytes。

- 目标目录项出现：约 0.269 s
- 目标开始分配/实际写入：约 0.885 s
- Finder 工具栏/复制状态首次明显切换：约 2.908 s
- 总复制时间：约 5.369 s
- 源/目标 SHA-256：一致

结论：Finder 仍显示不确定进度时，数据已经开始实际写入；不能把约 3 秒解释成 EDP 尚未启动 I/O。

### 本机纯 ExFAT 对照：完全绕过 EDP

建立本机 SSD 上的临时 8 GiB raw disk image，通过 DiskImages2 发布并由 Apple ExFAT 挂载。此路径没有：

- EDP metadata / crypto
- macFUSE
- physical USB

复制约 6.5 GiB Ubuntu ISO：

- 目标出现：约 0.222 s
- 目标开始分配：约 0.501 s
- Finder UI 首次状态切换：约 2.979 s
- 持续吞吐约 524.56 MB/s

### 同一 6.5 GiB ISO -> EDP 交换区

- Finder UI 首次状态切换：约 3.296 s
- 总时间约 70.211 s
- 持续吞吐约 92.85 MB/s
- SHA-256：一致

纯本机 ExFAT 约 2.98 s，EDP ExFAT 约 3.30 s。两者非常接近，而底层吞吐相差数倍，因此“约 3 秒”主要属于 Finder/文件复制 UI 的展示策略，而不是 EDP transport 的数据启动延迟。

## Apple 公开 API 能确认什么

### Foundation Progress / NSProgress

Apple 文档说明：

- `Progress.isIndeterminate` 在无法给出合理的 `completedUnitCount` / `totalUnitCount` 时为 true；若两者均为 0，也属于 indeterminate。
- 对 `Progress.Kind.file`，`totalUnitCount` / `completedUnitCount` 的单位是 bytes。
- `fractionCompleted` 由上述计数计算，可用于确定进度 UI。
- `throughput` 和 `estimatedTimeRemaining` 是可选信息，可以参与本地化进度描述。

公开文档：

- https://developer.apple.com/documentation/foundation/progress/isindeterminate
- https://developer.apple.com/documentation/foundation/progress/totalunitcount
- https://developer.apple.com/documentation/foundation/progress/completedunitcount
- https://developer.apple.com/documentation/foundation/progress
- https://developer.apple.com/documentation/foundation/nsprogress/throughput
- https://developer.apple.com/documentation/foundation/nsprogress/estimatedtimeremaining

这些 API 解释了“什么时候一个 Progress 可以是 determinate”，但 Apple 没有公开 Finder 内部把复制 UI 从 indeterminate 切换到 determinate 的固定时间阈值，也没有文档写明“3 秒”。

## 为什么约 3 秒

### 可以直接确认的部分

1. 不是等待第一笔真实数据写入：EDP 目标 0.27 s 出现，0.89 s 已写入。
2. 不是 EDP/macFUSE 特有：本机纯 ExFAT 对照仍约 2.98 s。
3. Finder 自己拥有本次文件复制操作及其 Progress/UI；EDP 只提供一个正常挂载的本地块设备/文件系统目标。

### 最合理但仍属于推断的部分

Finder 很可能在复制开始后的短窗口内进行一组 preflight / progress stabilization 工作，例如：

- 计算/确认总工作量与目录项；
- 获取目标空间和文件系统能力；
- 完成 metadata / xattr 初始化；
- 获取若干实际吞吐采样，再给出较稳定的 speed / ETA；
- 避免一个很短的操作闪现不稳定百分比/ETA。

Apple 的 `Progress` API确实把 total/completed bytes、throughput、estimated time 作为不同维度暴露，这与这种实现方式相容；但 Finder 的具体采样窗口和约 3 秒阈值是私有实现，当前没有公开依据可以断言其算法。

因此文档和代码中应使用：

> “受控 A/B 表明 Finder 对 ExFAT 本地卷本身存在约 3 秒的进度展示稳定窗口；其内部算法未公开。”

而不是写成“Finder 官方规定等待 3 秒”。

## 能否让系统 Finder 立即显示百分比

### 对当前架构：没有找到受支持的接口

EDP Drive 当前向系统提供正常的本地 ExFAT 卷：

`Finder -> Apple ExFAT FSKit -> DiskImages2 -> macFUSE Local -> EDP block translator`

我们没有找到 FSKit、Disk Arbitration、mount option 或普通本地文件系统属性，可以向 Finder 注入/覆盖 Finder 自己复制任务的 `totalUnitCount`、`completedUnitCount`、throughput 或 ETA。

### Finder Sync 不解决这个问题

Apple Finder Sync 文档只提供：

- monitored folder
- badges / labels
- contextual menu
- toolbar button

而且 Apple 明确说明 Finder Sync 不负责实际同步/文件传输。因此它可以额外显示 EDP 状态，但没有 API 替换 Finder 内置 copy progress。

公开文档：

- https://developer.apple.com/documentation/FinderSync
- https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html

### File Provider 不适合当前产品

File Provider 的 `globalProgress(for:)` 可以报告 provider 自己的 upload/download bytes，但这是远端/同步文件提供器模型。EDP 是真实本地块设备 + Apple 文件系统；为了一个进度条把它改造成 File Provider 会破坏当前原生磁盘语义、可移动卷语义和产品架构，不应采用。

公开文档：

- https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/globalprogress(for:)

## 真正可行的“第一帧确定进度”方案

只有在 **EDP Drive 自己成为复制操作的 owner** 时，我们才能完全控制进度：

1. 拖放/菜单动作交给 EDP 自己的 copy engine；
2. 开始前读取源文件大小，立即设置 `Progress(totalUnitCount: sourceBytes)`；
3. 按实际完成字节更新 `completedUnitCount`；
4. EDP 自己显示 determinate progress UI。

这能做到第一帧就知道总字节数，但它不再是 Finder 原生复制操作，属于新增复制产品功能，当前没有必要为了约 3 秒视觉窗口引入。

## 产品结论

- 不再把“约 3 秒不确定进度”列为 EDP I/O 性能 bug。
- 保留实际性能优化：首写、fsync、持续吞吐、生命周期仍需优化。
- 不伪造块设备 I/O、缓存完成状态、文件大小、fsync 成功语义来“骗 Finder”提前显示百分比。
- 当前最佳体验仍是让系统 Finder 保持原生复制流程；约 3 秒 UI 稳定窗口接受为 Finder/ExFAT 行为。
- 如果未来产品明确要求“即时百分比”，应新增 EDP-owned copy UX，而不是侵入/劫持 Finder Progress。
