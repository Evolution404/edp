# EDP Drive 完整自动化回归测试套件计划（2026-08-30）

## 1. 目标

建立一套**不依赖用户实际插入物理 U 盘**、能够自动覆盖 EDP Drive 关键介质识别、设备身份、插拔生命周期、raw access、凭据、挂载、读写、卸载、推出、服务生命周期、UI 状态和安装边界的完整回归测试体系。

最关键目标：以后修改 Drive 的 discovery/runtime/mount/UI 时，不能再依赖“插一个真实盘看起来没问题”来发现回归。真实盘只作为**最终发布资格确认**，不作为日常开发和 PR 回归的必要条件。

本计划不要求丢弃现有测试；相反，应把当前零散 validator、真实 metadata fixture、fixture adapter、DiskImages2/macFUSE E2E 统一成分层测试套件。

---

## 2. 当前测试资产盘点

现有可复用资产：

### 2.1 真实盘 metadata golden fixture

```text
Apps/Drive/fixtures/real_disks/disk4/
Apps/Drive/fixtures/real_disks/disk5/
Apps/Drive/fixtures/golden/disks.json
Apps/Drive/fixtures/golden/vectors.json
```

当前实证：

- disk4 LBA4 onlyId = `3164177653`；
- disk5 LBA4 onlyId = `2387350191`；
- 两盘均可作为标准加密盘真实 metadata truth source；
- fixture 只读，不得在测试里原地修改。

### 2.2 核心 validator

已有：

- `ValidateEDPMetadataProbe.swift`；
- `ValidateEDPNativeCore.swift`；
- `ValidateEDPAlignedRead.swift`；
- `ValidateCredentialStore.swift`；
- `ValidateTransportLifecycle.swift`；
- `ValidateBoundedVFS.swift`；
- `ValidateFinderNobrowseMount.swift`；
- `ValidateMacFUSEScratchCleanup.swift`；
- `ValidateProductModels.swift`；
- EDPCore Swift Package tests。

### 2.3 文件镜像/存储 E2E 工具

已有：

- `PrepareEDPFilesystemFixture.swift`；
- `DirectMFMountEDPFixtureAdapter.c`；
- `probe-edp-crypto-diskimages2-readwrite.sh`；
- `probe-edp-crypto-diskimages2.sh`；
- `DiskImages2Attach.m`。

这些是“不插物理 U 盘但走真实加密 + macFUSE + DiskImages2 + Apple filesystem”的关键基础，不得另起一套重复实现。

### 2.4 当前 CI 缺口

当前 `.github/workflows/drive.yml` 主要覆盖：

- 静态 architecture ratchet；
- crypto/native core；
- metadata classifier；
- transport lifecycle；
- bounded unmount；
- 编译；
- credential namespace。

缺失的核心是：

- 物理 USB discovery 生命周期可模拟；
- diskN 重用/换盘竞态；
- 五因素身份端到端；
- detach/error/short-read fault injection；
- daemon 多设备状态机；
- virtual physical disk mount lifecycle；
- UI 多状态自动化；
- 一条统一的本地/CI 测试入口。

---

## 3. 测试总原则

### 3.1 默认绝不碰真实 raw 盘

新自动化测试默认必须满足：

- 不打开 `/dev/rdiskN`；
- 不写 `/dev/diskN`；
- 不执行 `diskutil erase*`；
- 不执行 raw `dd of=/dev/...`；
- 不要求用户插盘；
- 不要求真实密码；
- 不要求真实 FDA 授权；
- 所有写操作限制在测试 temp directory / sparse image。

如果未来保留 real-hardware qualification，必须是**单独明确命令**，不能由 `make drive-test-all` 自动触发。

### 3.2 测生产逻辑，不复制生产逻辑

测试不能自己重新实现一份 EDP classifier/crypto，然后只证明“测试代码和测试代码一致”。

必须尽量调用生产：

