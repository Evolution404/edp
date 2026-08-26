# EDP USB Vault — FUSE-T Minimal FSKit Bridge 实时进度追踪

日期：2026-08-26  
分支：`test/fuset-minimal-fskit-bridge`  
基线：`6c44c1d`  
配套计划：`docs/PLAN-2026-08-26-fuset-minimal-fskit-bridge.md`

## 当前总状态

**状态：Phase A/B 已完成；原生 Swift 最小 bridge 与 Phase D 核心已通过；Phase E 已完整通过；Phase F 的 F1/F2/F3 已由 GitHub Actions macOS 26 / Xcode 26 实测通过，F5 已有 HFS+ 明确证据并等待修正后的精确类型断言转绿，F4 Finder 自动化继续探测。**

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
- GitHub Actions `macos-26` runner 的 PluginKit 注册状态与 FSKit enabled-modules 状态彼此独立。CI 为了无交互复现，在**一次性 runner** 的 `~/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist` 中追加 `org.fuset.fskit-srv.module` 并刷新 FSKit 用户态缓存；这仅是 CI 测试夹具，**不得进入产品路径或绕过真实用户在系统设置中的启用/授权流程**。

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

结论：`file://...` URL 形式不可用；已验证的 direct path 是把 `session.json` **普通文件路径**传给 `/sbin/mount -o nobrowse,rdonly -t fuset`。

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
| C5 | ✅ | 实现 root getattr / lookup / statfs | `get_root_attributes`、`statfs`、ENOENT 均通过；`lookup("volume.raw")` 返回 `lookup_item` 后，macOS `stat` 正确显示 inode 2、regular file、0444、size 4096 |
| C6 | ✅ | 实现 open / read / close | 请求已确认：`open {node_id:2,open_modes:1}` → 返回 `handle_id`；`read {node_id:2,offset,length}` → 响应 metadata `ok=true` + **raw frame payload**；`close {node_id:2,keeping_modes:0}` → `ok=true`。先用 Python 黑盒验证，随后已固化为 `FuseTMinimalBridge.swift`，不依赖 libfuse/go-nfsv4 |
| C7 | 🟡 | 实现 directory enumeration | `open_directory/close_directory/enumerate_directory` 已进入 Swift bridge，并为每次 open 分配独立 handle；`ls` 已能显示 `volume.raw`，但结束时仍报 `fts_read: Input/output error`，需继续校准 EOF/cookie/verifier 语义；不阻塞直接访问 `/volume.raw` |
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

Phase C 验收：**核心只读单文件路径已通过。已在完全不启动 `go-nfsv4`/libfuse 的情况下完成 FSKit mount + `/volume.raw` lookup/open/read/close；剩余目录枚举、xattr、mutation fail-closed。**

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
| D1 | ✅ | 只暴露 `/volume.raw` | direct lookup 仅对 `parent_id=1,name=volume.raw` 返回 node 2；其他探测项返回 ENOENT |
| D2 | ✅ | 正确报告 fixed logical size | synthetic PoC 正确报告 4096 bytes；`stat` 显示 Size=4096 |
| D3 | ✅ | 任意 offset/length 随机读 | 原生 Swift bridge + 8193-byte fixture 实测 `(0,1)`、`(1,31)`、`(4095,4097)`、`(8192,64)` 全部逐字节一致；跨 4K 与尾部短读正确 |
| D4 | ✅ | offset<size 不返回错误 0-byte READ | `offset=8192,size=8193,length=64` 正确返回 1 byte；所有 offset<size case 均无人工 0-byte read |
| D5 | ✅ | EOF 仅 offset>=size | `offset=8193` 与 `offset=8293` 均返回 0 bytes；边界与超 EOF 均正确 |
| D6 | 🟡 | mutation 全部只读失败 | 外部实测覆盖写 `volume.raw`、`touch new-file`、`rm volume.raw` 均 Permission denied；Swift bridge 对已知 mutation RPC 返回 `EROFS`。仍需补齐所有 mutation 方法名的系统调用覆盖 |
| D7 | ✅ | fixture 全文件哈希一致 | 8193-byte fixture 经 FSKit 完整读取 SHA-256 `40aad4a3dcbc0f12bfe6231e34fff39eb14338284396b090b01e7eadf3b653ef`，与 backing 完全一致 |

Phase D 验收：**核心随机读/EOF/完整性通过；只读 mutation 覆盖和目录 EIO 继续收口，但不阻塞后续 block-image / Apple 文件系统链路。**

