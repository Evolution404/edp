# EDP Drive 真实盘 EBUSY / Safe Eject 最终收口交接

日期：2026-09-01 16:58 +0800
分支：`codex/ui-macos26-liquid-glass`
项目：`/Users/zhangyuxi/edp`
本文所在提交即最新交接基线；接手后第一步执行 `git fetch`、`git rev-parse HEAD`、`git status --short`，不要复用本文中的历史 BSD 号作为操作依据。

> 目标：完成真实标准加密 EDP U 盘的 raw EBUSY 自动恢复、三分区 capability-aware 验收、safe eject 复测，并证明此前 `Disk Arbitration refused diskN: status=-119930877` 假失败不再出现。本文记录的是当前已验证事实；未完成项明确标注，不得把手工恢复后的 PASS 误写成产品自动恢复 PASS。

## 1. 已完成并已进入远端基线的关键提交

本轮 EBUSY 代码/测试已提交并 push：

- `1a639f94418a9c682b540d25bab4b42a505f449f` — `fix(drive): recover raw access from fskit busy state`

其父提交及相关历史基线：

- `36ad496f52df6b95149bfe3a561dd2b89eba9491` — `fix(drive): allow unrelated fskit mounts during upgrade`
- `ce3084f` — physical eject generation hardening：原 USB generation 消失即幂等成功、diskN 复用保护、duplicate eject single-flight、shutdown 等待 in-flight eject。
- `acf3960` — factory-clean 主机可直接构建 Clean.pkg，不依赖预装 macFUSE。
- `3136ff8` — single-App FDA retention 实机记录。
- `6ff00db` — FDA 只属于 `EDP Drive.app`，service 不单独授权；root service 通过同一个 App executable 的 hidden raw-fd broker + `SCM_RIGHTS` 获取 retained fd。
- `fec8de1` — native filesystem unmount 后 pre-unpublish quiescence，解决旧 UVFS generation 卡死。

## 2. 当前真实设备现场

用户已拔掉无关的 SN750；最近一次重新枚举时系统只剩一只标准 EDP SanDisk：

- BSD：当前观察为 `disk27`，但**接手后必须重新枚举，禁止直接复用**。
- VID/PID：`0781:5591`
- LBA4 onlyID：`2387350191`
- capacity：`123010547712`
- LBA11 metadata deviceID：`disk&ven_sandisk&prod_ultra_usb_3.0&rev_1.00`
- stable device identity：`disk&ven_sandisk&prod_ultra_usb_3.0&rev_1.00#023425d32affcd905fa0dc89`
- TCC：`kTCCServiceSystemPolicyAllFiles | com.edp.drive | auth_value=2`
- 不存在 `com.edp.drive.service` FDA；不要要求用户给 service 单独授权。
- 当前真实盘未挂载，无 EDP/UVFS/transport mount residue。

当前 snapshot 在**手工 force whole-unmount 之后**已经恢复为：

- `privilegedAccessReady=true`
- type1 `credential=notRequired`
- type2 `credential=saved`，当前策略曾显示 `autoMount=true`
- type4 最近一轮为 `credential=missing`

重要：当前 `privilegedAccessReady=true` 只证明手工 force-unmount 能解除现场 EBUSY。它**不能**证明新 WIP 自动 recovery 已实机通过。

## 3. 这轮 EBUSY 根因已经实证

### 3.1 FDA 不是问题

插盘后曾出现 `privilegedAccessReady=false`，但 tccd 对真实 root App broker 的 attribution/decision 已明确：

- subject：`com.edp.drive`
- `authValue=2`

因此 single-App FDA 模型本身有效；不能再把 raw probe 的所有失败统一显示为“需要完全磁盘访问”。

### 3.2 原错误分类会误导

原代码将 raw open / IOKit / metadata revalidation 的失败过度折叠；且 Swift adapter 用 `contains(":1")` 判断 EPERM，导致 `EDP_RAW_LEASE_OPEN_FAILED:1007` 也会因为文本以 `1` 开头被误判为 FDA。

提交 `1a639f94418a9c682b540d25bab4b42a505f449f` 已修：