- `EDPMetadataProbe`；
- `EDPVolumeMetadata`；
- `EDPCrypto`；
- `EDPEncryptedPartitionReader/Writer`；
- 生产 mount/transport lifecycle；
- 生产 `EDPDaemonController` 状态转换（通过依赖注入）；
- 生产 XPC model。

### 3.3 Fail closed

模拟介质只要关键证据不完整，就必须证明 Drive：

- 不 claim；
- 不创建 mount session；
- 不创建 raw lease；
- 不继承别的设备策略/凭据；
- 不因为一个坏盘影响其他好盘。

### 3.4 每个修复都要能沉淀成 regression

以后遇到任何真实盘 bug：

1. 先最小化成 fixture/scenario；
2. 先让自动化复现失败；
3. 再修代码；
4. 测试永久保留。

---

## 4. 测试分层

最终形成 6 层。

### T0 — Pure unit / crypto / parser

耗时目标：< 60 秒。

覆盖：

- CRC / MD5 / SHA；
- SM4；
- A6/B0；
- LBA4 onlyId；
- LBA7 decode；
- LBA11 deviceId；
- LBA12；
- partition descriptor；
- aligned read；
- five-factor stable ID。

每次 PR 必跑。

### T1 — Media classification / identity

耗时目标：< 60 秒。

覆盖：

- 5 种介质分类；
- 真实 disk4/disk5；
- 负向 metadata mutation；
- 五因素身份逐项变化；
- onlyId 缺失/非法。

每次 PR 必跑。

### T2 — Virtual physical USB lifecycle

耗时目标：1–3 分钟。

不使用真实 USB，用注入的 virtual media provider + file/memory raw device 模拟：

- 插入；
- 拔出；
- 重插；
- diskN 改变；
- diskN 被另一设备复用；
- 两台同型号盘；
- 多盘并发；
- raw I/O 错误；
- stale device；
- service restart。

每次 PR 必跑。

### T3 — Virtual storage E2E

耗时目标：3–8 分钟。

使用 sparse EDP image + fixture adapter：

```text
sparse EDP image
 -> production EDP crypto translation
 -> macFUSE Local
 -> volume.raw
 -> DiskImages2
 -> Apple native filesystem
 -> filesystem operations
```

不插 U 盘，但尽量复现实际数据路径。

PR 必跑核心子集；完整压力版本可 nightly。

### T4 — UI automation

使用 `EDP_UI_PREVIEW`/测试构造 snapshot：

- 主窗口；
- 侧栏；
- 4 一级页；
- 设备 3 子页；
- toolbar；
- 菜单栏；
- Light/Dark；
- 900px；
- Accessibility；
- Instruments hitch。

每次 UI PR 必跑 smoke；完整视觉/性能 nightly 或 release。

### T5 — Clean install/system acceptance

不要求真实 U 盘的部分自动化：

- installer payload；
- signature；
- launchd plist；
- service lifecycle；
- clean state；
- policy/keychain namespace；
- macFUSE runtime contract。

真实 FDA + 真盘保留为最终 release qualification，不阻塞日常开发测试。

---

## 5. 最关键架构：Virtual Physical USB Harness

### 5.1 为什么现有测试不够

当前 production discovery 直接耦合：

```text
IOKit whole USB media
 -> /dev/rdiskN
 -> EDPFileRawDevice / raw helper
 -> metadata read
 -> PhysicalDisk
```

这导致插拔、diskN 重用、USB descriptor 变化无法在 CI 中可控复现。

必须加一个**生产依赖注入 seam**，但不能增加生产后门。

### 5.2 建议抽象

建议从 `EDPNativeSystem.swift` / `EDPVaultRuntime.swift` 抽出：

```swift
struct EDPWholeUSBMedia: Sendable {
    let bsdName: String
    let sizeBytes: UInt64
    let mediaName: String
    let vidHex: String
    let pidHex: String
    let registryEntryID: UInt64
    let usbRegistryEntryID: UInt64
}

protocol EDPWholeUSBMediaProviding {
    func allWholeUSBMedia() throws -> [EDPWholeUSBMedia]
}

protocol EDPRawMetadataReading {
    func snapshot(for media: EDPWholeUSBMedia) throws -> EDPRawMetadataSnapshot
}
```

