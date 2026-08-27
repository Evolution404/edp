# EDP USB Vault — FUSE-T Minimal FSKit Bridge 实时进度追踪

日期：2026-08-26  
分支：`test/fuset-minimal-fskit-bridge`  
基线：`6c44c1d`  
当前远端基线：`c35bb268`（2026-08-27 `git fetch` 后的 `origin/test/fuset-minimal-fskit-bridge` HEAD）
配套计划：`docs/PLAN-2026-08-26-fuset-minimal-fskit-bridge.md`  
架构决策：`docs/DECISION-2026-08-26-fuset-minimal-fskit-bridge.md`

## 2026-08-27 — Direct MFMount + macFUSE Local 生命周期 P0

当前目标已从 FUSE-T/macFUSE 基础可行性实验切换为 **Direct MFMount + macFUSE Local 的正式 unmount/remount 生命周期**；不再重复已有基础实验，也不再枚举不同 shell 卸载命令。

已确认的硬结论：

- Direct MFMount encrypted RW adapter 已打通，直接链接 `MFMount.framework`，不依赖 libfuse。
- Local FSKit transport 已同时证明 encrypted random-access RW、DiskImages2 raw attach 和 Finder 隐藏能力。
- `MFChannelClose()` 只关闭 transport channel，**不能卸载仍由 Local FSKit 暴露的系统 volume**；把 channel close 当作 volume teardown 会留下 mount table 条目并阻塞同路径 remount。
- `diskutil unmount <mountpoint>` 与普通 `unmount(2)` 对该 Direct Local volume 均失败；后续不再继续尝试 shell 命令排列组合。
- macFUSE 5.3.2 不导出 `_MFChannelInterrupt`，5.3.3 导出该符号；该符号差异目前只证明 ABI/实现差异，**没有解决实际 volume unmount**，不能据此宣称 5.3.3 生命周期行为更正确。
- 当前尚未证明 5.3.2 与 5.3.3 在正确 Disk Arbitration teardown 下存在真实行为差异；必须在相同 source-DADisk 流程中完成 A/B 才能下结论。
- 相关证据 runs：`33035729103`、`33035940110`、`33036981246`、`33037233968`。
- 相关提交：`a6bd237`、`d84092c`、`85fc98b`、`c35bb268`。

官方源码核对（2026-08-27）：

- macFUSE `5.3.2` 的 Library-3 gitlink 为 `afdd74cf`；`fuse_session_mount_callback()` 用 `DADiskCreateFromVolumePath()` 保存 `DADiskRef`，但 `fuse_session_unmount()` 只是调用无 callback 的 `DADiskUnmount()` 后立即 `CFRelease`，没有等待 Disk Arbitration 完成，也没有在 graceful 路径随后关闭 channel。
- macFUSE `5.3.3` 的 Library-3 gitlink 为 `9a3db24b`；新增完整 mount state machine。unmount 在独立线程调度 DASession/run loop，等待 `DADiskUnmount` callback，成功后才 `fuse_session_close()`；失败时恢复 DADisk ownership 和 mounted 状态。
- 因此 5.3.2 → 5.3.3 **确实存在 libfuse teardown 实现差异**，但 Direct MFMount adapter 绕过 libfuse，不会自动获得 5.3.3 的 state machine；`_MFChannelInterrupt` 也不是上述正确 teardown 的决定性步骤。
- Direct adapter 当前按同一所有权顺序实现：从 mount table 解析 `/dev/diskN` source → `DADiskCreateFromVolumePath()` 并校验 `DADiskGetBSDName()` 匹配 source → 调度并等待 `DADiskUnmount` callback → 关闭 MFChannel → 验证 source/mountpoint 均从 mount table 消失。这样可以用完全相同的代码验证 5.3.2/5.3.3 runtime，而不会把 library 版本自身的不同 teardown 实现混入结果。
- 官方源码：`https://github.com/macfuse/library`；版本 gitlink 来自 `macfuse/macfuse` 的 `macfuse-5.3.2` / `macfuse-5.3.3` tag。

当前唯一诊断主线：

