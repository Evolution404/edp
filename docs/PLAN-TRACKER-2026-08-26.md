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
- [x] A2 固化正确的 NTFS-3G FSKit 启动方式
  - `direct decrypted image + local FSKit` 已由 run `32917383915` 否决：local module 启用 block resource，内部引出 `/dev/disk8`/Disk Arbitration NTFS probe，未稳定进入常规 mount I/O 阶段。
  - run `32917604083`（commit `fb475ce`）已确认：nonlocal mount 稳定，但 root-level `touch` 与新建目录下 `touch` 都返回 `ENOENT`；故障是整个 regular-file create 路径，不是新建目录后的局部缓存问题。
  - 5.3.2/5.3.3 版本矩阵已完成到最小 FUSE2 create 层。run `32918481783`：两个版本都能稳定建立 nonlocal FSKit mount，`m_create(/created.txt)` 回调都实际被调用并返回成功，但调用方随即收到 `ENOSYS`（`Function not implemented`），未进入 write；因此问题已从 NTFS-3G/EDP/DiskImages2 中剥离，集中到 macFUSE FSKit ↔ libfuse2 create 后续操作序列/缺失 callback 兼容性。
- [x] A3 synthetic NTFS 完整 RW/remount E2E，要求同一 commit 连续 3 次通过
  - 同一 HEAD `dfbdcc8` 连续成功 runs：`32920159540`、`32920839214`、`32920841484`。
  - 覆盖 create / 4 MiB+ write / random overwrite / renamex / delete / sync / clean unmount / ciphertext SHA 变化 / 全链重启 / remount / payload SHA 一致 / clean probe / bounded teardown。
- [x] A4 dirty / hibernated NTFS fail-closed
  - commit `d2a5a4f`，CI run `32923181506` 成功。
  - deterministic unclean `$LogFile` fixture：`RW probe=15`、`RO probe=0`。
  - deterministic `hiberfil.sys` (`HIBR` header) fixture：`RW probe=14`、`RO probe=0`。
  - 产品状态映射与禁止 `force/recover/remove_hiberfile` 静态门槛通过；最终 `RESULT=NTFS_FAIL_CLOSED_E2E_OK`。
- [x] A5 CI 与产品 NTFS mount 路径统一
  - shared policy：`product/EDPNTFSMountPolicy.swift`；产品 runtime 与 NTFS E2E 均从同一 Swift policy 生成参数。
  - 产品已移除错误的 `local` FSKit 参数，固定为已验证的 nonlocal `backend=fskit` 路径。
  - commit `f100656` 上 NTFS RW E2E `32924060750`、Fail-Closed `32924060775`、Clean Installer `32924060769` 全部成功。
- [ ] A6 raw sparse backup → 恢复验证 → 真实 EDP NTFS 读写（进行中）

### Raw sparse backup 证据

- [x] 真实 EDP raw 数据区抽样确认大量未使用区域为全 0。
- [x] 256 MiB 步长抽样 442 个 4 KiB block：404 个全 0、38 个非零，零块比例约 91.4%。
- [x] 数据区相对 +8/+16/+32/+64/+96/+110 GiB 的 1 MiB window 均为全 0。
- [x] 分区起点、MFT 物理位置、尾部关键区域验证为非零，排除“读失败误判为 0”。
- [x] 实现 raw sparse backup 工具。
  - `edp-raw-sparse` 的 physical source 只通过 `authopen` 取得 whole-disk `O_RDONLY` fd；没有 raw write mode。
  - backup 保持完整逻辑尺寸，以 64 KiB 默认粒度跳过全 0 block，并记录逻辑 SHA256、每个 stored extent 的 offset/length/SHA256、sector/chunk/block size 与实际占用。
  - restore 只允许新建普通文件，硬拒绝 `/dev/*` 输出；synthetic E2E 覆盖 head、LBA11/12、跨 block extent、分离中段 extent 与末尾 sector。
- [x] 真实 `disk5` whole-disk sparse backup 与 raw restore/SHA256 验证。
  - source：`/dev/rdisk5`，全程 `authopen O_RDONLY`；backup 前 whole disk unmount，未执行物理写入。
  - logical size：`124736503808`；stored extents：`17`；stored extent bytes：`13241155584`；allocated bytes：`13250199552`。
  - source/backup/restored logical SHA256：`61e54385b087e70f5378968114a04f8af9b785b2057172830d62629231924423`。
  - manifest SHA256：`a63f33eaa905a82684520f9bbd45e6da865ee237ffe6881f8b2019851ea0f123`；末尾仍保留 3 个独立 stored extents。
  - backup final verify 与独立 restored sparse image verify 均返回 `RESULT=EDP_RAW_SPARSE_VERIFY_OK`；restore 返回 `RESULT=EDP_RAW_SPARSE_RESTORE_OK`。
