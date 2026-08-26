# EDP USB Vault — FUSE-T Minimal FSKit Bridge 实时进度追踪

日期：2026-08-26  
分支：`test/fuset-minimal-fskit-bridge`  
基线：`6c44c1d`  
配套计划：`docs/PLAN-2026-08-26-fuset-minimal-fskit-bridge.md`

## 当前总状态

**状态：Phase A 已完成；Phase B 最小 resource 契约已提取；Phase C 已跑通 handshake/root/statfs/ENOENT，正在补目录与单文件 read**

当前实验目标：验证是否能只依赖 FUSE-T 1.2.7 官方签名的 1.7 MB `fuse-t.app`，由 EDP 自己实现 Unix Domain Socket backend，避免安装 FUSE-T 完整 core、`go-nfsv4`、macFUSE 和 NTFS-3G。

当前系统实验状态（建立 tracker 时）：

- `/Applications/fuse-t.app`：已安装，仅 FSKit app bundle，约 1.7 MB。
- `org.fuset.fskit-srv.module`：已在系统设置中启用。
- `/Library/Application Support/fuse-t`：未安装。
- `/usr/local/bin/go-nfsv4`：未安装。
- `/usr/local/lib/libfuse3.dylib`：未安装。
- macFUSE：此前实验已清理；本分支后续必须重新做无残留确认。
- FUSE-T core 仅允许从 `/private/tmp` 临时解包用于协议抓取，不做系统安装。
- 当前分支已按用户要求直接位于 `/Users/zhangyuxi/Desktop/edp-usb-vault`；不再使用 worktree。原 `feat/filesystem-agnostic-native-readonly` 未提交 tracker 已保存在 `stash@{0}`。

---

## Phase A — 干净运行时与签名基线

| ID | 状态 | 任务 | 证据/结果 |
|---|---|---|---|
| A0 | ✅ | 建立干净实验基线 | 最初以 worktree 从 `6c44c1d` 建分支；随后按用户要求删除 worktree，并在桌面实际 checkout 直接切到 `test/fuset-minimal-fskit-bridge` |
| A1 | ✅ | 创建测试分支 | `test/fuset-minimal-fskit-bridge` |
| A2 | ✅ | 编写实验计划 | `docs/PLAN-2026-08-26-fuset-minimal-fskit-bridge.md` |
| A3 | ✅ | 创建实时 tracker | 本文件 |
| A4 | ✅ | 固化 FUSE-T 1.2.7 host/appex SHA-256、体积、版本 | host 1.7 MB、appex 400 KB；二者 `CFBundleShortVersionString=0.1.3`；host executable SHA-256 `fc64ae9c17efc70540db07f256ecd75af1ff174a9fb83611bb6ffdb1cba8f2c5`；appex executable SHA-256 `199ba1246d36db18ebf45c60abd3d68ca4b4ad9d8080d55aa8e856f574772086` |
| A5 | ✅ | 固化 codesign / Team / hardened runtime | host `org.fuset.fskit-srv`，appex `org.fuset.fskit-srv.module`；`Developer ID Application: alex fishman (6DY7Z4SVDZ)`；Team `6DY7Z4SVDZ`；Runtime 26.4.0；Gatekeeper `accepted / Notarized Developer ID` |
| A6 | ✅ | 固化 host/appex provisioning profile | appex profile `Mac Team Direct Provisioning Profile: org.fuset.fskit-srv.module`，Team `6DY7Z4SVDZ`，expires 2044-03-25 |
| A7 | ✅ | 确认 `ProvisionsAllDevices=true` + FSKit entitlement | profile `ProvisionsAllDevices=true`；entitlement `com.apple.developer.fskit.fsmodule=true` |
| A8 | ✅ | 确认无 FUSE-T core / go-nfsv4 / global libfuse3 | `/Library/Application Support/fuse-t`、`/usr/local/bin/go-nfsv4`、`/usr/local/lib/libfuse3.dylib` 均不存在 |
| A9 | ✅ | 确认无 macFUSE runtime/helper/KEXT | `/Library/Filesystems/macfuse.fs`、launch daemon、privileged helper 均不存在；`kmutil showloaded` 无 macFUSE/FUSE-T KEXT |
| A10 | ✅ | 确认 PlugInKit 第三方实验模块状态 | 仅 `org.fuset.fskit-srv.module` 作为当前第三方实验 FSKit module；前序探测遗留 `FskitSrvModule` 进程和 `/private/tmp/fuset-edp*` 已清理 |

