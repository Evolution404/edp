# EDP USB Vault — NTFS 读写优先与原生化重构计划

日期：2026-08-26  
目标分支：`feat/macos26-native-fskit`  
当前基线：`5d3decf`  
目标平台：macOS 26+

## 1. 总体目标

本阶段按以下优先级执行：

1. **先把 NTFS 真正读写链路验证并稳定下来。**
2. 在不破坏已验证的 ExFAT / EDP 加解密 / DiskImages2 链路前提下，逐步移除生产路径中不必要的命令行调用和轮询。
3. 将用户侧产品形态收敛为 SwiftUI App + 原生系统服务，命令行工具只保留为开发/诊断入口，不作为最终用户工作流。
4. 对暂时无法替代的底层依赖（macFUSE、NTFS-3G、DiskImages2 private API）明确边界，不为了“纯 Swift”而重复实现成熟文件系统。

---

# Phase A — NTFS 读写优先

## A0. 当前事实基线

已经确认：

- EDP SM4 加解密随机读写：通过。
- EDP encrypted writable block abstraction：通过。
- macFUSE 5.x FSKit backing：通过。
- DiskImages2 writable block publication：通过。
- native ExFAT 格式化、写入、卸载、重挂、读取：通过。
- bundled NTFS-3G 2026.7.7 可重复构建：通过。
- `ntfs-3g.probe --readwrite` 对 clean NTFS fixture：通过。
- `ntfslabel`：通过。
- NTFS-3G 已经能够在 macOS 26 CI 上以 `backend=fskit` 建立读写 mount：通过。

当前最新 CI：

- workflow：`EDP Crypto + NTFS-3G Read/Write E2E`
- run：`32914814798`
- commit：`5d3decf`
- 结果：失败。

失败已经收敛到：

```text
NTFS_MOUNT_LINE=macfuse://... on /Volumes/EDPNTFSRW (... fskit ...)
RESULT=BUNDLED_NTFS3G_IMAGE_FSKIT_MOUNTED_READWRITE
```

随后测试写入：

```text
/Volumes/EDPNTFSRW/EDP-RW/proof.bin
```

出现 `ENOENT`。

这说明当前首要问题不是 NTFS metadata / probe / read-write capability，而是：

> **NTFS-3G + macFUSE FSKit mount 建立后生命周期不稳定，挂载点可能在进入实际 I/O 前自动消失或 NTFS-3G 进程提前退出。**

因此后续禁止继续通过修改写文件路径等方式掩盖问题，必须先确认 mount 生命周期。

## A1. 精确定位 NTFS mount 生命周期

### 要做

在 `probe-edp-crypto-ntfs-readwrite.sh` 中增加明确阶段标记和状态采样：

1. NTFS-3G 启动前记录 PID。
2. mount 出现后立即验证：
   - `kill -0 $NTFS_PID`
   - mount table 中 mountpoint 存在
   - `stat()` mountpoint 成功
   - 根目录 `readdir` 成功
3. 100 ms / 500 ms / 1 s 后再次重复上述检查。
4. 在第一次实际 `mkdir` 前再次确认进程和 mount 均存在。
5. NTFS-3G 一旦退出，必须记录 exit status 和完整 stderr。
6. 抓取 macFUSE / FSKit 相关 unified log，限定在测试窗口内。
7. teardown 全部 bounded，不允许 CI 再因清理 hang 而误报。

### 验收标准

必须能明确回答：

- NTFS-3G 是否自行退出？
- 如果退出，exit code 是什么？
- mount 是由谁撤销的？
- 是 FSKit local/nonlocal module 选择问题、source 类型问题，还是 NTFS-3G FUSE 生命周期问题？

在回答上述问题前，不进入真实 U 盘写入。

## A2. 固化正确的 NTFS-3G FSKit 启动方式

根据 A1 结果，只保留一个产品路径。

重点比较：

