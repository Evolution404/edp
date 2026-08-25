# EDP USB Vault — macOS 26 当前状态与唯一实施方案

更新时间：2026-08-25  
分支：`feat/macos26-native-fskit`

> 本文件是该分支唯一的状态、架构和后续实施交接文档。若实现、README 或历史结论与本文冲突，以本文和最新可复现实验证据为准。

## 1. 产品目标

目标平台仅为 **macOS 26+**。

最终体验目标：

- 原生 Swift/SwiftUI App；
- 用户插入 EDP U 盘后输入密码即可使用；
- EDP 层只负责 metadata / key / SM4 / block translation；
- **不自行实现 exFAT/APFS/FAT/NTFS 等具体文件系统语义**；
- 解密后的块设备继续交给 macOS 原生磁盘与文件系统栈；
- Finder 中表现为正常磁盘卷；
- 不使用 `hdiutil` 作为产品 runtime 依赖；
- 不使用 DriverKit / `IOUserBlockStorageDevice` entitlement；
- 不要求降低 SIP 或 Apple Silicon 启动安全策略；
- 不恢复旧 Rust/Tauri 产品架构。

macOS 15.x 不再是产品目标。15.7.9 机器只用于真实 EDP fixture/cipher/plain 采集。

## 2. 当前唯一产品架构

2026-08-25 已通过 macOS 26 hosted Apple Silicon CI 完整 E2E 验证以下桥接链：

```text
physical EDP USB
  -> raw device
  -> EDP metadata / password verification
  -> key derivation + SM4 block translation
  -> transparent decrypted block view
  -> macFUSE 5.3.3, backend=fskit
  -> hidden FUSE mount containing volume.raw
  -> Private DiskImages2 attach(volume.raw)
  -> AppleDiskImages / IOMedia
  -> /dev/diskN
  -> Disk Arbitration / Apple native filesystem implementation
  -> Finder / normal macOS volume
```

关键设计原则：

1. **macFUSE 只提供透明随机读写 backing file，不解析任何具体文件系统。**
2. **DiskImages2 负责 regular file -> IOMedia/BSD block device。**
3. **macOS 原生文件系统栈负责 exFAT/APFS/FAT 等识别、挂载和文件语义。**
4. EDP 层面对的是 offset/length block I/O，不面对目录、文件名或 exFAT metadata。
5. 产品不再依赖“自研 FSKit 文件系统实现”作为主路径。

## 3. 为什么该方案成立

### 3.1 macFUSE FSKit 本身不是 block-device publisher

已验证 macFUSE 5.3.3 的 `backend=fskit` 可以在 macOS 26 上得到：

```text
macfuse://UUID on /Volumes/... (macfuse, ..., fskit, ...)
```

但 FUSE 内暴露的 `volume.raw` 仍然是 regular file，而不是 `/dev/diskN`。

因此单独使用 macFUSE 无法完成“透明块层 -> Apple 原生文件系统”的最后一跳。

### 3.2 Private DiskImages2 补上 regular-file -> block-device 桥

macOS 自带：

```text
/System/Library/PrivateFrameworks/DiskImages2.framework
```

PoC 通过运行时加载私有 framework，并使用：

```text
DIAttachParams initWithURL:error:
DiskImages2 attachWithParams:handle:error:
DIDeviceHandle BSDName
```

将 macFUSE FSKit 中的 `volume.raw` 成功发布为真实 BSD disk。

该 PoC：

- 没有链接 DriverKit；
- 没有申请 block-storage entitlement；
- 测试 executable 没有特殊开发者 entitlement；
- runtime 没有调用 `hdiutil`；
- 没有启用 macFUSE kernel backend；
- macFUSE 使用的是 FSKit generic backend。

DiskImages2 是 **private API**，这是当前架构明确接受的兼容性风险。产品必须在启动时做 capability probe，并把具体 selector/class 可用性当作 runtime contract，而不是 SDK contract。

## 4. 2026-08-25 macOS 26 完整 E2E 证据

GitHub Actions：

```text
workflow: macFUSE + DiskImages2 PoC
run:      32848875297
runner:   macOS 26.5.2 (25F84), arm64
Xcode:    26.6
macFUSE:  5.3.3
libfuse:  2.9.9
```

