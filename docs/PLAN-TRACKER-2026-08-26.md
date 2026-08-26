# EDP USB Vault — 计划推进追踪

日期：2026-08-26  
目标分支：`feat/macos26-native-fskit`  
关联计划：`docs/PLAN-2026-08-26-ntfs-readwrite-and-native-refactor.md`

## 追踪规则

- 每完成一个明确里程碑，更新本文件并提交、推送到 GitHub。
- 记录实际证据：commit、GitHub Actions run、关键 RESULT/ERROR 标记、真实设备只读验证结果。
- 不用“预计完成”代替实际结果；未验证的项目保持 `TODO` / `BLOCKED`。
- 真实物理写入前必须满足计划中的 raw sparse backup 与恢复验证门槛。

## 当前状态

### Phase A — NTFS 读写

- [x] A1 NTFS mount 生命周期根因
  - 诊断 run：`32917076034`，commit `6cbcb68`。
  - NTFS-3G PID 在 mount T0 / 100 ms / 500 ms / 1 s 全程存活；mount、`stat`、根目录 `readdir` 全部正常。
  - `mkdir EDP-RW` 成功，100 ms 后 mount 和进程仍正常。
  - 第一个普通文件 `create(O_CREAT)` 返回 `ENOENT`；失败时 mount 与 NTFS-3G 进程仍存活。
  - 结论：问题不是 mount 生命周期，而是 NTFS-3G + macFUSE FSKit 的 regular-file create 路径。
- [ ] A2 固化正确的 NTFS-3G FSKit 启动方式
  - `direct decrypted image + local FSKit` 已由 run `32917383915` 否决：local module 启用 block resource，内部引出 `/dev/disk8`/Disk Arbitration NTFS probe，未稳定进入常规 mount I/O 阶段。
  - run `32917604083`（commit `fb475ce`）已确认：nonlocal mount 稳定，但 root-level `touch` 与新建目录下 `touch` 都返回 `ENOENT`；故障是整个 regular-file create 路径，不是新建目录后的局部缓存问题。
  - 5.3.2/5.3.3 版本矩阵已完成到最小 FUSE2 create 层。run `32918481783`：两个版本都能稳定建立 nonlocal FSKit mount，`m_create(/created.txt)` 回调都实际被调用并返回成功，但调用方随即收到 `ENOSYS`（`Function not implemented`），未进入 write；因此问题已从 NTFS-3G/EDP/DiskImages2 中剥离，集中到 macFUSE FSKit ↔ libfuse2 create 后续操作序列/缺失 callback 兼容性。
- [ ] A3 synthetic NTFS 完整 RW/remount E2E，要求同一 commit 连续 3 次通过
- [ ] A4 dirty / hibernated NTFS fail-closed
- [ ] A5 CI 与产品 NTFS mount 路径统一
- [ ] A6 raw sparse backup → 恢复验证 → 真实 EDP NTFS 读写

### Raw sparse backup 证据

- [x] 真实 EDP raw 数据区抽样确认大量未使用区域为全 0。
- [x] 256 MiB 步长抽样 442 个 4 KiB block：404 个全 0、38 个非零，零块比例约 91.4%。
- [x] 数据区相对 +8/+16/+32/+64/+96/+110 GiB 的 1 MiB window 均为全 0。
- [x] 分区起点、MFT 物理位置、尾部关键区域验证为非零，排除“读失败误判为 0”。
- [ ] 实现 raw sparse backup 工具。
- [ ] sparse backup 恢复/挂载/SHA256 验证。

### Phase B — 原生化

- [ ] B1 IOKit / IOUSBHost 替代 `ioreg`
- [ ] B2 Disk Arbitration + IOKit 替代 `diskutil list/info`
- [ ] B3 插拔事件驱动替代 2 秒轮询
- [ ] B4 Disk Arbitration 替代 `diskutil mount/unmount/eject`
- [ ] B5 移除 `/sbin/mount` / `/sbin/umount` 生产依赖
- [ ] B6 SwiftUI + XPC + ServiceManagement 替代用户可见 CLI 工作流
- [ ] B7 Keychain 替代自管 `master.key`

## 变更日志

### 2026-08-26 — Tracker 初始化

- 建立计划追踪文件。
- 计划与 tracker 首次推送：commit `57ce3ba`。

### 2026-08-26 — A1 生命周期诊断已实现