```text
mountpoint
  -> 读取 mount table 中真实 source /dev/diskN
  -> DASession + DADiskCreateFromVolumePath(mountpoint)
  -> DADiskGetBSDName() == source 的硬校验
  -> 对对应 DADiskRef 执行正确 unmount/deactivation 并等待 callback
  -> 再收口 MF transport/channel
  -> 确认 mount table 条目消失
  -> 同路径第二轮 Direct MFMount
  -> 验证第一轮 encrypted marker 仍存在
```

验收矩阵：

| ID | 状态 | 任务 | 当前结论 |
|---|---|---|---|
| L1 | ✅ | encrypted Direct MFMount RW，无 libfuse | 已通过 |
| L2 | ✅ | Local FSKit + DiskImages2 + Finder 隐藏 | 已通过 |
| L3 | ✅ | 排除 `MFChannelClose()` 作为 volume unmount | 只关闭 channel，不移除 Local volume |
| L4 | ✅ | 排除 mountpoint shell unmount 路径 | `diskutil unmount` / 普通 `unmount(2)` 均失败，不再重复 |
| L5 | 🟡 | 解析真实 mount source `/dev/diskN` 并对 source `DADiskRef` teardown | 已实现 source lookup、scheduled DASession、callback wait、channel close 和 mount-table gate；等待 matrix |
| L6 | ⏳ | mount table 消失后同路径 remount | 等待 L5 |
| L7 | ⏳ | 两轮 mount → RW → unmount → remount → encrypted marker persistence | 任一版本稳定通过即停止诊断并固定该版本 |
| L8 | 🟡 | macFUSE 5.3.2 / 5.3.3 真实行为差异 | 已确认 libfuse teardown 源码存在实质差异；相同 Direct lifecycle 下的 runtime 行为差异等待 matrix |
| L9 | ⏳ | 产品 transport provider 接入 `macfuse-local` | L7 后把 `EDPVaultRuntime.swift` 从硬编码 `edp-fuset-readwrite` / `EDPFuseTRuntimePolicy` 迁移到正式 provider |
| L10 | ⏳ | 完整产品 E2E | encrypted mount → RW → DiskImages2 → Apple FS/Finder → unmount → remount → persistence |

停止条件：一旦 5.3.2 或 5.3.3 稳定通过 L7，立即停止版本诊断实验、固定该版本并进入 L9/L10。

matrix run `33039249865`（commit `a07f654`）：5.3.2/5.3.3 均成功安装、构建、首轮 encrypted mount 和 marker RW，但都未在 40 秒 gate 内移除 mount table 条目。首版 stop 函数在输出 `server.log` 前执行断言，因而该 run 不能判断是 DADiskRef 创建失败、callback timeout 还是 dissenter；已改为所有失败分支先输出真实 source、DA callback 状态和残留 mount entry，再做下一轮判别。此轮不构成版本行为差异结论。

matrix run `33039433969`（commit `ed39089`）：两版本都把 Local mount source 解析为 `/dev/disk8`，`DADiskCreateFromBSDName("disk8")` 也都成功，但 `DADiskUnmount` callback 一致返回 `0xF8DA0007 = kDAReturnNotMounted`，mount table 条目保持不变。这证明 source block-device DADisk 不是 Disk Arbitration 记录的 mounted-volume DADisk；两版本在该错误对象路径上没有行为差异。下一版改为官方 library 使用的 `DADiskCreateFromVolumePath()`，同时要求 `DADiskGetBSDName()` 必须匹配先前解析的 source，避免只凭 mountpoint 取到错误 volume。

matrix run `33039579738`（commit `a5c240b`）：`DADiskCreateFromVolumePath()` 在两版本都返回 BSD name `disk8`，与 mount source `/dev/disk8` 精确匹配，但 default `DADiskUnmount` 仍一致返回 `kDAReturnNotMounted`。因此不是 DADisk 构造错误，而是 DA 不把 macFUSE Local 创建的 virtual whole disk 记录为普通 mounted volume；这也解释了官方 5.3.3 library 的 `failed to unmount DADiskRef`。下一版对该 whole source 使用 `kDADiskUnmountOptionWhole`，如果仍为 `NotMounted`，则对同一个 DADisk 执行 `DADiskEject` 以触发 virtual-device deactivation；只接受最终 callback success。

