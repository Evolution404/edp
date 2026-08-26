# EDP USB Vault — FUSE-T Minimal FSKit Bridge 实时进度追踪

日期：2026-08-26  
分支：`test/fuset-minimal-fskit-bridge`  
基线：`6c44c1d`  
配套计划：`docs/PLAN-2026-08-26-fuset-minimal-fskit-bridge.md`

## 当前总状态

**状态：Phase A 准备中**

当前实验目标：验证是否能只依赖 FUSE-T 1.2.7 官方签名的 1.7 MB `fuse-t.app`，由 EDP 自己实现 Unix Domain Socket backend，避免安装 FUSE-T 完整 core、`go-nfsv4`、macFUSE 和 NTFS-3G。

当前系统实验状态（建立 tracker 时）：

- `/Applications/fuse-t.app`：已安装，仅 FSKit app bundle，约 1.7 MB。
- `org.fuset.fskit-srv.module`：已在系统设置中启用。
- `/Library/Application Support/fuse-t`：未安装。
- `/usr/local/bin/go-nfsv4`：未安装。
- `/usr/local/lib/libfuse3.dylib`：未安装。
- macFUSE：此前实验已清理；本分支后续必须重新做无残留确认。
- FUSE-T core 仅允许从 `/private/tmp` 临时解包用于协议抓取，不做系统安装。
- 当前分支为独立 worktree，未继承源 checkout 的未提交 `docs/PROGRESS-TRACKER-NTFS-FINDER-2026-08-26.md` 修改。

---

## Phase A — 干净运行时与签名基线

| ID | 状态 | 任务 | 证据/结果 |
|---|---|---|---|
| A0 | ✅ | 创建隔离 worktree | `/Users/zhangyuxi/.devspace/worktrees/edp-usb-vault-be4e5e14`，base `6c44c1d` |
| A1 | ✅ | 创建测试分支 | `test/fuset-minimal-fskit-bridge` |
| A2 | ✅ | 编写实验计划 | `docs/PLAN-2026-08-26-fuset-minimal-fskit-bridge.md` |
| A3 | ✅ | 创建实时 tracker | 本文件 |
| A4 | ⏳ | 固化 FUSE-T 1.2.7 host/appex SHA-256、体积、版本 | 待执行 |
| A5 | ⏳ | 固化 codesign / Team / hardened runtime | 待执行 |
| A6 | ⏳ | 固化 host/appex provisioning profile | 待执行 |
| A7 | ⏳ | 确认 `ProvisionsAllDevices=true` + FSKit entitlement | 待执行 |
| A8 | ⏳ | 确认无 FUSE-T core / go-nfsv4 / global libfuse3 | 待执行 |
| A9 | ⏳ | 确认无 macFUSE runtime/helper/KEXT | 待执行 |
| A10 | ⏳ | 确认 PlugInKit 第三方实验模块状态 | 待执行 |

Phase A 验收：**未完成**。

---

## Phase B — 官方 FSKit resource 创建路径

| ID | 状态 | 任务 | 证据/结果 |
|---|---|---|---|
| B1 | ⏳ | 获取与 FUSE-T 内置 libfuse 3.19 匹配的最小 hello 示例 | 待执行 |
| B2 | ⏳ | 仅从 `/private/tmp` 加载 libfuse3，运行 `backend=fskit` | 待执行 |
| B3 | ⏳ | 捕获官方 session directory / `session.json` | 待执行 |
| B4 | ⏳ | 捕获 security-scoped FSPathURLResource 创建方式 | 待执行 |
| B5 | ⏳ | 确认 `go-nfsv4` 在 FSKit backend 是否启动 | 待执行 |
| B6 | ⏳ | 记录 probe/load/mount 完整日志 | 待执行 |
| B7 | ⏳ | 提取不依赖 libfuse 的最小 resource 契约 | 待执行 |

已知失败样本（分支建立前）：

```text
/sbin/mount -F -t fuset file:///private/tmp/.../session.json ...
→ FskitSrvModule 成功启动
→ probeResource failed to access security-scoped resource
→ EACCES
```

结论：直接传普通 file URL 不够，必须复现官方 security-scoped resource 路径。

Phase B 验收：**未完成**。

---

## Phase C — Unix Domain Socket RPC 最小化

| ID | 状态 | 任务 | 证据/结果 |
|---|---|---|---|
| C1 | ⏳ | 捕获首个 Unix socket handshake frame | 待执行 |
| C2 | ⏳ | 解析 framing / request_id / payload | 待执行 |
| C3 | ⏳ | 确认 `auth_token` 校验 | 待执行 |
| C4 | ⏳ | 实现 ping/handshake | 待执行 |
| C5 | ⏳ | 实现 root getattr / lookup / statfs | 待执行 |
| C6 | ⏳ | 实现 open / read / close | 待执行 |
| C7 | ⏳ | 实现 directory enumeration | 待执行 |
| C8 | ⏳ | 实现必须的 xattr 查询 | 待执行 |
| C9 | ⏳ | 所有 mutation 返回只读错误 | 待执行 |
| C10 | ⏳ | 验证无 TCP listener | 待执行 |

已知二进制字段（分支建立前）：