- [x] restored image EDP 解密 → NTFS 只读挂载 → 关键 metadata 与真实盘比对。
  - read-only harness 已实现：physical 仅允许 `/dev/rdiskN + authopen O_RDONLY`，restored image 普通只读 open；两边均以 NTFS-3G `ro,norecover,backend=fskit` 挂载。
  - source/backup/restored 全盘 raw logical SHA256 已一致，因此按用户要求不再逐文件重复计算内容 SHA；deterministic manifest 覆盖 path/type/mode/flags/link count/size/mtime/birthtime/symlink target，以及解密卷逻辑尺寸、头尾 4 KiB SHA256。
  - 真实盘重枚举为 `disk4` 后，restored/physical 均通过 EDP 解密、`RO probe=0`、`RW probe=0` 与只读 NTFS mount；两边 5 个 metadata entries / 3 个 regular files 完全一致。
  - matched metadata manifest SHA256：`42355f26cbbe40b4c0d43e46ea63f1db8febcf4de430f17fdfd37a79c22f66b2`；`RESULT=REAL_EDP_RESTORED_NTFS_FILES_MATCH_OK`、`PHYSICAL_WRITE_GATE=OPEN_RW_PROBE_CLEAN`。

### Phase B — 原生化

- [x] B1 IOKit / IOUSBHost 替代 `ioreg`
  - commit `9e44f0b`；真实 Lexar EDP 只读发现结果：`disk5 / 21c4:0cd1 / 124736503808 / USB Flash Drive`，与历史证据一致。
- [x] B2 Disk Arbitration + IOKit 替代 `diskutil list/info`
- [x] B3 插拔事件驱动替代 2 秒轮询
- [x] B4 Disk Arbitration 替代 `diskutil mount/unmount/eject`
- [x] B5 移除 `/sbin/mount` / `/sbin/umount` 生产依赖
  - Native Production Path run `32923731599`（`9e44f0b`）与 `32924060719`（`f100656`）成功。
  - `product/` 已无 `ioreg`、`diskutil`、`/sbin/mount`、`/sbin/umount`、`sleep(2)` 生产调用。
- [x] B6 SwiftUI + XPC + ServiceManagement 替代用户可见 CLI 工作流
  - commit `ad9668a` 引入 SwiftUI App + privileged Mach XPC；`db8c2c3` 完成双服务部署和真实 XPC smoke。
  - 正常用户路径不调用 Terminal/CLI；App 提供设备状态、密码授权、撤销、安全弹出、诊断和后台服务状态。
  - privileged XPC 对调用方执行 code-sign identifier / executable path 校验，拒绝非 `com.edp.usbvault.app` peer。
  - Developer ID/正式签名构建走嵌入 App 的 `SMAppService.daemon(...)`；ad-hoc CI/self-use 包自动使用 legacy LaunchDaemon fallback，但同样通过 MachService XPC，用户无需手工执行 `launchctl`。
  - Clean Installer run `32926201447`：`EDP_SERVICE_MODE=legacy`、`EDP_SERVICE_STATUS=enabled`、`RESULT=PRIVILEGED_XPC_ROUNDTRIP_OK`、`RESULT=LEGACY_XPC_SERVICE_SMOKE_OK`。
- [x] B7 Keychain 替代自管 `master.key`
  - commit `f100656`；临时 Keychain E2E 覆盖 write/read/index-no-secret/revoke。
  - Native Production Path `32924060719` 成功；旧 `master.key + credentials.json` 仅保留一次性迁移入口，新凭据进入 System Keychain。

### Phase C — 底层非原生组件边界

- [x] C1 NTFS-3G 保留并固定边界
  - 固定 NTFS-3G `2026.7.7` 与 source SHA256 `d67b769025d32860549d35c2147e45024d172f81c540d750390ce3602c059dab`。
  - CREATE type / `RENAME_EXCL` 两个 macOS FSKit adapter patch 随 source bundle 一并分发；test-only `mkntfs/ntfscp/fixture helper` 不进入生产 payload。
- [x] C2 macFUSE 暂时保留，仅使用 FSKit backend
  - 固定 macFUSE `5.3.3`；产品 NTFS policy 使用已验证的 nonlocal `backend=fskit`，不回退 legacy kernel backend。
  - exact-head NTFS RW/remount run `32926380174` 成功。