- `EDPRawValidation.h` 新增稳定 machine codes `1001...1007`；
- `EDPRawValidation.c` 保留真正 `open(2)` errno，post-open target/path/rdev/IOKit/metadata 分阶段返回独立 code；
- broker stderr 输出 `EDP_RAW_BROKER_VALIDATION_FAILED code=<code> errno=<errno>`；
- Swift adapter 精确解析完整整数 code，只有真正 `EPERM(1)` 才分类为 `.rawAccessPermission`。

真实现场最终得到：

`EDP_RAW_LEASE_OPEN_FAILED:16`

即 `errno=EBUSY`，不是 FDA。

### 3.3 macOS FSKit probe 留下 whole-media busy

插盘时序日志：

- `14:05:07.765` 创建 `disk27/disk27s1`
- `14:05:07.883` `msdos_fskit` probe ongoing
- `14:05:07.923` `msdos_fskit` probe failure
- `14:05:07.927` `disk is not readable /dev/disk27`
- EDP `edp-raw-metadata` helper 到 `14:05:08.188` 才启动

因此不是 EDP metadata reader 与系统 probe 并发把盘撞坏；系统 probe 先失败约 265ms。

现场同时满足：

- 无 mount；
- 无用户态 lsof 句柄；
- IOKit whole media `Open=Yes`；
- read-only metadata helper 可以读取 LBA 0/4/7/11/12；
- raw `O_RDWR` 被拒绝为 `EBUSY`。

### 3.4 排除的错误修复方向

`DADiskClaim` 是公开 API，已做 exact registry-generation 只读/不写盘 probe：

- claim/unclaim 可以成功；
- 但 claim 持有期间 EDP Drive broker 仍返回 raw validation failure / EBUSY。

所以不要把 claim 当作 EBUSY recovery。`Apps/Drive/Tests/Storage/DiskArbitrationClaimProbe.c` 是本轮诊断工具，若保留在仓库，仅用于证明 claim 语义，不属于发布 gate。

### 3.5 真正有效的恢复动作

对已经五因素识别的 exact EDP whole media：

- 普通 whole-unmount：命令返回成功，但 raw broker 仍 EBUSY；
- **forced whole-unmount**：不 eject、不格式化、不分区、不写数据；随后同一个 FDA App broker 从 exit `77` 变为 exit `71`。

broker probe 中：

- `77` = raw open/validation 失败；
- `71` = raw O_RDWR 已成功，只因诊断时故意不给有效 fd-passing socket，最后发送 fd 失败。

随后旧安装态 service 无重启、无重新 FDA 授权、无物理重插，即恢复 `privilegedAccessReady=true`。这构成第二份实证：EBUSY 的恢复条件就是 generation-bound forced whole-unmount。

## 4. 已提交的正式实现

### 4.1 Disk Arbitration API

`EDPDaemonDiskArbitrating` / `EDPDiskArbitrationController` 已增加：

- `forceUnmountWholeAsync(_:expectedRegistryEntryID:completion:)`

正式实现仍走公开 `DADiskUnmount` callback API，options 为：

- `kDADiskUnmountOptionWhole`
- `kDADiskUnmountOptionForce`

操作前继续用 `DADiskCopyIOMedia` + `IORegistryEntryGetRegistryEntryID` 验证 exact IOMedia generation，不能只信 `diskN`。

### 4.2 raw EBUSY recovery

`EDPDaemonController.rawAccessProbeAsyncLocked` 已改为：

1. 先按正常路径尝试 App broker raw lease；
2. 仅当 typed raw failure 对应 `EBUSY(16)` 时触发 recovery；
3. 只允许一次 `forceUnmountWholeAsync`；
4. force callback 返回后重新检查当前 connected disk 的 `deviceID + registryEntryID + rawPath`；
5. generation 未变化才第二次 open；
6. 第二次仍 EBUSY 或其他失败直接 terminal fail，不做第三次/无限循环；
7. DA force-unmount 失败直接 fail-closed；
8. EPERM、1001–1007 validation、deviceChanged 等非 EBUSY failure 绝不 force-unmount。

不要把 recovery 扩大成“任何 raw error 都 force”。

## 5. 新增 deterministic 回归 S31–S35

全部已经实际 PASS：

- `S31 raw_ebusy_force_unmount_retry_once`
- `S32 repeated_raw_ebusy_stops_after_one_recovery`
- `S33 busy_recovery_refuses_replacement_generation`
- `S34 busy_recovery_da_failure_is_fail_closed`
- `S35 non_busy_raw_failures_never_force_unmount`

