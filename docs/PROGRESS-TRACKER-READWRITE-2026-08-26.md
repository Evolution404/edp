# EDP USB Vault — Read/Write 实时进度追踪

日期：2026-08-26  
分支：`test/fuset-minimal-fskit-bridge`  
完整测试矩阵：`docs/TEST-MATRIX-READWRITE-2026-08-26.md`  
历史只读基线：`docs/PROGRESS-TRACKER-FUSET-MINIMAL-FSKIT-2026-08-26.md`

## 当前总状态

**目标已从“只读 thin bridge PoC”扩展为“读写产品路径 + 显式只读安全模式”。当前新增最高优先级 P0：隐藏 Finder 中的内部 FUSE-T transport 卷，同时保持最终用户卷和 RW 链不变。**

当前核心架构：

```text
physical /dev/rdiskN
  -> privileged launcher/authopen fixed O_RDWR | O_CLOEXEC
  -> inherited validated whole-device fd
  -> LBA11/LBA12 validation + password/file-key derive
  -> EDPEncryptedReadWriteBlockDevice
  -> EDP-owned FUSE-T Unix socket thin bridge
  -> hidden writable volume.raw
  -> DiskImages raw block device
  -> Apple filesystem / separately-installed FSKit filesystem provider
  -> Finder
```

强制边界：

- 产品核心不依赖 macFUSE、global libfuse、go-nfsv4、bundled NTFS-3G。
- FUSE-T 仅使用官方签名 `fuse-t.app` FSKit runtime；CI-only `enabledModules.plist` 注入不得进入产品。
- 密码不走 argv，不打印，不写仓库；formal physical RW bridge 从 control fd 读取并清零。
- whole raw device 仅允许 `/dev/rdiskN`；授权 helper 固定 `O_RDWR | O_CLOEXEC`，禁止 caller 注入 open flags；bridge 只接收并验证 privileged launcher 继承的 character-device fd。
- RO 模式继续保留并独立回归；RW 能力不得把 RO 安全模式静默升级为可写。
- NTFS 可写必须由实际可写 NTFS provider 证明；ExFAT/APFS 绿灯不能冒充 NTFS 已解决。
- 内部 FUSE-T transport 必须保持 filesystem-neutral；P0 隐藏方案不得把 NTFS/ExFAT/APFS 逻辑塞入 thin bridge。
- Finder 中最终只允许出现用户卷；任何 P0 workaround 都必须证明 `volume.raw` 仍可被 DiskImages2 消费且读写不退化。

---

## P0 — Finder 暴露内部 FUSE-T Transport 卷

实体产品已确认 Finder 会出现 `EDP Boot Transport` / `EDP Exchange Transport` / `EDP Secure Transport`。这些卷只是内部 `volume.raw` 传输层；用户若单独推出会破坏上层最终卷，因此必须隐藏。

当前 bridge 已明确传入：

```swift
mount.arguments = [
    "-o", readOnly ? "nobrowse,rdonly" : "nobrowse",
    "-t", "fuset", sessionURL.path, mountpoint,
]
```

因此 P0 不是“漏传 `nobrowse`”。专用 macOS 26 / FUSE-T 1.2.7 probe `.github/workflows/fuset-transport-nobrowse.yml` 已用 `statfs(2)` 直接读取内核 mount flags，得到：

```text
STATFS_FLAGS=0x10201018 MNT_DONTBROWSE=0 FSTYPE=fuse-t
```

### 已排除路径

| Probe | 结果 | 结论 |
|---|---|---|
| 当前 CLI `-o nobrowse -t fuset` | `MNT_DONTBROWSE=0` | FSKit backend 没有落地 no-browse flag |
| CLI `dontbrowse` | `MNT_DONTBROWSE=0` | 不是 option 拼写问题 |
| `~/.fuse-t/fuse-t.ini` `nobrowse=true` | `MNT_DONTBROWSE=0` | user config 不解决 FSKit mount flag |
| `/Library/Application Support/fuse-t/cfg/fuse-t.ini` `nobrowse=true` | `MNT_DONTBROWSE=0` | system config 不解决 FSKit mount flag |
| `/sbin/mount -u -o nobrowse <mountpoint>` | exit 72，寻找不存在的 `/Library/Filesystems/fuse-t.fs/.../mount_fuse-t` | FSKit-only 安装不能走 legacy helper update |
| direct `mount(2)` + `MNT_UPDATE|MNT_DONTBROWSE` + NULL FS data | `errno=14 EFAULT` | 不能用无 FS-specific data 的通用 VFS update |
| `/sbin/mount -u -t fuset ...` | node-only 语法 exit 64；source+node 仍转 legacy `mount_fuse-t` 并 exit 72 | 强制 FSKit short name 也不能做 post-mount update |

### 根因收敛

