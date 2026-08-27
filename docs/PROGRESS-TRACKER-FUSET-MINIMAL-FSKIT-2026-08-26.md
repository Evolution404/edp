# EDP USB Vault — FUSE-T Minimal / macFUSE Local 产品化实时进度追踪

日期：2026-08-26 起  
最后更新：2026-08-27  
分支：`test/fuset-minimal-fskit-bridge`  
当前已验证产品代码 HEAD：`116e77067bd200e9dc4d681a26f1fa3af21eaaca`  
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
- `3e82b2e`：将 `installer/build-transport-backends.sh` 的 Git mode 正式修为 `100755`，并让 Clean Installer 在当前测试分支产生 exact-head 证据。
- `ac8872a`：Clean Installer verifier 对齐 current-only raw-fd3 / transport 架构，删除已淘汰 `sys.openfile.readwrite.*` 正向假设，增加正式路径正/负 contract。
- `f85ea35`：XPC peer signer policy 收口为“双轨同签名边界”：有 Apple Team ID 时必须同 Team；双方均无 Team ID 时必须 exact leaf certificate 相同；纯 ad-hoc 继续拒绝。
- `79a876e`：Clean Installer CI 使用无 Team ID 的临时证书，实际覆盖 exact-leaf-certificate fallback 并执行安装后 XPC roundtrip。
- `116e770`：恢复已验证的逐组件 `productbuild --package` Distribution synthesis；保留 runtime/App 使用同一 signing identity 的必要改动。

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
| L11 | ✅ | Clean Installer | run `33047939672` 完整通过 build → verifier → writable DiskImages2 → component install → daemon enable → XPC roundtrip → artifact upload |

## 2026-08-27 — Product Lifecycle E2E 收口

原始红灯 `33044841240` 不是 runtime 行为失败，而是 workflow helper 编译 source list 不完整：`EDPNativeSystem.swift` 的 `EDPFileRawDevice / EDPMetadataProbe / EDPVolumeMetadata` 等依赖没有参与 `swiftc`。

处理过程：

1. `dff7a5c` 只补齐 helper source closure：`EDPRawIO.swift`、`EDPMetadataProbe.swift`、`EDPCrypto.swift`、`EDPVolumeMetadata.swift`、`EDPFileRawDevice.swift`、`EDPNativeSystem.swift`、`EDPBlockDevicePublisher.swift`。
2. run `33045515006` 已证明 helper 编译成功、正式 provider 选择成功；随后仅暴露 workflow 使用 `|&`，与 macOS runner 的 Bash 3.2 不兼容。
3. `769e3c8` 改为 `2>&1 | tee`。run `33045794164` 进一步证明 fixture、backend、provider、helper 均成功，但首次 MFMount 前报 `File system extension not enabled`；未进入 DiskImages2 或 teardown，因此不是生命周期回归。
4. `1791b78` 将 Product E2E 的 FSKit enablement 对齐已绿 Direct Encrypted Local workflow：同时启用 Generic + Local、写入两项 `enabledModules.plist`、`chmod 600`、重启 FSKit services，并用 `pluginkit` 硬断言两个 module 都 enabled。
5. exact-head run `33046142930` 全绿。

`33046142930` 的关键实证：

- macOS `26.5.2` / Xcode `26.6` hosted runner。
- macFUSE `5.3.3` 安装、签名和 notarization 校验成功。
- `io.macfuse.app.fsmodule.macfuse` 与 `io.macfuse.app.fsmodule.macfuse-local` 均 enabled。
- `RESULT=PRODUCT_MACFUSE_FSKIT_MODULES_ENABLED`。
- `RESULT=EDP_REAL_METADATA_FILESYSTEM_FIXTURE_READY`。
- `RESULT=SYNTHETIC_PHYSICAL_EDP_READY`。
- `RESULT=EDP_TRANSPORT_BACKENDS_BUILT`。
- product transport binary 直接链接 `MFMount.framework`，无 libfuse dylib dependency。
- `PROVIDER_BACKEND=macfuse-local`，`RESULT=PRODUCT_PROVIDER_LOCAL_SELECTED`。
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

因此 Product Lifecycle E2E 已不再只是 contract test，而是完整验证正式 provider → Direct MFMount → encrypted RW → `volume.raw` → DiskImages2 → Apple ExFAT/Finder → 系统卸载 → remount/persistence 的产品闭环。

## 2026-08-27 — Clean Installer release gate 收口

### 1. 原始 executable-bit 红灯

历史 run `33044779433` 是真实 macOS 26 runner 上的代码/打包失败，不是 cancelled、zombie 或 no-runner：