- [x] C3 DiskImages2 private API 隔离
  - commits `74f7189` / `db80bbe`：上层只依赖 `EDPBlockDevicePublisher`，具体 private helper 封装在 `EDPDiskImages2Publisher` adapter。
  - Native Production Path `32926201428`：`RESULT=DISKIMAGES2_PRIVATE_API_ISOLATED_TO_ADAPTER`。

### Phase D — 最终产品形态

- [x] SwiftUI App + privileged service + Finder mount engine 已形成完整产品路径。
- [x] IOKit / Disk Arbitration / native mount table / event-driven discovery / Keychain 已接入生产 runtime。
- [x] Clean Installer 将 App 安装到 `/Applications/EDP USB Vault.app`，生产 runtime 安装到 `/Library/Application Support/EDP USB Vault`；正常用户操作不需要 Terminal。
- [x] exact-head `db8c2c3` 最终回归：
  - Native Production Path `32926201428`：success。
  - NTFS Fail-Closed Safety `32926201454`：success。
  - Clean ExFAT + NTFS Installer `32926201447`：success，并完成实际 privileged XPC round-trip。
  - EDP Crypto + NTFS-3G Read/Write E2E `32926380174`：success。
- [ ] A6 / raw sparse backup / 真实物理 NTFS 写入：当前正在推进；此前其余阶段结项证据保持有效。

### macOS 26 实机 raw-device 权限收口

- [x] 真机确认 system LaunchDaemon 即使 `euid=0`，直接 `open(/dev/rdisk5)` / `open(/dev/disk5)` 均返回 `EPERM`；把 daemon primary group 改成 `operator` 仍无效，已撤回该方案。
- [x] 真机确认 console uid + effective gid `operator` 可以只读打开真实 `/dev/rdisk5`；产品改为 root daemon 启动 `edp-raw-metadata` 后立即降权，仅读取 LBA4/LBA7/LBA11/LBA12，因此插盘识别和密码 metadata 校验不需要管理员弹窗。
- [x] Apple `/usr/libexec/authopen` 验证通过：同一个 `system.privilege.admin` AuthorizationExternalForm 在 whole disk unmount 后可取得 `/dev/rdisk5` 的 `O_RDONLY` 与 `O_RDWR` fd；`O_RDWR` 实验只 open/close，明确未执行 `pwrite`。
- [x] 验证 AuthorizationRef 在 externalize 后释放，external form 仍可供 `authopen -extauth` 使用；daemon 因此只在内存保存 capability，不持久化管理员凭据。
- [x] SwiftUI App → privileged XPC 真机授予 capability 成功：snapshot 从 `rawAccessReady=false` 变为 `rawAccessReady=true`，真实设备保持 `authorized=false / mounted=false`，未触发真实文件系统挂载。
- [x] 真机 installer 升级发现并修复 PackageKit bundle relocation：旧 `com.edp.usbvault` 与历史 `EDP USB Vault*.localized` 路径会在 preinstall 清理，EDP App 作为固定 payload 安装到 `/Applications/EDP USB Vault.app`。
- [x] 官方 macFUSE 5.3.3 在实机重新安装恢复后，`edp-vaultctl doctor` 返回 `RESULT=EDP_RUNTIME_READY`。
- [ ] 真实物理 NTFS writable mount / `pwrite`：仍属于 A6，当前明确未执行。

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
- 已继续为最小 probe 增加 macOS 专有 `setattr_x` / `fsetattr_x` / `getxtimes` callback，并逐项打印调用日志；本地静态编译通过。
- run `32918908780`：5.3.2 与 5.3.3 的最小 probe 均通过完整 create→write→read→unlink；实际序列为 `CREATE → FGETATTR → FSETATTR_X(valid=0x90000007) → OPEN → WRITE`。这证明 FSKit 在 CREATE 后会立即提交 Apple 扩展属性。
- `0x90000007` 对应 mode / uid / gid / creation-time / flags；NTFS-3G 2026.7.7 没有直接实现 `setattr_x/fsetattr_x`，而是依赖 libfuse 拆分 fallback 到 `setcrtime/chmod/chown`。
- 同一 run 中 NTFS-3G 仍在 regular-file create 阶段返回 `ENOENT`，因此下一步开启 NTFS-3G/libfuse debug，精确确认 fallback 是 path/node lookup 失败还是 `setcrtime/chmod/chown` 中某一步失败。
- macFUSE 5.3.2/5.3.3 已证明该最小行为一致，后续主线回到产品 pin 5.3.3，停止重复双版本矩阵以缩短反馈周期。

