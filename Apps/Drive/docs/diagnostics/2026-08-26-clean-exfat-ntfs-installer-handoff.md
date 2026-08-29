# EDP USB Vault：干净 ExFAT/NTFS 读写安装包交接

更新日期：2026-08-26  
交接分支：`feat/macos26-native-fskit`  
功能基线提交：`cc01d398454a4908b07f9e3cac48935f2483c36d`  
远程仓库：<https://github.com/Evolution404/edp-usb-vault>

## 1. 目标与范围

项目目标是在 macOS 26 上提供一个不依赖 iBoysoft 授权、许可文件或二进制组件的安装包，自动识别并挂载 EDP 加密 U 盘，使解密后的 ExFAT 或 NTFS 文件系统可读写。

当前实现采用以下组合：

- EDP 加密层：项目自己的 Swift 随机访问读写实现；
- 用户态块设备：macFUSE FSKit；
- 解密块设备发布：macOS Private DiskImages2；
- ExFAT：macOS 原生文件系统；
- NTFS：开源 NTFS-3G，通过 macFUSE FSKit 后端挂载；
- 自动挂载：LaunchDaemon + 本地加密凭据存储；
- 安装包：内嵌官方 macFUSE 组件、NTFS-3G 运行时与对应源码/许可证。

“干净”在这里明确表示：安装包不包含、复制、调用或修改 iBoysoft 驱动、授权逻辑、`/var/iboysoft/ntfs.lic` 或其他专有组件。

## 2. 当前结论

| 能力 | 状态 | 证据边界 |
| --- | --- | --- |
| EDP 加密块随机读 | 已验证 | 合成介质、真实元数据产品解锁 smoke、随机读回归 |
| EDP 加密块随机写 | 已验证 | 合成介质 writer/block bridge 读回验证 |
| ExFAT 读写路径 | 已验证 | macOS 26 CI 合成磁盘完整链路 |
| NTFS-3G 编译与打包 | 已验证 | 固定源码、校验和、arm64、依赖与签名检查 |
| NTFS 文件系统识别 | 已验证 | 打包后的 `ntfs-3g.probe`/`ntfslabel` 识别合成 NTFS |
| DiskImages2 可写、禁止自动挂载 | 已验证 | CI 发布可写 `/dev/disk*`，`Media Read-Only: No` |
| macFUSE 组合安装包在干净 runner 构建 | 已验证 | macOS 26 GitHub Actions |
| 真实 EDP NTFS U 盘文件写入、重插和哈希回验 | **未验证** | 必须在有备份的专用测试盘完成 |
| LaunchDaemon 在真实设备上的自动重插挂载 | **未验证** | 只完成实现与打包检查 |
| 断电、拔盘、进程崩溃、睡眠唤醒容错 | **未验证** | 不得在唯一数据副本上测试 |
| Developer ID Installer 签名与公证 | **未完成** | 当前最终 product archive 未签名 |
| 图形界面 | **未实现** | 首次授权使用 CLI；授权后由 daemon 自动挂载 |

不要把 CI 的合成读写证明表述成“真实 EDP NTFS 盘已经通过”。下一位接手者最重要的任务是完成物理测试矩阵，同时保持失败关闭。

## 3. 数据路径

### ExFAT

```text
物理 EDP U 盘
  -> Swift 加密随机访问块后端
  -> macFUSE FSKit
  -> 隐藏 volume.raw
  -> Private DiskImages2（writable + no-auto-mount）
  -> 解密后的 /dev/disk* 或其分区
  -> macOS 原生 ExFAT 挂载
```

### NTFS

```text
物理 EDP U 盘
  -> Swift 加密随机访问块后端
  -> macFUSE FSKit
  -> 隐藏 volume.raw
  -> Private DiskImages2（writable + no-auto-mount）
  -> 解密后的 /dev/disk* 或其分区
  -> ntfs-3g.probe --readwrite
  -> NTFS-3G + macFUSE FSKit
  -> 可读写卷
```

NTFS 挂载参数目前包括：

```text
backend=fskit,no_detach,local,norecover,windows_names,
streams_interface=openxattr,noatime,big_writes,allow_other,
uid=<console uid>,gid=<console gid>,volname=<label>
```

`norecover` 是有意的安全门：遇到 dirty、休眠或不一致 NTFS 时拒绝读写挂载，不自动修复，不删除休眠文件。

## 4. 关键代码与职责

