# EDP USB Vault — Read/Write Regression & Performance Matrix

日期：2026-08-26  
目标分支：`test/fuset-minimal-fskit-bridge`

## 目标

当前目标从只读 PoC 扩展为 **macOS 26+ 可持续回归的 EDP 读写路径**，同时保留只读模式作为安全回退与防误写回归。

产品核心路径要求：

```text
EDP physical /dev/rdiskN
  -> narrow authopen O_RDWR | O_CLOEXEC
  -> LBA11/LBA12 validate + password/file-key derive
  -> EDPEncryptedPartitionReader / EDPEncryptedReadWriteBlockDevice
  -> EDP-owned FUSE-T Unix socket thin bridge
  -> hidden writable volume.raw
  -> DiskImages raw block device
  -> native filesystem / separately installed provider
  -> Finder
```

最终产品核心不依赖 macFUSE、libfuse、go-nfsv4 或 bundled NTFS-3G。NTFS provider 兼容测试可以存在，但必须与产品依赖边界分离。

## Hard-gate 矩阵

| Layer | Gate | 覆盖内容 | 通过条件 |
|---|---|---|---|
| Swift build | Swift 6 strict | `-warnings-as-errors`，standalone/library 两种构建 | 全部编译成功 |
| Raw storage | direct read/write | `pread/pwrite`、0-byte、bounds、sync | exact I/O；越界必须失败 |
| Crypto read | SM4 random access | 1B、跨 16B、4K、64K、1MiB、tail | plaintext exact match |
| Crypto write | aligned write | 4K/64K/1MiB | write-after-read exact match |
| Crypto write | partial RMW | 1B、31B、33B、4097B、7777B、unaligned 64K | 左右邻接字节不被破坏 |
| Crypto persistence | detach/reopen equivalent | sync 后重新打开 cipher backing | 全 plaintext state 保持 |
| Crypto safety | RO cannot upgrade | read-only raw backing 构造 RW block | 必须拒绝 |
| Thin RPC | writable protocol | request payload → `pwrite`；`write_size` response；flush/fsync | payload 长度与落盘一致 |
| Thin RPC | bounds | negative/overflow/end-of-file | 必须失败，不截断静默成功 |
| Thin RPC | RO mode | `readOnly: true` | final Apple FS 仍只读，backing 不变 |
| Product auth | raw-device path | 仅 `/dev/rdiskN` whole disk | regular file / partition node 拒绝 |
| Product auth | flags | fixed `O_RDWR | O_CLOEXEC` | caller 无法注入 flags；无 `O_TRUNC/O_CREAT` |
| Product secret | password/control stream | max 4096，secure zero，非 argv | 密码不打印、不写仓库 |
| ExFAT E2E | native RW | create/read/replace/rename/move/delete/64MiB file/Finder | `Media/Volume Read-Only: No` |
| ExFAT persistence | detach/remount | encrypted backing changes then remount | CRUD 与大文件 SHA 持久化 |
| RO regression | HFS+ | Apple FS read + Finder + attempted write | write fails；backing SHA/meta 不变 |
| Crash safety | backend death | uncached read after bridge SIGKILL | fail-closed，不返回 silent bad data |
| Cleanup | graceful/crash | hidden mount/session/socket/process | 无 stale EDP session/socket |

## Filesystem / provider 矩阵

| Filesystem | Provider | 产品依赖？ | Read | Write | Finder | Atomic replace | Remount persistence | 说明 |
|---|---|---:|---:|---:|---:|---:|---:|---|
| HFS+ | Apple | 否（测试 fixture） | ✅ | RO baseline | ✅ | N/A | ✅ | 用于 Apple FS 与 RO 安全回归 |
| ExFAT | Apple | 否（系统自带） | gate | gate | gate | gate | gate | 当前最重要的 hosted RW E2E |
| APFS | Apple | 否（系统自带） | 待补 | 待补 | 待补 | 待补 | 待补 | raw single-container fixture 需避免 APFS container 语义干扰 |
| NTFS | Apple | 否 | ✅ read | ❌ native write | ✅ | N/A | N/A | Apple 原生只读能力 |
| NTFS | separately installed provider | **不得成为核心依赖** | compat | compat | compat | compat | compat | provider 独立安装时验证 block transport 可交给它 |
| NTFS-3G + macFUSE | legacy comparison only | **否** | legacy | legacy | legacy | known issues | legacy | 仅用于历史/性能/语义对照，不重新进入产品 runtime |

## Finder / POSIX RW 操作矩阵

ExFAT RW hosted gate 至少覆盖：