原生 PoC：`native/EDPFSKitPoC/Tools/FuseTMinimal/FuseTMinimalBridge.swift`

编译条件：Swift 6 `-warnings-as-errors` 通过；运行时仅依赖系统 Foundation/Darwin。实机进程树未出现 `go-nfsv4`，无 TCP listener。隐藏 mountpoint 已改用 `/private/tmp/...`，不再需要管理员授权。

---

## Phase E — `volume.raw` → `/dev/diskN`

| ID | 状态 | 任务 | 证据/结果 |
|---|---|---|---|
| E1 | ✅ | 创建小型 synthetic raw/dmg fixture | GitHub Actions `macos-26` 构造 deterministic 8 MiB raw（16384 × 512 B），SHA-256 `638f4947a865d315c06c6c16913be984ff08270b8da0e22a3fedb044891ff59d`；普通 raw 直接 `hdiutil attach -readonly -nomount -imagekey diskimage-class=CRawDiskImage` 基线通过 |
| E2 | ✅ | `hdiutil attach -readonly -nomount` 读取 hidden `volume.raw` | native Swift bridge 暴露 8 MiB `/volume.raw`；先对 LBA `0/7/4095/8192/16383` 做 raw backing ↔ hidden file 逐扇区 `cmp`，全部一致；随后 nested `hdiutil` 返回 `RC=0` |
| E3 | ✅ | 产生 `/dev/diskN` | GitHub Actions macOS 26.5.2 / Xcode 26.6 产生 `/dev/disk8`；`diskutil info` 显示 Whole=Yes、Protocol=Disk Image、Virtual=Yes、512-byte block、8388608 bytes、**Media Read-Only=Yes** |
| E4 | ✅ | 随机 LBA 读回一致 | 对 `/dev/rdisk8` 再读 LBA `0/7/4095/8192/16383`，逐扇区与原始 raw fixture `cmp` 全部一致；`RESULT=E4_RANDOM_LBA_MATCH` |
| E5 | ✅ | 确认 backing store 无实际写入 | `a62c23e` 触发的 macOS 26 CI 将 backing 设为 `0444`；attach 前后 SHA-256 均为 `638f4947a865d315c06c6c16913be984ff08270b8da0e22a3fedb044891ff59d`，`size:mtime:mode` 前后均为 `8388608:1787748310:100444`；输出 `RESULT=E5_BACKING_SHA_SIZE_MTIME_MODE_UNCHANGED` |
| E6 | ➖ | 必要时对照 DiskImages2 adapter | 公共 `hdiutil` 路径已成功产生只读 `/dev/disk8`，当前无须私有/现有 DiskImages2 adapter；仅在后续回归失败时作为对照 |

Phase E 验收：**通过。thin FUSE-T bridge → hidden `volume.raw` → Apple DiskImages/hdiutil → read-only `/dev/diskN` 已获得 GitHub Actions 端到端证据，且 backing SHA/size/mtime/mode 不变。**

CI 关键证据：`docs/diagnostics/fuset-enabled-e2e-macos26-ci.txt`。首次仅做 PluginKit 注册时 runner 报 `Module org.fuset.fskit-srv.module is disabled!`；确认 FSKit `enabledModules.plist` 是 bundle-id NSArray 后，在一次性 CI runner 中追加 FUSE-T module 并刷新 `fskit_agent/extensionkitservice/fskitd`，E2-E5 随即全绿。该 enabled-list 写入**只用于 CI 无交互夹具，不属于产品安装/授权方案**。

---

## Phase F — Apple 默认文件系统

| ID | 状态 | 任务 | 证据/结果 |
|---|---|---|---|
| F1 | ✅ | Disk Arbitration 自动识别 fixture | 64 MiB HFS+ raw fixture 经 hidden FUSE-T `volume.raw` 后，`hdiutil attach -readonly -imagekey diskimage-class=CRawDiskImage` 在**不传 filesystem type**的情况下自动产生 `/dev/disk8` 并挂载 `/Volumes/EDP_FUSET_FINAL`；sentinel 与嵌套文件均实际读回 |
| F2 | ✅ | EDP/backend 不传 filesystem type | `FuseTMinimalBridge.swift` 通过 CI 静态断言，不含 HFS+/APFS/exFAT/FAT/NTFS 类型知识；运行时 `hdiutil` 仅收到 raw image class，无 filesystem type hint；输出 `RESULT=F2_NO_FILESYSTEM_TYPE_HINT_AT_RUNTIME` |
| F3 | ✅ | 最终 mount 为 `MNT_RDONLY` | `diskutil info`：Media Read-Only=Yes、Volume Read-Only=Yes；mount line：`/dev/disk8 ... (hfs, ... read-only, ...)`；`touch SHOULD_NOT_WRITE` 返回 `Read-only file system` |
| F4 | 🟡 | Finder 可浏览 | POSIX `find` 已能遍历 sentinel 与嵌套文件；hosted runner 的 Finder AppleEvents 自动化正在独立探测，不能用 TCC/UI 自动化限制替代 Finder 实机验收 |
| F5 | 🟡 | Finder 最终卷不是 `fuset` 文件系统 | 已有直接证据：最终 `diskutil` 显示 `File System Personality: HFS+`、`Type (Bundle): hfs`，mount line 为 `(hfs, ...)`；上一轮 CI 的负匹配误把卷名 `EDP_FUSET_FINAL` 中的 `FUSET` 当成文件系统类型，已改为 `stat -f %T` + `diskutil` 精确类型断言，等待本轮转绿 |