### 2026-08-26 — A2 regular-file CREATE 根因确认

- debug run `32919220730` 抓到了 NTFS-3G 的完整 FUSE 请求链。
- `MKDIR /EDP-RW` 正常：NTFS-3G 自己在 mkdir adapter 中显式补 `S_IFDIR`，随后 SETATTR 成功。
- 普通文件 `CREATE` 请求由 macFUSE FSKit 传入 `mode=0644`，即只有权限位、不含 `S_IFREG`。
- NTFS-3G 2026.7.7 的 `ntfs_fuse_create_file()` 原样把该 `mode` 传入 `ntfs_fuse_mknod_common()`；后者计算 `type = mode & ~07777`，结果为 0。
- `ntfs_create()` 明确只接受 `S_IFREG/S_IFDIR/S_IFIFO/S_IFSOCK`，因此打印 `Invalid arguments.` 并设置 EINVAL；文件没有真正落盘。随后 libfuse 的 `fgetattr` 找不到新路径，CREATE reply 最终表现为 `ENOENT`。
- 结论：这是 **macFUSE FSKit CREATE mode 语义与 NTFS-3G 传统 FUSE adapter 假设不兼容**；不是 EDP crypto、DiskImages2、NTFS on-disk 数据、mount 生命周期或单纯 macFUSE 5.3.3 回归。
- 已增加最小兼容 patch `patches/ntfs-3g-2026.7.7-macfuse-fskit-create-mode.patch`：`.create` 入口规范化为 `S_IFREG | (mode & 07777)`。该改动只修正 FUSE adapter 的文件类型，不改变 NTFS 核心读写/磁盘结构。
- `build-ntfs3g-runtime.sh` 在校验固定上游 SHA256 并解包后应用该 patch，并将 patch 一起放入 bundled source 目录，保持构建与 GPL source distribution 可审计。
- patch 已对固定 NTFS-3G 2026.7.7 原始源码完成 `patch --dry-run`、实际 apply、`bash -n` 与 `git diff --check` 验证。
- run `32919605335` 验证 CREATE mode patch 有效：root/nested `touch` 均成功，4 MiB 文件创建、顺序写、随机覆盖、临时文件删除全部通过；失败点已后移到 rename。
- rename debug 显示 macOS/FSKit 发出 `renamex(..., flags=0x4)`，即 `RENAME_EXCL`；NTFS-3G 只实现传统 `.rename`，macFUSE 的 `fuse_fs_renamex()` 在 `.renamex` 缺失时直接返回 `ENOSYS`，不会 fallback。
- 已增加第二个可审计 patch `patches/ntfs-3g-2026.7.7-macfuse-fskit-renamex.patch`：支持 flags=0 / `RENAME_EXCL`，目标存在时返回 `EEXIST`，否则复用 NTFS-3G 原有 rename；`RENAME_SWAP` 明确不支持并在 init 中关闭其 capability。
- build 脚本按固定顺序应用 CREATE mode + renamex 两个 patch，并将两者随 bundled source 一并保留。两 patch 已对固定上游 SHA 源码完成顺序 dry-run/apply 验证。

### 2026-08-26 — A4 fail-closed 结项

- commit `d2a5a4f` 的 `NTFS Fail-Closed Safety` run `32923181506` 成功。
- unclean fixture 不再依赖 `ntfsfix` 的 volume dirty flag，而是通过 test-only libntfs-3g helper 构造有效 Windows-style `$LogFile` restart page；`ntfs-3g.probe --readwrite` 返回 15，readonly 返回 0。
- hibernation fixture 通过 test-only upstream `ntfscp` 写入根目录 `hiberfil.sys`，4096-byte header 以 `HIBR` 开头；readwrite probe 返回 14，readonly 返回 0。
- `mkntfs` / `ntfscp` / fixture helper 均只位于 build runtime 的 `test-tools`；clean installer 仍只复制生产 bin/lib/licenses/source。
- 产品 `EDPNTFSWriteSafety` 对 14/15 的错误传播已由 Swift validator 覆盖，且 CI 明确拒绝出现 `force`、`recover`、`remove_hiberfile`。

### 2026-08-26 — A2/A3 结项