Apple 当前公开 FSKit API 中，`requestedMountOptions` 返回 `FSVolume.MountOptions`，公开 option 只有 `.readOnly`；`mount(options:)` 的 `FSTaskOptions` 也没有定义可用于 no-browse 的公开 mount flag。FUSE-T 文档虽列出 `-o nobrowse`，但在 1.2.7 FSKit backend 上没有公开 FSKit API 可映射到 `MNT_DONTBROWSE`，与 CI 实测一致。

FUSE-T 当前最新 release 仍为 `1.2.7`，release notes 没有 FSKit no-browse 修复。因此当前不计划升级到不存在的版本，也不把 legacy helper 装回产品。

### 下一步候选（必须用 Finder 可浏览性硬判据验证）

1. 用 Foundation `URLResourceKey.volumeIsBrowsableKey` 直接判断 transport 是否会出现在 GUI/Finder；该 key 的定义就是“是否在 Finder/Desktop 等 GUI 文件浏览环境可见”。
2. 对照测试：当前 `/Volumes/.edp-*` + 正常 `volume_name`、非 `/Volumes` 内部 mount root、点号前缀 `volume_name`、隐藏 mount root 等候选。
3. 每个候选必须同时验证：FUSE-T RW `volume.raw`、`hdiutil attach -imagekey diskimage-class=CRawDiskImage` 可消费、detach/cleanup 正常。
4. 只有 `volumeIsBrowsable == false` 且 DiskImages2/RW 同时通过的方案才允许进入 `product/EDPVaultRuntime.swift`。
5. 集成后还需实体 Mac Finder 侧边栏三分区最终验收；CI 只能证明 Foundation/Finder browsability contract，不能替代最终截图/交互实证。

P0 当前状态：**根因已确定，post-mount flag 路径已排除，产品修复尚未落地；正在验证安全隐藏候选。**

---

## Phase I — RW 核心与防回归矩阵

| ID | 状态 | 任务 | 当前证据 / 下一步 |
|---|---|---|---|
| I1 | ✅ | thin RPC writable transport | `FuseTWriteBacking`、`pwrite`、`synchronize`、`write_size` response；explicit `readOnly` mode |
| I2 | ✅ | encrypted SM4 random-access writer | `EDPEncryptedPartitionReader` 16-byte aligned RMW；single `NSLock` 串行 read/write/sync |
| I3 | ✅ | formal physical RW adapter | `FuseTEDPAuthorizedReadWriteBridge.swift`；whole `/dev/rdiskN` identity + inherited character-device fd validation；control-fd secret；无 plaintext cache |
| I4 | ✅ | narrow privileged raw-open helper | `product/EDPRawReadWriteAuthorization.c` 固定 `O_RDWR|O_CLOEXEC`；whole `/dev/rdiskN` only；无 `O_TRUNC/O_CREAT` |
| I5 | ✅ | deterministic encrypted RW matrix | run `33027996180` / job `98373742938` 全绿：1B/31B/33B/4097B/7777B/4K/64K/1MiB/tail + concurrent unaligned/RMW serialization + bounds + zero-write + true close/reopen + RO cannot upgrade |
| I6 | ✅ | strict product/RPC contract workflow | run `33027996180` 3/3 jobs 全绿：encrypted block matrix、filesystem-neutral thin transport、physical authorized product contract；thin transport 继续禁止 filesystem/provider knowledge |
| I7 | 🟡 | ExFAT encrypted RW E2E | 首轮失败仅因 `_` 非法卷标；已改 `EDP-EXFAT-RW`；下一步跑完整 CRUD + atomic replace + rename/delete + large file + detach/remount persistence |
| I8 | 🟡 | HFS+ explicit RO safety regression | hidden mount 字符串不是可靠 RO 判据；已改为 `ACCESS_MODE=read-only` + final HFS Media/Volume RO + write fail + backing unchanged；需下一轮有效 run |
| I9 | 🟡 | APFS encrypted RW E2E | workflow 已创建：real metadata → cipher → thin RW → APFS → CRUD/xattr/Finder → remount persistence；需实跑并补齐与 ExFAT 同等级 RW 语义 |
| I10 | ⏳ | physical EDP `/dev/rdiskN` RW | hosted runner 无真实 USB；formal auth contract 已全绿，随后仍需实机真实介质读写与断电/拔盘验证 |

### 2026-08-27 RW regression 实证

