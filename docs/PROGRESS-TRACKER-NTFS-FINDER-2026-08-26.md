# EDP USB Vault — NTFS Finder 进度追踪

最后更新：2026-08-26
分支：`feat/macos26-native-fskit`
稳定读写基线：`56dcf39`
当前 WIP 保全：`4f0171d`

> 维护规则：每推进一个可验证步骤，立即更新本文件；写明“做了什么、结果、证据、下一步”，并尽快 commit/push。不要只写“完成/失败”。

## 当前总目标

把真实 EDP U 盘交换区做成 macOS 26+ 上可长期使用的 NTFS 读写卷：

- UI 一键挂载；
- Finder 可读写；
- TextEdit 可正常保存；
- Finder 多选删除/Trash 正常；
- Finder 尽量显示为本地/外置卷而不是网络卷；
- 连续复制性能达到正常可用水平；
- dirty/hibernated/invalid NTFS 坚持 fail-closed；
- 不要求 Reduced Security / kernel backend。

## 状态总览

| 项目 | 状态 | 当前结论 |
|---|---|---|
| macFUSE 5.3.3 FSKit enablement | ✅ | 已启用并真实挂载，勿重复 |
| 自动重试/弹窗风暴 | ✅ | failedMounts 锁存已修 |
| Keychain 后台读取 | ✅ | v3 policy 已修 |
| 精确 raw-device Authorization | ✅ | RW 使用 `sys.openfile.readwrite./dev/rdiskN` |
| 真实 EDP NTFS 读取 | ✅ | `/Volumes/EDP-NTFS` 可读 |
| 真实 EDP NTFS 写入 | ✅ | 临时文件写/读回/sync/delete 已通过 |
| NTFS write safety gate | ✅ | `ntfs-3g.probe --readwrite` 必须先通过 |
| TextEdit 保存 | ❌ P0 | rename-over-existing 返回 `EOPNOTSUPP` |
| Finder 多选删除 | ⚠️ WIP | generic mount 的 `.Trashes` 为 `EPERM`；outer `local` WIP 记录可修复 |
| Finder 本地卷显示 | ⚠️ WIP | stable baseline `MNT_LOCAL=false`；outer `local` WIP 待冷挂载复核 |
| 连续复制性能 | ⚠️ WIP | baseline 约 5.8 MB/s；SM4/FUSE WIP 记录提升到几十 MB/s，需回归 |
| clean installer | ✅ baseline | `56dcf39` 读写版通过 verifier；WIP 需重建复核 |

## 已完成里程碑

### M1 — 只读 Finder mount

- [x] macFUSE generic FSKit 用户会话挂载成功
- [x] root daemon + UID 501 FUSE/NTFS 架构确定
- [x] `/Volumes/EDP-NTFS` 能读取真实文件
- [x] 只读写入负向测试通过

关键 commit：`393fe47`

### M2 — NTFS 真实读写

- [x] App raw right 改为 `sys.openfile.readwrite./dev/rdiskN`
- [x] bridge 改为 `--device-auth` / `O_RDWR`
- [x] `ntfs-3g.probe --readwrite`
- [x] NTFS-3G 去掉 `ro`
- [x] 实盘 44-byte 临时文件写入
- [x] 读回一致
- [x] sync
- [x] 删除并确认不存在
- [x] installer verifier 增加 production RW ratchet

关键 commit：`56dcf39`

### M3 — Finder 语义问题定位

- [x] TextEdit 原子替换路径复现
- [x] `rename(temp, existing-target)` 返回 errno 102 / `EOPNOTSUPP`
- [x] xattr set/remove 正常
- [x] directory rename 正常
- [x] 普通批量 unlink 正常
- [x] generic mount `.Trashes` `listdir/mkdir` 返回 `EPERM`
- [x] 证实多选删除问题主要是 Finder Trash 语义，不是底层 unlink 不可用

### M4 — WIP local/performance 实验保全

- [x] outer NTFS policy 添加 `local`
- [x] CI policy ratchet 改为要求 `local`
- [x] inner bridge 只加 `big_writes,noatime`，不加 `local`
- [x] SM4 ECB 热路径减少临时 Array 分配
- [x] WIP 单独保全到 commit `4f0171d`
- [ ] 重新构建/安装 WIP 后完整冷挂载回归
- [ ] GitHub Actions 全绿
- [ ] 将 WIP 升级为稳定实现或回退不安全部分