- commit `dfbdcc8` 的首次完整 E2E run `32920159540` 成功。
- 为满足“同一 commit 连续 3 次”门槛，未修改 HEAD，额外 workflow_dispatch 两次；runs `32920839214`、`32920841484` 均成功，且 `headSha` 均为 `dfbdcc8ae6c8acb9f15e6c97420c7530a6f763d2`。
- 三次均完成完整 teardown；主验证覆盖 NTFS create、4 MiB+ 顺序写、随机覆盖、rename、delete、sync、卸载、密文 SHA 变化、全链重启、remount、payload SHA256 一致以及最终 clean writable probe。
- A2 结论：产品底层采用 macFUSE 5.3.3 nonlocal FSKit；NTFS-3G 2026.7.7 通过两个最小 Darwin/FSKit adapter patch 兼容 CREATE type 与 `RENAME_EXCL`。
- A3 正式完成，进入 A4 dirty / hibernated fail-closed。

### 2026-08-26 — 除 A6 外计划全部收口

- `db8c2c3` 将 ad-hoc CI/self-use 与正式签名发布的 service deployment 分离：ad-hoc 使用 installer-managed legacy LaunchDaemon fallback，正式签名构建保留 `SMAppService.daemon(...)`；两者对 App 都暴露同一个 privileged MachService XPC contract。
- Clean Installer `32926201447` 在 macOS 26 runner 实际安装 EDP component 后确认 legacy daemon 为 `enabled`，随后由 App 发起 `diagnostics` XPC 调用并得到 `RESULT=PRIVILEGED_XPC_ROUNDTRIP_OK`。
- Native Production Path `32926201428`、NTFS Fail-Closed `32926201454`、Clean Installer `32926201447`、手动 exact-head NTFS RW/remount `32926380174` 全部 success。
- C3 `BlockDevicePublisher` adapter 边界、SwiftUI 用户路径、Keychain、IOKit、Disk Arbitration、事件驱动 daemon 均进入最终生产结构。
- A6 与 raw sparse backup/restore/真实物理写入保持未执行，符合用户本轮明确要求。

### 2026-08-26 — A6 raw sparse backup 工具里程碑

- 新增 `edp-raw-sparse backup/verify/restore`；backup image 与 manifest 都以新文件 + atomic rename 生成，避免把不完整结果误认成可恢复备份。
- manifest format v1 保留原盘完整 logical size、sector size、scan chunk、sparse block、logical SHA256、allocated bytes，以及每个 extent 的 offset/length/SHA256。
- physical backup 唯一授权入口 `EDPRawReadAuthorization.c` 只接受严格的 `/dev/rdiskN` whole-disk path，并固定请求 `O_RDONLY`。
- restore 明确禁止全部 `/dev/*` 目标；在真实备份恢复与挂载校验完成前，仍不进行任何物理盘写入。
- 本地 64 MiB synthetic raw E2E 已通过 backup → verify → restore → verify，恢复前后 logical SHA256 一致，完整逻辑尺寸保留且稀疏实际占用低于逻辑尺寸 1/4；GitHub Actions run 待首次 push 后补录。

### 2026-08-26 — A6 真实 raw backup/restore 里程碑

- commit `28fd935` exact-head CI 全绿：Raw Sparse Backup Safety `32932022923`、Native Production Path `32932022703`、NTFS Fail-Closed Safety `32932022774`、Clean Installer `32932022780`。
- 对真实 `disk5 / 21c4:0cd1 / 124736503808` 完成 whole-disk 顺序只读扫描；扫描前成功 unmount `/dev/disk5s1`，授权 helper 固定使用 `O_RDONLY`。
- final sparse image 逻辑尺寸与物理盘完全一致；17 个 stored extents 合计 `13241155584` bytes，实际 APFS 占用 `13250199552` bytes，且包含物理盘尾部 extents。
- manifest 的 source logical SHA256 为 `61e54385b087e70f5378968114a04f8af9b785b2057172830d62629231924423`；final backup 全逻辑 verify 匹配。
- 已按 manifest 恢复到第二个独立 sparse regular file，恢复镜像 logical size、17 个 extent SHA 与全逻辑 SHA 全部匹配，`RESULT=EDP_RAW_SPARSE_RESTORE_OK`。
- raw 层 backup/restore 门槛已通过；EDP 解密后的 NTFS 文件/metadata 比对尚未完成，因此真实物理 writable mount / `pwrite` 仍禁止。

### 2026-08-26 — A6 restored/physical NTFS 只读比对 harness