`FakeDiskArbitration` 已增加 force-unmount call recording / injected error / callback hook；ControllerEnvironment 可注入 raw opener。

`run-service-lifecycle.sh` 已扩大检查到 S35。

`run-system.sh` 新 marker：

- `RESULT=DRIVE_SYSTEM_RAW_VALIDATION_DIAGNOSTICS_OK`
- `RESULT=DRIVE_SYSTEM_RAW_EBUSY_RECOVERY_OK`

并锁定：

- force whole-unmount 必须带 exact registry identity；
- recovery 只能在 EBUSY 触发；
- retry 次数有界；
- raw validation machine code 不能重新折叠成 FDA 文案。

## 6. 当前已通过的 gate

代码提交 `1a639f9` 已实际通过：

- service lifecycle：C01–C08 / D01–D13 / S01–S35 / M11 PASS；
- deterministic model：10,000 sequences × 32 steps = 320,000 events PASS；
- `make drive-test-virtual-usb` PASS；
- `make drive-test-system` PASS；
- `make drive-test-fast` PASS；
- `git diff --check` PASS。

新 WIP Clean.pkg 已从未提交 WIP 构建并 verifier PASS：

- 路径：`Apps/Drive/artifacts/EDP-Drive-0.6.0-arm64-Clean.pkg`
- SHA-256：`9fbd47a71edb86246259012fa70248d64c75924afcc3965a0a4ccb39e455bfd5`
- `RESULT=EDP_CLEAN_INSTALLER_VERIFIED`
- `RESULT=FULL_DISK_ACCESS_SINGLE_APP_RAW_FD3_TRANSPORT_PATH_ENFORCED`
- `RESULT=PRODUCTION_APPLE_NTFS_POLICY_ENFORCED`

注意：这个 SHA 是**提交前 WIP 构建**。代码 commit 后必须从 exact new HEAD 重新构建，最终测试不得继续使用这个 SHA 作为发布包。

## 7. 尚未完成，下一位 AI 必须按顺序执行

### A. 先确认仓库

1. `git fetch`
2. 读取本文、`docs/PLAN-2026-08-30-async-lifecycle-hardening.md`、`docs/PROGRESS-2026-08-30-async-lifecycle-hardening.md`
3. `git rev-parse HEAD`
4. `git status --short`，应为 clean
5. 不新建 worktree，不 reset/revert 已完成提交

### B. exact-head 重新打包

从接手时最新 HEAD：

1. `make drive-test-fast`
2. `make drive-test-virtual-usb`
3. `make drive-test-system`
4. `git diff --check`
5. `build-self-signed-installer.sh`
6. `verify-clean-installer.sh`
7. 固定 exact-head Clean.pkg SHA-256

UI performance gate 当前是独立已知项；不要为了本轮 raw/eject 收口放宽 33ms 门槛。如果要跑 UI，结果单独记录。

### C. 安装 exact-head 包

当前真实 EDP U 盘可能仍插着且未挂载。用户此前允许在“exact EDP identity + mounted=false + 无 EDP transport”条件下为本次验收临时放宽带盘覆盖安装，但这不是永久安全策略。

安装前必须重新枚举并验证：

- external physical 数量/身份；
- EDP 盘五因素；
- mount=0；
- 无 `.edp-block-*` / UVFS / transport residue。

管理员授权只用于 installer，不要新增 service FDA。

### D. 最关键：fresh 物理重插验证自动 EBUSY recovery

**当前盘的 busy 已经被人工 force-unmount 清除，所以仅在当前 generation 上看到 `privilegedAccessReady=true` 不算产品 recovery PASS。**

安装新版后必须要求用户：

1. 物理拔出标准 EDP U 盘；
2. 再重新插入一次；
3. 从头重新枚举 BSD/registry identity；
4. 不沿用历史 `disk27`。

然后验证：

- TCC 仍只有 `com.edp.drive=2`；
- 无 `com.edp.drive.service` FDA；
- fresh insert 后 service 自动完成 raw acquisition；
- canonical `verify-fda-device 0781:5591` 返回 `RESULT=FDA_RETAINED_RAW_ACCESS_READY`；
- diagnostics 最终 `rawAccessErrors` 清空、`privilegedAccessReady=true`。