生产实现：

```text
EDPIOKitWholeUSBMediaProvider
EDPPrivilegedRawMetadataReader
```

测试实现：

```text
EDPVirtualWholeUSBMediaProvider
EDPVirtualRawMetadataReader
```

不要通过正式 App 的隐藏 environment variable 切换 provider。优先使用 initializer dependency injection，测试 executable 直接构造 test dependencies。

### 5.3 物理身份对象集中化

建议新增纯值对象：

```swift
struct EDPPhysicalIdentity: Hashable, Sendable {
    let vidHex: String
    let pidHex: String
    let labelOnlyID: UInt64
    let sizeBytes: UInt64
    let metadataDeviceID: String

    var stableDeviceID: String { ... }
}
```

并让 discovery 与 retained raw FD revalidation 共用同一逻辑。

硬规则：

```text
VID + PID + LBA4 onlyId + whole-device capacity + LBA11 deviceId
```

五项全部一致才是同一设备。

### 5.4 Virtual media state machine

测试 provider 要能在 scenario 中改变：

```text
present
removed
reinserted
replaced
readFailure
shortRead
identityMutation
registryMutation
```

并提供明确步骤：

```swift
harness.insert(deviceA, as: "disk4")
harness.remove("disk4")
harness.insert(deviceA, as: "disk8")
harness.replace("disk8", with: deviceB)
```

这样可以自动证明 diskN 不是身份。

---

## 6. Virtual Raw Device / Fault Injection

建立可注入故障的 raw backend。

建议能力：

```text
read(offset,length)
write(offset,data)
sync()
close()
```

故障计划：

```swift
.failRead(atLBA: 4, error: EIO)
.shortRead(atLBA: 11, bytes: 128)
.detachAfterReadCount(2)
.failWrite(afterBytes: ...)
.failSync(errno: EIO)
.replaceBackingImage(afterReadCount: ...)
```

测试必须覆盖：

- LBA0 read fail；
- LBA4 read fail；
- LBA7 read fail；
- LBA11 read fail；
- LBA12 read fail；
- exact read 变 short read；
- metadata read 后设备被替换；
- raw lease 建立后 onlyId 改变；
- raw lease 建立后 LBA11 deviceId 改变；
- fd 被提前关闭；
- sync failure。

---

## 7. Fixture 设计

建议新增：

```text
Apps/Drive/Tests/
  VirtualUSB/
    EDPVirtualMedia.swift
    EDPVirtualMediaProvider.swift
    EDPVirtualRawDevice.swift
    EDPFaultPlan.swift
    EDPVirtualDiskFactory.swift
  Scenarios/
    RecognitionScenarios.swift
    IdentityScenarios.swift
    LifecycleScenarios.swift
    MountScenarios.swift
    FailureScenarios.swift
  Fixtures/
    manifests/
  Tools/
    ValidateVirtualPhysicalUSB.swift
  run-all.sh
```

具体位置可按工程组织调整，但必须形成一个**明确统一的 Tests 根目录**，不要继续把所有新测试散到多个 `Tools/Validate*.swift`。

现有 validator 可逐步迁移，不要求一次重写。

### 7.1 fixture 类型

A. Immutable captured truth：

```text
fixtures/real_disks/disk4
fixtures/real_disks/disk5
```

B. Deterministic generated fixture：

- standard encrypted；
- legacy no-password；
- current no-password；
- malformed EDP；
- ordinary USB。

C. Mutation fixture：

由基线在内存/临时目录变异，不提交大量重复二进制。

### 7.2 sparse image

物理容量可能显示 64/128GB，但测试文件不应真的占用同等空间。

使用 sparse file：

- logical size 可为大容量；
- 只落盘 metadata sector 和测试分区需要的 block；
- 不允许复制真实整盘镜像。