- `probe-edp-crypto-ntfs-readwrite.sh` 已增加 NTFS-3G PID / process state / exit status 捕获。
- mount 建立后按 T0 / 100 ms / 500 ms / 1 s 四个时间点验证 mount、`stat`、根目录 `readdir`。
- 实际 I/O 被拆成 `BEFORE_MKDIR`、`AFTER_MKDIR`、`AFTER_MKDIR_100MS`、文件 create/random-write/delete 等阶段，便于确认首个致命操作。
- NTFS-3G 一旦提前退出，会把 exit status 和完整 `ntfs-3g.log` 写入 CI report。
- failure diagnostics 增加 macFUSE / FSKit unified log 与 PluginKit module 状态。
- `bash -n`、`git diff --check` 已通过；若本机存在 `actionlint` 也已执行。
- 状态：该诊断由 run `32917076034` 完成，A1 已结项。

### 2026-08-26 — A1 结项，进入 A2

- run `32917076034` 明确排除了 NTFS-3G 进程提前退出和 mount 自动消失。
- 故障点收敛到 regular-file create：目录创建/读取正常，普通文件 `O_CREAT` 返回 `ENOENT`。
- 本机 `gromgit/fuse/ntfs-3g-mac 2026.7.7` 的标准 mount 配置使用 `local` 等 macFUSE 选项；之前 `local + DiskImages2 block device` 曾出现 hang，但尚未测试 `local + direct decrypted image`。
- A2 第一项实验改为 `direct decrypted image + local FSKit`；另外增加 root/nested `touch` 分离测试，判断问题是否仅发生在新建目录下的 create。

### 2026-08-26 — A2 local FSKit 实验否决

- run `32917383915`：`direct decrypted image + local FSKit` 失败。
- unified log 显示 `macfuse-local` 以 `enableBlockResource 1` 加载，并把资源交给 block-resource 路径；Disk Arbitration 随后对内部出现的 `/dev/disk8` 做 NTFS probe 并失败。
- 该路径还出现 `close_kernel_fd` / unregister fd 异常，和此前 `local + DiskImages2` hang 证据一致。
- 结论：当前产品不采用 local FSKit；继续使用能稳定建立并保持 mount 的 nonlocal module。
- 下一实验：nonlocal + root/nested create probe，确认普通文件 create 的失败范围。

### 2026-08-26 — A2 nonlocal create 范围确认

- run `32917604083`，commit `fb475ce`。
- mount T0/100ms/500ms/1s 全部健康；`mkdir` 成功。
- `/Volumes/EDPNTFSRW/root-create.tmp`：`touch` → `ENOENT`。
- `/Volumes/EDPNTFSRW/EDP-RW/nested-create.tmp`：`touch` → `ENOENT`。
- create 失败后 NTFS-3G PID、mount、`stat`、`readdir` 仍正常。
- 结论：排除“仅新建目录 lookup/cache”问题；nonlocal FSKit 的 regular-file create 路径整体异常。
- 下一步不再改变 EDP crypto/DiskImages2 层，集中验证 macFUSE FSKit mount options / create forwarding。

### 2026-08-26 — A2 增加 macFUSE 版本对照

- macFUSE 官方 release 页当前 latest 为 5.3.3。
- 官方 issue #1180 报告 5.3.3 相比 5.3.2 存在 FSKit ENOENT 回归；降级 5.3.2 后恢复。
- 已独立下载官方 `macfuse-5.3.2.dmg` 并计算 SHA256：`9328a8cd0b893b4347097270d6605408630dd764ddca275256959dc0e9a07936`。
- CI 改为 5.3.2 / 5.3.3 matrix；两边使用同一 NTFS-3G、同一 synthetic fixture、同一 EDP crypto bridge 和同一 create probe。
- 判定规则：如果 5.3.2 create 成功而 5.3.3 失败，则优先把产品 macFUSE pin 回退到 5.3.2，并完整跑 ExFAT/NTFS/installer 回归；若两者都失败，再进入 mount option / FUSE protocol tracing。

### 2026-08-26 — 5.3.2 matrix 首轮环境修正

- run `32917900639` 第一轮不能用于比较 create：5.3.2 官方安装成功，但 NTFS-3G build 在 link 阶段报 `ld: framework 'MFMount' not found`，因此根本未进入 E2E；5.3.3 仍复现 create `ENOENT`。
- 已检查官方 5.3.2 package：`MFMount.framework` 实际位于 `/Library/Filesystems/macfuse.fs/Contents/Frameworks/MFMount.framework`。
- `libfuse.dylib` 也明确依赖该绝对路径；问题只是 NTFS-3G 链接时缺少 framework search path。
- `build-ntfs3g-runtime.sh` 增加 `-F/Library/Filesystems/macfuse.fs/Contents/Frameworks`，使 5.3.2/5.3.3 都能使用官方 MFMount framework 完成链接。
- 下一次 matrix 才是有效的版本行为对照。

