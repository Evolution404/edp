# EDP USB Vault — FUSE-T Minimal / macFUSE Local 产品化实时进度追踪

日期：2026-08-26 起  
最后更新：2026-08-27  
分支：`test/fuset-minimal-fskit-bridge`  
当前已验证产品代码 HEAD：`1791b78d181feb5fbb517df4e0197e7608aac828`  
配套计划：`docs/PLAN-2026-08-26-fuset-minimal-fskit-bridge.md`

> 本文件现在以“当前产品架构与 release gate”为主。此前 FUSE-T thin bridge、macFUSE Local 生命周期诊断和淘汰路径的逐轮原始记录仍保留在本文件的 Git 历史（截至 `6ccc930` 及更早提交），不再在当前正文重复展开。

## 当前正式产品方向

正式产品路径已经从早期 FUSE-T-only PoC 收口为：

```text
physical / synthetic EDP raw device
  -> LBA11/LBA12 + password validation + file-key derivation
  -> EDP encrypted random-access RW adapter
  -> EDPTransportProvider(.macfuse-local)
  -> Direct MFMount + macFUSE 5.3.3 Local FSKit transport
  -> hidden volume.raw
  -> DiskImages2 writable publish
  -> /dev/diskN
  -> Apple filesystem driver (ExFAT verified)
  -> Finder
```

产品固定 macFUSE `5.3.3`。FUSE-T 仍保留为历史实验/回归参考，但**不再是当前正式产品架构**。

## 已关闭：macFUSE Local 卸载生命周期

根因已经确定并修复，不再重开 MFChannelClose、Disk Arbitration whole-unmount/eject、private XPC、root-session MFMount 等实验。

根因：`macfuse-local` 的 `FSVolume.deactivate()` 会发送 `FUSE_DESTROY` 并等待 reply；EDP Direct server 原来收到 DESTROY 后只停止 receive loop，没有返回 `fuse_out_header` success reply，形成：

```text
unmount(2, MNT_FORCE)
  -> FSVolume.deactivate()
  -> wait FUSE_DESTROY reply
  -> EDP server exits receive loop without reply
  -> permanent wait
```

修复提交：`1ad32b1 fix: reply to Local FSKit destroy request`。

正式卸载责任边界固定为：

```text
privileged unmount(2, MNT_FORCE)
  -> macOS VFS / FSKit
  -> Local FSVolume.deactivate()
  -> FUSE_DESTROY
  -> EDP server success reply
  -> Local extension device/deactivate
  -> virtual /dev/diskN detach
  -> transport bounded natural exit
```

产品代码不得改回“先 `Process.terminate()` 再卸载”。

生命周期最终证据：

- `33043742188`：macFUSE 5.3.2 / 5.3.3 两版本连续两轮 `mount → encrypted RW → privileged unmount → remount → marker persistence` 全绿。
- `33043742178`：5.3.2 encrypted Local transport success。
- `33043742169`：5.3.3 encrypted Local transport success。
- `33043742222`：Transport Backend Builder success。
- `33043742179`：Physical Product Adapter Contract success。

结论：5.3.2 与 5.3.3 在正确 Direct lifecycle 下没有需要继续追踪的行为差异；产品统一 pin 5.3.3。

## 产品化关键提交

- `9ad2261`：`EDPVaultRuntime` 接入 `EDPTransportRuntimePolicy / EDPTransportProvider / EDPTransportSession`，默认 `macfuse-local`。
- `c66702d`：credential validator 对齐 current-only Keychain API/schema/root ACL。
- `5275b45`：新增 macFUSE Local Product Lifecycle E2E。
- `6ccc930`：修复 Product Lifecycle E2E ExFAT fixture label。
- `dff7a5c`：补齐 Product Lifecycle `BlockLifecycle.swift` 的原生 Swift source closure。
- `769e3c8`：Product Lifecycle workflow 改用 macOS Bash 3.2 兼容的 stderr pipe。
- `1791b78`：Product Lifecycle 与已验证 Direct Local workflow 对齐，完整启用并断言 Generic + Local FSKit modules。

## 当前验收矩阵