- `EDPReadOnlyFuseBridge` 新增 strictly read-only inherited-fd path；interactive authorization 只接受完整 `/dev/rdiskN` whole-disk path，并固定 `authopen O_RDONLY`。
- `probe-real-edp-backup-readonly.sh` 依次挂载 physical 与 restored raw，正式挂载路径固定使用只读 `volume.raw` 与 NTFS-3G `ro,norecover,backend=fskit`；独立 probe alias 只允许 read-write open、不实现 write callback，且底层 raw fd 始终为 `O_RDONLY`，用于在零写入前提下检查 dirty/hibernated gate。
- `EDPFilesystemManifest.swift` 生成 deterministic metadata 清单，并包含解密卷逻辑尺寸、boot/tail 4 KiB SHA256；source/backup/restored 的全盘 raw SHA 已经一致，按用户要求取消重复的逐文件内容 SHA 扫描。
- 本地 Swift 6 strict compile、C `-Wall -Wextra`、shell syntax、deterministic manifest round-trip 与禁止 `O_RDWR/pwrite` 静态门槛通过；实体介质为测试盘，按用户确认使用测试密码执行。
- 首次 CI `32933796415` 在既有 read-only bridge probe 的 link 阶段暴露新增 Security symbols 未链接；尚未进入任何 EDP/FUSE I/O。所有既有 read-only bridge build sites 已显式补 `-framework Security`。
- 首次真机启动同样在 background Authorization 阶段 fail closed（`EDP_FUSE_AUTHOPEN_READONLY_FAILED`），无 raw fd、无 mount；修正为 GUI Authorization App 内前台完成 Authorization/authopen，并让 libfuse 始终保持 foreground，避免 macOS 26 Objective-C fork-after-multithread abort。
- terminal 前台进程仍没有 GUI Authorization bootstrap，第二次同样在 raw open 前 fail closed；最终验证入口与成功 backup 一致，封装为 ad-hoc signed `.app` 由 LaunchServices 启动，密码仅经 mode `0600` FIFO 传入、不落盘。

### 2026-08-26 — A6 restored/physical NTFS 恢复门通过

- macFUSE 两个 FSKit modules 在系统设置启用后，临时 mountpoint 移到 `/private/tmp`，避免 `fskitd mount(2)` 对 Desktop 路径返回 `EPERM`。
- Authorization App 将 `libEDPReadOnlyBridge.dylib` 内嵌到 Frameworks 并重写加载路径；FUSE 固定 foreground，消除 DYLD sandbox failure 与 fork-after-multithread crash。
- restored sparse image 与重新枚举为 `/dev/rdisk4` 的同一实体盘均以只读 EDP bridge 解密，NTFS-3G 固定 `ro,norecover,backend=fskit`；两边 `RO probe=0`、`RW probe=0`。
- 全盘内容一致性直接采用已完成的 raw logical SHA256 `61e54385b087e70f5378968114a04f8af9b785b2057172830d62629231924423`，不再逐文件重复哈希；metadata + boot/tail manifest 两边 byte-for-byte 一致，SHA256 为 `42355f26cbbe40b4c0d43e46ea63f1db8febcf4de430f17fdfd37a79c22f66b2`。
- 输出 `RESULT=REAL_EDP_RESTORED_NTFS_FILES_MATCH_OK` 与 `PHYSICAL_WRITE_GATE=OPEN_RW_PROBE_CLEAN`；至此 backup → restore/mount → 关键 metadata 恢复门通过。该里程碑执行期间 physical fd 始终为 `O_RDONLY`，尚未发生任何真实物理 `pwrite`。

### 2026-08-26 — UI Finder mount：失败锁存与 macFUSE FSKit enablement 根因

- 取消 daemon 的定时挂载重试：原 `failureDeadline + 30s` 改为 per-device/partition `failedMounts` 锁存。一次挂载失败后保持 fail-closed，不再由后续设备事件反复触发；仅设备拔插、重新授权或用户在 App 主动点击“挂载交换区”后允许再次尝试。
- SwiftUI/XPC 增加显式 `retryMount(deviceID:)`；本地编译通过，静态检查输出 `RESULT=NO_TIMED_MOUNT_RETRY` 与 `RESULT=UI_RETRY_CONTROL_BUILDS_OK`。
- Finder 只读路径补齐端到端 readonly 边界：`--device-auth-readonly` 使用 `authopen O_RDONLY`，并调用现有 `EDPReadOnlyUnlock/EDPEncryptedReadOnlyBlockDevice`；FUSE read 允许读取、write 固定 `EROFS`。安装包同时补入 `edp-console-exec` 与 read-only bridge symbols。
- 当前 macFUSE 5.3.3 文件、Developer ID 签名与两个 FSKit appex 均完整；PluginKit 可发现 `io.macfuse.app.fsmodule.macfuse` 与 `io.macfuse.app.fsmodule.macfuse-local`，但 macOS 26 `FSClient.shared.fetchInstalledExtensions` 仅返回 Apple exfat/ftp/msdos，未返回任何 macFUSE module。
- macFUSE launchservice 实机日志反复给出 `File system extension io.macfuse.app.fsmodule.macfuse-local not enabled`；因此当前阻塞位于 macOS FSKit module enablement 状态，而非 EDP 密码、解密、NTFS 数据或 macFUSE 文件缺失。
- PluginKit `+` 状态不能替代 FSKit enablement；`pluginkit -e use` 后 FSClient 结果不变。当前用户为管理员且无 MDM enrollment，排除普通用户权限/MDM 禁用。
- 另有待继续解释的异常：EDP 当前 bridge 与 NTFS policy 均只传 `backend=fskit`、没有 `local`，但 macFUSE mount daemon 的失败日志却检查 `macfuse-local`。下一步需要验证 macFUSE 5.3.3 在本机重新注册后的 module selection/FSKit 状态，并在产品 mount 前增加 FSKit enablement preflight，避免即使手动重试也出现 macFUSE 系统弹窗。