matrix run `33039845053`（commit `0418e0c`）：两版本的 `DADiskUnmount(..., kDADiskUnmountOptionWhole, ...)` callback 都返回 success，随后 `MFChannelClose()` 也都返回 success，server 正常走到 `DIRECT_MFMOUNT_EXIT=0`。失败来自 harness 在看到 server 已退出时提前中止 mount-table 轮询，且 detached teardown worker 随进程终止，未能完成 `MOUNT_TABLE_GONE` 日志；这不是 runtime teardown 失败或版本差异。已增加 server 端 teardown-complete barrier，并让 CI 在进程先退出时仍继续等待 mount table 消失。

matrix run `33039997642`（commit `69bb5cc`）：server-side barrier 证明两版本在 whole-unmount success + channel-close success 后等待 10 秒、外部等待 40 秒，mount entry 仍不会消失；因此上轮并非单纯 harness 时序问题。macFUSE Local source 是 mount service 创建的 virtual disk，whole-unmount callback 成功并不等价于 virtual resource deactivation。正式顺序改为：whole unmount → 若 source mount entry 仍存在则 `DADiskEject` 同一 DADisk → callback success → channel close → mount-table gate。

matrix run `33040192662`（commit `cb7591f`）：两版本 whole-unmount callback 仍一致 success；对同一 `/dev/disk8` 立即执行 `DADiskEject` 时，两版本都返回 `0xC010 = unix_err(EBUSY)`，mount entry 保持不变。由 Darwin error 编码（`err_sub(3) | 16`）可知这不是 5.3.2/5.3.3 API 差异，而是 Local virtual disk 仍被活跃 MFMount transport 占用。下一版保留 scheduled `DASession`/精确 `DADiskRef`，调整为 whole-unmount acknowledgement → `MFChannelClose()` 收口 XPC transport → `DADiskEject()` deactivation → mount-table gate；server teardown barrier 保证 eject callback 完成前进程不退出。

## 当前总状态

**状态：Phase A/B 已完成；原生 Swift 最小 bridge 与 Phase D 核心已通过；Phase E/F 已完整通过；Phase G 的 synthetic SM4 G1-G3 已通过，且 G4a/G5a/G6a“真实捕获 metadata + 正式 EDPReadOnlyUnlock + hosted macOS 26”子里程碑已通过。Phase H hosted H1-H4、H5a、H6 已通过，H7-H10 已完成许可核对、macFUSE 对照与最终架构决策。最终选择：`A. 推荐 FUSE-T thin bridge`，限定 macOS 26+ 只读产品路径。物理 `/dev/rdiskN` 的 G4/G5/G6 与 sleep/wake/真实拔盘 H5b 仍保留为 release gate；商业发布还必须先取得适用 FUSE-T commercial license。**

当前实验目标：只依赖 FUSE-T 1.2.7 官方签名约 1.7 MB `fuse-t.app`，由 EDP 自己实现 Unix Domain Socket backend，避免安装 FUSE-T 完整 core、`go-nfsv4`、macFUSE 和 NTFS-3G；hidden `volume.raw` 仅作 transport，最终用户卷交给 Apple DiskImages + Apple 文件系统驱动。

当前重要边界：

- `/Applications/fuse-t.app`：实验只使用官方签名 FSKit app bundle。
- `org.fuset.fskit-srv.module`：Developer ID Team `6DY7Z4SVDZ`。
- `/Library/Application Support/fuse-t`、`go-nfsv4`、全局 `libfuse3`：最终 runtime 不安装。
- macFUSE runtime/KEXT：本实验只读路径不依赖。
- CI-only `enabledModules.plist` 注入仅在一次性 Actions runner 模拟用户启用官方 extension，**不得进入产品授权绕过路径**。
- FUSE-T 1.2.7 package 固定 SHA-256 `6a29c747e61a86a405a189efc3de42812d73147135f93a1bb0624c1e7b90e654`；升级必须重跑 binary contract 与 E/F/G/H 核心回归。
- 当前分支直接在主工作目录使用，不使用 worktree。

