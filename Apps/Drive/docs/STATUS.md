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
- 每次 discovery/reconcile 都重新读取上述 5 个扇区并重新分类，禁止用缓存设备记录绕过标准盘判定；
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
- EDPCore tests、SM4 标准向量、real LBA11/LBA12 golden、两只真实盘共 1024 个随机读 golden；
- encrypted reader/writer boundary / persistence；
- 五类 USB classifier 的 golden 与真实 Lexar/SanDisk 标准盘 positive fixtures；每次扫描重新分类，禁止 cached-device 绕过标准盘判定；
- 单 App + embedded Service installer build / expansion contract，包内无 `ntfs-3g`，固定 App ID `com.edp.drive` / Service ID `com.edp.drive.service`；
- 固定 `EDP Project Code Signing` 证书 + 一次性 Full Disk Access；未修改 TCC 数据库；
- cold-start fd3/CLOEXEC 继承修复：真实 Lexar 冷启动后交换区/保密区自动恢复；
- Swift 6 NSXPC callback `@Sendable` 修复：旧版 MainActor/XPC `SIGTRAP` 不再复现；
- macFUSE FSKit `not found/not enabled` transient auto-mount recovery；
- bounded DiskImages2/hdiutil helper；transport hidden mount 未消失时 fail closed，不 kill transport；
- VFS unmount 已从 privileged Service 的 direct `Darwin.unmount(2)` 移到 bounded `/sbin/umount` 子进程；`ValidateBoundedVFS.swift` timeout probe 约 0.229 s 返回；
- teardown 严格按 user filesystem -> DiskImages2 BSD -> hidden macFUSE -> transport process，自上而下 fail closed；
- explicit partition unmount / credential-delete unmount / whole-device eject 均传播 incomplete teardown 错误，session 未清空时不释放 raw lease、不尝试物理 eject；
- real Lexar 在 bounded-VFS 修复后连续两轮 Stop -> demand Start：两次 Stop 均约 1 s，Service `exit 0`，user/hidden/transport residue 为 0；第二轮 Start 后两区约 8 s 恢复；
- mounted 状态 App restart：UI PID 变化，Service PID 与 type2/type4 mount 持续不变；
- `80f1cb6` 安装后 Service 连续稳定运行约 7 小时，两区仍为可写 ExFAT，无新 crash；
- 产品 XPC whole-device safe eject：约 1 s 完成，type2/type4/hidden/transport 全清空，snapshot 进入 saved/offline 状态；
- safe eject 后 15 s 不重新接管，App restart 也不重新接管；
- 用户物理拔出/等待/重新插入后，两区 1 s 内自动恢复，stable device ID/VID:PID 保持一致，`privilegedAccessReady=true`；
- 重插后未出现可见 SecurityAgent/CoreServicesUIAgent/Installer 授权窗口，未发生第二次管理员/Touch ID 授权；
- 同一 `.menuBarExtraStyle(.window)` 内多级 `设备 -> 分区 -> 操作` 菜单、`仅退出界面` / `完全退出` 生命周期；禁止恢复 AppKit cascading `Menu(...)`；
- Drive/Studio 原生 App Icon 与 Finder copyright metadata；EDP Studio inspector 使用真实 `HSplitView`；
- `80f1cb61b4949d5ccf7d90f2cdb84987c340b9d0` exact-head Drive CI run `33261528346` success；
- exact-head clean combined installer 已从本地 pinned macFUSE 5.3.3 DMG + pinned license 离线重建并通过 `verify-clean-installer.sh`，SHA-256 `183fc2836aae54979d67526bd81c5b39d1f4af968ae40325bc5025310b34a75f`；
- 三个旧 GitHub 仓库历史已迁入 monorepo并已删除。

当前仍需补齐的发布验收：

1. 普通 U 盘：物理验证必须完全交给 macOS，Drive 不接管；
2. 旧版 NoPwd：物理验证 `legacyNoPassword` 且 Drive 不接管；
3. 最新 NoPwd：物理验证 `currentNoPassword` 且 Drive 不接管；
4. `unrecognizedEDP` 物理负例：Drive 不建立 raw lease/mount session；
5. type 1 如当前产品策略需要由 Drive 管理时再补对应实机验收；当前 final trial 的 type 1 autoMount=false；
6. 最终 physical replug 仍复用了 `disk6`，因此“真实 BSD `diskN` 数字变化”这一子项没有被本次实机强制复现；不得伪称已验证；
7. `80f1cb6` 安装后的单独一次 Mac reboot 未重新重复；此前多个 acceptance reboot 已证明固定身份/FDA persistence，而 `80f1cb6` 只新增 eject error propagation；如发布流程要求 exact-head reboot gate，可再单独执行；
8. Drive/Studio 最终视觉验收仍以用户主观确认结果为准。

Finder 复制性能补充：受控 A/B 已证明约 3 秒的“不确定/折返进度”在完全绕过 EDP 的本机 ExFAT DiskImages2 卷上同样存在（约 2.98 s），EDP 交换区约 2.91-3.30 s；实际目标 <1 s 已开始写入。因此该 UI 延迟不再作为 EDP I/O bug。6.5 GiB 真实 Finder 持续写约 92.85 MB/s，SHA-256 一致；短时复制可更高。详见 `docs/diagnostics/2026-08-29-finder-progress-estimation.md`。

EDP 公开资料研究补充：北信源专利/公开产品资料确认加密介质存在启动区、交换/交互区、保密区和密码/标签控制模型，但未找到 type 1/2/4、LBA4/LBA7/LBA11/LBA12、`EDPF`、CRC、SM4 字节级公开格式；这些仍以真实盘 fixture/golden 为权威。详见 `docs/diagnostics/2026-08-29-edp-metadata-public-research.md`。

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

当前完整交接入口：

```text
docs/HANDOFF-2026-08-29.md
```

身份迁移历史计划：

```text
Apps/Drive/docs/PLAN-2026-08-29-single-app-service-migration.md
```

首次安装 / 升级验收：

```text
Apps/Drive/docs/FIRST-INSTALL-ACCEPTANCE.md
Apps/Drive/scripts/first-install-acceptance.sh
```

旧分支、旧 handoff、旧 NTFS-3G/FUSE-T 实验仅作为 Git 历史证据，不得作为当前实现入口。