如日志显示第一次 open 是 EBUSY，必须看到 exact-generation forced whole-unmount 后仅一次 retry 成功；如果该次 fresh insert 恰好没有 EBUSY，只要最终 raw ready 仍可 PASS，但不要虚构 recovery 被触发。

### E. 三分区 capability-aware 实机验收

禁止 format / erase / repartition / raw test write。

当前 credential 状态可能是：type2 saved、type4 missing；重新 snapshot 为准。密码不得从聊天/历史记录猜测或传入 shell。如果 type4 仍 missing，只能让用户在 App UI 重新验证并保存真实密码。

按当前 filesystem capability：

- FAT16 / Apple NTFS read-only：mount → inspect → unmount → remount → unmount，只读一致性；
- 只有明确 writable filesystem 才允许正常 filesystem-level 临时 marker/hash persistence；
- type1 永远不得写 marker。

### F. safe eject 最终复测

必须使用产品 XPC safe-eject，不用 `diskutil eject` 替代最终产品验收。

要求：

- 不再出现 `Disk Arbitration refused diskN: status=-119930877` 假失败；
- 如果 physical generation 在 synthetic teardown 中提前消失，按 `ce3084f` 语义应 terminal success；
- diskN 被新设备复用时不得误 eject 替换盘；
- duplicate eject single-flight；
- Finder 正常；
- UVFSService / adapter / `.edp-block-*` / DiskImages publication residue=0；
- 无 `U-state`。

最后再物理拔插一次验证 single-App FDA retention，仍不得新增管理员/FDA授权。

## 8. 安全边界

- 真实 EDP U 盘绝对禁止 format / erase / repartition / raw test write。
- destructive storage tests 只允许经过 synthetic identity 证明的 fixture。
- 每次物理操作必须重新枚举，不信历史 diskN/PID。
- physical DA target 必须绑定 current registry generation。
- force whole-unmount **只能**作为标准 EDP raw open 的 EBUSY 单次 recovery，不能推广到普通 USB 或其他 raw error。
- 不给 `edp-drive-service` 单独 FDA。
- 不使用历史密码/Keychain秘密作为脚本参数或日志。
- 不用私有 Disk Arbitration API；本轮所有实现基于公开 `DADiskUnmount`。
- 不把 `DADiskClaim` 重新包装成修复；实机已经证明 claim 不解除底层 EBUSY。

## 9. 当前工作区文件范围

本轮预期代码/测试文件：

- `Apps/Drive/product/EDPNativeSystem.swift`
- `Apps/Drive/product/EDPVaultRuntime.swift`
- `Apps/Drive/product/EDPRawValidation.c`
- `Apps/Drive/product/EDPRawValidation.h`
- `Apps/Drive/product/EDPRawFDBroker.c`
- `Apps/Drive/Tests/VirtualUSB/ValidateCredentialPolicyServiceLifecycle.swift`
- `Apps/Drive/Tests/run-service-lifecycle.sh`
- `Apps/Drive/Tests/run-system.sh`
- `Apps/Drive/Tests/Storage/DiskArbitrationClaimProbe.c`（诊断工具，不是发布 gate）
- 本交接文档
- progress tracker 更新

下一位 AI 不应删除 safe-eject generation hardening、single-App FDA、native-FS pre-unpublish quiescence 或 installer exact orphan identity 保护来换取测试通过。

## 10. 完成本轮的定义

只有以下全部成立才可宣称本轮 DONE：

- 当前 WIP 已 commit/push；
- exact-head fast/virtual/system PASS；
- exact-head Clean.pkg build + verifier PASS；
- exact-head 包实际安装；
- fresh physical reinsert 后 raw access 自动 ready，不需要手工 `diskutil unmountDisk force`；
- 如触发 EBUSY，forced whole-unmount recovery 仅一次且 exact-generation；
- 三分区 capability-aware 验收完成；
- safe eject 不再弹 stale `BadArgument` 假失败；
- Finder/UVFS/transport/DiskImages residue=0，无 U-state；
- single-App FDA 拔插 retention PASS；
- tracker 更新，工作树 clean，最终 exact HEAD 与 package SHA 记录完整。
