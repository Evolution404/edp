# EDP USB Vault — FUSE-T Minimal FSKit Bridge 实时进度追踪

日期：2026-08-26  
分支：`test/fuset-minimal-fskit-bridge`  
基线：`6c44c1d`  
配套计划：`docs/PLAN-2026-08-26-fuset-minimal-fskit-bridge.md`  
架构决策：`docs/DECISION-2026-08-26-fuset-minimal-fskit-bridge.md`

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