## 当前最高优先级任务

### T1 — P0 TextEdit 原子保存

状态：**未解决**

已知复现：

```text
rename(temp, existing-target)
-> errno 102
-> EOPNOTSUPP
-> "Operation not supported on socket"
```

下一步：

- [x] 建最小 macFUSE FSKit rename-over-existing reproducer，先不经过 EDP/NTFS
- [x] generic module 测一次
- [ ] local module/outer-local 测一次
- [x] 记录普通 `rename`、`renamex_np`、swap/exclusive flag 行为
  - 2026-08-26 实机 outer-local `/Volumes/EDP-NTFS`：`renamex_np(flags=0)` 覆盖已有目标返回 `errno=102/EOPNOTSUPP`；`RENAME_EXCL` 对已有目标正确返回 `EEXIST(17)`；`RENAME_SWAP` 返回 `EOPNOTSUPP`。
  - 当前 `ntfs-3g` patch 对 flags=0 最终调用上游 `ntfs_fuse_rename()`；上游 2026.7.7 的 existing-destination 路径本身以 hard-link/unlink 临时名实现，并明确带有 `FIXME: Rename should be atomic.`，因此不能把该路径直接包装成“安全原子替换”。
- [ ] 查 macFUSE 5.3.3/Tahoe FSKit upstream issue/release notes
- [ ] 判断能否在 NTFS-3G/FUSE 用户态做安全兼容；要求是真正 crash-safe/atomic，不接受先删目标再 rename
- [ ] 增加 atomic replace regression test
- [ ] TextEdit 实机 Cmd+S 验收

禁止：先删除旧目标再 rename 的非原子 workaround。

#### 2026-08-26 16:14 — generic FSKit 锁定 `RENAME_SWAP`

目标：
- 将 TextEdit/普通 POSIX 覆盖式 rename 与 EDP、NTFS-3G 解耦，确认 macFUSE FSKit 实际送到 FUSE2 userspace 的操作和 flags。

改动：
- 扩展 `ValidateFuse2Create.c`，预置 `target.txt`，增加 `.rename` / `.renamex` / init capability 日志；
- 扩展 `probe-fuse2-create.sh`，用 libc `rename(temp, existing-target)` 做最小覆盖测试；本机 mountpoint 使用 `/private/tmp`，避免再次请求 sudo。

验证：
- generic FSKit mount：`macfuse://... (macfuse,...,fskit,mounted by zhangyuxi)`；
- create/write/read 正常；
- libc `rename(created.txt, target.txt)` 返回 `errno=102 / EOPNOTSUPP`；
- 服务端不是进入传统 `.rename`，而是明确收到 `FUSE2_RENAMEX old=/created.txt new=/target.txt flags=0x2`；
- `0x2` 即 `RENAME_SWAP`；init 中已执行 `conn->want &= ~FUSE_CAP_RENAME_SWAP`，但 FSKit 仍然发送 swap 请求。

结论：
- PASS（根因进一步收敛）。当前仓库的 NTFS-3G adapter patch 对 `RENAME_SWAP` 明确返回 `-EOPNOTSUPP`，与实机 TextEdit/普通覆盖 rename 的错误完全吻合。不能再把该问题笼统归类为“macFUSE 上游不可修”；下一判别点是安全实现 swap callback 后，FSKit 是否会自行完成 POSIX replace 所需的旧路径清理。

下一步：
- 在最小内存 FUSE2 probe 中实现真正的 `RENAME_SWAP`（交换两个已存在对象），观察 libc `rename()` 返回前 FSKit 是否追加 unlink/其他操作并最终保证 source path 消失；
- 若最小语义成立，再研究 NTFS-3G 内部可否原子实现 exchange，而不是采用先删目标的非原子 workaround；
- 之后再比较 outer `local` 行为。

commit:
- `3c8390f test: isolate FSKit rename swap semantics`

#### 2026-08-26 16:16 — 字面 `RENAME_SWAP` 不能直接作为修复

目标：
- 验证只要 userspace 真正实现 `RENAME_SWAP`，macFUSE FSKit 是否会在 libc `rename(temp, existing-target)` 返回前自动补做 source cleanup，从而恢复 POSIX replace 语义。