```text
installer/build-clean-installer.sh: line 102:
installer/build-transport-backends.sh: Permission denied
```

根因是 Git 将 `installer/build-transport-backends.sh` 记录为 `100644`，而 `build-clean-installer.sh` 与 `build-native-installer.sh` 都直接执行该脚本。

`3e82b2e` 将 Git mode 正式改为 `100755`。同 exact HEAD：

- Product Lifecycle regression `33046590862` — success。
- Transport Backend Builder `33046590874` — success。
- Clean Installer `33046590866` 已完整跨过 `Build clean combined installer`，证明原 Permission denied 根因关闭；随后暴露的是 verifier 自身 current-only 漂移。

### 2. verifier current-only 漂移

`33046590866` 的下一红灯发生在 package verifier：旧脚本仍要求 App binary 包含已经随原生菜单栏重构删除的 `sys.openfile.readwrite.*` AuthorizationDB marker。

当前正式 raw-device ownership 已是：

```text
signed App
  -> privileged root XPC daemon
  -> edp-console-exec opens discovered whole /dev/rdiskN O_RDWR
  -> raw fd pinned to fd 3
  -> drop to console user
  -> selected transport backend (default macfuse-local)
```

`ac8872a` 将 verifier 改为 current-only 正/负 contract：

- package 必须包含 `edp-mfmount-local-readwrite`。
- App 不得重新包含退休的 `sys.openfile.readwrite.*`。
- 必须证明 `edp-vaultctl → edp-console-exec → /dev/rdiskN → fd3 → macfuse-local` marker 链。
- 保留生产 NTFS policy、`--device-auth-readonly` 负断言、dylib linkage、source hash、help smoke、writable DiskImages2 system test。

run `33046921087` 已通过 package build、上述 verifier、writable DiskImages2 和 component install，并成功得到 `EDP_SERVICE_MODE=legacy / EDP_SERVICE_STATUS=enabled`；最后仅在 XPC smoke 被拒绝。

### 3. XPC signer hardening 与 Clean CI 签名模型对齐

XPC 红灯不是 daemon readiness race。历史成功 run 已证明同一 legacy install 后可立即 roundtrip；版本差分定位到原生产品安全加固：`EDPXPCPeerValidator` 新增了 App/daemon 同 TeamIdentifier 要求，而 Clean builder 仍使用 ad-hoc runtime 签名。ad-hoc 没有 TeamIdentifier，当前 daemon 因而正确拒绝。

曾用 CI 自签证书验证能否通过 OU 构造 Team ID；run `33047514649` 明确输出 `TeamIdentifier=not set`，因此“伪造 Apple Team ID”路径被排除，不再尝试。

正式修复 `f85ea35` 保留 Apple 签名安全边界，并对非 Apple 开发/CI 证书定义严格 fallback：

```text
peer + daemon 都有 TeamIdentifier
  -> 必须 exact same TeamIdentifier

peer + daemon 都没有 TeamIdentifier
  -> 必须双方都有 leaf signing certificate
  -> leaf certificate DER 必须完全相同

只有一方有 TeamIdentifier
  -> reject

纯 ad-hoc（无 Team、无 leaf certificate）
  -> reject
```

原有 `SecCodeCheckValidity`、App bundle identifier、固定安装路径、root ownership、禁止 group/world write 等检查全部保留。

`79a876e` 的 Clean workflow 生成一次性 `EDP CI Code Signing` 证书，明确断言 `TeamIdentifier=not set`，并让 runtime daemon 与 App 使用同一 leaf certificate，以真实覆盖该 fallback；不是关闭 peer validation。

### 4. packaging 回归修复

签名调整过程中曾误把已验证的 Distribution synthesis 改成只传 `--package-path`，run `33047657775` 因 `productbuild --synthesize` 缺少 product contents 在 package build 阶段失败。这是 CI/installer harness 回归，不是产品 runtime 或 XPC fallback 失败。

`116e770` 恢复原有逐个 `components/*.pkg` → `--package` 的 synthesis，再用 `--distribution + --package-path` 生成最终 product；同时只保留必要签名变化：runtime 与 App 使用同一个 `APP_SIGN_IDENTITY`。

### 5. 最终 exact-head 全绿

Clean Installer run `33047939672` @ `116e77067bd200e9dc4d681a26f1fa3af21eaaca`：**completed / success**，真实 GitHub-hosted `macos-26-arm64` runner。

关键证据：