测试使用一个 128 MiB、支持随机读写的内存 backing，通过 macFUSE FSKit 暴露为：

```text
/Volumes/edp-macfuse-di2/volume.raw
```

实测关键标记：

```text
RESULT=POC_TOOLS_BUILT
RESULT=MACFUSE_FSKIT_BACKING_READY
RESULT=DISKIMAGES2_FRAMEWORK_LOADED
RESULT=DISKIMAGES2_PRIVATE_CLASSES_FOUND
RESULT=DI_ATTACH_PARAMS_CREATED
RESULT=DISKIMAGES2_ATTACH_OK
DI_BSD_NAME=disk8
RESULT=DISKIMAGES2_PUBLISHED_BSD_DEVICE
RESULT=DISKIMAGES2_CREATED_BLOCK_DEVICE
```

`diskutil info disk8` 实际报告：

```text
Device Node:       /dev/disk8
Device / Media Name: Disk Image
Protocol:          Disk Image
Disk Size:         134217728 Bytes
Device Block Size: 512 Bytes
Media Read-Only:   No
Virtual:           Yes
```

随后 macOS 原生磁盘栈直接在该虚拟块设备上创建 exFAT：

```text
Formatting disk8s1 as ExFAT with name EDPDI2TEST
RESULT=NATIVE_EXFAT_FORMAT_OK
```

系统自动挂载后进行了真实文件 I/O：

```text
PROOF=EDP macFUSE + DiskImages2 + native exFAT OK
RESULT=NATIVE_EXFAT_MOUNT_READ_WRITE_OK
```

最后正常 teardown：

```text
Volume EDPDI2TEST on disk8s1 unmounted
Disk disk8 ejected
RESULT=DISKIMAGES2_TEARDOWN_OK
RESULT=MACFUSE_FSKIT_DISKIMAGES2_NATIVE_FS_E2E_OK
```

这已经证明：

> **macFUSE FSKit 可以只充当透明 backing-file transport，Private DiskImages2 可以把该 backing file 发布成 macOS 原生块设备，随后 Apple 原生文件系统实现可以正常格式化、挂载和读写。**

因此“不自行实现 exFAT，只实现 EDP 块层”的架构在 macOS 26 上已经完成结构性验证。

## 5. 当前 EDP native core

现有纯 Swift EDP core 已包含：

- aligned window calculation；
- exact aligned segmented read loop；
- LBA4 serial / LBA7 reserved-sector recognition；
- LBA11 device identity；
- LBA12 decode / partition descriptor parsing；
- CRC32；
- password/key validation；
- SM4；
- encrypted partition byte translation；
- `EDPEncryptedPartitionReader`。

Native core 当前不依赖 Rust/C ABI bridge。

现有 deterministic/property/random coverage 保留 **3,200 cases**，外加 golden/negative vectors。

## 6. 仍未完成的关键证明

当前成功 PoC 的 backing store 是内存块设备，不是真实 EDP 加密分区。

因此还不能声称产品已经完成。剩余关键 gate 是：

```text
真实 EDP raw device
  -> LBA11/LBA12
  -> password/key
  -> SM4 transparent read/write translation
  -> macFUSE volume.raw
  -> DiskImages2 diskN
  -> existing native filesystem
  -> Finder
```

必须验证：

- DiskImages2 对真实 EDP 分区大小/随机 I/O 模式正常；
- read translation 与真实盘现有数据完全一致；
- write translation 能正确回写加密块且不破坏邻接数据；
- unaligned / partial-sector / multi-block writes 正确；
- flush/fsync/teardown 顺序不会造成文件系统损坏；
- 拔盘、App crash、DiskImages2 attach 失败时可安全恢复；
- 真实 exFAT 卷由系统直接识别并在 Finder 可读写。

在完成真实盘写路径证明前，默认先做 **read-only product milestone**。

## 7. Private DiskImages2 风险边界

DiskImages2 不是公开 SDK API，因此必须接受以下工程约束：

- Apple 可在 macOS 小版本或大版本中修改 class/selector/behavior；
- 不能依赖编译期 SDK 稳定性；
- App 启动时必须 `dlopen` + runtime selector probe；
- attach 功能必须有明确错误分类与兼容性诊断；
- 每个目标 macOS 更新都要自动跑 E2E；
- 不把 private selector 散落在业务代码中，集中封装为单一 `DiskImages2Bridge`；
- 版本不兼容时 fail closed，不尝试未验证 selector 猜测。

