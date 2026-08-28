# EDPOpen

cems 加密 U 盘分析与免密改造的桌面工具（Tauri 2：Rust 后端 + WebView 前端）。

> EDP = 目标盘的加密分区格式（EDPF），Open = 解开 / 开放。

## 功能

- **盘识别**：USB 外置盘枚举、device_id 自动识别、盘状态判定（标准加密盘 / 免密盘 / 已改造）
- **盘地图**：全盘区域色块缩略 + LBA0-13 元数据区方格网格，字段分类着色，悬停显示含义，点击跳转扇区
- **扇区浏览器**：任意 LBA hexdump，字段级着色 + hover 释义，raw / 解密视图切换
- **字节级编辑器**：任意字节修改；加密区在明文视图编辑，保存时按对应算法重新加密（含 LBA6 校验和重算）
- **免密改造**：预览 → 管理员授权写入（自动备份 → 写 5 扇 → 回读校验）
- **备份管理**：按盘身份（labelOnlyId 终验）匹配、MD5 校验还原
- **离线模式**：拖入备份 / 镜像文件全流程分析，不插盘

## 架构

```
src/            前端(原生 JS, 无框架)
src-tauri/src/  Rust 后端
  crypto.rs     crc32_bare / AES-128 变体(A6B0/a7f0) / 滚动 XOR / LBA6 校验和
  parser.rs     LBA4/6/7/8/9/11/12 解析 + EDPF entry + ELABEL(GBK) + MBR
  disk.rs       盘枚举(diskutil) / device_id 两候选识别 / 扇区读写
  convert.rs    免密改造 5 扇生成 / 备份还原
  commands.rs   Tauri 命令门面
```

macOS 下读盘无需提权（热插拔盘设备节点 owner=当前用户）；写盘通过
`osascript` 管理员授权拉起本程序 `--write-sectors` 子命令（先备份 →
按序写入 → 回读校验）。

## 参照与对拍基准

算法与流程移植自 Python 版工具（另行保存），测试向量取自真实盘的
LBA0-13 备份，Rust 与 Python 输出逐字节对拍。

## 状态

规划完成，开发中。功能计划与测试策略见开发文档。