改动：
- 最小内存 FUSE2 probe 增加可选 `EDP_FUSE2_SUPPORT_RENAME_SWAP=1`；收到 `flags=0x2` 时真正交换 temp/target 两个对象的数据；
- probe 在 rename 返回后立即检查 target 内容和 source path 是否仍存在。

验证：
- 不启用 swap 支持时，仍稳定复现 `errno=102/EOPNOTSUPP`；
- 启用字面 swap 时，libc `rename()` 返回 0，target 内容变成新内容；
- 但 source path **仍存在**，且内容变成旧 target 的 `old-content`；服务端没有在 syscall 返回前收到额外 unlink；
- 因此最终状态是“交换”，不是 POSIX `rename()` 要求的“source 消失 + target 原子替换”。

结论：
- PASS（否决直接实现 swap）。不能把当前 patch 从 `EOPNOTSUPP` 简单改成字面 `RENAME_SWAP`，否则 TextEdit 可能表面保存成功但会留下临时旧文件，语义错误。
- 结合 `7040dc6` 已记录的源码审阅：NTFS-3G 2026.7.7 现有 existing-target rename 本身也有 `FIXME: Rename should be atomic.`，所以也不能简单把 FSKit 的 `0x2` 映射到现有 `ntfs_fuse_rename()` 后宣称满足产品原子性。

下一步：
- 查 macFUSE 5.3.3 FSKit rename bridge/upstream issue，确认为何普通 POSIX rename 被编码为 `RENAME_SWAP`；
- 同时审阅 libntfs-3g 更底层目录项 API，寻找可在单事务/可恢复语义内完成 replace/exchange 的 primitive；若没有，则需要明确记录上游阻塞而不是引入非原子 workaround。

commit:
- `f1db145 test: reject literal FSKit rename swap fix`

#### 2026-08-26 16:20 — macFUSE/libntfs 原子能力边界

目标：
- 判断 P0 是否存在不破坏原子性的“小补丁”路径。

验证：
- 本机 macFUSE 5.3.3 FUSE2 头文件对普通 `rename`/`renamex` 明确写明：目标存在时应 **atomically replaced**；`FUSE_CAP_RENAME_SWAP` 只是声明 filesystem 支持 `renamex_np(..., RENAME_SWAP)` 的额外能力。
- 但最小 generic FSKit 实证已表明：即使 filesystem 在 init 中清除 `FUSE_CAP_RENAME_SWAP`，普通 libc `rename(temp, existing-target)` 仍被 FSKit 转成 `renamex(..., flags=0x2)`。
- macFUSE 官方 capability 文档同样把 `FUSE_CAP_RENAME_SWAP` 定义为 `renamex()` 的 swap-renaming 能力，而不是普通 POSIX replace 的替代语义；官方 issue #1140 也有 Tahoe/TextEdit 无法保存的同类报告。
- 审阅固定 libntfs-3g 2026.7.7：没有公开 `ntfs_rename` / atomic exchange API；`dir.c` 仍写有 FIXME “Write ntfs_rename that uses __ntfs_link”，当前 rename 使用临时 hard-link/unlink 序列。`$LogFile` 代码主要用于检查/清理 journal，没有可直接复用的 userspace rename transaction primitive。

结论：
- PARTIAL / UPSTREAM-BOUNDARY。当前没有一个可以安全地把 `RENAME_SWAP` 直接映射成 NTFS 原子 replace 的现成 primitive。
- 不应在 EDP/NTFS patch 中实现 delete-then-rename、link/unlink swap 或其他会在 crash 中留下双名/丢名窗口的 workaround。
- P0 下一步转为验证 **TextEdit 实际完整保存事务**：若应用在 swap 成功后主动 unlink 临时旧文件，则真正需求是“原子 exchange”；若没有，则 macFUSE FSKit 本身把普通 POSIX rename 暴露成错误语义，必须等待/推动 upstream bridge 修复。

下一步：
- 用最小、隔离的文件监控/回调日志捕获 TextEdit 保存全过程（只对临时测试 txt），确认 swap 后是否由 TextEdit 自己删除旧内容临时路径；
- 同时继续观察 macFUSE upstream 对 Tahoe/TextEdit/FSKit rename 的修复，不修改真实用户文件。

