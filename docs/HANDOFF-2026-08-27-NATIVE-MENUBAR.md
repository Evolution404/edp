# EDP USB Vault 0.6.0 原生菜单栏产品交接

日期：2026-08-27

分支：`test/fuset-minimal-fskit-bridge`

状态：原生菜单栏 App、特权服务和三分区读写链已经在实体 U 盘上跑通；Finder 暴露内部 Transport 卷仍是当前 P0。

本文是下一位 AI 的首要入口。旧的 `docs/STATUS.md` 和 2026-08-26 tracker
保留历史实验信息，但产品现状以本文和当前代码为准。

## 1. 用户最终目标

制作 macOS 26+ 原生 App：

- 常驻顶部菜单栏，可打开完整 SwiftUI 主界面；
- 用户按 U 盘设置显示名称、交换区密码、保密区密码和自动挂载策略；
- 插盘后按策略自动挂载启动区、交换区、保密区；
- 交换区和保密区挂载为 NTFS 时仍能通过 Finder 自带“抹掉”改为 ExFAT；
- App 不实现文件系统，也不提供自制格式化按钮；
- 安装和系统批准完成后，日常插盘、挂载不再要求管理员密码；
- 用户应只看到最终卷，不应看到内部块传输卷。

## 2. 当前已经完成的结果

### 2.1 原生产品

- `/Applications/EDP USB Vault.app` 已安装 0.6.0；
- App 使用 SwiftUI + AppKit，`LSUIElement=true`，没有 Dock 图标；
- 菜单栏菜单可以打开“设备 / 活动 / 设置”主界面；
- root 服务通过 `SMAppService.daemon` 注册，当前服务名
  `com.edp.usbvault.mountd`；
- XPC Mach service 为 `com.edp.usbvault.xpc`；
- XPC 服务校验客户端签名、Team ID、App identifier 和 root-owned 安装路径；
- App/服务当前使用 Apple Development 签名，Team ID `W82WPH8HY7`；
- 安装包本身尚无 Developer ID Installer 签名，不能当正式发布包。

### 2.2 分区策略与密码

- type 1 启动区：无密码，默认自动挂载；
- type 2 交换区：独立密码和独立自动挂载开关；
- type 4 保密区：独立密码和独立自动挂载开关；
- 交换区和保密区密码分别存入 System Keychain；
- 旧版单设备密码有分区级迁移路径；
- 设备显示名称、全局自动挂载、三个分区策略保存在 root-only 原子 JSON；
- 当前实体盘策略中启动区、交换区会自动挂载；保密区本次是手动挂载，默认策略仍为关闭。

### 2.3 实体 U 盘验证结果

实体设备是 Lexar `VID:PID=21c4:0cd1`，物理盘当前为 `/dev/disk28`，
大小 `124736503808` bytes。整盘 `O_RDWR` 打开后 macOS 不再展示实体子分区，
这是预期现象，三个分区由产品重新发布为虚拟磁盘：

| 分区 | 当前虚拟盘 | 挂载点 | 文件系统 | 大小 | 只读 |
|---|---|---|---|---:|---|
| 启动区 type 1 | `/dev/disk29` | `/Volumes/启动区` | MS-DOS FAT12 | 10,453,504 B | 否 |
| 交换区 type 2 | `/dev/disk30` | `/Volumes/交换区` | ExFAT | 118,477,684,736 B | 否 |
| 保密区 type 4 | `/dev/disk31` | `/Volumes/保密区` | ExFAT | 6,234,963,968 B | 否 |

三个卷同时稳定挂载超过 60 秒。交换区已经由用户通过 Finder 自带抹掉从
NTFS 改为 ExFAT，之后重新挂载成功。保密区走同一套可写发布链，也支持
Finder 抹掉；执行前必须明确提醒用户这会清空对应分区。

### 2.4 正式数据链

```text
physical EDP USB whole disk
  -> type 1: validated writable plain MBR/FAT slice
  -> type 2/4: password validation + Swift SM4 random-access block adapter
  -> inherited raw fd 3, then drop from root to console user
  -> pinned FUSE-T 1.2.7 FSKit thin transport exposing volume.raw
  -> DiskImages2 writable virtual media
  -> Apple native FAT / ExFAT / NTFS filesystem stack
  -> Finder final volume
```