---

## Phase A — 干净运行时与签名基线

| ID | 状态 | 任务 | 证据/结果 |
|---|---|---|---|
| A0 | ✅ | 建立干净实验基线 | 从 `6c44c1d` 建实验分支，后按要求直接 checkout 到当前工作目录 |
| A1 | ✅ | 创建测试分支 | `test/fuset-minimal-fskit-bridge` |
| A2 | ✅ | 编写实验计划 | `docs/PLAN-2026-08-26-fuset-minimal-fskit-bridge.md` |
| A3 | ✅ | 创建实时 tracker | 本文件 |
| A4 | ✅ | 固化 FUSE-T 1.2.7 host/appex 指纹 | host 约 1.7 MB、appex 约 400 KB；host executable SHA-256 `fc64ae9c17efc70540db07f256ecd75af1ff174a9fb83611bb6ffdb1cba8f2c5`；appex `199ba1246d36db18ebf45c60abd3d68ca4b4ad9d8080d55aa8e856f574772086` |
| A5 | ✅ | codesign / Team / hardened runtime | `Developer ID Application: alex fishman (6DY7Z4SVDZ)`；Team `6DY7Z4SVDZ`；Gatekeeper accepted / notarized |
| A6 | ✅ | provisioning profile | appex profile Team `6DY7Z4SVDZ`，expires 2044-03-25 |
| A7 | ✅ | FSKit entitlement | `ProvisionsAllDevices=true`；`com.apple.developer.fskit.fsmodule=true` |
| A8 | ✅ | 无 FUSE-T core/helper/global libfuse | `/Library/Application Support/fuse-t`、`/usr/local/bin/go-nfsv4`、`/usr/local/lib/libfuse3.dylib` 均不存在 |
| A9 | ✅ | 无 macFUSE runtime/KEXT | filesystem runtime/helper/KEXT 均不在实验运行时 |
| A10 | ✅ | 第三方 FSKit module 基线 | 当前实验只使用官方 `org.fuset.fskit-srv.module` |

Phase A 验收：**通过**。

---

## Phase B — 官方 FSKit resource 创建路径

| ID | 状态 | 任务 | 证据/结果 |
|---|---|---|---|
| B1 | ✅ | 匹配 FUSE-T 内置 libfuse 3.19 的最小 hello | `FuseTHello319.c` 编译/运行通过 |
| B2 | ✅ | 临时参考 backend=fskit 路径 | 只从临时目录加载 libfuse/go helper，不安装 core；确认官方调用链 |
| B3 | ✅ | 捕获 `session.json` | 字段：`session_id`、`socket_path`、`auth_token`、`namedattr`、`readonly`、`volume_name` |
| B4 | ✅ | 确认 resource 创建方式 | `/sbin/mount -o nobrowse,rdonly -t fuset <普通 session.json 路径> <mountpoint>`；`file://` URL 会导致 EACCES |
| B5 | ✅ | 确认官方 helper 行为 | 官方 backend 会启动 `go-nfsv4 --backend fskit`，但无 TCP listener，仅 Unix socket |
| B6 | ✅ | probe/load/mount 日志 | `probeResource → session → loadResource → rpc → activate → mount` 完整复现 |
| B7 | ✅ | 移除 libfuse/go helper 的最小契约 | EDP-owned listener + `session.json` + signed FSKit appex 可直接 mount |

Phase B 验收：**通过**。最终路径不再需要 libfuse/go-nfsv4。

---

## Phase C — Unix Domain Socket RPC 最小化

| ID | 状态 | 任务 | 证据/结果 |
|---|---|---|---|
| C1 | ✅ | handshake framing | 8-byte BE `metadata_len + payload_len` |
| C2 | ✅ | request/payload framing | JSON metadata + raw payload；约 16 MiB frame 上限 |
| C3 | ✅ | auth token | handshake 必须携带匹配 token |
| C4 | ✅ | handshake/ping | 响应必须同时 `ok=true` + matching `session_id` |
| C5 | ✅ | root getattr / lookup / statfs | root/node metadata、ENOENT、statfs 已通过 |
| C6 | ✅ | open/read/close | read 使用 raw frame payload，不做 Base64/JSON 数据膨胀 |
| C7 | 🟡 | directory enumeration | `ls` 能显示 `volume.raw`，但结束仍有 `fts_read: Input/output error`；不阻塞 direct raw transport |
| C8 | ⏳ | 必须 xattr 查询 | 待收口 |
| C9 | ⏳ | mutation RPC 全矩阵 fail-closed | 已知 mutation 返回 EROFS，完整方法矩阵待补 |
| C10 | ✅ | 无 TCP listener | direct backend 仅 app-group Unix socket |