- local FSKit module vs nonlocal FSKit module。
- 直接把 decrypted `volume.raw` 作为 source vs 先通过 DiskImages2 发布 `/dev/diskN`。
- root daemon 启动 vs console user 启动。
- `no_detach` 的实际行为。
- macFUSE mount service 对 backing source 类型的约束。

### 选择原则

优先级：

1. 稳定性。
2. 数据一致性。
3. 可自动挂载。
4. 最少权限。
5. 最少中间层。

如果 NTFS-3G 可以稳定直接从 decrypted image / `volume.raw` 工作，则 NTFS 路径不强制经过 DiskImages2。

如果只有 `/dev/diskN` 路径稳定，则保留 DiskImages2。

**ExFAT 与 NTFS 不要求为了架构形式一致而强行走完全相同的末端路径。**

## A3. 完成 synthetic NTFS 真正读写 E2E

必须覆盖：

1. 创建 clean NTFS fixture。
2. 加密成 EDP ciphertext image。
3. 启动 EDP random-access decrypt/write bridge。
4. NTFS-3G 挂载 RW。
5. 创建目录。
6. 创建 4 MiB+ 文件。
7. 顺序写。
8. 随机覆盖写。
9. rename。
10. delete 临时文件。
11. `fsync` / `sync`。
12. 卸载 NTFS。
13. 停止 EDP bridge。
14. 验证 ciphertext SHA 已变化。
15. 完整重新启动 bridge。
16. 重新挂载 NTFS。
17. 校验文件 SHA256 与第一次完全一致。
18. 验证被删除文件没有复活。
19. 再次 clean unmount。
20. `ntfs-3g.probe --readwrite` 再次确认卷仍为 clean writable。

### 必须连续通过

单次 CI success 不作为完成。

要求同一 commit：

- GitHub macOS 26 runner 连续 3 次通过。
- 每次完整 teardown。
- 无 orphan `ntfs-3g` / FUSE / `umount` 进程。

## A4. NTFS fail-closed 验证

产品必须拒绝：

- dirty / unclean NTFS。
- Windows hibernation / Fast Startup 状态。
- 无法确认安全写入状态的卷。

禁止使用：

- `force`
- `recover`
- `remove_hiberfile`
- 任何自动修改 Windows hibernation 状态的行为。

需要准备可重复 fixture，分别验证 `ntfs-3g.probe` 的拒绝路径和 EDP runtime 的错误传播。

## A5. 产品路径与测试路径统一

当前 CI probe 不能长期维护一套与 `product/EDPVaultRuntime.swift` 不同的 NTFS mount 参数。

目标：

- 把 NTFS 参数定义提取成共享代码/共享配置。
- CI 调用与产品 daemon 尽量走相同 mount engine。
- 防止测试通过但产品路径不同。

最终必须验证 Clean installer 内实际 bundled 的：

```text
ntfs-3g
ntfs-3g.probe
ntfslabel
libntfs-3g.90.dylib
```

而不是 Homebrew 版本。

## A6. 真实 U 盘 NTFS 验证

只有 A1-A5 全部完成后才进入。

### 安全前置条件

真实写入前不要求 1:1 占满磁盘空间的整盘镜像。**首选直接建立原始 EDP raw sparse image**：逻辑长度与原物理盘完全一致，但连续全 0 区域保持 hole，只让实际非零 extents 占用物理空间。

2026-08-26 已对真实 `disk5` 完成只读抽样验证，确认该方案可行：

- EDP type-2 数据区起点为 LBA 20480；该位置为非零。
- NTFS MFT 对应物理位置（数据区相对约 3.0 GiB）为非零，证明读取到的是实际密文数据。
- 从隐藏数据区起点开始，以 256 MiB 为步长抽取 442 个 4 KiB raw block：404 个全 0、38 个非零，抽样零块比例约 91.4%。
- 数据区相对 +8 GiB、+16 GiB、+32 GiB、+64 GiB、+96 GiB、+110 GiB 的 1 MiB raw window 均为 100% 全 0。
- 数据区末尾 4 KiB 仍有非零内容，因此备份必须保持完整逻辑长度和尾部 extents，不能简单按最后一个常规文件截断。