产品没有实现 FAT、ExFAT 或 NTFS 目录/文件语义。NTFS 是否可写由 Apple
文件系统能力决定，但虚拟介质保持可写，因此 Finder 可以“抹掉”并格式化为
ExFAT。

## 3. 当前 P0：Finder 出现多余 Transport 卷

用户最后截图中出现：

- `EDP Boot Transport`
- `EDP Secure Transport`

它们不是额外数据分区，而是 FUSE-T 暴露 `volume.raw` 的内部传输卷。交换区
也有同类 `EDP Exchange Transport`，截图可能没有截到。

**不要让用户单独推出这些 Transport 卷。** 推出后其上层最终卷会失去块后端，
可能产生 I/O 错误。用户应使用 App 的“卸载”或“安全推出”统一逆序清理。

当前三个内部挂载点：

```text
/Volumes/.edp-block-disk-ven_lexar-prod_usb_flash_drive-1
/Volumes/.edp-block-disk-ven_lexar-prod_usb_flash_drive-2
/Volumes/.edp-block-disk-ven_lexar-prod_usb_flash_drive-4
```

代码已经在 `FuseTMinimalBridge.swift` 中调用：

```swift
mount.arguments = [
    "-o", readOnly ? "nobrowse,rdonly" : "nobrowse",
    "-t", "fuset", sessionURL.path, mountpoint,
]
```

但是当前 `mount` 输出的三个 `fuse-t` 卷都没有 `nobrowse` 标志，Finder 仍将
它们加入侧边栏。也就是说，不能再把问题简单归因为“忘记传 nobrowse”。

已确认的 FUSE-T 1.2.7 FSKit session descriptor 字段只有：

```text
session_id, socket_path, auth_token, namedattr, readonly, volume_name
```

官方文档把 `-o nobrowse` 列为支持选项，但当前 FSKit backend 没有把它反映到
实际 mount flags。FUSE-T appex 二进制中能看到 `requestedMountOptions`，下一步
应优先查清 `mountWithOptions:` 对 FSKit options 的处理，而不是直接改最终卷。

建议的排查顺序：

1. 用仓库的最小 FUSE-T fixture 单独复现，避免反复重启实体盘会话；
2. 对比 `/sbin/mount -o nobrowse -t fuset ...`、不同 option 传递形式以及
   FSKit `requestedMountOptions` 的实际内容；
3. 检查 FUSE-T 官方源码/发布版本是否对 FSKit backend 实现了 no-browse；
4. 若属于上游限制，验证只隐藏内部资源的安全替代方案，例如 FSKit/Disk
   Arbitration 的 no-browse mount option；
5. 最后才考虑将内部 `volume_name` 改为点号开头。该方案必须实测 Finder、
   DiskImages2 attach、卸载恢复和三个分区同时存在，不能凭名称推断有效；
6. 只隐藏 FUSE-T transport，绝不能隐藏 `/dev/disk29`、`disk30`、`disk31`
   对应的最终用户卷。

修复验收：Finder 侧边栏只出现“启动区 / 交换区 / 保密区”；三个最终卷仍可
读写；Finder 抹掉交换区/保密区仍可用；App 卸载和安全推出无泄漏。

## 4. P1 和技术债

### 4.1 挂载期间发现日志风暴

整盘已被授权会话打开、实体子设备消失时，后台发现会短时间高频输出：

```text
EDP discovery skipped disk28 because raw metadata read failed:
raw open failed: errno=1 Operation not permitted
```

随后三个最终卷仍能正常挂载，所以它目前不是功能失败。代码已有 5 秒 transient
disappearance grace，但日志仍很吵。应对 active session 的整盘跳过重复 metadata
probe，或按 device 做节流/去重；不要用吞掉所有发现错误的方式处理。

### 4.2 Keychain 弃用 API

`EDPCredentialStore.swift` 为 root-only System Keychain ACL 使用：

- `SecKeychainOpen`
- `SecAccessCreateWithOwnerAndACL`

它们在现代 macOS 已标记 deprecated。当前构建成功，只产生警告。替换前必须
证明新的 Keychain 访问控制仍允许 root daemon 自动读取，同时不让普通进程读取。

### 4.3 发布签名和许可

- App/helper 当前是 Apple Development 签名，不是 Developer ID Application；
- `.pkg` 当前 unsigned；
- 正式发布需要 Developer ID Application、Developer ID Installer、公证和干净机 Gatekeeper 验证；
- FUSE-T 二进制未捆绑，运行时严格校验外部 1.2.7；
- 商业产品发布前必须取得适用的 FUSE-T commercial license，不能把自动下载当成规避许可。