Phase F 验收：**核心 F1/F2/F3 已通过；F5 仅剩 CI 精确断言转绿，F4 Finder GUI 枚举单独收口。**

CI 关键证据：`docs/diagnostics/fuset-applefs-macos26-ci.txt`。当前已重复证明用户可见最终卷是 Apple HFS+ 而非 hidden FUSE-T transport；FUSE-T 只承担隐藏的单文件 raw transport。

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
F5：让修正后的精确 filesystem-type 断言转绿，并完成 backing 不变式复核
↓
F4：继续 Finder AppleEvents 枚举；如 hosted runner 因 TCC/UI 会话不可用，则保留为本机 Finder 验收项，不误判底层文件系统失败
↓
G1-G3：接入离线 EDP/SM4 fixture，把 bridge 的 backing read 切换为 random-access decrypt reader，不生成完整 plaintext cache
↓
并行次优先级：修复 C7 directory enumeration 尾部 EIO，补齐 D6 mutation syscall matrix
```

## 失败实验登记

| 时间 | 实验 | 结果 | 避免重复 |
|---|---|---|---|
| 2026-08-26（分支建立前） | 普通 file URL 直接 `/sbin/mount -F -t fuset` | extension 启动成功，但 security-scoped resource access `EACCES` | 不再用 `file://...` URL；direct path 固定传普通 session 文件路径 |
| 2026-08-26（分支建立前） | 使用最新版 libfuse `hello.c` 编译 FUSE-T 内置 headers | 示例 API 与 FUSE-T 内置 libfuse 3.19 不匹配 | 后续固定使用 3.19 对应示例/API |
| 2026-08-26 | 直接 `/sbin/mount -t fuset file:///private/tmp/.../session.json` | `probeResource` EACCES | 根因是传了 `file://` URL；正式 direct path 必须传普通文件路径 |
| 2026-08-26 | 普通 session path + EDP-owned app-group Unix listener | FskitSrvModule 成功连接并发出 handshake；无需 go-nfsv4/libfuse | 证明 resource/mount 层可彻底移除 19 MB helper |
| 2026-08-26 | handshake 响应 `{request_id}` / `{request_id,ok}` / `{request_id,session_id}` | 均 rejected | 必须同时 `ok=true` + matching `session_id` |
| 2026-08-26 | handshake + ping + root_attrs + statfs + ENOENT lookup | **无 go-nfsv4 下 FSKit mount 成功** | 已继续突破单文件路径 |
| 2026-08-26 | `volume.raw` lookup/getattr | `stat` 正确看到 inode 2 / regular / 0444 / 4096 bytes | 文件 metadata 契约确认 |
| 2026-08-26 | open + read raw payload + close | `dd` 成功读 512 bytes；SHA-256 与预期完全一致 | 证明 read 数据可直接走 frame raw payload，无 Base64/JSON 膨胀 |
| 2026-08-26 | `FuseTMinimalBridge.swift` 原生化 | Swift 6 warnings-as-errors 编译通过；仅 Foundation/Darwin | 正式移除 PoC 对 Python/libfuse/go helper 的运行依赖 |
| 2026-08-26 | 8193-byte native bridge 边界矩阵 | 跨 4K、尾部短读、EOF/超 EOF 全部正确，完整 SHA 一致 | Phase D 核心通过 |
| 2026-08-26 | 原生 bridge 写/创建/删除测试 | 全部 Permission denied | mount + bridge 双层只读成立 |
| 2026-08-26 | 原生 bridge `ls` | 能列出 `volume.raw`，但结尾 `fts_read: Input/output error` | C7 保留未完成，不阻塞 direct path |
| 2026-08-26 | hidden mountpoint 改到 `/private/tmp/edp-fuset-hidden-mnt` | 正常 mount/read，不需要管理员授权 | 后续隐藏 transport 不再创建 `/Volumes` 测试目录 |
| 2026-08-26 | Actions runner 仅 `lsregister`/PluginKit 注册官方 FUSE-T app | PluginKit 显示 `+`，但 FSKit mount 报 `Module org.fuset.fskit-srv.module is disabled!` | PluginKit enable 与 FSKit enabledModules 是两层状态；不要再把 PluginKit `+` 当作 FSKit 已启用 |
| 2026-08-26 | Actions runner 将 FUSE-T bundle id 加入一次性 `enabledModules.plist` NSArray + 刷新 FSKit cache | native bridge mount 成功；hidden `volume.raw` → `hdiutil -readonly -nomount` → `/dev/disk8`；5 个随机/边界 LBA 与 raw backing 全一致，Media Read-Only=Yes | Phase E E2-E4 已突破；CI-only enablement 不得演变成产品授权绕过 |
| 2026-08-26 | Phase E backing 设为 0444 后重复 attach | SHA-256、size、mtime、mode 前后完全一致 | E5 已关闭，Phase E 正式通过 |
| 2026-08-26 | Phase F 首轮 `hdiutil create ... -format UDRW` | macOS 26 报 `-format requires -srcfolder or -srcdevice` | fixture 制作参数问题，不是 bridge/DiskImages 架构失败；已移除该参数 |
| 2026-08-26 | Phase F 第二轮 Apple filesystem E2E | F1/F2/F3 均实际通过；后续 Finder AppleScript 因脚本语法失败导致 job 红 | 将 Finder UI 自动化与核心磁盘链路分离；先编译 AppleScript 再执行 |
| 2026-08-26 | Phase F 第三轮 F5 负匹配 | 最终 mount 实际为 `(hfs, ... read-only)`，但卷名 `EDP_FUSET_FINAL` 包含 `FUSET`，`grep -i fuset` 误报 | 禁止对整条 mount line 做模糊负匹配；改用 `stat -f %T` + `diskutil Type (Bundle)` 精确判定 |