1. create directory；
2. create small file；
3. overwrite existing file；
4. atomic-style `rename(temp, existing-target)`；
5. rename same directory；
6. move file across directories；
7. delete file；
8. delete multiple files / directory tree（后续补 Finder UI automation）；
9. 64 MiB deterministic file write + SHA readback；
10. Finder enumeration；
11. xattr：记录 supported / provider-rejected，不将 ExFAT 不支持某 xattr 误判为 transport 失败；
12. detach/remount 后重复 2/4/6/7/9 的持久化检查。

## Direct vs encrypted 性能矩阵

### 原则

- 同一台 `macos-26` runner；
- direct 与 encrypted 使用相同大小的实际分配文件；
- `F_NOCACHE=1`、`F_RDAHEAD=0`；
- `-O` optimized Swift；
- 每组 3 次，取 median；
- trial 顺序交替 direct/encrypted，减少热机顺序偏差；
- write 每次 run 末尾包含一次 durability sync；
- crypto-only 对照 **不经过 FSKit/DiskImages/filesystem**，只测加密层成本；
- 现有 FUSE-T performance workflow 继续测 end-to-end transport read，两个口径不得混用。

### 基准项

| Operation | Pattern | Block | Per-trial bytes | 指标 |
|---|---|---:|---:|---|
| read | random | 4 KiB | 64 MiB | MiB/s, IOPS, CPU seconds |
| read | random | 64 KiB | 64 MiB | 同上 |
| read | random | 1 MiB | 64 MiB | 同上 |
| read | sequential | 4 KiB | 64 MiB | 同上 |
| read | sequential | 64 KiB | 64 MiB | 同上 |
| read | sequential | 1 MiB | 256 MiB | 同上 |
| write | random | 4 KiB | 64 MiB | MiB/s, IOPS, CPU seconds |
| write | random | 64 KiB | 64 MiB | 同上 |
| write | random | 1 MiB | 64 MiB | 同上 |
| write | sequential | 4 KiB | 64 MiB | 同上 |
| write | sequential | 64 KiB | 64 MiB | 同上 |
| write | sequential | 1 MiB | 256 MiB | 同上 |
| write | random partial RMW | 4097 B | ~16 MiB | 专门测非 16-byte aligned RMW tax |

每项输出：

```text
direct_mib_s
encrypted_mib_s
direct_iops
encrypted_iops
slowdown_x = direct / encrypted
efficiency_pct = encrypted / direct * 100
direct_cpu_s
encrypted_cpu_s
cpu_ratio_x = encrypted / direct
```

首轮基准只要求结果有效且可重复；完成首轮后，用 3 次 median 作为 baseline，再设置 performance ratchet。建议 ratchet 至少留出 hosted runner 噪声余量，不直接用单次峰值。

## CI workflow 对应关系

| Workflow | 角色 | Gate |
|---|---|---|
| `fuset-readwrite-regression-contract.yml` | crypto / thin RPC / authorized physical RW 静态与 deterministic gate | hard |
| `fuset-edp-exfat-readwrite.yml` | encrypted EDP → FUSE-T → raw disk → Apple ExFAT RW/Finder/persistence | hard |
| `fuset-minimal-fskit-applefs.yml` | explicit RO safe-mode regression | hard |
| `fuset-minimal-fskit-contract.yml` | FUSE-T session/RPC binary contract | hard |
| `fuset-minimal-fskit-edp-sm4.yml` | encrypted random-read regression | hard |
| `fuset-minimal-fskit-edp-unlock.yml` | captured real metadata unlock | hard |
| `fuset-minimal-fskit-stability.yml` | crash/cleanup/Finder large-file | hard |
| `edp-crypto-io-overhead.yml` | direct vs encrypted read/write cost | baseline → ratchet |
| `fuset-minimal-fskit-performance.yml` | full FUSE-T transport read performance | baseline → ratchet |
| `edp-crypto-ntfs3g-readwrite.yml` | legacy/provider comparison | compatibility only |

## 当前执行状态

- ✅ writable thin RPC 已实现并保留 explicit RO mode。
- ✅ EDP encrypted block writer 使用 serialized 16-byte aligned RMW。
- ✅ formal physical authorized RW bridge 固定 whole `/dev/rdiskN` + `O_RDWR|O_CLOEXEC`。
- ✅ deterministic encrypted RW matrix tool 已提交。
- ✅ direct-vs-encrypted read/write benchmark tool/workflow 已提交。
- 🟡 read-write regression contract：等待首轮 Actions 结果。
- 🟡 ExFAT encrypted RW E2E：已修正 ExFAT label，等待首轮完整 CRUD/remount 结果。
- 🟡 HFS+ RO regression：已改为 backend + final block-layer 实质判定，等待回归结果。
- 🟡 crypto performance comparison：等待首轮 13 组 × 3 trial 结果，之后设置 ratchet。
- ⏳ physical EDP `/dev/rdiskN` 真机 RW、sleep/wake、拔盘仍是 release gate。