### 4.4 仍需发布级实机回归

- 干净 macOS 26：安装 → 批准 FSKit/后台服务 → 重启 → 插盘自动挂载；
- sleep/wake；
- 正常拔盘、异常拔盘、App 强退、daemon `SIGTERM`；
- Finder 复制大文件、删除、改名、Quick Look；
- ExFAT 格式化后重插和跨 Windows/macOS 读写；
- 多块 EDP 盘以及同一设备反复插拔；
- 交换区/保密区密码错误、缺失、更新和 Keychain 迁移。

## 5. 关键代码位置

| 文件 | 责任 |
|---|---|
| `product/App/EDPUSBVaultApp.swift` | 菜单栏、SwiftUI 主窗、设备/活动/设置 UI、SMAppService 注册、XPC client |
| `product/EDPVaultRuntime.swift` | root daemon、设备发现、策略协调、挂载/卸载/恢复、XPC service |
| `product/EDPDevicePolicyStore.swift` | root-only 设备名称和分区自动挂载策略 |
| `product/EDPCredentialStore.swift` | System Keychain、分区密码、旧密码迁移 |
| `product/EDPXPCProtocol.swift` | App/daemon Codable DTO 和 XPC protocol |
| `product/EDPXPCSecurity.swift` | XPC 客户端签名和 Team 校验 |
| `product/EDPConsoleExec.c` | 继承 raw fd 3、降权到 console user、启动 bridge |
| `native/EDPFSKitPoC/Tools/FuseTMinimal/FuseTEDPAuthorizedReadWriteBridge.swift` | 实体盘二次校验、type 1 明文切片、type 2/4 SM4 块设备 |
| `native/EDPFSKitPoC/Tools/FuseTMinimal/FuseTMinimalBridge.swift` | FUSE-T session/RPC、内部 `volume.raw`、当前 nobrowse 调用 |
| `installer/build-native-installer.sh` | 0.6.0 App、daemon、runtime 和 pkg 构建 |
| `installer/scripts/native-preinstall` | 安装前兼容旧 launchd job |
| `installer/scripts/native-postinstall` | 权限、旧 job 清理、现有现代服务 kickstart |
| `product/Tests/ValidateProductModels.swift` | 策略默认值、持久化和 XPC snapshot round-trip |

安全边界要保持：不保存 `AuthorizationExternalForm`，不修改 AuthorizationDB；
root 只打开已由设备发现层确认的 whole raw disk；bridge 收到 fd 3 后再次验证字符
设备、size、VID/PID、EDP metadata 和分区边界。

## 6. 构建、测试和安装

完整构建：

```bash
EDP_APP_SIGN_IDENTITY='<本机 Apple Development identity>' \
EDP_SERVICE_MODE=smappservice \
./installer/build-native-installer.sh artifacts
```

当前产物：

```text
artifacts/EDP-USB-Vault-0.6.0-Native.pkg
SHA-256 c8411bebd5ecfd42f89c2896daff90d59e9a957199bceb66ce49a2f3d4b81e67
```

这只是开发测试包，pkg 没有 Installer 签名。安装或更新会重启服务并短暂卸载
最终卷；必须先让用户停止写入。保密区自动挂载默认关闭，所以更新后若没有回来，
需从 App 手动挂载或让用户开启对应策略。

本次交接前验证：

```text
0.6.0 smappservice package build: PASS
product model validation: RESULT=EDP_PRODUCT_MODELS_OK
FUSE-T bridge compile with -warnings-as-errors: PASS
installer shell syntax: PASS
git diff --check: PASS
physical three-volume simultaneous mount: PASS
```

## 7. 下一位 AI 的建议开工步骤

1. `git status`，确认交接提交后的工作树干净；
2. 阅读本文，再读 `README.md` 和上述关键代码；
3. 不要先卸载当前实体盘会话，也不要让用户推出 Transport；
4. 在最小 fixture 上解决 P0，完成后跑 bridge warnings-as-errors 和产品模型测试；
5. 提前告诉用户更新会导致三个卷短暂卸载，再构建、安装并实机验证；
6. 验证 Finder 只显示三个最终卷后，再处理发现日志节流；
7. 每个破坏性格式化实验都必须再次确认目标是交换区或保密区，禁止整盘和启动区误抹掉。