```text
session_id
socket_path
auth_token
namedattr
readonly
volume_name
request_id
ping
readFileWithNodeID
fetchAttributesForNodeID
enumerateDirectory
```

Phase C 验收：**未完成**。

---

## Phase D — 单文件 `volume.raw`

| ID | 状态 | 任务 | 证据/结果 |
|---|---|---|---|
| D1 | ⏳ | 只暴露 `/volume.raw` | 待执行 |
| D2 | ⏳ | 正确报告 fixed logical size | 待执行 |
| D3 | ⏳ | 任意 offset/length 随机读 | 待执行 |
| D4 | ⏳ | offset<size 不返回错误 0-byte READ | 待执行 |
| D5 | ⏳ | EOF 仅 offset>=size | 待执行 |
| D6 | ⏳ | mutation 全部只读失败 | 待执行 |
| D7 | ⏳ | fixture 全文件哈希一致 | 待执行 |

Phase D 验收：**未完成**。

---

## Phase E — `volume.raw` → `/dev/diskN`

| ID | 状态 | 任务 | 证据/结果 |
|---|---|---|---|
| E1 | ⏳ | 创建小型 synthetic raw/dmg fixture | 待执行 |
| E2 | ⏳ | `hdiutil attach -readonly -nomount` 读取 hidden `volume.raw` | 待执行 |
| E3 | ⏳ | 产生 `/dev/diskN` | 待执行 |
| E4 | ⏳ | 随机 LBA 读回一致 | 待执行 |
| E5 | ⏳ | 确认 backing store 无实际写入 | 待执行 |
| E6 | ⏳ | 必要时对照 DiskImages2 adapter | 待执行 |

Phase E 验收：**未完成**。

---

## Phase F — Apple 默认文件系统

| ID | 状态 | 任务 | 证据/结果 |
|---|---|---|---|
| F1 | ⏳ | Disk Arbitration 自动识别 fixture | 待执行 |
| F2 | ⏳ | EDP/backend 不传 filesystem type | 待执行 |
| F3 | ⏳ | 最终 mount 为 `MNT_RDONLY` | 待执行 |
| F4 | ⏳ | Finder 可浏览 | 待执行 |
| F5 | ⏳ | Finder 最终卷不是 `fuset` 文件系统 | 待执行 |

Phase F 验收：**未完成**。

---

## Phase G — EDP SM4 random-access

| ID | 状态 | 任务 | 证据/结果 |
|---|---|---|---|
| G1 | ⏳ | 离线 EDP 加密 fixture 接入 | 待执行 |
| G2 | ⏳ | `read(offset,length)` → SM4 random-access reader | 待执行 |
| G3 | ⏳ | 不生成完整 plaintext cache | 待执行 |
| G4 | ⏳ | 真实 EDP 仅 `O_RDONLY|O_CLOEXEC` | 待执行 |
| G5 | ⏳ | 真实 EDP → Apple 默认 FS → Finder | 待执行 |
| G6 | ⏳ | 测试后确认无介质写入 | 待执行 |

Phase G 验收：**未完成**。

---

## Phase H — 性能、稳定性、许可、决策

| ID | 状态 | 任务 | 证据/结果 |
|---|---|---|---|
| H1 | ⏳ | 4 KiB / 64 KiB / 1 MiB random read benchmark | 待执行 |
| H2 | ⏳ | 256 MiB sequential benchmark | 待执行 |
| H3 | ⏳ | CPU / memory / context switch | 待执行 |
| H4 | ⏳ | Finder / Quick Look / 大文件 | 待执行 |
| H5 | ⏳ | sleep/wake / 拔盘 / backend crash | 待执行 |
| H6 | ⏳ | 清理 socket/session/mount 泄漏 | 待执行 |
| H7 | ⏳ | FUSE-T binary redistribution 许可结论 | 待执行 |
| H8 | ⏳ | 商业 bundling / 自动下载许可结论 | 待执行 |
| H9 | ⏳ | 与 macFUSE Minimal Runtime 对比 | 待执行 |
| H10 | ⏳ | 最终架构决策 | 待执行 |

已知许可风险：FUSE-T binary distribution 当前声明非商业使用免费；商业使用或与商业软件捆绑需商业许可。该项在正式产品决策前必须重新核对 authoritative license。

Phase H 验收：**未完成**。

---

## 当前下一步

立即执行：

```text
A4-A10 固化干净运行时/签名基线
↓
commit + push
↓
B1-B3：libfuse 3.19 backend=fskit 官方 smoke
```

## 失败实验登记

| 时间 | 实验 | 结果 | 避免重复 |
|---|---|---|---|
| 2026-08-26（分支建立前） | 普通 file URL 直接 `/sbin/mount -F -t fuset` | extension 启动成功，但 security-scoped resource access `EACCES` | 不再用普通 file URL 直接调用作为正式路径 |
| 2026-08-26（分支建立前） | 使用最新版 libfuse `hello.c` 编译 FUSE-T 内置 headers | 示例 API 与 FUSE-T 内置 libfuse 3.19 不匹配 | 后续固定使用 3.19 对应示例/API |

---

## 提交记录

| Commit | 内容 | 远端状态 |
|---|---|---|
| 待提交 | 新测试分支 + 计划 + 实时 tracker | 待 push |