---

## 提交记录

| Commit | 内容 | 远端状态 |
|---|---|---|
| `2fe69cd` | 新测试分支 + 计划 + 实时 tracker | 已 push |
| `ac8c1b1` | Phase A：固化 FUSE-T 最小签名/运行时基线 | 已 push |
| `c44ca83` | Phase B：FUSE-T 3.19 官方 `backend=fskit` 参考路径跑通 | 已 push |
| `7ee9ca3` | Phase B/C：提取 direct mount + RPC framing/handshake/root/statfs 最小契约 | 已 push |
| `c8175ed` | Phase C/D：`volume.raw` lookup/open/raw-payload-read 数据一致性验证 | 已 push（rebase 后 commit id） |
| `d6154c1` | 原生 Swift minimal bridge + Phase D random/EOF/full-hash 实机验证 | 已 push |
| `48d5881` / `64da44b` / `7217a8e` | 固化 dependency-free RPC framing tests + macOS 26 FUSE-T 1.2.7 binary-contract CI，并修复诊断首次回写 | 已 push |
| `4c7b065` / `6f08cc2` | 固化 open/read/close/EROFS 边界契约并提取官方 binary JSON tags | 已 push |
| `ecfe418` / `f6c3644` | Phase E 初始 hdiutil CI：E1 raw baseline 通过，定位 hosted runner FSKit module disabled 边界并保存诊断 | 已 push |
| `496c322` / `f80a0b1` | CI-only enabledModules array + cache refresh；E2-E4 thin bridge → `/dev/disk8` 端到端通过并保存诊断 | 已 push |
| `a62c23e` / `c99fd59` | E5：backing 0444 + SHA/size/mtime/mode 前后不变；保存 Actions 证据 | 已 push |
| `35a58cd` / `13b8dc0` | Phase F 初始 Apple filesystem E2E；定位 macOS 26 fixture create 参数问题 | 已 push |
| `ddeef7c` / `a27cb7d` | 修复 HFS+ raw fixture；F1/F2/F3 首次端到端通过并保存诊断 | 已 push |
| `5232630` / `f0a9210` | 分离 Finder probe；复现 F1/F2/F3，并定位 F5 卷名误匹配测试 bug | 已 push |
| `86a28ac` | F5 改为精确解析实际 filesystem type，触发第 4 轮 macOS 26 Actions | 已 push / CI 运行中 |