---

## 8. 物理 U 盘场景矩阵（无需真实 U 盘）

下面是必须自动化的最低矩阵。

### P01 标准 Lexar fixture

- 真实 LBA4/7/11/12；
- 正确 VID/PID/容量；
- `standardEncrypted`；
- five-factor ID 稳定。

### P02 标准 SanDisk fixture

同 P01，证明不是单厂商特例。

### P03 ordinary USB

无 EDP evidence：

- `ordinaryUSB`；
- Drive 不 claim。

### P04 legacy no-password

- `legacyNoPassword`；
- 不 claim；
- 交还 macOS。

### P05 current no-password

- `currentNoPassword`；
- 不 claim。

### P06 malformed/unrecognized EDP

- 有部分 EDP evidence；
- geometry 不一致；
- `unrecognizedEDP`；
- fail closed。

### P07 missing LBA4 onlyId

- LBA7/11/12 都有效；
- LBA4 没 onlyId；
- 不能成为 `standardEncrypted`。

### P08 non-numeric onlyId

`$$$LEXAR-001$$$` 必须拒绝。

### P09 overflow onlyId

大于 UInt64 必须拒绝。

### P10 five-factor: VID mismatch

其余四项完全相同，只改 VID：必须是另一设备。

### P11 PID mismatch

同上。

### P12 onlyId mismatch

同型号、同 PID/VID/容量/LBA11，只改 onlyId：必须另一设备。

这是最关键的“同型号两只 U 盘”回归。

### P13 capacity mismatch

必须另一设备。

### P14 LBA11 deviceId mismatch

必须另一设备。

### P15 VID/PID hex casing

`21c4` 与 `21C4` 规范化后应为同一身份。

### P16 same device, diskN changed

```text
insert as disk4 -> remove -> reinsert as disk9
```

五因素相同：必须恢复同一个 stable deviceID、同一策略/凭据命名空间。

### P17 diskN reuse by different device

```text
device A discovered as disk4
remove A
insert B as disk4
```

必须识别为 B，绝不能沿用 A。

### P18 replacement between discovery and raw lease

在 discovery 与 retained raw open 之间把 backing device 换成 B：

- raw lease revalidation 必须拒绝；
- 不挂载。

### P19 onlyId mutation after discovery

同 `diskN`、same registry，LBA4 onlyId 改变：拒绝。

### P20 LBA11 mutation after discovery

拒绝。

### P21 registryEntryID mutation

拒绝旧 lease/目标。

### P22 detach during metadata read

- 不 crash；
- 不产生半条设备记录；
- 下轮 refresh 可恢复。

### P23 detach after discovery before mount

- mount fail cleanly；
- 状态恢复 unavailable/unmounted；
- 不残留 session。

### P24 detach during mount

- bounded cleanup；
- 不无限等待；
- 不残留 user mount。

### P25 reinsert same identity

- 自动重新识别；
- 不新建重复 policy；
- auto-mount 按既有 policy。

### P26 two same-model devices concurrently

两盘 VID/PID/容量/LBA11 可人为设为相同，仅 onlyId 不同：

- snapshot 两台；
- deviceID 不同；
- 密码/策略互不串。

### P27 two devices, one broken

A 正常，B metadata read EIO：

- A 正常工作；
- B 被跳过/报诊断；
- discovery 不整体失败。

### P28 short read

LBA11 只返回 128 bytes：拒绝，不 crash。

### P29 4K physical transfer alignment

验证 legacy 512-byte metadata 在 4096 block 设备上的 aligned read。

### P30 very small/invalid capacity

不足 metadata 最低尺寸：拒绝。

---

## 9. 密码与策略场景

### C01 type 1

- `notRequired`；
- 无 keychain；
- 可挂载。

### C02 type 2 password missing

- mount disabled/refused；
- type 4 不受影响。

### C03 type 4 password missing

反向独立。

### C04 wrong password

- 验证失败；
- 不保存 Keychain；
- 不污染旧有效 credential。

