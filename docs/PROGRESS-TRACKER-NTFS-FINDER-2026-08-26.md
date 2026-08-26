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

- [ ] 建最小 macFUSE FSKit rename-over-existing reproducer，先不经过 EDP/NTFS
- [ ] generic module 测一次
- [ ] local module/outer-local 测一次
- [x] 记录普通 `rename`、`renamex_np`、swap/exclusive flag 行为
  - 2026-08-26 实机 outer-local `/Volumes/EDP-NTFS`：`renamex_np(flags=0)` 覆盖已有目标返回 `errno=102/EOPNOTSUPP`；`RENAME_EXCL` 对已有目标正确返回 `EEXIST(17)`；`RENAME_SWAP` 返回 `EOPNOTSUPP`。
  - 当前 `ntfs-3g` patch 对 flags=0 最终调用上游 `ntfs_fuse_rename()`；上游 2026.7.7 的 existing-destination 路径本身以 hard-link/unlink 临时名实现，并明确带有 `FIXME: Rename should be atomic.`，因此不能把该路径直接包装成“安全原子替换”。
- [ ] 查 macFUSE 5.3.3/Tahoe FSKit upstream issue/release notes
- [ ] 判断能否在 NTFS-3G/FUSE 用户态做安全兼容；要求是真正 crash-safe/atomic，不接受先删目标再 rename
- [ ] 增加 atomic replace regression test
- [ ] TextEdit 实机 Cmd+S 验收

禁止：先删除旧目标再 rename 的非原子 workaround。

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