Phase C 验收：**核心只读单文件路径通过**；C7-C9 属于后续协议硬化。

---

## Phase D — 单文件 `volume.raw`

| ID | 状态 | 任务 | 证据/结果 |
|---|---|---|---|
| D1 | ✅ | 只暴露 `/volume.raw` | node 2，仅目标名称可 lookup |
| D2 | ✅ | fixed logical size | `stat` size 正确 |
| D3 | ✅ | 任意 offset/length random read | 非对齐、跨 4K、尾部随机读逐字节一致 |
| D4 | ✅ | offset<size 不错误返回 0 byte | 尾部短读正确 |
| D5 | ✅ | EOF 仅 offset>=size | 边界/超 EOF 正确 |
| D6 | 🟡 | mutation 全部只读失败 | overwrite/touch/rm 外部测试均失败；完整 syscall matrix 待补 |
| D7 | ✅ | full hash | 8193-byte fixture virtual SHA 与 backing 一致 |

Phase D 验收：**核心通过**。

---

## Phase E — `volume.raw` → `/dev/diskN`

| ID | 状态 | 任务 | 证据/结果 |
|---|---|---|---|
| E1 | ✅ | deterministic raw fixture | 8 MiB raw，SHA-256 `638f4947a865d315c06c6c16913be984ff08270b8da0e22a3fedb044891ff59d` |
| E2 | ✅ | hidden `volume.raw` → hdiutil | `hdiutil attach -readonly -nomount -imagekey diskimage-class=CRawDiskImage` 成功 |
| E3 | ✅ | `/dev/diskN` | hosted macOS 26 产生 `/dev/disk8`，Media Read-Only=Yes |
| E4 | ✅ | random LBA 一致 | LBA `0/7/4095/8192/16383` 与 backing 一致 |
| E5 | ✅ | backing 无写入 | 0444 backing SHA/size/mtime/mode 前后完全一致 |
| E6 | ➖ | 私有 DiskImages2 对照 | 公共 hdiutil 已满足需求，暂不需要私有 adapter |

Phase E 验收：**通过**。

---

## Phase F — Apple 默认文件系统

| ID | 状态 | 任务 | 证据/结果 |
|---|---|---|---|
| F1 | ✅ | Disk Arbitration 自动识别 | 不传 filesystem type，自动识别并挂载 HFS+ fixture |
| F2 | ✅ | backend 无文件系统类型知识 | runtime 只传 raw image class |
| F3 | ✅ | 最终卷只读 | Media/Volume Read-Only=Yes；写入返回 Read-only file system |
| F4 | ✅ | Finder 可浏览 | Finder AppleScript 实际枚举 `EDP Folder`、`EDP_SENTINEL.txt` |
| F5 | ✅ | 最终卷不是 fuset | final `File System Personality: HFS+`、`Type (Bundle): hfs`；hidden transport 才是 `fuse-t ... fskit` |

Phase F 验收：**通过**。关键证据：`docs/diagnostics/fuset-applefs-macos26-ci.txt`。

---

## Phase G — EDP SM4 random-access

