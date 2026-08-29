# EDP Drive — macOS 26 当前状态与唯一实施方案

更新时间：2026-08-29
开发真源：`Evolution404/edp` monorepo，`main`

> 本文件只描述当前仍然有效的生产架构和验收状态。2026-08-26 以前的 FUSE-T、NTFS-3G、authopen、旧 Raw Access App、旧 `com.edp.usbvault.*` 身份等实验结果只保留在 Git 历史中，不再作为实现依据。

## 1. 当前产品拓扑

EDP Drive 只保留一个用户 App 和一个嵌入式后台 Service：

```text
/Applications/EDP Drive.app                     com.edp.drive
├── Contents/MacOS/EDP Drive
├── Contents/Library/LaunchServices/edp-drive-service
└── Contents/Library/LaunchDaemons/com.edp.drive.service.plist

embedded service / LaunchDaemon / Mach service:
com.edp.drive.service
```

不再存在第二个 Raw Access `.app`，也不引入 `EDP Drive Service.app`。

后台 Service 负责：

- whole USB passive classification 与标准 EDP 加密盘身份验证；
- Full Disk Access 下的 `/dev/rdiskN` 打开和 retained raw fd 生命周期；
- EDP metadata / stable device identity / password verification；
- `Packages/EDPCore`；
- type 1 / 2 / 4 挂载生命周期；
- macFUSE Local block transport；
- DiskImages2；
- Disk Arbitration / Finder 集成；
- 自动挂载、卸载、安全推出；
- App ↔ Service XPC。

App 设置页提供后台 Service 的：

```text
启动
停止
重启
```

停止必须通过 XPC graceful shutdown，先卸载所有 EDP session、释放 raw fd、停止 disk monitor 后再退出。产品不通过 `kill -9` 实现正常停止。

Service plist 不使用 `KeepAlive` 或 `RunAtLoad`，避免用户主动停止后被 launchd 立即重新拉起；Mach service 保持按需激活能力。

## 2. USB 分类与唯一数据路径

Drive 对 whole USB 只做一次只读 passive sniff，读取 LBA0/4/7/11/12 后区分：

```text
standardEncrypted   标准 EDP 加密盘
legacyNoPassword    旧版免密改造盘
currentNoPassword   最新免密改造盘
unrecognizedEDP     有 EDP 证据但结构异常/无法可靠识别
ordinaryUSB         普通 U 盘
```

接管规则是硬约束：**只有 `standardEncrypted` 进入 Drive 的 raw/password/mount pipeline**。旧版免密、最新版免密、异常 EDP 和普通 U 盘都不创建 retained raw lease、不建立 EDP mount session、不卸载系统卷，直接留给 macOS / Disk Arbitration / Finder。

标准加密盘当前唯一数据路径：

```text
physical standard EDP USB
  -> retained raw fd
  -> LBA metadata / password / key derivation
  -> Packages/EDPCore
  -> SM4 transparent block translation
  -> macFUSE 5.3.x Local block transport
  -> hidden volume.raw
  -> Private DiskImages2
  -> /dev/diskN / IOMedia
  -> Disk Arbitration
  -> Apple native filesystem stack
  -> Finder
```

职责边界：

1. EDP Drive / EDPCore 只负责 EDP 格式、密码学和块翻译；
2. macFUSE Local 只暴露 random-access `volume.raw`；
3. DiskImages2 把该块视图发布为 macOS 磁盘；
4. 文件系统语义交给 Apple 原生文件系统栈。

## 3. 明确删除的旧路径

当前生产树明确不再包含或调用：

```text
Tauri / Rust
FUSE-T
ntfs-3g
NTFS-3G write fallback
macFUSE kernel backend
authopen
sys.openfile.* AuthorizationDB workaround
DriverKit block-storage workaround
自研 exFAT / FAT / NTFS 文件系统
```

NTFS magic / partition type detection仍保留，但只用于识别和状态展示；实际挂载交给 Apple / Disk Arbitration。若 macOS 对 NTFS 仅提供只读能力，Drive 如实显示只读状态，不恢复 `ntfs-3g`。

## 4. EDPCore

共享核心位于：

```text
Packages/EDPCore
```

Drive 和 Studio 都直接链接这一份原生核心，不再跨仓库 pin revision。

已实现：

- SM4；
- CRC32；
- EDP metadata / identity；
- LBA11 / LBA12；
- password validation / key derivation；
- sector decoding；
- caller-owned / in-place buffer API；
- 大块自适应多核 SM4。

M1 Pro 实测 crypto 吞吐约：

```text
64 KiB   ~0.75-0.8 GiB/s
128 KiB  ~1.1 GiB/s
1 MiB    ~1.6-1.7 GiB/s
64 MiB   ~2.0 GiB/s
```