### 2026-08-26 — macFUSE 5.3.2 / 5.3.3 第二轮对照

- run `32918126839`，commit `5989bba`。
- 5.3.3：NTFS-3G runtime 构建成功，nonlocal FSKit mount 稳定，root/nested regular-file create 均继续返回 `ENOENT`；与前两轮完全一致。
- 5.3.2：NTFS-3G runtime 已成功构建，但在启动最外层 `edp-readwrite-fuse` bridge 时发生 `SIGSEGV`，日志停在 `EDP_FUSE_BLOCK_SIZE=134217728`，尚未进入 NTFS-3G mount/create。
- 因此当前不能把 5.3.2 判定为“create 正常”或“create 也失败”；它在更早的 libfuse/FSKit bridge 阶段即不兼容。
- 暂不修改产品 pin（仍为 5.3.3）。
- A2 下一判别实验：用最小 libfuse2 filesystem 在 macFUSE 5.3.3 nonlocal FSKit 下直接测试 regular-file create；若最小 create 也失败，则根因在 macFUSE FSKit/libfuse2 compatibility；若最小 create 成功，则继续 instrument NTFS-3G `create` callback / request sequence。

### 2026-08-26 — 最小 libfuse2 CREATE 判别探针

- 新增 `ValidateFuse2Create.c`：纯内存最小 FUSE 2.6 filesystem，只实现 root + regular-file `create/open/read/write/truncate/unlink`。
- 新增 `probe-fuse2-create.sh`：以 `backend=fskit` nonlocal 方式 mount，然后创建、写入、读取、删除一个普通文件并做 bounded cleanup。
- 该探针完全绕过 NTFS-3G、EDP crypto、DiskImages2，因此可以把 create 故障归因到 macFUSE FSKit/libfuse2 或 NTFS-3G 两者之一。
- 已加入 5.3.2 / 5.3.3 CI matrix，且 artifact 名包含 macFUSE 版本，避免矩阵产物重名。
- `bash -n`、C 编译、`git diff --check` 已通过。

### 2026-08-26 — libfuse2 CREATE 后续操作锁定

- run `32918481783`：5.3.2 与 5.3.3 的最小 libfuse2 FS 都成功建立 nonlocal FSKit mount。
- 两个版本中 `FUSE2_CREATE path=/created.txt` 回调都实际被调用并返回成功，但调用方紧接着得到 `ENOSYS`（`Function not implemented`）。
- 这证明 regular-file create 并非没有被转发到 userspace；失败发生在 CREATE 成功后的后续 FUSE 2.6 操作。
- libfuse2 API 文档指出：当 filesystem 实现 `create()` 时，创建后会调用 `fgetattr()`。
- 检查 NTFS-3G 2026.7.7 `src/ntfs-3g.c`：`ntfs_3g_ops` 有 `.create = ntfs_fuse_create_file`，但没有 `.fgetattr`。
- 最小探针当前同样缺 `.fgetattr`，因此下一实验只增加 `fgetattr -> getattr` wrapper；若 create/write/read 立即通过，即可确认根因并为 NTFS-3G 提供最小兼容补丁。
- run `32918481783` 已完成：5.3.2 与 5.3.3 都成功 mount；两边都打印 `FUSE2_CREATE path=/created.txt flags=0xa02`，证明 `create` callback 已真正执行，但 shell 端同时报 `Function not implemented`，`write` callback 未发生。
- 结论：版本回退不能解决这个最小 create 问题；当前要追踪 `create` 返回之后 FSKit/libfuse2 请求的下一操作（优先检查 `ftruncate` / `fgetattr` / setattr 类 callback），直到最小 probe 能完成 create→write→read。
- 已在最小 probe 中实现并注册 `fgetattr -> getattr` 与 `ftruncate -> truncate` wrapper，并增加 `FUSE2_FGETATTR` / `FUSE2_FTRUNCATE` / `FUSE2_TRUNCATE` 日志；静态编译、`bash -n`、`git diff --check` 均通过。
- run `32918751432`：`FUSE2_CREATE` 与 `FUSE2_FGETATTR` 均被实际调用，但随后调用方仍收到 `ENOSYS`，且 `ftruncate/write` 尚未发生，说明缺口继续位于 create 后 Apple 属性阶段。
- 已继续为最小 probe 增加 macOS 专有 `setattr_x` / `fsetattr_x` / `getxtimes` callback，并逐项打印调用日志；本地静态编译通过。下一轮 CI 用一轮结果确认 FSKit 是否强制依赖这些 Apple 扩展。