- `RESULT=CI_CERTIFICATE_SIGNING_IDENTITY_READY`；证书 `Authority=EDP CI Code Signing`，`TeamIdentifier=not set`。
- `RESULT=NTFS3G_REPRODUCIBLE_RUNTIME_BUILT`。
- `RESULT=EDP_TRANSPORT_BACKENDS_BUILT`。
- `RESULT=EDP_CLEAN_COMBINED_INSTALLER_BUILT`。
- verifier：`RESULT=LEGACY_XPC_DAEMON_PACKAGED`。
- verifier：`RESULT=NATIVE_SWIFTUI_XPC_APP_PACKAGED`。
- verifier：`RESULT=PRODUCTION_NTFS_RUNTIME_CONTAINS_NO_FIXTURE_TOOLS`。
- verifier：`RESULT=CURRENT_RAW_FD3_TRANSPORT_PATH_ENFORCED`。
- verifier：`RESULT=PRODUCTION_APPLE_NTFS_POLICY_ENFORCED`。
- writable DiskImages2 system test 通过，最终 `RESULT=EDP_CLEAN_INSTALLER_VERIFIED`。
- 实际 component install：`installer: The install was successful.`。
- 安装后的 App 与 `/Library/Application Support/EDP USB Vault/bin/edp-vaultctl` 均为 `Authority=EDP CI Code Signing`、`TeamIdentifier=not set`。
- `RESULT=CLEAN_INSTALL_CERTIFICATE_FALLBACK_READY`。
- `EDP_SERVICE_MODE=legacy`，`EDP_SERVICE_STATUS=enabled`。
- `XPC_SMOKE_DETAIL=diagnostics contract OK`。
- `RESULT=PRIVILEGED_XPC_ROUNDTRIP_OK`。
- `RESULT=LEGACY_XPC_SERVICE_SMOKE_OK`。
- artifact `EDP-USB-Vault-0.5.0-arm64-Clean` 上传成功，Artifact ID `9636443568`；artifact ZIP SHA-256 `1c50b239f4f61b0706d59e07f26cb353429d1c019376495ab756fc225273aae8`。

结论：Clean Installer 已从“能构建”提升到真实 `build → verify → writable DiskImages2 → install → privileged service enable → signer validation → XPC roundtrip → artifact` 全闭环，当前 scoped hosted release gate 关闭。

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

新增产品化关键验证：

- Product Lifecycle `33046142930` @ `1791b78d181feb5fbb517df4e0197e7608aac828` — success。
- Product Lifecycle regression `33046590862` @ `3e82b2ec895079fd576c6c7f438e565a3901b267` — success。
- Transport Backend Builder `33046590874` @ `3e82b2ec895079fd576c6c7f438e565a3901b267` — success。
- Clean Installer `33047939672` @ `116e77067bd200e9dc4d681a26f1fa3af21eaaca` — success。

## 当前 release gate

| Gate | 状态 | 说明 |
|---|---|---|
| macFUSE Local lifecycle | ✅ | 根因关闭，禁止重开旧诊断 |
| L9 transport provider | ✅ | 正式 `macfuse-local` provider 已接入并实际运行 |
| L10 formal Product E2E | ✅ | `33046142930` 全绿；`33046590862` 回归同样全绿 |
| Clean Installer | ✅ | `33047939672` build/install/XPC/artifact 全闭环 |
| XPC signer boundary | ✅ | Apple Team-ID 同 Team；无 Team-ID 时 exact leaf cert；纯 ad-hoc 拒绝；真实 XPC roundtrip 已验证 fallback |
| macFUSE version | ✅ | 产品固定 5.3.3 |
| FUSE-T-only architecture | ➖ | 历史 PoC/回归参考，不是当前正式产品方向 |

**本轮 `macfuse-local transport provider + DiskImages2 + Apple filesystem/Finder + Clean Installer` 的 GitHub-hosted release gate 已全部关闭。**

这不自动替代此前文档中另行定义、需要物理设备或商业发布条件才能完成的 gate（例如真实 EDP USB 拔插/sleep-wake、物理介质最终验收、第三方商业许可）；这些属于后续 release 阶段，不应与本轮 hosted 产品闭环混为一谈。

## 执行约束

- 每次继续工作前先读取远端最新 HEAD 和最新 Actions。
- 只使用 GitHub 远程仓库和 GitHub Actions；不依赖 Mac、本地 worktree。
- 区分代码失败与 cancelled/zombie/no-runner。
- 生命周期根因已关闭；不得重新堆 MFChannelClose、DA whole-unmount/eject、private XPC、root-session MFMount 诊断。
- 产品 teardown 不得改为先 `Process.terminate()`。
- 当前产品架构必须保持 `macfuse-local transport provider + DiskImages2 + Apple filesystem/Finder`。
