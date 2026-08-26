# EDP USB Vault — 文件系统无感知 / 系统默认只读挂载方案

日期：2026-08-26  
目标分支：`feat/filesystem-agnostic-native-readonly`  
状态：**待用户审核，禁止在审核前继续实现**  
目标平台：macOS 26+

## 0. 不可突破的约束

本分支把以下条件视为产品级硬约束：

1. **用户不需要 Apple Developer 账号。**
2. **不申请 FSKit / DriverKit / System Extension 等特殊 entitlement。**
3. **SIP 必须保持开启。**
4. **不要求用户进入 Recovery 降低安全策略。**
5. **不要求关闭 AMFI。**
6. **不安装或依赖第三方文件系统驱动。**
7. **不安装 macFUSE、FUSE-T、Paragon、Tuxera、iBoysoft 等文件系统运行时。**
8. **EDP 产品代码不判断目标逻辑卷是 NTFS、ExFAT、APFS、HFS+ 或其他文件系统。**
9. **EDP 产品代码不包含 NTFS-3G、NTFS probe、NTFS mount policy、NTFS write safety 等文件系统专用逻辑。**
10. **真实 EDP 物理 U 盘始终只读打开；本分支不允许向物理 EDP 介质写入。**

任何实现如果需要突破上述任意一条，必须先停止并重新提交方案审核。

---

## 1. 产品职责边界

新的 EDP USB Vault 只负责 EDP 容器层：

```text
physical EDP USB
    ↓
EDP device discovery
    ↓
LBA4/LBA7/LBA11/LBA12 metadata
    ↓
password verification / key derivation
    ↓
SM4 transparent decryption
    ↓
plain read-only raw image
    ↓
macOS system disk-image stack
    ↓
/dev/diskN
    ↓
Disk Arbitration
    ↓
macOS default filesystem support
    ↓
Finder
```

EDP **不知道也不关心** `/dev/diskN` 内部是什么文件系统。

产品层不再做：

```text
NTFS boot-sector detection
ExFAT boot-sector detection
ntfs-3g.probe
ntfslabel
NTFS dirty / hibernation判断
NTFS mount options
macFUSE FSKit module selection
FinderInfo/xattr compatibility patch
TextEdit rename compatibility patch
```

如果 macOS 原生支持该文件系统，则由 macOS 挂载。

如果 macOS 原生不支持，则 EDP 只报告：

```text
macOS 无法使用系统默认文件系统支持挂载该卷
```

EDP 不做 fallback。

---

## 2. 为什么不能做“实时纯原生虚拟块设备”

在以下约束同时成立时：

```text
无 Apple Developer 账号
+ 不申请 entitlement
+ SIP/AMFI 正常开启
+ 不安装第三方驱动
```

EDP 无法合法、稳定地向 macOS 注册一个自己的实时虚拟 block device。

被排除的路径：

### 2.1 自有 FSKit module

需要 Apple 授权的 FSKit module entitlement。

**拒绝。**

### 2.2 DriverKit 虚拟块设备

需要 Developer ID / DriverKit entitlement / 系统扩展分发链。

**拒绝。**

### 2.3 KEXT / legacy VFS driver

需要降低现代 macOS 安全策略，且不符合 SIP 保持开启的产品要求。

**拒绝。**

### 2.4 macFUSE / FUSE-T

不需要 EDP 自己的 entitlement，但需要额外安装第三方文件系统/系统组件。

与本分支“原生环境”目标冲突。

**拒绝。**

因此，本分支的纯原生可实施方案必须使用一个普通、可 seek 的本地 raw image 作为系统磁盘映像输入。

---

## 3. 推荐架构：先物化解密 raw image，再交给系统

### 3.1 第一步：物理 EDP 始终 O_RDONLY

App 只申请：

```text
sys.openfile.readonly./dev/rdiskN
```

禁止申请：

```text
sys.openfile.readwrite./dev/rdiskN
```

后台只允许：

```text
O_RDONLY | O_CLOEXEC
```

生产二进制中不保留对真实 EDP 盘的 write/pwrite 入口。

### 3.2 第二步：顺序解密到本地 raw image

新增一个文件系统无感知的导出器，例如：

```text
edp-decrypt-image
```

输入：

```text
raw EDP device
EDP volume descriptor
password/key
```

输出：

```text
volume.raw
```

它只做：

```text
offset translation
SM4 decrypt
sequential read
sequential local-file write / sparse seek
```

它不读取 NTFS MFT，不读取 ExFAT FAT，不判断 boot-sector magic。

### 3.3 第三步：raw image 只读 attach

优先使用 macOS 自带磁盘映像工具链，把：

```text
volume.raw
```

以 **read-only + no-auto-mount** 方式 attach 成：

```text
/dev/diskN
```

优先验证公开系统工具：

```text
/usr/bin/hdiutil attach -readonly -nomount ...
```

目标是逐步取消生产代码对 private `DiskImages2.framework` selector 的依赖。

如果 `hdiutil` 在 raw filesystem image 上不能稳定满足需求，再单独提交是否继续使用现有 DiskImages2 adapter 的审核，不在本计划中默认接受 private API。