| ID | 状态 | 任务 | 证据/结果 |
|---|---|---|---|
| G1 | ✅ | 离线 EDP 加密 fixture | 64 MiB Apple FS raw 经现有 `EDPCrypto` SM4 加密后由 bridge 解密 |
| G2 | ✅ | read → existing random-access reader | `EDPFileRawDevice → EDPEncryptedPartitionReader`，随机窗口与完整 SHA 一致 |
| G3 | ✅ | 无完整 plaintext cache | `PLAINTEXT_CACHE=none`；bridge 只打开 cipher；cipher backing 不变；run `32973525009` 全绿 |
| G4a | ✅ | 真实捕获 metadata + 正式 hosted unlock | run `32975531345`：真实 LBA11/LBA12 + VID/PID/device size，经 `EDPReadOnlyUnlock` 正式解析；raw access `O_RDONLY|O_CLOEXEC` |
| G5a | ✅ | real-metadata hosted → Apple FS → Finder | logical partition `118477684736` bytes；`/dev/disk8` HFS+；Finder 枚举成功 |
| G6a | ✅ | hosted whole-device backing 无写入 | 124736503808-byte sparse container，LBA11/LBA12/data head/tail hash 与 size/mtime/mode 前后不变 |
| G4 | 🟡 | 物理 EDP 仅 O_RDONLY | 仍需真实 `/dev/rdiskN` descriptor/权限最终确认 |
| G5 | 🟡 | 物理 EDP → Apple FS → Finder | hosted payload 为测试 Apple FS；真实物理 EDP 文件系统 Finder 验收待实机 |
| G6 | 🟡 | 物理介质零写入证明 | hosted 已证明；真实 USB 前后介质采样仍待实机 |

Phase G 验收：**G1-G3、G4a-G6a 通过；物理 G4-G6 保留。**

关键证据：`docs/diagnostics/fuset-edp-sm4-macos26-ci.txt`、`docs/diagnostics/fuset-edp-unlock-realmeta-macos26-ci.txt`。

---

## Phase H — 性能、稳定性、许可、决策

| ID | 状态 | 任务 | 证据/结果 |
|---|---|---|---|
| H1 | ✅ | 4 KiB / 64 KiB / 1 MiB random read benchmark | macOS 26.5.2 / Xcode 26.6、real-metadata product unlock、`F_NOCACHE=1`、read-ahead=0；3 次中位数：4 KiB **7.533 MiB/s / 1928.4 IOPS**，64 KiB **37.234 MiB/s / 595.7 IOPS**，1 MiB **52.357 MiB/s / 52.4 IOPS**；run `32976967634` 全绿 |
| H2 | ✅ | 256 MiB sequential benchmark | 同一 no-cache 条件，1 MiB block × 256：**45.597 MiB/s**，5.614 s |
| H3 | ✅ | CPU / memory / context switch baseline | client 5.63 s real、max RSS 7,159,808 bytes、258 voluntary / 24 involuntary context switches；bridge CPU `0:28.09 → 0:32.76`（约 4.67 CPU-s），峰值 RSS **163,808 KiB ≈ 160 MiB**；RSS 偏高列为优化目标 |
| H4 | ✅ | Finder / Quick Look / 大文件 | run `32978050642`：192 MiB real-metadata EDP fixture；64 MiB `EDP_LARGE.bin` size/hash 完整验证，Finder 实际枚举；`qlmanage` 成功生成 `EDP_PREVIEW.txt.png` thumbnail |
| H5a | ✅ | backend crash fail-closed | full Apple FS attach 后对 bridge `SIGKILL`；未缓存 read 立即 `Connection reset by peer`，无静默错误数据；`/dev/disk8` 可 forced detach/eject |
| H5b | 🟡 | sleep/wake / 真实拔盘 | hosted runner 无法真实模拟睡眠唤醒和物理 USB 拔插；保留 macOS 26 实机验收 |
| H6 | ✅ | graceful/crash cleanup 无泄漏 | graceful unmount 后 bridge 自然退出并删除 session/socket；crash 路径由 `FuseTSessionCleanup.swift` 严格校验 EDP temp/session + app-group socket 后清理；最终全局 `edp-fuset-*` session/socket 扫描为 0 |
| H7 | ✅ | FUSE-T binary redistribution 许可结论 | 官方 `License.txt`：binary 非商业使用免费且 redistribution 需保留 notice/conditions；**commercial use 或 commercial-software bundling 必须取得 FUSE-T commercial license**。官网也明确 commercial license available for embedding/shipping |
| H8 | ✅ | commercial bundling / 自动下载边界 | FUSE-T 的 commercial-use 条款意味着不能把“由产品自动下载而非内嵌”当成免费商业绕过；商业场景须先取得授权并按合同分发。对照 macFUSE license 更明确把 commercial context 的 automated download/install 也纳入需 prior written permission 的范围 |
| H9 | ✅ | 与 macFUSE Minimal Runtime 对比 | 只读目标下 FUSE-T thin path 仅约 1.7 MB signed app + EDP-owned backend，final Finder 卷为 Apple FS；macFUSE+NTFS-3G 既有路径组件/安装/维护面更大，stable 路径还存在 `MNT_LOCAL=false`、TextEdit atomic rename `EOPNOTSUPP` 等 outer-FUSE 语义问题。性能口径不同，不宣称绝对胜负；thin hosted no-cache seq 45.597 MiB/s，macFUSE WIP inner read约 55.8 MiB/s。两者商业分发都需要许可 |
| H10 | ✅ | 最终架构决策 | **A. 推荐 FUSE-T thin bridge**，仅针对 macOS 26+ EDP 只读路径；商业许可、物理 G4-G6/H5b、version-pin/binary-contract、正常用户 FSKit enablement 为 release gates。完整决策见 `docs/DECISION-2026-08-26-fuset-minimal-fskit-bridge.md` |