### C05 correct password

- 验证后保存；
- 可 mount。

### C06 delete credential

- 只删对应 partition；
- 另一 encrypted partition 保持。

### C07 new five-factor identity

即使 LBA11/VID/PID 看起来相同，只要 onlyId 不同：

- 不继承 display name；
- 不继承 auto-mount；
- 不继承 keychain credential。

### C08 policy persistence

service restart 后：

- display name；
- global auto-mount；
- each partition auto-mount 保持。

---

## 10. Mount / filesystem E2E 场景

使用 sparse image / fixture adapter，不插盘。

### M01 boot mount

- plaintext slice；
- FAT16；
- 只读语义符合产品预期。

### M02 exchange encrypted RW

```text
mount -> create -> write -> fsync -> read -> hash -> unmount -> remount -> hash
```

### M03 secure encrypted RW

同 M02。

### M04 Finder atomic save pattern

至少模拟：

```text
create temp
write
fsync
rename(temp, existing-target)
reopen
verify
```

防止历史 TextEdit atomic-save 类回归。

### M05 multiple file delete

批量创建、多选等价删除语义，验证目录状态。

### M06 rename

- file rename；
- directory rename；
- overwrite semantics。

### M07 Unicode filename

中文、空格、emoji（filesystem 允许范围内）。

### M08 large sequential file

建议 128–512MB，不必数 GB；验证吞吐无灾难退化和数据 hash。

### M09 random read/write

固定 seed，数千次 block-range 随机操作。

### M10 unmount/remount loop

至少 50–100 次，检查：

- transport process；
- volume.raw；
- synthetic device；
- user mount；
- fd 泄漏。

### M11 unmount busy/failure

模拟 VFS unmount failure：

- XPC 必须返回错误；
- UI/runtime 不能谎报成功；
- eject fail closed。

### M12 transport crash

mount 后 transport 异常退出：

- cleanup bounded；
- 后续可重新 mount。

### M13 fsync failure

必须向上层传播，不得吞掉 durability failure。

### M14 concurrent partitions

同一 virtual physical disk：type 1/2/4 同时 mount/unmount，不串状态。

---

## 11. Service / daemon 生命周期场景

### S01 startup with no device

snapshot 正常，0 device。

### S02 device already present when service starts

自动 discovery。

### S03 stop service with no mounts

正常退出，launchd 不 KeepAlive 拉起。

### S04 stop service with mounts

按 production teardown 顺序完整释放。

### S05 restart service

同 virtual device 仍 present：重新识别同一 identity。

### S06 App restart, service keeps running

foreground 生命周期不影响 service。

### S07 transient mount retry

模拟 FS extension not found/not enabled -> ready：retry 能恢复。

### S08 one device failure isolation

坏盘不能让 daemon controller 全局不可用。

### S09 stale session recovery

构造 persisted stale session，启动后清理。

### S10 graceful full exit

UI full exit -> request graceful shutdown -> mounts/raw leases 全部释放。

---

## 12. UI 自动化测试计划

### U01 preview snapshot factory

建立可选择 scenario 的 preview/test snapshot，不调用真实 XPC。

### U02 4 一级导航

总览/设备/活动/设置均可选且 detail 正确切换。

### U03 设备子页

概览/分区/安全。

### U04 sidebar geometry

900×680 自动 toggle 20 次：

- 无 `»`；
- 无 focus ring；
- 无 overshoot。

### U05 Instruments

Xcode 26.6 `Animation Hitches`：

- 6 次 sidebar toggle；
- `hitches = 0`。

### U06 toolbar

总览/设备显示适当 device controls；活动/设置不发生 overflow。

### U07 menu bar

Mini Control Center：

- service state；
- device rows；
- partition action enablement；
- global auto-mount；
- footer。

### U08 Light/Dark

关键状态文字不能出现黑底黑字/白底白字。

### U09 Reduce Motion / Transparency

无不可用状态。

### U10 Accessibility