当前 macOS 26.5.2 实验表明普通测试 executable 可以成功调用 attach，不需要额外 private client entitlement；但该事实属于 runtime evidence，不视为 Apple 的公开兼容承诺。

## 8. macFUSE 使用边界

产品只使用 macFUSE 5.x 的 **FSKit backend**：

```text
backend=fskit
```

不使用：

- legacy kernel backend；
- kext data path；
- Reduced Security；
- 关闭 SIP；
- `/sbin/mount -F` 旧 FSKit 路径。

macFUSE 的职责非常小：只公开一个隐藏的 `volume.raw` random-access file。

后续应优先考虑直接用 macFUSE.framework/libfuse 在原生 App 进程中托管该 bridge，避免恢复常驻 helper daemon。

## 9. CI 与永久回归

新增永久架构回归：

```text
.github/workflows/macfuse-diskimages2-poc.yml
native/EDPFSKitPoC/Tools/DiskImages2Attach.m
native/EDPFSKitPoC/Tools/probe-macfuse-diskimages2.sh
```

该 workflow 的最终成功标记：

```text
RESULT=MACFUSE_FSKIT_DISKIMAGES2_NATIVE_FS_E2E_OK
```

这条测试应在以下变化后运行：

- macOS runner image 更新；
- macFUSE 版本更新；
- DiskImages2 bridge 修改；
- backing-file FUSE implementation 修改；
- 文件系统 attach/teardown 逻辑修改。

此前的 pure Swift EDP core、fixture、capture、SDK probes 继续保留，用于验证加密层和真实盘 evidence。

## 10. 下一步实施顺序

### P0 — 把成功 PoC 变成产品级 block bridge

1. 定义 `EDPBlockDevice` abstraction：`size / read(offset,length) / write(offset,data) / flush`；
2. 用现有 Swift EDP crypto/partition code 实现 decrypted block view；
3. 将 PoC 内存 backing 替换为该 `EDPBlockDevice`；
4. FUSE 只暴露固定隐藏文件 `volume.raw`；
5. 集中封装 `DiskImages2Bridge.attach/detach`；
6. 先以 read-only 真实 EDP 卷完成 Finder mount/read。

### P1 — 真实盘写支持

7. 增加 encrypted partial-write/read-modify-write；
8. 验证 filesystem metadata 写入、fsync、eject；
9. 断电/拔盘/进程 crash fault tests；
10. 再开启正常 Finder 写支持。

### P2 — 原生 App / 一键安装

11. SwiftUI 负责设备发现、密码、安全状态与 mount lifecycle；
12. macFUSE 首次安装/FSKit module approval 做一次性引导；
13. 后续插盘自动识别 -> 解锁 -> DiskImages2 attach -> Finder；
14. 卸载时反向执行 filesystem unmount -> DiskImages2 eject/detach -> FUSE teardown -> key zeroization。

## 11. 已废弃的产品方向

当前主方案不再继续：

- 自研 Swift exFAT reader/writer；
- 自己实现通用 filesystem namespace/FSVolume；
- 把 EDP 解密字节包装成第二个公开 `FSBlockDeviceResource` 的假想 FSKit module stacking；
- DriverKit `IOUserBlockStorageDevice`；
- macFUSE kernel backend；
- `hdiutil` 作为产品 runtime bridge；
- macOS 15 产品兼容；
- Rust/Tauri 作为最终产品架构；
- 常驻 helper daemon 作为必要数据路径。

原生 FSKit skeleton 与相关研究代码可以暂时保留作为历史/对照实验，但不再是产品主数据路径。

## 12. 当前结论

截至 2026-08-25，项目最重要的架构问题已经得到实验证明：

> **`macFUSE FSKit + Private DiskImages2` 可以在 macOS 26 上实现“用户态透明块视图 -> 系统 BSD disk -> Apple 原生文件系统 -> Finder”，因此 EDP USB Vault 不需要自行实现 exFAT。**

下一阶段应停止文件系统语义开发，把全部实现资源集中到 **真实 EDP block translation、lifecycle、安全写入和原生 App 集成**。