Phase H hosted 技术与架构验收：**H1-H4、H5a、H6-H10 已通过；H5b 需物理实机。架构决策已完成。**

性能关键证据：`docs/diagnostics/fuset-performance-macos26-ci.txt`。第 3 轮曾因 VFS cache 出现 1–10 GiB/s 虚高值，因此不采纳；`7ffb293` 后显式 `F_NOCACHE=1` + `F_RDAHEAD=0`，第 4 轮数据稳定，作为正式 hosted baseline。

稳定性关键证据：`docs/diagnostics/fuset-stability-macos26-ci.txt`。crash read 明确返回 `Connection reset by peer`，final disk `"disk8" ejected.`，recovery 输出 `RESULT=FUSET_SESSION_CRASH_CLEANUP_COMPLETE`。

许可 authoritative sources：

- `https://github.com/macos-fuse-t/fuse-t/blob/main/License.txt`
- `https://www.fuse-t.org/`
- `https://github.com/macfuse/framework`
- `https://github.com/macfuse/macfuse/wiki/Open-Source-Status`

---

## 当前下一步

```text
P0：把当前 thin bridge 从 PoC 目录收敛为 product read-only runtime adapter；保留 version/SHA/binary-contract supply-chain gate
↓
P0：实现正式安装/检测流程：只验证官方 bundle、签名与 FSKit enablement，绝不写 enabledModules.plist 绕过授权
↓
P1：优化 H3 bridge peak RSS ~160 MiB，并建立 memory regression budget
↓
P1：C7 directory EOF/EIO、C8 xattr、C9/D6 mutation fail-closed matrix
↓
Release gate：macOS 26 实机 physical G4-G6 + H5b；商业发布场景取得 FUSE-T commercial license
```

## 失败实验登记

