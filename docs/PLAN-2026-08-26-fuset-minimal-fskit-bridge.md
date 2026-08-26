# EDP USB Vault — FUSE-T Minimal FSKit Bridge 实验计划

日期：2026-08-26  
实验分支：`test/fuset-minimal-fskit-bridge`  
基线：`6c44c1d`（`feat/filesystem-agnostic-native-readonly`）  
目标平台：macOS 26+  
性质：**隔离 PoC / 架构验证，不代表产品正式采用 FUSE-T**

## 0. 实验目标

验证是否可以仅复用 FUSE-T 官方已签名、已 notarize 的极薄 FSKit bridge，而不安装其完整 core runtime，把 EDP 解密后的随机访问数据以只读方式交给 macOS FSKit，再让 Apple 默认文件系统栈完成最终挂载。

目标最小链：

```text
physical EDP USB
    ↓ O_RDONLY
authopen / raw authorization
    ↓
EDP metadata + password/key + SM4 random-access decrypt
    ↓
EDP minimal backend
    ↓ Unix Domain Socket RPC
FUSE-T signed FskitSrvModule.appex
    ↓ Apple FSKit
hidden read-only volume exposing /volume.raw
    ↓
hdiutil / DiskImages2 --readonly
    ↓
/dev/diskN
    ↓
Disk Arbitration
    ↓
macOS default filesystem support
    ↓
Finder read-only
```

成功标准不是“FUSE-T 能挂一个普通 FUSE 文件系统”，而是：

1. 不安装 `go-nfsv4`。
2. 不安装 FUSE-T 完整 core runtime。
3. 不使用 TCP、HTTP、NFS、SMB 作为 EDP 数据路径。
4. EDP 产品代码不识别 NTFS / ExFAT / APFS / HFS+。
5. 最终 Finder 看到的是 Apple 文件系统挂载出的本地卷，而不是 FUSE-T 卷。
6. 真实 EDP 介质始终只读。

---

## 1. 已知实验基础

本计划建立前已在本机确认：

- FUSE-T 1.2.7 官方 PKG 使用 Developer ID Installer 签名并通过 Apple notarization。
- `/Applications/fuse-t.app` 约 1.7 MB。
- `FskitSrvModule.appex` 约 400 KB。
- 只有一个 FSKit module：`org.fuset.fskit-srv.module`。
- extension entitlement 包含 `com.apple.developer.fskit.fsmodule = true`。
- embedded provisioning profile 为 `ProvisionsAllDevices = true`，有效期至 2044。
- 在未安装 `/Library/Application Support/fuse-t`、`libfuse3`、`go-nfsv4` 的情况下，FSKit extension 已能被 `fskit_agent` 拉起。
- 二进制可见 session descriptor 字段：`session_id`、`socket_path`、`auth_token`、`namedattr`、`readonly`、`volume_name`。
- FSKit backend 通过 Unix Domain Socket RPC 与用户态 backend 通信。
- 直接 `/sbin/mount -F -t fuset file:///.../session.json` 会因为缺少 security-scoped FSPathURLResource 在 probe 阶段返回 `EACCES`。

这些结论只作为实验起点，正式分支中的关键结论必须重新留下可复现证据。

---

## 2. 不可突破的实验约束

1. **不得关闭 SIP。**
2. **不得关闭或弱化 AMFI。**
3. **不得进入 Recovery 降低系统安全策略。**
4. **不得加载 macFUSE KEXT 或任何第三方 KEXT。**
5. **不得向真实 EDP USB 写入任何数据。**
6. 真实设备只允许 `O_RDONLY | O_CLOEXEC`。
7. 不得把 HTTP/TCP/NFS/SMB 作为拟议产品数据路径。
8. FUSE-T 只允许使用其公开发行、原始签名未修改的二进制。
9. 不得修改 `fuse-t.app` / appex 后继续依赖其原 Developer ID 签名。
10. 不得假定 FUSE-T 允许商业捆绑；许可结论必须独立验证。
11. 所有临时 mount、socket、session descriptor 使用唯一测试路径，并在测试后清理。
12. 在完成 synthetic fixture 测试之前，不接真实 EDP 介质。
13. 不把实验性私有协议直接合入正式产品路径；先完成协议稳定性和许可评估。