### 2026-08-26 — UI → Finder 真实交换区只读挂载通过

- 覆盖重装 macFUSE 5.3.3 后执行官方 `macfuse install --force`，两个 FSKit appex 重新注册；用户在“文件系统扩展”中启用后，最小 FUSE 实测成功启动 `io.macfuse.app.fsmodule.macfuse`，系统日志进入 `ReallyMountVolume`，确认不是安装损坏。
- 证明旧产品失败与进程身份有关：root 直接启动 bridge 时 macFUSE 选择 `macfuse-local`；控制台用户 UID 501 启动时选择 generic `macfuse`。产品因此固定为 root daemon 负责授权/编排，`edp-readwrite-fuse`、`ntfs-3g.probe`、`ntfs-3g` 通过 `edp-console-exec` 降权到控制台用户执行。
- 删除不可靠的第三方 `FSClient.fetchInstalledExtensions` preflight：macOS 26 上该 API 仍只返回 Apple exfat/ftp/msdos，即使 macFUSE 已实际启用。产品仅检查 macFUSE runtime 完整性；真实 enablement 由一次受控 mount 决定，失败后继续由 `failedMounts` 锁存，不产生弹窗风暴。
- 修正 raw-device Authorization：App 不再只申请 `system.privilege.admin`，而是针对当前 `/dev/rdiskN` 前台预授权精确的 `sys.openfile.readonly./dev/rdiskN`，external form 再交给 `authopen -extauth`；独立 `--xpc-mount-smoke` 与 `EDPXPCMountSmoke.swift` 覆盖该路径。
- System Keychain 凭据升级为 schema v3：旧 ad-hoc daemon 默认 ACL 绑定 cdhash，更新二进制后后台读取返回 `-25308`。v3 item 使用 root-only owner policy；普通用户无交互读取实测失败，daemon 更新后 credential index/Keychain item 保持有效。
- 修正 FSKit 用户会话边界：root daemon 无权直接 `open()` UID 501 generic FSKit mount 内的 `volume.raw`（实测 `errno=1`），因此 NTFS probe 与最终 NTFS mount 都切到同一 UID 501 上下文；root 仅观察全局 mount table。
- 修正 bridge readiness：不再用 root `FileManager.isReadableFile(volume.raw)` 判断，而以 `getfsstat` mount table 是否出现 bridge mountpoint 为准，避免已经成功的 FSKit mount 被误判为 20 秒超时。
- 修正只读完成判据：macFUSE FSKit 实测不会把 NTFS-3G `ro` 映射成 `MNT_RDONLY`，但 NTFS-3G 日志明确为 `Read-Only`，且底层 bridge 固定 `--device-auth-readonly`/write=`EROFS`。因此不再因缺失 `MNT_RDONLY` 主动杀掉已成功 mount，并记录 warning 说明双层 fail-closed 保证。
- 真实实体 `/dev/disk4` 端到端 smoke 输出 `RESULT=XPC_MOUNT_SMOKE_OK`；最终状态 `authorized=true mounted=true rawAccessReady=true`，`/Volumes/EDP-NTFS` 可读取真实“交换区”文件，Finder 已打开该目录。
- 只读负向验证：对 `/Volumes/EDP-NTFS/.edp-readonly-probe` 的 `touch` 返回非零且文件不存在；该只读里程碑当时未对实体 U 盘执行成功写入。

### 2026-08-26 — Finder NTFS 读写路径实机打通