| 时间 | 实验 | 结果 | 避免重复 |
|---|---|---|---|
| 2026-08-26（前序） | `file://.../session.json` 作为 mount resource | extension 启动但 EACCES | direct path 固定传普通 session 文件路径 |
| 2026-08-26 | 最新 libfuse hello 对 FUSE-T 3.19 headers | API 不匹配 | 固定使用 3.19 对应 API |
| 2026-08-26 | handshake 缺 `ok` 或 matching session id | rejected | 两者必须同时存在 |
| 2026-08-26 | 原生 bridge `ls` | 能列 `volume.raw`，尾部 EIO | C7 保留，不阻塞 direct path |
| 2026-08-26 | Actions 只做 PluginKit enable | FSKit 报 module disabled | PluginKit 与 FSKit `enabledModules.plist` 是两层状态 |
| 2026-08-26 | Phase F `hdiutil create ... -format UDRW` | macOS 26 参数错误 | fixture 不再传该 format |
| 2026-08-26 | Finder AppleScript 首版 | 脚本语法导致 job 红 | 先 osacompile 后执行 |
| 2026-08-26 | F5 整行 `grep -i fuset` | 卷名含 FUSET 导致误报 | 用 diskutil/mount 精确类型 |
| 2026-08-26 | `stat -f %T` 判 filesystem type | macOS 语义不符合预期 | 删除该判据 |
| 2026-08-26 | generic backing 后 Swift standalone/library entrypoint | 两种构建模式冲突 | `2d1f0e4` 收口全局初始化/conditional entrypoint |
| 2026-08-26 | H benchmark 首轮 | `$GITHUB_ENV` 在同 step 不立即进入 shell env | 同 step 显式解析值；后续 step 使用 env |
| 2026-08-26 | H benchmark 第二轮 | benchmark helper `@main` 单文件构建冲突 | helper 改普通 standalone top-level entrypoint |
| 2026-08-26 | H benchmark 第三轮 | 64 KiB/1 MiB 后续 trial 命中 VFS cache，出现 GiB/s 假数据 | 不采纳；增加 `F_NOCACHE=1` + `F_RDAHEAD=0` 后重测 |
| 2026-08-26 | H4-H6 stability 首轮 | **全绿，无架构修补** | 64 MiB Finder/Quick Look、graceful cleanup、SIGKILL fail-closed、force detach、crash cleanup 均一次通过 |

---

## 提交记录

| Commit | 内容 | 远端状态 |
|---|---|---|
| `2fe69cd` | 新测试分支 + 计划 + tracker | 已 push |
| `ac8c1b1` | Phase A 签名/运行时基线 | 已 push |
| `c44ca83` | Phase B FUSE-T 3.19 backend=fskit 参考路径 | 已 push |
| `7ee9ca3` | direct mount + RPC 契约 | 已 push |
| `c8175ed` | volume.raw lookup/open/read | 已 push |
| `d6154c1` | 原生 Swift bridge + random/EOF/full hash | 已 push |
| `48d5881` / `64da44b` / `7217a8e` | RPC/binary contract CI | 已 push |
| `4c7b065` / `6f08cc2` | open/read/close/EROFS contract | 已 push |
| `ecfe418` / `f6c3644` | Phase E 初始 hdiutil CI / module-disabled 诊断 | 已 push |
| `496c322` / `f80a0b1` | CI-only enabledModules；E2-E4 `/dev/disk8` | 已 push |
| `a62c23e` / `c99fd59` | E5 backing 不变式 | 已 push |
| `35a58cd` / `13b8dc0` | Phase F 初始 Apple FS E2E | 已 push |
| `ddeef7c` / `a27cb7d` | 修复 HFS+ fixture；F1-F3 | 已 push |
| `5232630` / `f0a9210` / `86a28ac` | Finder/F5 精确判定 | 已 push |
| `ae74e0e` | `FuseTReadBacking` 抽象 | 已 push |
| `60e9e2d` | existing SM4 random-access adapter | 已 push |
| `4bb13a0` / `2d1f0e4` | standalone/library build-mode 修复 | 已 push |
| `5ec6df5` | real-metadata sparse EDP fixture builder | 已 push |
| `7ef069c` | product-style `FuseTEDPUnlockBridge` | 已 push |
| `6894b0a` / `765cee5` | G4a-G6a workflow + diagnostic；run `32975531345` | 已 push / 全绿 |
| `5909543` | Swift pread benchmark helper | 已 push |
| `bd6f2b7` | H1-H3 performance workflow | 已 push |
| `b49a980` / `c4fb2f6` | benchmark env/entrypoint 修复 | 已 push |
| `7ffb293` / `c383c85` | no-cache benchmark + 正式 H1-H3 diagnostic；run `32976967634` | 已 push / 全绿 |
| `9bf266d` | validated `FuseTSessionCleanup.swift` crash cleanup helper | 已 push；contract 回归全绿 |
| `500830b` / `45f4610` | H4-H6 stability workflow + diagnostic；run `32978050642` | 已 push / 全绿 |
| `67c6e0b` | tracker 收口 hosted H1-H6 | 已 push |
| `c94feac` | H7-H10 许可、macFUSE 对照与最终架构决策文档 | 已 push |