---

## 3. 分阶段执行计划

### Phase A — 干净运行时与签名基线

目标：确认实验只依赖 1.7 MB 官方 FUSE-T FSKit App。

执行：

- 记录 `fuse-t.app`、appex 精确版本、SHA-256、体积。
- 记录 `codesign` authority、Team ID、hardened runtime。
- 解码 host / appex provisioning profile。
- 验证 `ProvisionsAllDevices = true`。
- 验证 FSKit entitlement。
- 验证系统不存在 FUSE-T core、`go-nfsv4`、全局 `libfuse3`。
- 验证不存在 macFUSE runtime / helper / KEXT。
- 验证 PlugInKit 中只有 FUSE-T 一个第三方实验 FSKit module。

验收：签名、profile、模块注册、最小运行时状态都有可重复命令和日志。

### Phase B — 复现官方 FSKit resource 创建路径

目标：解决当前 `FSPathURLResource` security-scoped access 失败。

执行：

- 使用与 FUSE-T 1.2.7 对应的 libfuse 3.19 示例运行 `backend=fskit`。
- FUSE-T core 仅从 `/private/tmp` 临时加载，不安装到系统。
- 抓取 session directory / session.json。
- 抓取 mount / FSKit API 调用参数。
- 验证是否生成 bookmark / security-scoped resource。
- 确认 `go-nfsv4` 在 `backend=fskit` 下是否被启动。
- 如果 libfuse 路径只是负责创建 descriptor/resource，则提取最小调用契约。

验收：在没有系统安装 FUSE-T core 的前提下，官方 FSKit module 能通过 probe/load 并连接 backend。

### Phase C — Unix Domain Socket RPC 协议最小化

目标：不依赖 FUSE-T libfuse/core，自行实现只读最小 backend。

执行：

- 抓取 handshake frame 格式。
- 确认 framing：长度、JSON/header、binary payload、request_id。
- 记录认证字段 `auth_token` 的校验逻辑。
- 实现 synthetic backend，仅支持：
  - ping / handshake
  - volume statistics
  - root getattr
  - lookup
  - open / close
  - read
  - directory enumeration
  - 必需的 xattr 查询
- 所有 mutation RPC 明确返回只读错误。
- 验证无 TCP listener。

验收：只用 `fuse-t.app` + 我们自己的临时 backend，即可挂载一个最小只读 synthetic filesystem。

### Phase D — 单文件 `volume.raw` bridge

目标：将 synthetic filesystem 收敛为隐藏单文件 transport。

目录模型固定为：

```text
/
└── volume.raw
```

执行：

- `volume.raw` 报告固定逻辑大小。
- 支持任意合法 `pread(offset, length)`。
- `offset < size` 时不得错误返回 0-byte READ。
- EOF 只允许在 `offset >= size`。
- write / truncate / rename / unlink / mkdir / xattr mutation 全部只读失败。
- 对 DiskImages2 可能使用的 open flags 做兼容；允许“打开语义”不等于允许实际写入。

验收：普通进程可以随机读取整个 synthetic raw image，哈希与 backing fixture 一致。

### Phase E — `volume.raw` → 系统块设备

目标：证明 Apple 磁盘映像栈能直接随机读取隐藏 FUSE-T `volume.raw`。

执行：

- 使用小型 synthetic raw/dmg fixture。
- 首选公开 `/usr/bin/hdiutil attach -readonly -nomount`。
- 必要时仅做对照测试现有 DiskImages2 adapter。
- 验证产生 `/dev/diskN`。
- 对随机 LBA 做读回比对。
- 验证 bridge 层没有实际写请求落到 backing store。

验收：无需完整物化 raw image，系统获得只读 `/dev/diskN`。

### Phase F — Apple 默认文件系统挂载

目标：证明 EDP/FUSE-T bridge 不识别内部文件系统。

执行：