Phase A 验收：**通过**。当前系统为：只保留官方签名 `/Applications/fuse-t.app`，不安装 FUSE-T core，不存在 macFUSE runtime/KEXT。

---

## Phase B — 官方 FSKit resource 创建路径

| ID | 状态 | 任务 | 证据/结果 |
|---|---|---|---|
| B1 | ✅ | 获取与 FUSE-T 内置 libfuse 3.19 匹配的最小 hello 示例 | 新增 `native/EDPFSKitPoC/Tools/FuseTHello319.c`，`FUSE_USE_VERSION=319`；使用 FUSE-T 1.2.7 自带 headers/lib 编译成功；运行时报告 `FUSE library version: 3.19.0-rc0` |
| B2 | ✅ | 仅从 `/private/tmp` 加载 libfuse3，运行 `backend=fskit` | 不向系统安装 core；`DYLD_LIBRARY_PATH` 指向解包后的临时 `libfuse3.4.dylib`；将 helper 通过 `FUSE_NFSSRV_PATH`/`_FUSE_DAEMON_PATH` 指向 `/private/tmp/.../go-nfsv4-1.2.7` 后，FSKit mount 成功 |
| B3 | ✅ | 捕获官方 session directory / `session.json` | `/private/tmp/fuset-session-3466332312/session.json`；字段确认：`session_id`、`socket_path`、`auth_token`、`namedattr`、`readonly`；socket 位于 `~/Library/Group Containers/group.org.fuset.fskit-srv/s/*.sock` |
| B4 | ✅ | 捕获 security-scoped FSPathURLResource 创建方式 | 反汇编 `go-nfsv4` 的 `mountArgs/runMountCommand` 并实机复现：调用 `/sbin/mount -o nobrowse,rdonly -t fuset <session.json普通文件路径> <mountpoint>` 即可。**不需要私有 security-scoped API**；此前 EACCES 的根因是错误传入 `file://...` URL 而不是普通 path。FskitSrvModule 会由系统收到可访问的 `FSPathURLResource` |
| B5 | ✅ | 确认 `go-nfsv4` 在 FSKit backend 是否启动 | **会启动**：`go-nfsv4-1.2.7 -r --backend fskit <mountpoint>`；但 `lsof` 确认无 TCP listener，仅 Unix domain sockets。因此 FSKit backend 本身不是网络卷 |
| B6 | ✅ | 记录 probe/load/mount 完整日志 | `probeResource → session init → usable result → loadResource → session ready → rpc connected → rpc handshake accepted → volume init → activate → mount`；`hello.txt` 实际读取成功，mount 显示 `fuse-t, local, ... fskit` |
| B7 | ✅ | 提取不依赖 libfuse/go-nfsv4 的最小 resource 契约 | 已实机证明直接创建 `session.json` + app-group Unix socket，再调用 `/sbin/mount -o nobrowse,rdonly -t fuset <plain path> <mountpoint>`，FskitSrvModule 可直接连接 EDP-owned listener；无需 libfuse/go-nfsv4 参与 resource/mount 阶段 |

已知失败样本（分支建立前）：

```text
/sbin/mount -F -t fuset file:///private/tmp/.../session.json ...
→ FskitSrvModule 成功启动
→ probeResource failed to access security-scoped resource
→ EACCES
```

结论：直接传普通 file URL 不够，必须复现官方 security-scoped resource 路径。

Phase B 验收：**通过。官方参考路径和不依赖 libfuse/go-nfsv4 的最小 resource 契约均已复现。**

已确认官方参考链：

```text
FuseTHello319
→ temporary libfuse3.4.dylib
→ go-nfsv4-1.2.7 --backend fskit
→ session.json + Unix domain socket
→ security-scoped FSPathURLResource
→ signed FskitSrvModule.appex
→ Apple FSKit
→ /Volumes/EDP-FUSET-Hello
```

实际读回：`EDP FUSE-T FSKit bridge smoke`。

---

## Phase C — Unix Domain Socket RPC 最小化