- 历史失败 run `33025487148` 中 encrypted block matrix 与 thin transport 两个 job 已成功；唯一失败的 physical authorized job **Swift/C 编译链接均成功**，失败点是 workflow 仍断言旧 `AUTHOPEN` bridge marker。
- 当前产品实现已收紧为：privileged launcher/authopen 打开 whole raw disk，再把已授权 fd 传给非特权 bridge。bridge 校验 `--raw-fd >= 3`、`F_GETFD`、`fstat` 与 `S_IFCHR`，并保持 `/dev/rdiskN` whole-device identity 校验。
- commit `9bdb9ea` 将 CI 契约同步到该更严格模型，且保留/增加 `O_RDWR|O_CLOEXEC`、whole raw disk、character-device fd、secure password zero、无 plaintext cache、explicit RW 等断言。
- 新 run `33027996180` 已验证 3/3 jobs success；不再把该问题归因于 macOS 26 runner。
- 5 条历史 zombie queued runs 继续按 GitHub Actions 后端僵尸状态忽略，不用于队列健康判断，也不再尝试 cancel/force-cancel/delete。

---

## Phase J — Direct vs Encrypted 性能

目标：把 **crypto layer 本身** 与 **FUSE-T/FSKit transport** 开销分开测。

| ID | 状态 | 任务 | 当前证据 / 下一步 |
|---|---|---|---|
| J1 | ✅ | direct/encrypted benchmark helper | `EDPCryptoIOBenchmark.swift`；同 raw adapter；`F_NOCACHE=1`、`F_RDAHEAD=0`；optimized `-O` |
| J2 | ✅ | 读性能矩阵定义 | random + sequential；4 KiB / 64 KiB / 1 MiB；3 trials median |
| J3 | ✅ | 写性能矩阵定义 | random + sequential；4 KiB / 64 KiB / 1 MiB；每 run 末 durability sync；3 trials median |
| J4 | ✅ | partial-write RMW tax | random 4097 B，专门测非对齐 SM4 RMW 额外成本 |
| J5 | ✅ | 公平性约束 | 同 runner、同 256 MiB span、同实际分配文件、direct/encrypted 执行顺序交替 |
| J6 | 🟡 | 首轮 13 组性能结果 | benchmark workflow/helper 已提交；下一步获取真实 run 的 13 组 direct/encrypted read/write throughput、IOPS、slowdown/efficiency 数据 |
| J7 | ⏳ | performance ratchet | 首轮稳定 median 后再设置阈值；不凭空设性能数字，不用单次峰值做 gate |
| J8 | ✅ | full transport read baseline 保留 | 原 H workflow：4K 7.533 MiB/s、64K 37.234 MiB/s、1MiB 52.357 MiB/s、seq 45.597 MiB/s；该口径包含 FUSE-T/FSKit，不与 crypto-only 混用 |

性能输出字段：`direct_mib_s`、`encrypted_mib_s`、IOPS、`slowdown_x`、`efficiency_pct`、direct/encrypted CPU seconds、`cpu_ratio_x`。

---

## Phase K — 文件系统 / Provider

| ID | 状态 | 任务 | 当前证据 / 下一步 |
|---|---|---|---|
| K1 | 🟡 | Apple ExFAT RW | hosted hard gate 待有效 run 完整闭环 CRUD/atomic replace/rename/delete/large file/remount persistence |
| K2 | 🟡 | Apple APFS RW | encrypted E2E 已编写，待同等级实跑 |
| K3 | ✅ | Apple HFS+ RO | 历史 read/Finder 基线已绿；当前只需新 RW-capable bridge 下 RO regression 再绿 |
| K4 | ✅ | Apple native NTFS read | 历史已有只读能力；Apple 不提供 native NTFS write |
| K5 | 🟡 | pure-FSKit NTFS provider 候选审计 | `whereteam/ntfskit`：pure FSKit + Kernel-Offloaded I/O，driver GPL-2.0；`HuanchuanTech/xntfs`：FSKit + libntfs-3g，GPL-2.0；均不依赖 macFUSE。先做外部 provider 构建/engine/许可审计，不直接并入产品 |
| K6 | ⏳ | NTFS provider 真正 E2E | 必须验证 Finder/TextEdit create/overwrite/atomic save/replace/rename/move/delete/large-file/remount；并确认 macOS 26 entitlement/signing/distribution 可行性 |
| K7 | ➖ | legacy NTFS-3G + macFUSE | 只保留历史兼容/性能对照；不得重新成为产品 runtime dependency |

### NTFS provider 当前风险

- `whereteam/ntfskit` driver 基于 GPL-2.0/libntfs-3g 衍生代码；若直接分发/修改需按许可证评估，不能简单复制进闭源产品。
- `xntfs` 明确需要受限 `com.apple.developer.fskit.fsmodule` provisioning 才能运行扩展；hosted CI 可以先做 engine/build，但不能把“编译成功”冒充“系统已加载并实挂载”。
- 最终 NTFS RW 结论必须来自真实外部可写 provider + DiskArbitration/FSKit mount + Finder/TextEdit E2E，而不是 transport 层单测。

---

## 当前优先级