- synthetic fixture 至少覆盖一个 Apple 原生可挂载格式。
- 让 Disk Arbitration 自动识别并挂载。
- EDP backend 不传 filesystem type。
- 最终 mount 强制验证 `MNT_RDONLY`。
- Finder 中确认卷为系统默认文件系统驱动提供，而非 `fuset`。

若使用 NTFS fixture，仅用于确认 Apple `ntfs.fs` 默认只读行为；产品逻辑不得包含 NTFS 分支。

验收：Finder 可浏览最终卷，隐藏 FUSE-T transport 不暴露给用户。

### Phase G — 接入 EDP random-access decrypt

前置条件：A-F 全绿。

目标：把 `volume.raw` backing 从普通 fixture 换成现有 EDP SM4 随机访问 reader。

执行：

- physical device 只读授权。
- metadata / password / key derivation 沿用现有 EDP core。
- `read(offset,length)` 映射到 encrypted partition reader。
- 不生成完整 plaintext cache。
- 先用离线加密 fixture，再用真实 EDP USB。
- 真实盘测试前记录设备 BSD path、只读 fd flags；测试后确认介质未发生写入。

验收：真实 EDP 内容经随机解密 → hidden `volume.raw` → `/dev/diskN` → Apple 默认文件系统 → Finder，只读浏览成功。

### Phase H — 性能、稳定性、许可与产品决策

执行：

- benchmark 4 KiB / 64 KiB / 1 MiB random read。
- benchmark sequential 256 MiB read。
- 测量 CPU / memory / context switches。
- Finder 多文件浏览、大文件读取、Quick Look。
- sleep/wake、拔盘、异常 backend exit、forced unmount。
- 检查 socket/session 文件是否泄漏。
- 检查 FUSE-T 1.2.7 binary distribution license。
- 明确非商业免费与商业 bundling 条款。
- 检查是否允许 EDP 自动下载安装、随包分发或要求用户独立安装。
- 与 macFUSE Minimal Runtime 对比：体积、helper、开关数量、许可证、维护风险。

最终输出只能是以下之一：

```text
A. 推荐 FUSE-T thin bridge
B. 技术可行但许可不适合产品捆绑
C. 技术协议不稳定，退回 macFUSE MFMount
D. 两者均不适合，恢复完整物化 raw image 方案
```

---

## 4. 测试产物原则

PoC 代码优先放在：

```text
native/EDPFSKitPoC/Tools/FuseTMinimal/
```

不得混入正式 daemon / GUI 生产路径，直到 Phase H 做出正式架构决策。

临时运行产物统一使用：

```text
/private/tmp/edp-fuset-*
/Volumes/EDP-FUSET-*
```

不得把下载的第三方已签名二进制提交进 Git 仓库。

---

## 5. 提交与实时追踪规则

实时执行情况记录在：

`docs/PROGRESS-TRACKER-FUSET-MINIMAL-FSKIT-2026-08-26.md`

规则：

1. 每完成一个可独立验证的小节点，立即更新 tracker。
2. tracker 必须记录命令级证据摘要、结果和下一阻塞点。
3. 每个 Phase 至少一个独立 commit。
4. commit 后立即 push 到 `origin/test/fuset-minimal-fskit-bridge`。
5. 失败实验也必须记录，避免后续 AI 重复踩坑。
6. 若系统状态改变（安装/注册/启用/清理），tracker 必须记录当前状态和清理方法。
7. 不修改其他分支未提交的 tracker 或工作树。

---

## 6. 当前优先级

立即执行顺序：

```text
A1 签名/运行时基线固化
→ B1 libfuse 3.19 官方 backend=fskit smoke
→ B2 捕获 security-scoped resource 创建方式
→ B3 确认 go-nfsv4 是否完全不参与
→ C1 捕获 Unix socket handshake
→ C2 最小自有 backend
→ D 单文件 volume.raw
→ E hdiutil / DiskImages2
→ F Apple 默认文件系统
→ G EDP SM4 random-access
→ H 性能与许可决策
```

除非前一阶段已经留下可复现证据，否则不得跳阶段直接接真实 EDP USB。