- 用户随后明确要求将 Finder 交换区切换为 NTFS 可读写，因此解除此前 physical write 暂停约束；产品 raw-device Authorization 从精确 `sys.openfile.readonly./dev/rdiskN` 切到精确 `sys.openfile.readwrite./dev/rdiskN`。
- `MountManager` 从 `--device-auth-readonly` 切换到已有 `--device-auth` / `edp_rw_open_device_fd` 路径；底层 raw fd 由 `authopen -extauth -o O_RDWR` 打开，写入仍经 EDP sector translation + SM4 对称变换进入实体设备。
- Finder NTFS 层在 UID 501 同一 FSKit 用户会话中先执行 `ntfs-3g.probe --readwrite`；只有 status=0 才继续，dirty/hibernated/invalid NTFS 等继续使用 `EDPNTFSWriteSafety` fail-closed 拒绝。
- 最终 NTFS-3G mount 去掉 `ro`，使用 production `backend=fskit,norecover,windows_names,streams_interface=openxattr,noatime,big_writes` 读写策略；若 mount table 明确返回 `MNT_RDONLY` 则视为失败。
- 实体 `/dev/disk4` 完整 XPC smoke 输出 `RESULT=XPC_MOUNT_SMOKE_OK`，daemon 日志确认 `EDP mounted ... partition 2 as NTFS (read/write) at /Volumes/EDP-NTFS`；partition type 4 被 write probe 以 `not a valid NTFS volume` 正确拒绝，不影响 type 2 成功。
- 实盘最小写验证通过：在 `/Volumes/EDP-NTFS` 创建 44-byte 临时 probe，立即读回内容一致、执行 `sync`、SHA256=`804aeb48591837af764647e84053b41b7bbdde80cf8f58125ccf22a95f2e5152`，随后删除并再次 `sync`，确认 probe 文件不存在；未修改任何既有用户文件。

### 2026-08-26 — Finder 本地卷语义、批量删除与 I/O 性能收口

- 用户实机反馈三项问题：TextEdit 修改 txt 后无法保存、文件复制速度异常慢、Finder 多选文件不能删除。逐项复现后确认并非同一根因：覆盖已有目标的 `rename()` 在 macFUSE 5.3.3 FSKit 下稳定返回 `EOPNOTSUPP`；generic FSKit mount 的 `.Trashes` 访问返回 `EPERM`；原内层解密 `volume.raw` 顺序读仅约 5.8 MB/s。
- 外层 NTFS-3G 增加 macFUSE `local` 选项后，挂载源由 `macfuse://UUID` 变为 `/dev/diskN` 且 mount flags 出现 `local`；`.Trashes/501` 恢复可访问。真实 Trash 路径批量移动 10 个临时文件 0 错误，100 个文件批量 unlink 0 错误。CI mount-policy ratchet 同步翻转为必须包含 `local`。
- `local` 只能用于最外层 NTFS；给内层单文件解密 bridge 也加 `local` 会导致 production `ntfs-3g.probe --readwrite` 假报 status 13/EIO。使用既有严格 O_RDONLY 验证链复核当前实体盘时，readonly probe=0、readonly alias 上 readwrite probe=0，证明物理 NTFS 并未损坏。因此内层保持 generic FSKit，仅保留 `big_writes,noatime`。
- 重写 `EDPSM4` 热路径：取消每 16-byte block 的 slice/state/S-box/output Array 分配，改为一次性输出 buffer + 4 个 `UInt32` 状态寄存器 + 直接 S-box 位运算。标准 SM4 vector、1024 组真实 key 随机读、加密写边界和密文持久化回归全部通过。
- 实机性能：内层解密 256 MiB 顺序读由约 5.8 MB/s 提升至约 55.8 MB/s（约 9.7×）；外层 NTFS 64 MiB `fsync` 顺序写约 37.8 MB/s；500×4 KiB 小文件写约 6 秒。完成 clean unmount → daemon restart → readwrite probe → cold remount，`RESULT=XPC_MOUNT_SMOKE_OK`，确认写后卷一致性保持。
- TextEdit 原子保存仍未解决：即使 outer `local`，plain overwrite rename 仍返回 `EOPNOTSUPP`。macFUSE 官方已有 Tahoe/TextEdit 同类问题，且官方明确说明 FSKit backend 仍存在功能与性能限制；本机尝试 VFS/kernel backend 返回 `mount_macfuse: the file system is not available (1)`，当前未要求用户进入 Recovery 降低安全策略启用 kext。该项作为上游 FSKit 限制保留，不以数据层 hack 绕过。