| ID | 状态 | 任务 | 证据/结果 |
|---|---|---|---|
| C1 | ✅ | 捕获首个 Unix socket handshake frame | 首帧：8-byte header `uint32_be metadata_len + uint32_be payload_len`；请求 `{"request_id":1,"method":"handshake","auth_token":"..."}` |
| C2 | ✅ | 解析 framing / request_id / payload | `readFskitRPCFrame/writeFskitRPCFrame` 反汇编与实测一致：8-byte BE 长度头 + JSON metadata + raw payload；metadata/payload/总长均受约 16 MiB 上限约束 |
| C3 | ✅ | 确认 `auth_token` 校验 | handshake 请求携带 `session.json` 中的 `auth_token`；响应若缺 `ok=true` 或缺匹配的 `session_id` 均被 extension 拒绝 |
| C4 | ✅ | 实现 ping/handshake | 可接受 handshake 响应必须为 `{"request_id":N,"ok":true,"session_id":"<匹配session_id>"}`；随后收到 `ping`，`{"request_id":N,"ok":true}` 可通过 |
| C5 | 🟡 | 实现 root getattr / lookup / statfs | `get_root_attributes` 与 `statfs` 已通过并让纯 EDP-owned listener 成功完成 FSKit mount；`lookup` 的 ENOENT `{"ok":false,"errno":2,...}` 已验证；下一步补 `volume.raw` 成功 lookup |
| C6 | ⏳ | 实现 open / read / close | 待执行 |
| C7 | 🟡 | 实现 directory enumeration | 已捕获下一请求 `open_directory`；尚需实现 handle/enumerate/close |
| C8 | ⏳ | 实现必须的 xattr 查询 | 待执行 |
| C9 | ⏳ | 所有 mutation 返回只读错误 | 待执行 |
| C10 | ✅ | 验证无 TCP listener | 官方 `backend=fskit` 与 EDP-owned direct listener 实验均无 TCP listener；仅使用 `~/Library/Group Containers/group.org.fuset.fskit-srv/s/*.sock` Unix socket |

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

Phase C 验收：**部分通过。已在完全不启动 `go-nfsv4`/libfuse 的情况下完成 FSKit mount；剩余目录、单文件 read/xattr/只读 mutation。**

当前最小已验证调用链：

```text
EDP-owned Unix listener
+ session.json
+ /sbin/mount -o nobrowse,rdonly -t fuset <plain-session-path> <mountpoint>
→ signed FskitSrvModule.appex
→ handshake
→ ping
→ get_root_attributes
→ statfs
→ lookup/ENOENT
→ macOS mount 成功显示 (fuse-t, local, ... fskit)
```

握手响应的四组对照中，仅同时包含 `ok=true` 和匹配 `session_id` 的响应被接受；这已排除偶然成功。

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
C7 实现 `open_directory/enumerate_directory/close_directory`
↓
C5/C6 实现 `/volume.raw` lookup/open/read/close
↓
D1-D7 用固定 synthetic `volume.raw` 验证随机读和完整哈希
```

## 失败实验登记

| 时间 | 实验 | 结果 | 避免重复 |
|---|---|---|---|
| 2026-08-26（分支建立前） | 普通 file URL 直接 `/sbin/mount -F -t fuset` | extension 启动成功，但 security-scoped resource access `EACCES` | 不再用普通 file URL 直接调用作为正式路径 |
| 2026-08-26（分支建立前） | 使用最新版 libfuse `hello.c` 编译 FUSE-T 内置 headers | 示例 API 与 FUSE-T 内置 libfuse 3.19 不匹配 | 后续固定使用 3.19 对应示例/API |
| 2026-08-26 | 直接 `/sbin/mount -t fuset file:///private/tmp/.../session.json` | `probeResource` EACCES | 根因是传了 `file://` URL；正式 direct path 必须传普通文件路径 |
| 2026-08-26 | 普通 session path + EDP-owned app-group Unix listener | FskitSrvModule 成功连接并发出 handshake；无需 go-nfsv4/libfuse | 证明 resource/mount 层可彻底移除 19 MB helper |
| 2026-08-26 | handshake 响应 `{request_id}` / `{request_id,ok}` / `{request_id,session_id}` | 均 rejected | 必须同时 `ok=true` + matching `session_id` |
| 2026-08-26 | handshake + ping + root_attrs + statfs + ENOENT lookup | **无 go-nfsv4 下 FSKit mount 成功** | 下一阻塞为 `open_directory` |

---

## 提交记录

| Commit | 内容 | 远端状态 |
|---|---|---|
| `2fe69cd` | 新测试分支 + 计划 + 实时 tracker | 已 push |
| `ac8c1b1` | Phase A：固化 FUSE-T 最小签名/运行时基线 | 已 push |
| `c44ca83` | Phase B：FUSE-T 3.19 官方 `backend=fskit` 参考路径跑通 | 已 push |
| 待提交 | Phase B/C：提取 direct mount + RPC framing/handshake/root/statfs 最小契约 | 待 push |