这推翻了之前“EDP 空闲区原始密文通常会是随机非零”的假设。对当前真实 EDP 介质而言，大量未使用区域在**物理 raw 层本身就是 0**，因此不需要先解密并解析 NTFS `$Bitmap` 才能获得高压缩率的备份。

首选策略：

1. 对整个物理 `/dev/rdiskN` 做只读扫描，生成与原盘逻辑容量完全一致的 sparse raw image。
2. 连续全 0 extents 不实际写入 backing storage；所有非零 extents 按原始物理 offset 原样保存。
3. 因为备份对象是整个 raw disk，所以 MBR/启动区、LBA4/LBA7/LBA11/LBA12、隐藏 NTFS 数据区、MFT、backup boot sector、尾部结构以及尚未识别的 EDP 元数据都会一起保留，无需预先理解每一种结构。
4. manifest 记录原盘逻辑尺寸、sector size、扫描 chunk size、非零 extent 的 offset/length、每个 extent SHA256，以及 sparse image 的实际占用空间。
5. 创建完成后将 sparse raw image 作为真实 EDP 盘的只读替身，走现有 LBA11/LBA12 + SM4 解密链，验证 NTFS 能正常识别和挂载。
6. 对镜像中的当前可读文件生成路径/大小/mtime/SHA256 清单，并与真实盘读到的结果比对。
7. 必须完成一次 sparse image 恢复/挂载演练并通过文件 SHA256 校验后，才允许真实物理 NTFS 写入。

NTFS `$Bitmap` / `ntfsclone` 仍保留为第二层优化方案：如果完整 raw 扫描发现某些未分配区并非 0，或者 raw sparse image 实际占用明显高于有效数据量，再采用 filesystem-aware used-extents backup；当前不把它作为第一方案。

没有通过恢复校验的 sparse/minimal backup，不做真实物理 NTFS 写入。

### 真机验收

- 插盘自动识别。
- 密码校验。
- Finder 出现 NTFS 卷。
- 创建文件。
- 大文件写入。
- 随机写。
- rename/delete。
- 安全弹出。
- 拔插。
- 自动重挂。
- SHA256 一致。
- Windows 机器读取并验证。
- Windows 写入后回到 Mac 再验证。

---

# Phase B — 生产路径原生化

原则：**不在 NTFS 尚未稳定前大规模重构底层。**

每一步必须保持 Phase A 和 ExFAT CI 继续通过。

## B1. 移除 `ioreg` 命令行依赖

当前：

```text
Process -> /usr/sbin/ioreg
```

改为：

- IOKit / IOUSBHost 原生 API。
- 直接读取 USB VID/PID、device tree identity。
- 建立稳定的 physical EDP device model。

验收：

- 不启动 `ioreg` 子进程。
- 真实 Lexar EDP VID/PID 与当前结果一致。
- synthetic/unit fixture 保留。

## B2. 移除 `diskutil list/info` 设备发现依赖

当前：

```text
Process -> diskutil list/info -plist
```

改为：

- Disk Arbitration。
- IOKit block storage properties。

读取：

- BSD name。
- whole disk。
- external/internal。
- size。
- removable。
- media name。
- device tree path / registry association。

验收：

- daemon discovery 不再启动 `diskutil`。
- 插入/拔出识别结果与当前实现一致。

## B3. 从 2 秒轮询改为事件驱动

当前：

```swift
while true {
    discoverEDPDisks()
    sleep(2)
}
```

改为：

- Disk Arbitration callbacks。
- IOKit matching / termination notification。

目标：

```text
USB inserted
 -> callback
 -> validate EDP
 -> mount

USB removed
 -> callback
 -> cleanup session
```