commit:
- `1ec3c38 docs: record FSKit atomic rename boundary`

#### 2026-08-26 16:23 — 显式 swap capability 仍不恢复 POSIX rename

目标：
- 排除“因为 probe/NTFS patch 清除了 `FUSE_CAP_RENAME_SWAP`，FSKit 才异常发送 swap”的可能。

改动：
- 最小 FUSE2 probe 在 `EDP_FUSE2_SUPPORT_RENAME_SWAP=1` 时显式保留/请求 `FUSE_CAP_RENAME_SWAP`；未开启时继续清除 capability，形成可控对照。

验证：
- generic FSKit：`capable=0x67a00800`，`want_before=0x86200010`；启用实验后 `want_after=0x86200010`，确认 bit `0x02000000` (`FUSE_CAP_RENAME_SWAP`) 实际保留。
- libc `rename(created.txt,target.txt)` 仍只触发 `FUSE2_RENAMEX ... flags=0x2`。
- callback 返回成功后 syscall 返回 0、target 为新内容，但 source 仍存在且持有旧 target 内容；FSKit 没有追加 unlink。probe 最后的 `FUSE2_UNLINK /created.txt` 是测试清理代码，不属于 rename syscall。

结论：
- PASS。问题不是 capability negotiation 配错；即使明确宣告 swap，macFUSE 5.3.3 FSKit 对普通 overwrite rename 的可见语义仍是“exchange 后 source 保留”。
- 因此不能通过单纯打开 `FUSE_CAP_RENAME_SWAP` 修复 TextEdit，也不能把当前 NTFS patch 的 `EOPNOTSUPP` 改成字面 swap 后视为完成。

附加实机：
- 对真实 `/Volumes/EDP-NTFS` 仅创建 `.edp-textedit-automation-probe.txt` 临时文件，AppleScript 驱动 TextEdit 打开、修改、保存，稳定得到 AppleEvent save failure；保存过程中出现 `.sb-*` 临时路径，目标内容保持旧值。关闭文档后专用测试文件已清理，未触碰既有用户文件。
- 尝试在最小 FUSE 上捕获完整 TextEdit 流程时，macFUSE 先创建 `._target.txt` AppleDouble 文件；`noappledouble` 在 FSKit backend 下未抑制该行为，因此当前单动态文件 probe 尚不足以进入 TextEdit 的 rename 阶段。

下一步：
- 若继续做 TextEdit 全事务诊断，最小 probe 需要支持多个并存临时文件/AppleDouble，而不是改变生产路径；
- P0 代码修复仍必须等待可证明的原子 primitive 或 upstream FSKit rename bridge 修复。

补充验证：
- 将 synthetic probe 的 init 改为在 `support_swap=1` 时真实保留 `FUSE_CAP_RENAME_SWAP` 协商位，再次运行；`want_after=0x86200010` 明确包含 swap capability。
- 结果仍是：libc `rename()` 返回 0、target 变为新内容、source 仍存在且保存旧 target 内容。说明该错误语义不是因为先前 init 清掉 `want` 导致，而是 FSKit/bridge 对 overwrite rename 的实际编码行为。

commit:
- pending

### T2 — P1 Finder 本地卷 + Trash

状态：**WIP，代码已保全到 4f0171d**

下一步：

- [ ] 构建并安装 `4f0171d` 对应 runtime
- [ ] 安全卸载旧卷后 cold remount
- [ ] `mount` 检查 outer source/flags
- [ ] `statfs` 确认 `MNT_LOCAL=true`
- [ ] Finder 确认不再归类为网络位置
- [ ] `.Trashes/501` list/create 可用
- [ ] Finder 多选 10 个临时文件删除
- [ ] Finder 多选 100 个临时文件删除
- [ ] Trash 恢复
- [ ] 清空 Trash
- [ ] 确认 inner `volume.raw` 仍是 generic FSKit

风险：inner bridge 不能随意加 `local`，已有实验记录会导致 `ntfs-3g.probe --readwrite` status 13/EIO。

### T3 — P1 性能

状态：**WIP，需正式回归**

下一步：