| ID | 状态 | 任务 | 当前结论 |
|---|---|---|---|
| L1 | ✅ | encrypted Direct MFMount RW，无 libfuse | 已通过 |
| L2 | ✅ | Local FSKit + DiskImages2 + Finder 隐藏 | 已通过 |
| L3 | ✅ | 排除 `MFChannelClose()` 作为 volume unmount | 已关闭；只关闭 channel，不是系统 volume teardown |
| L4 | ✅ | 排除旧 shell / DA / eject / private-XPC 路径 | 已关闭，不再重复 |
| L5 | ✅ | 正式 privileged VFS teardown 边界 | root `unmount(2,MNT_FORCE)` → FSKit deactivate → DESTROY reply |
| L6 | ✅ | mount table/source 消失后同路径 remount | 5.3.2 / 5.3.3 均连续通过 |
| L7 | ✅ | 两轮 mount → RW → unmount → remount → encrypted marker persistence | run `33043742188` 全绿 |
| L8 | ✅ | 版本差异结论 | 无需继续追 5.3.2/5.3.3；产品固定 5.3.3 |
| L9 | ✅ | 正式产品 transport provider 接入 `macfuse-local` | provider/session/runtime policy、5.3.3 pin、backend builder 均已接入并由正式产品 E2E 实际使用 |
| L10 | ✅ | 正式产品 E2E | run `33046142930` 完整通过 encrypted mount → RW → DiskImages2 → Apple ExFAT/Finder → unmount → detach → remount → persistence |

## 2026-08-27 — Product Lifecycle E2E 收口

原始红灯 `33044841240` 不是 runtime 行为失败，而是 workflow helper 编译 source list 不完整：`EDPNativeSystem.swift` 的 `EDPFileRawDevice / EDPMetadataProbe / EDPVolumeMetadata` 等依赖没有参与 `swiftc`。

处理过程：

1. `dff7a5c` 只补齐 helper source closure：
   - `EDPRawIO.swift`
   - `EDPMetadataProbe.swift`
   - `EDPCrypto.swift`
   - `EDPVolumeMetadata.swift`
   - `EDPFileRawDevice.swift`
   - `EDPNativeSystem.swift`
   - `EDPBlockDevicePublisher.swift`
2. run `33045515006` 已证明 helper 编译成功、正式 provider 选择成功；随后仅暴露 workflow 使用 `|&`，与 macOS runner 的 Bash 3.2 不兼容。
3. `769e3c8` 改为 `2>&1 | tee`。run `33045794164` 进一步证明 fixture、backend、provider、helper 均成功，但首次 MFMount 前报 `File system extension not enabled`；未进入 DiskImages2 或 teardown，因此不是生命周期回归。
4. `1791b78` 将 Product E2E 的 FSKit enablement 对齐已绿 Direct Encrypted Local workflow：同时启用 Generic + Local、写入两项 `enabledModules.plist`、`chmod 600`、重启 FSKit services，并用 `pluginkit` 硬断言两个 module 都 enabled。
5. exact-head run `33046142930` 全绿。

`33046142930` 的关键实证：

- macOS `26.5.2` / Xcode `26.6` hosted runner。
- macFUSE `5.3.3` 安装、签名和 notarization 校验成功。
- `io.macfuse.app.fsmodule.macfuse` 与 `io.macfuse.app.fsmodule.macfuse-local` 均显示 enabled。
- `RESULT=PRODUCT_MACFUSE_FSKIT_MODULES_ENABLED`。
- `RESULT=EDP_REAL_METADATA_FILESYSTEM_FIXTURE_READY`。
- `RESULT=SYNTHETIC_PHYSICAL_EDP_READY`。
- `RESULT=EDP_TRANSPORT_BACKENDS_BUILT`。
- product transport binary 直接链接 `MFMount.framework`，无 libfuse dylib dependency。
- `PROVIDER_BACKEND=macfuse-local`。
- `RESULT=PRODUCT_PROVIDER_LOCAL_SELECTED`。
- hidden transport：`/dev/disk9 on /Volumes/.edp-product-e2e (macfuse, local, ..., fskit)`。
- DiskImages2 发布：`PUBLISHED_BSD=disk10`。
- Apple filesystem：`File System Personality: ExFAT`，`Volume Read-Only: No`。
- Finder 实际枚举到 `Product Created`。
- 第一轮：`RESULT=PRODUCT_USER_FILESYSTEM_UNMOUNTED` → `RESULT=PRODUCT_DISKIMAGES2_UNPUBLISHED` → `DIRECT_MFMOUNT_PRIVILEGED_UNMOUNT_RESULT=0 errno=0`。
- 加密 backing 确认发生变化：`RESULT=PRODUCT_ENCRYPTED_BACKING_CHANGED`。
- 同路径完整 remount 后 marker 与 atomic replace 持久化：`RESULT=PRODUCT_FILES_PERSIST_AFTER_FULL_REMOUNT`。
- 第二轮再次完成 user FS unmount、DiskImages2 unpublish 和 privileged transport unmount。
- transport 收到并成功回复 DESTROY：`DIRECT_MFMOUNT_DESTROY_RECEIVED=1`、`DIRECT_MFMOUNT_DESTROY_REPLIED=1`。
- transport 自然退出：`DIRECT_MFMOUNT_EXIT=0`。
- 最终：`RESULT=MACFUSE_LOCAL_PRODUCT_LIFECYCLE_E2E_PASS`。