保留低频 reconciliation 只作为异常恢复，不作为主检测机制。

## B4. 移除 `diskutil mount/unmount/eject`

改为 Disk Arbitration：

- `DADiskMount`
- `DADiskUnmount`
- `DADiskEject`

ExFAT 优先走 Apple native filesystem + Disk Arbitration。

验收：

- ExFAT E2E 不调用 `diskutil`。
- 自动挂载和拔盘恢复保持通过。

## B5. 移除 `/sbin/mount` / `/sbin/umount`

mount 状态查询改为：

- `getmntinfo()`
- `statfs()` / `getfsstat()`

卸载优先：

- Disk Arbitration。
- 对 macFUSE mount 使用可控的 macFUSE API / mount lifecycle，而不是 shell `umount`。

必须特别吸取已经出现过的 cleanup race：

> 不允许先杀 filesystem process 再尝试卸载 active mount。

## B6. ServiceManagement / XPC 替代用户可见 CLI 工作流

当前：

```text
edp-vaultctl authorize
edp-vaultctl revoke
edp-vaultctl daemon
launchctl kickstart
```

最终：

```text
EDP USB Vault.app
    -> SwiftUI
    -> XPC / privileged service
    -> mount engine
```

目标：

- 用户不需要 Terminal。
- App 内完成首次授权。
- App 内显示设备状态。
- App 内 revoke / eject / diagnostics。
- background service 由 ServiceManagement 管理。

`edp-vaultctl` 可以保留为开发/维修工具，但不能成为正常用户路径。

## B7. Keychain 替代自管 master.key

当前：

```text
/var/db/com.edp.usbvault/master.key
credentials.json + AES-GCM
```

目标：

- Keychain Services。
- 每个 EDP device ID 独立 credential item。
- 评估 Touch ID / user presence 作为可选策略。
- daemon 所需 unattended automount 与 Keychain access policy 必须兼容。

这里不能为了“更原生”破坏自动挂载体验，因此先做威胁模型和 access-group / privileged-helper 方案，再迁移。

---

# Phase C — 底层非原生组件边界

以下三项不在第一轮原生化中强行消除。

## C1. NTFS-3G：保留

原因：

- macOS 没有公开可写 NTFS filesystem API。
- 自己实现 NTFS writable driver 风险极高。
- NTFS-3G 已成熟且可审计。

要求：

- 固定版本与 SHA256。
- bundled runtime 可重复构建。
- 明确 GPL 许可和 source distribution。
- 作为内部 filesystem engine，不暴露 CLI 给用户。

## C2. macFUSE：暂时保留

当前使用 macFUSE 5.x 的 FSKit backend，不使用 legacy kernel backend。

保留原因：

- 它当前提供了最可行的 userspace filesystem / image bridge。
- Apple 公开 FSKit API 本身不能直接发布一个任意 transformed block device 给另一个 filesystem 使用。

后续单独研究是否存在公开 Apple API 可完全替代。

在没有等价稳定替代前，不删除已工作的 macFUSE 链路。

## C3. DiskImages2：逐步隔离

DiskImages2 是 Apple 自己的 framework，但属于 PrivateFramework。

目标：

- 把所有 DiskImages2 使用集中进单独 adapter。
- 上层只依赖抽象 `BlockDevicePublisher`。
- ExFAT/NTFS mount engine 不直接了解私有类。
- 后续如果找到公开替代，可以只替换 adapter。

同时把当前 Objective-C `DiskImages2Attach.m` helper 改造成库/Swift bridge 的可行性单独评估。

---

# Phase D — 最终产品形态

目标架构：