- [ ] 对 SM4 优化跑标准 vector
- [ ] 跑现有 native crypto fast checks
- [ ] 跑 DiskImages2/NTFS readwrite E2E
- [ ] 实盘 256 MiB inner sequential read
- [ ] 实盘 256 MiB outer sequential read
- [ ] 实盘 256 MiB outer sequential write + fsync
- [ ] 1000×4 KiB small files
- [ ] 记录 CPU 占用和平均请求尺寸
- [ ] 比较 baseline `56dcf39` 与 WIP `4f0171d`

当前 tracker 中已有实验参考值，但下一个 AI 应重新复核：

```text
baseline inner sequential read ≈ 5.8 MB/s
WIP inner sequential read ≈ 55.8 MB/s
WIP outer write + fsync ≈ 37.8 MB/s
500 × 4 KiB ≈ 6 s
```

### 2026-08-26 — P0 rename syscall 边界确认

目标：
- 把 TextEdit 保存失败从“可能的 FSKit 特殊行为”收敛到确切 callback/NTFS adapter 语义。

验证：
- 当前真实卷保持 inner generic FSKit + outer `local`；只创建并清理 `.edp-rename-probe-*` 临时文件。
- `renamex_np(temp,target,0)`：`errno=102/EOPNOTSUPP`。
- `renamex_np(temp,target,RENAME_EXCL)`：`errno=17/EEXIST`，符合排他重命名语义。
- `renamex_np(a,b,RENAME_SWAP)`：`errno=102/EOPNOTSUPP`。
- 审阅固定 NTFS-3G 2026.7.7 源码：existing-target rename 走 `ntfs_fuse_rename_existing_dest()` / `ntfs_fuse_safe_rename()`，内部是 link → unlink → link → unlink，并由上游注释明确标记 rename 尚非 atomic。

结论：
- PARTIAL。P0 不是 EDP crypto/块层问题，也不只是 TextEdit 的 swap flag；普通 replace (`flags=0`) 也会落到 NTFS-3G 当前不满足产品原子性要求的 existing-target rename 路径。
- 下一步只接受两类方向：找到 macFUSE/FSKit 可转发的真正原子 primitive，或在 NTFS-3G/libntfs 层实现可证明的 NTFS 原子目录项替换；不采用 delete-then-rename workaround。

commit:
- pending

## 回归任务

### T4 — NTFS safety

- [ ] dirty NTFS 拒绝 RW mount
- [ ] hibernated/Fast Startup 拒绝 RW mount
- [ ] invalid partition type 4 继续拒绝
- [ ] wrong password fail closed
- [ ] raw authorization 丢失时不自动循环弹窗

### T5 — 生命周期

- [ ] UI 挂载
- [ ] UI 安全弹出
- [ ] 拔盘
- [ ] daemon restart
- [ ] FUSE crash cleanup
- [ ] NTFS-3G crash cleanup
- [ ] remount 后文件 hash 一致

### T6 — 发布前

- [ ] `git diff --check`
- [ ] clean installer rebuild
- [ ] `RESULT=PRODUCTION_NTFS_READWRITE_PATH_ENFORCED`
- [ ] `RESULT=EDP_CLEAN_INSTALLER_VERIFIED`
- [ ] GitHub Actions 全绿
- [ ] 更新 `docs/STATUS.md`
- [ ] 更新本 tracker
- [ ] commit + push

## 当前 Git 边界

稳定基线：

```text
56dcf39 feat: enable Finder NTFS read-write mounts
```

当前 WIP：

```text
4f0171d wip: preserve Finder local-volume and performance work
```

`4f0171d` 只表示“不要丢失当前实验代码”，不等于发布批准。

## 每次进展记录模板

```text
### YYYY-MM-DD HH:MM — <短标题>

目标：
- ...

改动：
- ...

验证：
- command/test: ...
- result: ...
- evidence: ...

结论：
- PASS / FAIL / PARTIAL

下一步：
- ...

commit:
- <hash or pending>
```

## 交接读取顺序

下一个 AI 必须先读：

1. `docs/STATUS.md`
2. `docs/diagnostics/2026-08-26-ntfs-finder-semantics-handoff.md`
3. `docs/PROGRESS-TRACKER-NTFS-FINDER-2026-08-26.md`
4. `docs/PLAN-TRACKER-2026-08-26.md`

然后检查 Git HEAD、working tree、当前已安装 runtime 与当前 mount，不要根据旧聊天猜状态。