### 3.4 第四步：Disk Arbitration 默认挂载

EDP 只向 Disk Arbitration 提交：

```text
mount this BSD disk
```

不传文件系统类型。

不调用：

```text
mount_ntfs
mount_exfat
/sbin/mount -t ...
ntfs-3g
```

最终效果例如 NTFS：

```text
volume.raw
→ /dev/diskN
→ Disk Arbitration
→ Apple /System/Library/Filesystems/ntfs.fs
→ Finder read-only
```

如果是 ExFAT：

```text
volume.raw
→ /dev/diskN
→ Disk Arbitration
→ Apple exfat.fs
```

由于 block image 本身是 read-only attach，EDP 仍要求最终 mount 必须为 `MNT_RDONLY`；如果系统出现读写 mount，立即 unmount 并 fail closed。

注意：这意味着本分支是“**所有目标文件系统统一只读**”，不是只把 NTFS 强制只读。

---

## 4. 本地 raw image 的缓存策略

这是本方案最大的工程取舍。

### 4.1 必须接受的事实

在不使用虚拟块设备驱动的条件下，macOS 需要一个可随机访问、可 seek 的 backing image。

因此第一次挂载前需要先把解密后的逻辑卷物化到本地。

对于 120 GiB 逻辑卷，若有效解密吞吐约 55 MB/s，完整顺序扫描的理论量级约为几十分钟。

实际时间必须实测，不能用历史 55 MB/s 直接作为验收数据。

### 4.2 sparse raw image

导出器按固定大块扫描，例如：

```text
1 MiB / 4 MiB
```

若**解密后的整块**全部为 0，则只 `seek`，不实际写入，从而形成 sparse hole。

不能依赖 NTFS `$Bitmap`、ExFAT FAT 或任何文件系统分配表，因为那会破坏“文件系统无感知”原则。

因此 sparse 的实际节省比例取决于解密后内容，必须实测。

### 4.3 不承诺本地空间一定很小

如果目标文件系统的空闲区域仍保留历史非零数据，文件系统无感知模式无法知道这些 sector 是否“逻辑空闲”。

所以最坏情况：

```text
本地 raw image 实际占用 ≈ 整个逻辑卷大小
```

这必须在 UI 中提前检查可用空间并明确告知用户。

---

## 5. 明文缓存安全

直接生成 `volume.raw` 会在 Mac 本地形成解密后的明文数据。

这与当前流式 FUSE 方案相比是一个明显安全退化，不能隐藏。

### 5.1 PoC 阶段

仅用于验证架构时：

```text
/private/var/db/com.edp.usbvault/cache/<device-id>/volume.raw
```

要求：

```text
root:wheel
0700 directory
0600 image
```

卸载后立即删除缓存。

### 5.2 产品发布门槛

在正式发布前二选一：

**方案 A：要求系统盘已开启 FileVault。**

若未开启 FileVault，则拒绝建立明文本地缓存。

或者：

**方案 B：建立一个系统原生的临时加密 cache container。**

使用系统磁盘映像能力创建加密容器，使用随机会话密钥，把 `volume.raw` 放在该容器中；EDP 仍不解析目标文件系统。

方案 B 会增加一层系统 disk image，但不需要 Developer 账号、entitlement 或关闭 SIP。

正式实现前需要单独比较 A/B 的崩溃恢复和性能。

**本计划默认：PoC 可先使用严格权限的临时明文 cache；正式发布不允许在未确认主机存储加密策略的情况下长期留下明文 image。**

---

## 6. 文件系统无感知的代码 ratchet

产品代码必须满足静态扫描：

### 6.1 runtime 中禁止出现

```text
ntfs-3g
ntfslabel
NTFS-3G
EDPNTFSMountPolicy
EDPNTFSWriteSafety
com.apple.FinderInfo 特判
com.apple.ResourceFork 特判
EXFAT boot magic
NTFS boot magic
```

测试 fixture / 历史 docs 可以保留这些词，但生产 runtime、App、installer payload 不允许依赖。

### 6.2 installer 中禁止包含

```text
macFUSE.pkg
macfuse.fs
ntfs-3g
libntfs-3g
NTFS patch source
FSKit appex
KEXT
DriverKit extension
```

### 6.3 App 不链接 FSKit

当前 App 如果只是 UI/XPC，则删除：

```text
-framework FSKit
```

产品不注册任何 FSKit extension。

---

## 7. 用户交互

授权后 UI 只显示 EDP 层概念：

```text
设备已识别
密码已验证
正在准备只读卷
正在解密到安全缓存（xx%）
正在交给 macOS 挂载
只读卷已挂载
```

不显示：

```text
NTFS probe
NTFS-3G
macFUSE
FSKit backend
```

系统无法挂载时只显示：

```text
macOS 无法使用系统自带文件系统支持打开该卷。
```

不根据文件系统类型提供不同 fallback。

---

## 8. 实施阶段

### Phase A — 最小纯原生 PoC