```text
EDP USB Vault.app (SwiftUI)
        |
        +-- Device UI / status / authorization
        |
        +-- XPC privileged service
                |
                +-- IOKit / IOUSBHost
                +-- Disk Arbitration
                +-- Keychain
                +-- Swift EDP Core
                |     +-- LBA metadata
                |     +-- password validation
                |     +-- SM4
                |     +-- random-access encrypted block I/O
                |
                +-- Block publication adapter
                |     +-- macFUSE FSKit
                |     +-- DiskImages2 (isolated private adapter)
                |
                +-- Filesystem engine
                      +-- Apple ExFAT
                      +-- bundled NTFS-3G
```

用户最终体验：

1. 安装 App。
2. 按 Apple 要求启用必要的 FSKit/macFUSE component。
3. 插入 EDP U 盘。
4. App 首次提示输入密码。
5. 可选择记住设备。
6. Finder 自动出现卷。
7. 后续插盘自动挂载。
8. 菜单栏/App 一键安全弹出。
9. 无 Terminal、无用户可见 shell command。

---

# 执行顺序

严格按以下顺序：

```text
A1  NTFS mount 生命周期根因
 -> A2 固化 NTFS mount 路径
 -> A3 synthetic NTFS 完整 RW/remount E2E
 -> A4 dirty/hibernated fail-closed
 -> A5 CI/产品路径统一
 -> A6 有已验证最小充分备份后的真实 EDP NTFS 写入

 -> B1 IOKit 替代 ioreg
 -> B2 Disk Arbitration 替代 diskutil discovery
 -> B3 事件驱动替代轮询
 -> B4 Disk Arbitration mount/unmount/eject
 -> B5 移除 mount/umount CLI
 -> B6 SwiftUI + XPC + ServiceManagement
 -> B7 Keychain

 -> C 阶段继续隔离底层依赖
 -> D 完成最终产品体验
```

---

# 每阶段硬性质量门槛

任何重构必须满足：

- Swift 6 strict typecheck 通过。
- Native Swift Fast Checks 通过。
- EDP metadata/password/key derivation 测试通过。
- encrypted random read/write 测试通过。
- ExFAT E2E 不回归。
- NTFS E2E 一旦通过后不得回归。
- macOS 26 GitHub Actions 通过。
- teardown 不遗留 disk/mount/process。
- 真实物理写入必须先完成并验证 **raw sparse backup**；逻辑镜像保持原物理盘全尺寸，连续全 0 extents 保持 hole，所有非零 raw extents 按原 offset 原样保存。只有 raw sparse 实际占用异常偏大或无法通过恢复验证时，才降级到 NTFS `$Bitmap` / `ntfsclone` 的 filesystem-aware used-extents 方案。

---

# 当前审核决策点

在开始实现前，需要确认以下架构原则：

1. **NTFS 读写稳定性优先于原生化重构。**
2. **不追求所有底层实现都用 Swift；NTFS-3G 暂时保留。**
3. **用户路径必须原生化：SwiftUI + IOKit + Disk Arbitration + ServiceManagement/XPC + Keychain。**
4. **macFUSE 暂时保留，只使用 FSKit backend。**
5. **DiskImages2 作为 private adapter 隔离，而不是让业务层直接依赖。**
6. **如果 NTFS 直接从 decrypted image 挂载比 DiskImages2 路径更稳定，允许 ExFAT 和 NTFS 使用不同末端路径。**
7. **没有通过恢复校验的 raw sparse backup 前，不进行真实 EDP NTFS 写测试。当前真实盘已验证 raw 层存在大面积全 0 区域，因此默认直接对完整 EDP 物理盘生成全逻辑尺寸 sparse image；NTFS allocation-aware 备份只作为第二方案。**
8. **后续只读 raw 验证不得反复要求管理员密码。** 优先使用受限 helper / privileged service：只开放 `O_RDONLY + pread`，不提供写接口；开发阶段可使用临时只读 helper，最终产品由 XPC privileged service 统一管理原始设备访问。禁止为了方便长期修改用户组、长期放宽 `/dev/rdiskN` 权限或保存管理员密码。

本文件审核通过后，再开始按 A1 顺序修改实现。