真实 USB 性能改造后曾实测：

```text
旧路径 1 GiB 冷读   ~46.8 MiB/s
新路径 1 GiB 冷读   ~158.8 MiB/s

旧路径 1 GiB 写入   ~54 MB/s
新路径 1 GiB 写入   ~166 MB/s
```

核心性能优化包括：

- 去除 `Data -> [UInt8] -> Data` 热路径复制；
- raw `pread` 直接写 caller-owned/FUSE buffer；
- SM4 原地解密；
- 物理 raw 并行读取严格按 sector / 4 KiB 边界切块；
- 防止真实 `/dev/rdiskN` 非 sector-aligned `pread` 返回 `EIO`。

## 5. 权限与安全模型

长期签名身份固定为：

```text
Identity: EDP Project Code Signing
Certificate SHA-256:
D9142CE44ABCB5DD662DF9621D48A88C88EDBCB0392D3C74EBACBB1292B7B5A7

Certificate leaf/root SHA-1:
040B5488FB2B6C02B0786E76B674CB4460658CA2
```

禁止：

- 使用 Apple Developer 账号替代这张项目专属证书；
- 修改 DefaultKeychain / SearchList；
- 把私钥、P12、密码提交到仓库；
- 修改 TCC 数据库；
- 修改 AuthorizationDB；
- 放宽 `/dev` node owner/mode；
- 对真实 EDP U 盘做 raw-sector destructive write test。

Service 打开 raw device 前后继续验证：

- root service 身份；
- whole USB；
- character device；
- `st_rdev` 一致性；
- VID/PID / 容量 / registry identity；
- LBA0 / LBA4 / LBA7 / LBA11 / LBA12 metadata 与标准加密盘几何；
- stable EDP device ID；
- 只把 raw fd 传给允许的 EDP transport。

App ↔ Service XPC 继续执行固定 App path、code identifier 和固定 EDP signing leaf requirement，不提供 arbitrary raw path open API。

## 6. 新身份与迁移

当前 Drive 正式身份：

```text
App:       com.edp.drive
Service:   com.edp.drive.service
Mach/XPC:  com.edp.drive.service
Data root: /var/db/com.edp.drive
Keychain:  com.edp.drive.partition-password.v1
```

旧身份只允许出现在升级清理 / credential migration 代码中：

```text
com.edp.usbvault.*
/Applications/EDP USB Vault.app
/Applications/EDP USB Vault Raw Access.app
/var/db/com.edp.usbvault
```

升级迁移必须幂等：新 namespace 写入和验证成功后才能删除旧凭据；不得把密码明文落盘。

## 7. 当前验证状态

已通过：

- Swift 6 `warnings-as-errors`；
- EDPCore tests；
- SM4 标准向量；
- real LBA11 / LBA12 golden；
- 两只真实盘共 1024 个随机读 golden；
- encrypted reader/writer boundary / persistence；
- 单 App + embedded Service installer build / expansion contract；
- 包内无 `ntfs-3g`；
- App ID `com.edp.drive`；
- Service code/Mach ID `com.edp.drive.service`；
- graceful shutdown API / UI Start-Stop-Restart 编译 gate；
- XPC disconnect race hardening；
- monorepo exact-head Core / Drive / Studio GitHub Actions。

仍需在真实本机完成：

1. 从旧 `EDP USB Vault + Raw Access App` 升级安装到新 `EDP Drive.app`；
2. 为新身份完成一次 Full Disk Access 授权；
3. type 1 / 2 / 4 functional-all；
4. UI Stop -> 确认所有 session 安全退出且 Service 不自动复活；
5. UI Start；
6. UI Restart；
7. App restart；
8. USB replug / diskN change；
9. Mac reboot；
10. 后续均不再出现管理员/Touch ID 授权；
11. 真实 USB 性能 sanity check，确认约 160 MB/s 级基线未明显回退。

以上实机验收完成前，不删除三个旧 GitHub 仓库。

## 8. 当前开发入口

唯一仓库：

```text
https://github.com/Evolution404/edp
```

主要目录：

```text
Apps/Drive
Apps/Studio
Packages/EDPCore
```

当前身份迁移计划：

```text
Apps/Drive/docs/PLAN-2026-08-29-single-app-service-migration.md
```

首次安装 / 升级验收：

```text
Apps/Drive/docs/FIRST-INSTALL-ACCEPTANCE.md
Apps/Drive/scripts/first-install-acceptance.sh
```

旧分支、旧 handoff、旧 NTFS-3G/FUSE-T 实验仅作为 Git 历史证据，不得作为当前实现入口。