- `product/EDPVaultRuntime.swift`
  - `diskutil`/IORegistry 外置物理磁盘发现；
  - 保守的 EDP 元数据识别；
  - VID/PID/容量及 LBA11 device ID 读取；
  - AES-GCM 凭据存储；
  - `authorize`、`revoke`、`doctor`、`list`、`status`、`cleanup`、`daemon`；
  - 加密块桥、DiskImages2、ExFAT/NTFS 挂载编排；
  - 解密设备为整盘或带分区表时的节点解析；
  - 会话状态与陈旧会话清理。
- `native/EDPFSKitPoC/Tools/DiskImages2Attach.m`
  - Private DiskImages2 公布设备；
  - `--writable-noautomount` 公共 attach 路径；
  - 输出 `DI_READ_ONLY=NO`、`DI_AUTO_MOUNT=NO` 等可检查标记。
- `scripts/build-ntfs3g-runtime.sh`
  - 下载并校验 NTFS-3G `2026.7.7`；
  - 针对 macFUSE 构建 arm64 运行时；
  - 将动态库改成相对 `@loader_path`；
  - 一并打包准确源码归档及 GPL/LGPL 文本。
- `installer/build-clean-installer.sh`
  - 获取并固定 macFUSE `5.3.3`；
  - 内嵌 Core 和 PreferencePane 组件；
  - 构建运行时、FUSE bridge、DiskImages2 helper 和 NTFS-3G；
  - 生成 LaunchDaemon 和最终组合安装包；
  - 可用 `PRODUCT_SIGN_IDENTITY` 对最终 product archive 签名。
- `scripts/verify-clean-installer.sh`
  - 展开安装包并检查负载、许可证、校验和、架构、动态库、代码签名和命令入口。
- `.github/workflows/clean-installer.yml`
  - 在干净 macOS 26 runner 安装固定 macFUSE、构建、验证并上传安装包。

运行时安装位置：

```text
/Library/Application Support/EDP USB Vault
/Library/LaunchDaemons/com.edp.usbvault.mountd.plist
/usr/local/bin/edp-vaultctl
/var/db/com.edp.usbvault
/var/log/edp-usbvault.log
```

## 5. 固定上游与校验值

### NTFS-3G

- 版本：`2026.7.7`
- 官方源码 SHA-256：

```text
d67b769025d32860549d35c2147e45024d172f81c540d750390ce3602c059dab
```

### macFUSE

- 版本：`5.3.3`
- DMG SHA-256：

```text
7a0b7b66c0e7f8932707d1215dc9cf486e178d097ae0a2dcdf17d8530566aa15
```

- LICENSE SHA-256：

```text
1201956ec47b2c53c4c4fe7751be6d6f55fefcc44a6eca08780a94e009bcdbcd
```

macFUSE 的内嵌与分发基于用户声明的非商业用途。若用途变化为商业分发，应先重新核对并取得适用许可。

## 6. 获取、构建与验证

```bash
git fetch origin
git switch feat/macos26-native-fskit
git pull --ff-only

./installer/build-clean-installer.sh artifacts
./scripts/verify-clean-installer.sh \
  artifacts/EDP-USB-Vault-0.5.0-arm64-Clean.pkg
```

验证成功的最终标记：

```text
RESULT=EDP_CLEAN_INSTALLER_VERIFIED
```

需要正式签名时：

```bash
PRODUCT_SIGN_IDENTITY='Developer ID Installer: Example Corp (TEAMID)' \
  ./installer/build-clean-installer.sh artifacts
```

这只处理 Installer 签名入口。发布前仍需完成真实身份下的签名链检查、公证、staple 和 Gatekeeper 验证。

## 7. 已通过的 CI