所有 icon-only button 有 label/help；分区状态可被 VoiceOver 读取。

---

## 13. Installer/System 自动化（无真盘）

保留现有 FIRST-INSTALL 真盘流程作为 release qualification，但新增无盘自动 smoke：

- package 构建；
- payload 路径；
- code signature；
- LaunchDaemon plist；
- App/service version；
- no KeepAlive/RunAtLoad；
- service start/stop/restart；
- XPC health/snapshot with no device；
- login keychain 未被修改；
- installer 不残留旧 helper/FUSE-T；
- macFUSE runtime contract；
- clean uninstall/cleanup 不触碰 external physical disk。

---

## 14. 统一测试命令

最终要求提供稳定入口，建议 Makefile：

```text
make drive-test-fast
make drive-test-identity
make drive-test-virtual-usb
make drive-test-storage
make drive-test-ui
make drive-test-system
make drive-test-all
```

定义：

### `drive-test-fast`

T0 + T1 + compile，日常秒级反馈。

### `drive-test-virtual-usb`

完整 P01–P30 + C01–C08 + daemon lifecycle。

### `drive-test-storage`

M01–M14。

### `drive-test-ui`

preview + Accessibility + core UI geometry smoke。

### `drive-test-all`

不插盘情况下能够运行的全部测试。

**`drive-test-all` 绝不能要求用户输入 sudo/password，也不能触发真实 raw device。**

---

## 15. CI 规划

建议把当前单一 `native` job 拆成明确 job，便于定位：

### Job A — contract-and-build

- architecture ratchet；
- Swift 6 compile；
- shell syntax。

### Job B — core-and-metadata

- EDPCore；
- metadata；
- five-factor identity；
- golden real fixture。

### Job C — virtual-physical-usb

- P/C/S scenarios；
- fault injection。

### Job D — storage-e2e

- sparse EDP image；
- macFUSE Local；
- DiskImages2；
- filesystem RW。

如果 GitHub-hosted macOS 26 对某个系统 extension 有限制，允许把 Job D 放到受控 macOS 26 runner；但仍然不插物理 U 盘。

### Job E — ui-smoke

- `EDP_UI_PREVIEW`；
- navigation/accessibility；
- 900px sidebar；
- compile。

### Nightly

- 100-loop mount/unmount；
- large/random IO；
- Instruments；
- race/fault matrix repeated seeds。

---

## 16. 测试结果格式

短期可继续使用明确 `RESULT=`，但统一命名：

```text
RESULT=DRIVE_CORE_OK
RESULT=DRIVE_IDENTITY_OK
RESULT=DRIVE_VIRTUAL_USB_OK
RESULT=DRIVE_STORAGE_E2E_OK
RESULT=DRIVE_UI_SMOKE_OK
RESULT=DRIVE_SYSTEM_SMOKE_OK
```

中期建议生成：

- JUnit XML；
- scenario summary JSON；
- CI artifacts（仅日志/trace，不含密码/敏感 raw dump）。

每个失败必须能看出：

```text
scenario ID
expected
actual
seed
fixture
fault plan
```

---

## 17. 安全 ratchet

CI 必须加入以下静态/运行安全门：

- 测试 harness 默认拒绝 `/dev/rdisk*`；
- 不存在 `diskutil eraseDisk` / `eraseVolume`；
- 不存在测试 `dd ... of=/dev/`；
- virtual fixture 的 write root 必须在 `${TMPDIR}`；
- captured real fixtures read-only；
- synthetic password 只能存在 temp/test memory；
- CI 日志不得打印 password/key material；
- production binary 不得包含 test provider selector 环境后门。

---

## 18. 实施阶段

### Phase TEST-A — 统一 runner + inventory

- 创建 `Apps/Drive/Tests/`；
- 把现有 validator 纳入统一 runner；
- Makefile command；
- 先不改 production semantics。

验收：现有 CI 全绿，`make drive-test-fast` 可重复。

### Phase TEST-B — 身份与 classifier 矩阵