因此 Product Lifecycle E2E 已不再只是 contract test，而是完整验证了正式 provider → Direct MFMount → encrypted RW → `volume.raw` → DiskImages2 → Apple ExFAT/Finder → 系统卸载 → remount/persistence 的产品闭环。

## 已通过的产品化回归

在 `5275b45` 基线上已通过：

- Native Production Path `33044776714`
- Transport Backend Builder `33044781707`
- Direct MFMount Internal Unmount Matrix `33044784039`
- Direct MFMount Encrypted Local Transport `33044787234`
- Physical Product Adapter `33044791031`
- FUSE-T Minimal `33044793706`
- FUSE-T RW regression `33044796341`
- Crypto + DiskImages2 RW E2E `33044798287`
- Provider Switch `33044800148`
- Transport Runtime Policy `33044802648`
- macFUSE 5.3.3 Runtime Policy `33044805320`
- FUSE-T Thin Product Contract `33044808654`

新增正式 Product Lifecycle exact-head：

- `33046142930` @ `1791b78d181feb5fbb517df4e0197e7608aac828` — **success**。

## 当前唯一 P0：Clean Installer

历史 run `33044779433` 是真实 macOS 26 runner 上的代码/打包失败，不是 cancelled、zombie 或 no-runner：

```text
installer/build-clean-installer.sh: line 102:
installer/build-transport-backends.sh: Permission denied
```

原因：Git 当前把 `installer/build-transport-backends.sh` 记录为 `100644`，但 `build-clean-installer.sh` 与 `build-native-installer.sh` 都直接执行该脚本。

下一步固定为：

1. 将 `installer/build-transport-backends.sh` Git mode 修正为 `100755`，不通过产品代码绕过。
2. 让 `Clean ExFAT + NTFS Installer` workflow 能在当前测试分支因该脚本/自身变更触发，以取得 exact-head CI 证据。
3. 验证 clean combined installer build、package verification、writable DiskImages2 mode、实际 component install、ServiceManagement/XPC registration smoke、artifact upload。
4. 同一 exact HEAD 重新跑 Product Lifecycle E2E，确认 installer mode 变更没有破坏正式产品闭环。
5. Clean Installer 与 Product Lifecycle 均绿后，本 tracker 再记录最终 release-gate 状态。

## 当前 release gate

| Gate | 状态 | 说明 |
|---|---|---|
| macFUSE Local lifecycle | ✅ | 根因关闭，禁止重开旧诊断 |
| L9 transport provider | ✅ | 正式 `macfuse-local` provider 已接入并实际运行 |
| L10 formal Product E2E | ✅ | `33046142930` 全绿 |
| Clean Installer | ⏳ | 待修 `build-transport-backends.sh` executable bit 并取得 exact-head green run |
| macFUSE version | ✅ | 产品固定 5.3.3 |
| FUSE-T-only architecture | ➖ | 历史 PoC/回归参考，不是当前正式产品方向 |

## 执行约束

- 每次继续工作前先读取远端最新 HEAD 和最新 Actions。
- 只使用 GitHub 远程仓库和 GitHub Actions；不依赖 Mac、本地 worktree。
- 区分代码失败与 cancelled/zombie/no-runner。
- 生命周期根因已关闭；不得重新堆 MFChannelClose、DA whole-unmount/eject、private XPC、root-session MFMount 诊断。
- 产品 teardown 不得改为先 `Process.terminate()`。
- 当前产品架构必须保持 `macfuse-local transport provider + DiskImages2 + Apple filesystem/Finder`。