- [Clean ExFAT + NTFS Installer，run 32909610319](https://github.com/Evolution404/edp-usb-vault/actions/runs/32909610319)
  - 干净 macOS 26 runner 安装固定官方 macFUSE；
  - 构建组合安装包；
  - 验证可写、禁止自动挂载的 DiskImages2 路径；
  - 上传 artifact `EDP-USB-Vault-0.5.0-arm64-Clean`。
- [EDP Crypto + DiskImages2 Read/Write E2E，run 32909610278](https://github.com/Evolution404/edp-usb-vault/actions/runs/32909610278)
  - 真实元数据产品解锁 smoke；
  - 加密 reader 证明；
  - 加密 writer/block bridge 证明。
- [macFUSE + DiskImages2 PoC，run 32909610294](https://github.com/Evolution404/edp-usb-vault/actions/runs/32909610294)

上述 run 对应功能基线提交 `cc01d398454a4908b07f9e3cac48935f2483c36d`。

CI artifact 中的安装包 SHA-256：

```text
7fbb2fb108765c88977f51cfe3794b70374c80e0fe2b5da5cf9c9b9a4b8382e8
```

artifact 同时包含 `.sha256` 文件。请从 run 页面下载并再次本地校验；GitHub Actions artifact 会过期，不应把它当长期发布渠道。

## 8. 安装与基本操作

在专用测试 Mac 上安装组合包。安装会写入系统目录，因此需要管理员确认：

```bash
open artifacts/EDP-USB-Vault-0.5.0-arm64-Clean.pkg
```

安装完成后：

```bash
sudo edp-vaultctl doctor
sudo edp-vaultctl list
sudo edp-vaultctl authorize diskN
edp-vaultctl status
```

注意：

- `diskN` 每次插拔都可能变化，必须通过当次 `list` 或 `diskutil list external physical` 确认；
- 首次 `authorize` 是一次性管理员动作，成功后 daemon 根据加密凭据自动处理重插；
- 不要把示例中的 `diskN` 替换成历史记录里的固定编号；
- `authorize` 前确认选中的是有完整备份、允许破坏性测试的 EDP 测试盘。

撤销和清理命令：

```bash
sudo edp-vaultctl revoke <device-id>
sudo edp-vaultctl cleanup
```

## 9. 本机已知状态

当前开发机不是“干净 macFUSE 环境”：

- `/Library/Frameworks/macFUSE.framework` 与 `/usr/local/lib/libfuse.2.dylib` 存在；
- `/Library/Filesystems/macfuse.fs` 缺失；
- 先前检查显示 iBoysoft V8 installer 的 preinstall 删除了 `macfuse.fs`，这会导致 MFMount 无法加载；
- 当前 iBoysoft 安装镜像可能仍挂载在 `/Volumes/iBoysoft NTFS for Mac`；
- 未自动卸载、删除或篡改任何 iBoysoft 组件；
- 未在本机安装最终组合包，因为安装需要交互式管理员认证；
- 工作期间看到过物理 EDP 设备为 `/dev/disk6`，但没有向该物理盘写入；该编号不稳定，不能复用。

建议在隔离测试机上安装组合包，或先由用户明确授权后再清理冲突产品。不要为了让测试通过而修改 iBoysoft 授权文件或提取其驱动。

## 10. 下一位接手者的任务顺序

### P0：真实介质最小闭环

1. 在可回滚、没有唯一数据副本的 macOS 26 测试机安装 CI artifact 或本地重建包。
2. 运行 `sudo edp-vaultctl doctor`，确认以下关键项都正常：
   - `/Library/Filesystems/macfuse.fs` 存在；
   - macFUSE FSKit/MFMount 可启动；
   - NTFS-3G 运行时和依赖完整；
   - DiskImages2 helper 可加载。
3. 只插入有完整镜像备份的 EDP 测试盘，运行 `sudo edp-vaultctl list`，人工核对物理设备、容量和 device ID。
4. 运行 `sudo edp-vaultctl authorize diskN`。
5. 分别对 ExFAT 和 NTFS 执行：
   - 创建小文件；
   - 写入随机内容并记录 SHA-256；
   - `sync`；
   - 正常推出；
   - 完整拔插；
   - 自动重挂载后重新计算 SHA-256；
   - 在 Windows 上额外执行文件读取与卷检查。
6. 查看 `edp-vaultctl status`、`/var/log/edp-usbvault.log` 和 `/var/db/com.edp.usbvault/sessions.json`，确认没有陈旧设备或错误会话。
7. 构造或准备已知 dirty/hibernated NTFS 测试镜像，确认系统明确拒绝读写挂载，且未运行自动恢复。

只有“写入 -> sync -> 推出 -> 拔插 -> 自动重挂载 -> 哈希一致”全部完成，才能把真实设备 NTFS 写入状态改为已验证。

### P1：稳定性和边界

- 验证 LaunchDaemon 冷启动、重插和重启后的自动挂载；
- 验证解密后为整盘文件系统以及存在分区表的两类设备；
- 验证多分区场景，特别是历史设备的分区 2/4 布局；
- 验证两只 EDP 设备并发、同标签卷名和 device ID 隔离；
- 验证 Finder 推出、CLI 清理、进程被杀、强制拔盘、睡眠/唤醒和系统重启；
- 验证 daemon 崩溃后会话清理，不遗留隐藏 raw 卷、DiskImages2 节点或 FUSE mount；
- 验证磁盘空间耗尽、权限变化和控制台用户切换；
- 对物理盘执行前，先在可丢弃合成镜像跑同样的故障注入矩阵。

### P2：发布完善

- 使用真实 Developer ID 对所有自有可执行文件和最终 Installer 完整签名；
- 完成 notarization、staple、`spctl`/`pkgutil --check-signature` 验证；
- 增加原生 Swift UI，覆盖授权、撤销、状态、错误说明和安全推出；
- 持续验证 macOS 小版本更新对 Private DiskImages2 的兼容性；
- macFUSE 新版本发布后重新核对许可证、固定校验和并跑全套 CI，不盲目升级；
- 评估 macFUSE FSKit 已知问题和上游 issue #1188 的变化。

## 11. 必须保持的安全门

- 永远不要在唯一数据副本上测试写入或故障恢复；
- 任何物理写测试前必须先保存完整块级镜像和校验值；
- 不使用 `force`、`recover` 或 `remove_hiberfile` 绕过 NTFS 状态；
- dirty、Windows Fast Startup/hibernated 或不一致 NTFS 必须失败关闭；
- 合成介质测试未通过时，不进入物理写测试；
- 发现设备身份、容量、分区或元数据有歧义时停止，不猜测；
- 每次 macOS 更新后重新探测 Private DiskImages2，探测失败时停止挂载；
- 不修改授权文件、不复制专有驱动、不把 iBoysoft 二进制带入安装包；
- 未完成重插与哈希回验前，不宣称真实 NTFS 写入成功。

## 12. 已知实现债务与审查重点

- `EDPVaultRuntime.swift` 当前是 MVP 编排器，daemon 采用约 2 秒轮询；后续可迁移到更直接的系统事件通知。
- 最终 product archive 当前未签名。内层自有 Mach-O 为 ad-hoc 签名；macFUSE payload 的代码签名仍可验证。
- 为绕过 macOS 26 PackageKit 在组合官方 macFUSE product package 时的崩溃，构建脚本先展开组件、再 `pkgutil --flatten`、最后 `productbuild`。这样不会保留原官方外层 product 签名，但 payload 二进制签名仍在；最终发布包必须用自己的 Installer 身份签名。
- DiskImages2 是私有 API，系统更新可能改变行为；所有调用必须保留 runtime probe 和 fail-closed。
- 初次授权目前是 CLI 管理员流程，不是无人值守 GUI 流程。
- 凭据存储位于 root-only 的 `/var/db/com.edp.usbvault`，使用 AES-GCM；继续审查密钥生命周期、备份恢复、撤销和多用户边界。
- 真实多分区设备节点解析已有实现，但尚未覆盖足够物理设备样本。
- macFUSE FSKit 与 NTFS-3G 的组合仍需要真实大文件、稀疏文件、xattr、文件名规则、并发和长时间压力测试。

## 13. 接手时建议先执行

```bash
git status --short --branch
git log -1 --oneline
git pull --ff-only

gh run view 32909610319
gh run view 32909610278
gh run view 32909610294

./scripts/verify-clean-installer.sh \
  artifacts/EDP-USB-Vault-0.5.0-arm64-Clean.pkg
```

如果本地没有 artifact，应从成功的 installer run 下载或重新构建。下载后先校验 SHA-256，再安装到专用测试机。

## 14. 交接完成定义

下一阶段可以视为完成，至少需要同时具备：

1. 有备份的真实 EDP ExFAT 盘完成写入、重插、哈希一致；
2. 有备份的真实 EDP NTFS 盘完成写入、重插、哈希一致；
3. dirty/hibernated NTFS 被可靠拒绝；
4. daemon 自动挂载、推出与陈旧会话清理在真实设备通过；
5. 故障测试没有造成超出测试盘范围的写入；
6. 发布场景下 Installer 已签名、公证并通过 Gatekeeper；
7. 文档明确记录测试机器、macOS、macFUSE、NTFS-3G、设备型号、VID/PID、分区布局、操作步骤和校验值。

