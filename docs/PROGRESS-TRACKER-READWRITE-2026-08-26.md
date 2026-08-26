# EDP USB Vault — Read/Write 实时进度追踪

日期：2026-08-26  
分支：`test/fuset-minimal-fskit-bridge`  
完整测试矩阵：`docs/TEST-MATRIX-READWRITE-2026-08-26.md`  
历史只读基线：`docs/PROGRESS-TRACKER-FUSET-MINIMAL-FSKIT-2026-08-26.md`

## 当前总状态

**目标已从“只读 thin bridge PoC”扩展为“读写产品路径 + 显式只读安全模式”。**

当前核心架构：

```text
physical /dev/rdiskN
  -> authopen fixed O_RDWR | O_CLOEXEC
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
- whole raw device 仅允许 `/dev/rdiskN`，固定 `O_RDWR | O_CLOEXEC`，禁止 caller 注入 open flags。
- RO 模式继续保留并独立回归；RW 能力不得把 RO 安全模式静默升级为可写。
- NTFS 可写必须由实际可写 NTFS provider 证明；ExFAT/APFS 绿灯不能冒充 NTFS 已解决。

---

## Phase I — RW 核心与防回归矩阵

| ID | 状态 | 任务 | 当前证据 / 下一步 |
|---|---|---|---|
| I1 | ✅ | thin RPC writable transport | `FuseTWriteBacking`、`pwrite`、`synchronize`、`write_size` response；explicit `readOnly` mode |
| I2 | ✅ | encrypted SM4 random-access writer | `EDPEncryptedPartitionReader` 16-byte aligned RMW；single `NSLock` 串行 read/write/sync |
| I3 | ✅ | formal physical RW adapter | `FuseTEDPAuthorizedReadWriteBridge.swift`；whole `/dev/rdiskN`；control-fd secret；无 plaintext cache |
| I4 | ✅ | narrow privileged raw-open helper | `product/EDPRawReadWriteAuthorization.c` 固定 `O_RDWR|O_CLOEXEC`；无 `O_TRUNC/O_CREAT` |
| I5 | 🟡 | deterministic encrypted RW matrix | tool 已提交；1B/31B/33B/4097B/7777B/4K/64K/1MiB/tail + bounds + zero-write + true close/reopen + RO cannot upgrade；workflow run #1 queued，run #2 出现 `startup_failure`（无 job，按 runner/infrastructure 处理，不弱化测试） |
| I6 | 🟡 | strict product/RPC contract workflow | `.github/workflows/fuset-readwrite-regression-contract.yml` 已注册；等待可执行 run 完成 3 jobs |
| I7 | 🟡 | ExFAT encrypted RW E2E | 首轮失败仅因 `_` 非法卷标；已改 `EDP-EXFAT-RW`；待完整 CRUD/Finder/detach-remount 持久化 run |
| I8 | 🟡 | HFS+ explicit RO safety regression | hidden mount 字符串不是可靠 RO 判据；已改为 `ACCESS_MODE=read-only` + final HFS Media/Volume RO + write fail + backing unchanged；最近 run 被 Actions 并发/runner 状态中断，需下一轮有效 run |
| I9 | 🟡 | APFS encrypted RW E2E | workflow 已创建：real metadata → cipher → thin RW → APFS → CRUD/xattr/Finder → remount persistence；需第二次 workflow 提交注册并实跑 |
| I10 | ⏳ | physical EDP `/dev/rdiskN` RW | hosted runner 无真实 USB；formal auth contract 先全绿，随后实机验证真实介质读写与断电/拔盘 |

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
| J6 | 🟡 | 首轮 13 组性能结果 | `.github/workflows/edp-crypto-io-overhead.yml` 已第二次提交以触发注册；等待 run |
| J7 | ⏳ | performance ratchet | 首轮稳定 median 后再设置阈值；不凭空设性能数字，不用单次峰值做 gate |
| J8 | ✅ | full transport read baseline 保留 | 原 H workflow：4K 7.533 MiB/s、64K 37.234 MiB/s、1MiB 52.357 MiB/s、seq 45.597 MiB/s；该口径包含 FUSE-T/FSKit，不与 crypto-only 混用 |

性能输出字段：`direct_mib_s`、`encrypted_mib_s`、IOPS、`slowdown_x`、`efficiency_pct`、direct/encrypted CPU seconds、`cpu_ratio_x`。

---

## Phase K — 文件系统 / Provider

| ID | 状态 | 任务 | 当前证据 / 下一步 |
|---|---|---|---|
| K1 | 🟡 | Apple ExFAT RW | hosted hard gate 正在跑 |
| K2 | 🟡 | Apple APFS RW | encrypted E2E 已编写，待实跑 |
| K3 | ✅ | Apple HFS+ RO | 历史 read/Finder 基线已绿；当前只需新 RW-capable bridge 下 RO regression 再绿 |
| K4 | ✅ | Apple native NTFS read | 历史已有只读能力；Apple 不提供 native NTFS write |
| K5 | 🟡 | pure-FSKit NTFS provider 候选审计 | `whereteam/ntfskit`：pure FSKit + Kernel-Offloaded I/O，driver GPL-2.0；`HuanchuanTech/xntfs`：FSKit + libntfs-3g，GPL-2.0；均不依赖 macFUSE。先做外部 provider 构建/engine/许可审计，不直接并入产品 |
| K6 | ⏳ | NTFS provider 真正 E2E | 必须验证 Finder create/overwrite/atomic replace/rename/move/delete/large-file/remount；并确认 macOS 26 entitlement/signing/distribution 可行性 |
| K7 | ➖ | legacy NTFS-3G + macFUSE | 只保留历史兼容/性能对照；不得重新成为产品 runtime dependency |

### NTFS provider 当前风险

- `whereteam/ntfskit` driver 基于 GPL-2.0/libntfs-3g 衍生代码；若直接分发/修改需按许可证评估，不能简单复制进闭源产品。
- `xntfs` 明确需要受限 `com.apple.developer.fskit.fsmodule` provisioning 才能运行扩展；hosted CI 可以先做 engine/build，但不能把“编译成功”冒充“系统已加载并实挂载”。
- 最终 NTFS RW 结论必须来自真实 provider + DiskArbitration/FSKit mount 的 E2E，而不是 transport 层单测。

---

## 当前优先级

```text
P0  跑绿 I5/I6 deterministic RW + formal authorized product contract
P0  跑绿 I7 ExFAT encrypted RW CRUD/Finder/remount
P0  跑绿 I8 explicit RO regression，证明 RW 扩展没有破坏 RO 安全模式
P0  完成 J6 direct-vs-encrypted 首轮 13 组 median，并据此设 J7 ratchet
P1  跑绿 I9/K2 APFS encrypted RW
P1  K5/K6 纯 FSKit NTFS provider 构建/许可/真实语义验证
P1  性能优化：SM4 CPU、small-block RMW、bridge RSS、FSKit transport overhead 分层处理
Release gate  physical EDP `/dev/rdiskN` RW + sleep/wake + 真实拔盘/异常断开 + 商业许可
```

---

## 本轮失败登记

| 问题 | 真实原因 | 处理 |
|---|---|---|
| ExFAT fixture 创建失败 | `newfs_exfat` 不接受 `_` 卷标 | 改为 `EDP-EXFAT-RW`；不弱化 CRUD |
| HFS RO regression 误报 | writable-capable FUSE-T transport 的 mount line 不保证包含 `read-only`，即使 backend session 是 RO | 改为 backend `ACCESS_MODE=read-only` + final block/media RO + write rejection + backing invariant |
| deterministic RW test 首版 | assertion helper 非 throwing autoclosure | 改为 throwing assertion；测试范围不缩减 |
| reopen persistence 首版 | local `active` 仍强引用旧 writer，不能证明 fd 真关闭 | 用作用域释放整个 block/reader/raw graph 后再 reopen；marker `RW_CIPHER_PERSISTENCE_AFTER_TRUE_REOPEN` |
| RW workflow run #2 | GitHub Actions `startup_failure`，无 jobs 创建 | 保留 queued run #1；视为 runner/infrastructure，不改测试 |

---

## 本轮提交

| Commit | 内容 |
|---|---|
| `a4ea147` | RO 回归改为 backend + final block semantics |
| `230d1c4` | 修复 ExFAT 合法卷标 |
| `ef511a0` / `e934594` / `058082a` | deterministic encrypted RW matrix + throwing assertion + true close/reopen |
| `efe15d8` / `f975d95` | RW hard-gate workflow + true-reopen marker |
| `711ebdb` | direct vs encrypted benchmark helper |
| `fa3625e` / `2d38a92` | crypto I/O performance workflow + identical span contract |
| `6f1f432` | 完整 RW / performance test matrix 文档 |
| `4dfd376` | encrypted APFS RW E2E workflow |
