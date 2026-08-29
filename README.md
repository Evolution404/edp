# EDPOpen

cems 加密 U 盘分析与免密改造的桌面工具（Tauri 2：Rust 后端 + WebView 前端）。

> EDP = 目标盘的加密分区格式（EDPF），Open = 解开 / 开放。

## 功能

- **盘识别**：USB 外置盘枚举、device_id 自动识别、盘状态判定（标准加密盘 / 免密盘 / 已改造）
- **盘地图**：全盘区域色块缩略 + LBA0-13 元数据区方格网格，字段分类着色，悬停显示含义，点击跳转扇区
- **扇区浏览器**：任意 LBA hexdump，字段级着色 + hover 释义，raw / 解密视图切换
- **字节级编辑器**：点击字节修改、diff/撤销、重加密预览、raw 导出、敏感区警告；LBA4/6/7/8/9/11/12 在明文视图编辑后由 Rust 重加密，保存前做 expected-raw 防竞态、整盘身份复核、自动备份与回读；支持 Encrypted/NoPwd 编辑，禁止保存会改变 LBA4 labelOnlyId 的编辑
- **免密改造**：预览 → 管理员授权写入（自动备份 → 写 5 扇 → 回读校验）
- **备份管理**：7168B/MD5 校验、LBA4 labelOnlyId 当前盘匹配、来源 EDPF+Encrypted 二次验证；还原前自动再备份当前状态并使用同一 authopen O_RDWR FD 回读验证
- **离线模式**：拖入备份 / 镜像文件全流程分析，不插盘

## 架构

```
src/            前端(原生 JS, 无框架)
src-tauri/src/  Rust 后端
  crypto.rs     crc32_bare / AES-128 变体(A6B0/a7f0) / 滚动 XOR / LBA6 校验和
  parser.rs     LBA4/6/7/8/9/11/12 解析 + EDPF entry + ELABEL(GBK) + MBR
  disk.rs       盘枚举(diskutil) / device_id 识别 / authopen raw-device FD
  convert.rs    免密改造 5 扇生成 / 目标盘复核 / 备份与授权写入
  commands.rs   Tauri 命令门面
```

macOS 26 下 raw 设备节点可能是 `root:operator`，普通进程不能直接读取。
EDPOpen 先尝试直接只读；受保护时使用系统 `/usr/libexec/authopen` 获取已授权 FD。
写盘在再次核验 VID/PID、容量、device_id、LBA4 唯一 ID 和加密盘状态后，先卸载卷，
再通过 `authopen -stdoutpipe -o O_RDWR` 获取单个读写 FD，使用同一 FD 完成
LBA0-13 备份 → LBA0 最后写 → `sync` → 逐扇回读校验。GUI 不再依赖
`osascript → root → open(/dev/rdiskN)`；该 direct-open 路径已在 macOS 26 实测为 EPERM。

## 统一本机签名

`EDPOpenNative` 与 `edp-usb-vault` 统一使用同一张长期 self-signed Code Signing 证书：

```text
Identity: EDP Unified Local Code Signing
Certificate SHA-256: EA97420A16432AAB05E6E775E8E1698FD9A0E33B3F65CA66186A8AA683850F85
Certificate root (DR SHA-1): fda987d4d26950461a1f1810b3a66eb8bf8724c3
Validity: 2026-08-29 .. 2036-08-26
```

私钥只保存在当前用户 `login.keychain-db`，仓库不保存 PEM/P12。原生 App 和 Raw Broker 使用 Manual Signing，XPC 双向 requirement 固定 bundle identifier + 该 certificate root，不再依赖 Apple Development Team ID。

规范本机构建入口：

```bash
native/EDPOpenNative/Scripts/build-native.sh
```

该脚本会在构建前校验证书 SHA-256、私钥可用性和 certificate root，防止同名错误证书被误用。

## 参照与对拍基准

算法与流程移植自 Python 版工具（另行保存），测试向量取自真实盘的
LBA0-13 备份，Rust 与 Python 输出逐字节对拍。

## 状态

开发中（进度约 60%）。**接手/继续开发先读：**
- [PLAN.md](PLAN.md) — 权威计划：架构、算法规则表、重加密表、测试体系、剩余任务
- [HANDOFF.md](HANDOFF.md) — 执行记录：进度快照、模块地图、关键决策、已知坑、上手命令