只做 synthetic image，不碰真实 U 盘：

1. 准备一个已有 filesystem raw fixture。
2. 模拟 EDP SM4 ciphertext。
3. 使用现有 decrypt core 顺序导出 plaintext `volume.raw`。
4. `hdiutil attach -readonly -nomount`。
5. Disk Arbitration 默认 mount。
6. 验证 Finder 可读。
7. 验证最终 `MNT_RDONLY=true`。
8. detach。
9. 删除 cache。

验收关键点：

> mount engine 完全不传 filesystem type。

### Phase B — 多文件系统证明“无感知”

使用同一套产品代码验证不同 fixture：

- Apple 原生可读文件系统 fixture。
- NTFS fixture：必须由系统默认 NTFS 支持只读挂载。
- 一个 macOS 不支持的 filesystem fixture：必须稳定 fail closed，而不是进入任何第三方 fallback。

生产代码不得因 fixture 类型改变。

### Phase C — 删除生产文件系统依赖

1. 删除产品 NTFS mount 路径。
2. 删除 `EDPNTFSMountPolicy.swift` 的生产引用。
3. 删除 `EDPNTFSWriteSafety.swift` 的生产引用。
4. Clean installer 不再构建/打包 NTFS-3G。
5. Clean installer 不再嵌 macFUSE。
6. 删除 App 的 macFUSE/FSKit readiness UI。
7. raw authorization 从 readwrite 收紧到 readonly。
8. 生产 bridge 不链接任何 write API。

### Phase D — 真实 EDP 只读验证

只在 A-C 全绿后：

1. 真实 EDP raw device `O_RDONLY`。
2. 读取 EDP metadata。
3. 密码验证。
4. 只读顺序解密到 cache。
5. SHA/抽样验证 cache 内容稳定。
6. 系统 read-only attach。
7. Disk Arbitration mount。
8. Finder 浏览。
9. 从 Finder 复制若干文件**到 Mac 本地**。
10. TextEdit 打开文件验证读取。
11. 尝试在该卷创建/修改文件必须失败为只读。
12. eject / detach / cache cleanup。
13. 全过程确认物理 EDP 没有 write/pwrite。

---

## 9. CI / 测试门槛

新增一个独立 workflow，例如：

```text
Filesystem-Agnostic Native Read-Only E2E
```

CI 环境明确不得安装：

```text
macFUSE
NTFS-3G runtime（生产依赖）
第三方 filesystem driver
```

允许 test-only 工具在构造 fixture 阶段使用，但最终 product payload 必须通过静态扫描确认没有依赖。

必须检查：

```text
APP_HAS_FSKIT_EXTENSION=NO
PRODUCT_HAS_MACFUSE=NO
PRODUCT_HAS_NTFS3G=NO
RAW_DEVICE_OPEN_MODE=READONLY_ONLY
BLOCK_IMAGE_ATTACH=READONLY
FILESYSTEM_TYPE_ARGUMENTS=NONE
FINAL_MOUNT_READONLY=YES
```

---

## 10. 与当前读写分支的关系

原 `feat/macos26-native-fskit` 保留作为实验历史，不继续在本分支修：

```text
TextEdit RENAME_SWAP
Finder xattr/FinderInfo
NTFS-3G compatibility
macFUSE local/nonlocal semantics
NTFS write performance
```

这些问题在本分支架构里全部从产品职责中移除。

新分支不是在现有 NTFS-3G 方案上“改成 ro 参数”，而是重新定义边界：

```text
EDP = encrypted block/container product
macOS = filesystem product
```

---

## 11. 明确不做

本分支禁止：

- 申请 Apple Developer Program 解决 FSKit entitlement。
- 自签 FSKit module 并要求用户关闭 AMFI。
- 要求关闭 SIP。
- 要求 Recovery 中降低 Startup Security。
- 打包赤友/Paragon/Tuxera 等商业驱动。
- 逆向商业驱动后直接嵌入其二进制。
- 用 NTFS-3G 做隐藏 fallback。
- 在物理 EDP 上尝试 NTFS 写入。
- 为提高空间效率而解析 NTFS/ExFAT allocation metadata。

---

## 12. 审核前需要用户确认的唯一架构取舍

在“不申请开发者账号、不关闭 SIP、不安装第三方驱动”的前提下，我建议接受：

> **首次挂载需要先把目标 EDP 逻辑卷完整顺序解密成一个本地 sparse raw image，然后再由 macOS 原生磁盘映像 + 文件系统栈只读挂载。**

它的优点：

- 系统环境最干净。
- 无 Apple entitlement。
- 无第三方 filesystem driver。
- EDP 完全不关心目标文件系统。
- NTFS 使用 Apple 默认只读实现。
- Finder/TextEdit 等语义全部由 Apple filesystem driver 提供。
- 真实 U 盘永远只读。

它的代价：

- 首次挂载不再是即时的。
- 需要扫描完整逻辑卷。
- 需要本地 cache 空间。
- 必须认真处理解密明文 cache 的存储安全。

**审核结论未明确前，本分支不继续写实现代码。**