- P01–P15；
- real disk4/disk5；
- mutation generator；
- five-factor regression。

### Phase TEST-C — production dependency seam

- media provider protocol；
- raw metadata provider；
- `EDPPhysicalIdentity`；
- production adapter；
- test adapter。

要求：默认 production 行为 byte-for-byte/semantic 不变。

### Phase TEST-D — Virtual Physical USB

- state machine；
- fault plan；
- P16–P30；
- multi-device；
- diskN reuse。

### Phase TEST-E — daemon/policy/credential

- C01–C08；
- S01–S10；
- no legacy device-ID migration。

### Phase TEST-F — Storage E2E

- 复用 `PrepareEDPFilesystemFixture`；
- fixture adapter；
- M01–M14；
- loop/stress。

### Phase TEST-G — UI automation

- preview scenarios；
- navigation；
- menu bar；
- accessibility；
- Instruments。

### Phase TEST-H — CI 拆分与 release gate

- Jobs A–E；
- nightly；
- artifacts；
- README/testing 文档。

---

## 19. 完整验收标准

测试改造只有满足以下条件才完成。

### 19.1 无物理盘覆盖

- [ ] `make drive-test-all` 在**没有插任何物理 U 盘**的 Mac 上通过；
- [ ] 不要求人工密码；
- [ ] 不要求管理员交互；
- [ ] P01–P30 全自动；
- [ ] C01–C08 全自动；
- [ ] S01–S10 全自动；
- [ ] M01–M14 至少在 CI/受控 runner 全自动。

### 19.2 五因素身份

自动证明：

- [ ] VID 改变 -> 新设备；
- [ ] PID 改变 -> 新设备；
- [ ] onlyId 改变 -> 新设备；
- [ ] 容量改变 -> 新设备；
- [ ] LBA11 deviceId 改变 -> 新设备；
- [ ] 五项相同但 diskN 改变 -> 同一设备；
- [ ] 同型号双盘 onlyId 不同 -> 两台独立设备；
- [ ] 新身份不继承旧策略/钥匙串。

### 19.3 介质归属

- [ ] 只有 `standardEncrypted` 被 Drive claim；
- [ ] legacy/current no-password 直接交 macOS；
- [ ] unrecognized fail closed；
- [ ] ordinary USB 不受影响。

### 19.4 生命周期

- [ ] 插/拔/重插；
- [ ] diskN reuse；
- [ ] discovery/open race；
- [ ] detach mid-read/mount；
- [ ] service restart；
- [ ] stale cleanup；
- [ ] multi-device failure isolation。

### 19.5 存储

- [ ] type 1；
- [ ] type 2；
- [ ] type 4；
- [ ] create/read/write/fsync/rename/delete；
- [ ] remount persistence；
- [ ] random IO；
- [ ] 50–100 mount loop；
- [ ] failure propagation；
- [ ] no lingering mount/process/fd。

### 19.6 UI

- [ ] approved UI preview scenarios；
- [ ] 900px sidebar no overflow/no bounce；
- [ ] menu bar smoke；
- [ ] Light/Dark；
- [ ] Accessibility；
- [ ] no hitches baseline。

### 19.7 CI

- [ ] exact HEAD Jobs A–E green；
- [ ] nightly stress green；
- [ ] failure artifacts 可定位 scenario；
- [ ] 测试不依赖真实 U 盘。

---

## 20. Real hardware 的最终定位

建立本套件之后，真实 U 盘验收仍有价值，但角色改变为：

```text
Release qualification / hardware confidence
```

而不是：

```text
日常 regression detection
```

`Apps/Drive/docs/FIRST-INSTALL-ACCEPTANCE.md` 可以继续作为最终机器验收流程，但任何普通 UI/runtime 修改都应先由上述无盘自动套件发现回归。

最终目标：**真实盘验收只确认“虚拟测试无法覆盖的 macOS/TCC/USB 硬件边界”，不再承担核心逻辑回归发现职责。**