```text
P0  修复 Finder 暴露内部 FUSE-T Transport：Foundation volumeIsBrowsable hard gate + DiskImages2/RW 同时成立后再集成
P0  跑绿 I7/K1 ExFAT encrypted RW CRUD/atomic replace/rename/delete/large-file/remount
P0  跑绿 I9/K2 APFS encrypted RW 同等级 E2E
P0  完成 J6 direct-vs-encrypted 首轮 13 组 median，并据此评估 J7 ratchet
P0  跑绿 I8 explicit HFS RO regression，证明 RW 扩展没有破坏 RO 安全模式
P1  K5/K6 纯 FSKit NTFS provider 构建/许可/真实 Finder/TextEdit 语义验证
P1  性能优化：SM4 CPU、small-block RMW、bridge RSS、FSKit transport overhead 分层处理
Release gate  physical EDP `/dev/rdiskN` RW + sleep/wake + 真实拔盘/异常断开 + NTFS 外部可写 provider 实证 + 商业许可
```

---

## 本轮失败登记

| 问题 | 真实原因 | 处理 |
|---|---|---|
| Finder 暴露内部 `EDP * Transport` | FUSE-T 1.2.7 FSKit 初始 mount 丢失 `nobrowse`；Apple 公共 `FSVolume.MountOptions` 无 no-browse option | 已建立 `statfs(MNT_DONTBROWSE)` probe；停止 legacy/post-mount update 方向，转测 Foundation `volumeIsBrowsable` + 产品隔离方案 |
| `/sbin/mount -u -o nobrowse` | FSKit mount 的 `statfs` type 是 `fuse-t`，mount(8) 转 legacy helper；FSKit-only 安装无 helper | 排除，不进入产品 |
| direct `mount(2)` update | FUSE-T update 需要 FS-specific data；NULL data 返回 EFAULT | 排除，不进入产品 |
| physical authorized product contract run `33025487148` | product bridge 已切换到 privileged launcher inherited-fd 模型，但 workflow 仍 grep 旧 `AUTHOPEN` marker；编译链接本身成功 | `9bdb9ea` 同步并加强契约；run `33027996180` 3/3 jobs success |
| ExFAT fixture 创建失败 | `newfs_exfat` 不接受 `_` 卷标 | 改为 `EDP-EXFAT-RW`；不弱化 CRUD |
| HFS RO regression 误报 | writable-capable FUSE-T transport 的 mount line 不保证包含 `read-only`，即使 backend session 是 RO | 改为 backend `ACCESS_MODE=read-only` + final block/media RO + write rejection + backing invariant |
| deterministic RW test 首版 | assertion helper 非 throwing autoclosure | 改为 throwing assertion；测试范围不缩减 |
| reopen persistence 首版 | local `active` 仍强引用旧 writer，不能证明 fd 真关闭 | 用作用域释放整个 block/reader/raw graph 后再 reopen；marker `RW_CIPHER_PERSISTENCE_AFTER_TRUE_REOPEN` |
| 历史 5 条 queued runs | GitHub Actions backend zombie；cancel/force-cancel=409、DELETE=403 | 永久忽略，不清理，不用于当前 queue 状态判断 |

---

## 本轮提交

| Commit | 内容 |
|---|---|
| `cd49e3c` | P0：显式 FSKit short-name post-mount update probe；确认仍无法绕开 legacy helper |
| `1178750` | P0：对比 CLI `dontbrowse`、user/system `fuse-t.ini` no-browse delivery；均未置 `MNT_DONTBROWSE` |
| `3a88de6` | P0：direct `mount(2)` `MNT_UPDATE|MNT_DONTBROWSE` probe；NULL FS data 返回 EFAULT |
| `5ee801d` | P0：改用 `statfs.f_flags & MNT_DONTBROWSE` 作为内核硬判据，确认初始 FSKit mount flag 为 0 |
| `fadc464` / `e2a6854` / `f9bc38c` | P0：建立、修正最小 FUSE-T no-browse probe 脚手架 |
| `9bdb9ea` | physical RW contract 对齐并加强为 privileged inherited-fd model；触发 run `33027996180` 3/3 全绿 |
| `a4ea147` | RO 回归改为 backend + final block semantics |
| `230d1c4` | 修复 ExFAT 合法卷标 |
| `ef511a0` / `e934594` / `058082a` | deterministic encrypted RW matrix + throwing assertion + true close/reopen |
| `efe15d8` / `f975d95` | RW hard-gate workflow + true-reopen marker |
| `711ebdb` | direct vs encrypted benchmark helper |
| `fa3625e` / `2d38a92` | crypto I/O performance workflow + identical span contract |
| `6f1f432` | 完整 RW / performance test matrix 文档 |
| `4dfd376` | encrypted APFS RW E2E workflow |