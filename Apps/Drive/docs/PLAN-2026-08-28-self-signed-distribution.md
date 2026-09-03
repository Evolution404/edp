# EDP USB Vault 零 Apple 年费分发验证计划（2026-08-28）

> **HISTORICAL — distribution experiment evidence only.** Current Drive product architecture and release authority: `STATUS.md`, `ARCHITECTURE.md`, `TESTING.md`, `RELEASE-CHECKLIST.md`.

分支：`test/self-signed-standalone-distribution`

> 2026-08-29 更新：本文 E/F 阶段中的 `authopen + sys.openfile.* + AuthorizationExternalForm` raw-device 模型已被实机否定并废弃。当前正式权限模型改为稳定签名的 Full Disk Access Raw Access helper，详见 `docs/PLAN-2026-08-29-fda-raw-access.md`。本文保留为 self-signed 分发和历史实验记录，不再作为 raw 权限实现规范。

## 目标

满足两个硬条件：

1. 构建与发布不依赖付费 Apple Developer Program、Developer ID 或 notarization；
2. 其他 macOS 26+ 用户可以安装并正常使用，允许用户在“系统设置 → 隐私与安全性 → 仍要打开”中显式放行。

## 选型

优先验证 **稳定自签 Code Signing certificate + installer-managed legacy LaunchDaemon + 现有 privileged Mach XPC**。

不把 ad-hoc 签名作为正式方案：本机已实测 ad-hoc App 可以启动、legacy root daemon 可以启动，但 `com.edp.usbvault.xpc` Mach service 激活失败，日志为 `Operation not permitted`。同时 `EDPXPCPeerValidator` 也明确拒绝无 TeamIdentifier、无 leaf certificate 的 ad-hoc peer。

暂不采用 Unix domain socket 替换 XPC。2026-08-28 已做过独立原型，证明可以工作，但自签 leaf 已实测可以直接保留现有 Mach XPC 安全模型，因此 Unix socket 会引入没有必要的新 IPC 面和维护成本。

## 验收阶段

### A. 自签 leaf 能否替代 Apple Development 身份

状态：✅ 已通过

- 使用 OpenSSL 生成临时 self-signed code-signing certificate；
- App 与 daemon 使用同一 leaf 签名；
- `TeamIdentifier=not set`；
- `Authority=EDP USB Vault Test Signing`；
- `EDPServiceMode=legacy`；
- `/Library/LaunchDaemons/com.edp.usbvault.mountd.plist` 正常启动 root daemon；
- App `--xpc-smoke` 返回 `RESULT=PRIVILEGED_XPC_ROUNDTRIP_OK`。

### B. 最终用户是否需要安装/信任发布证书

状态：✅ 已通过

- 构建后删除本机临时 signing keychain、certificate、private key 与 P12；
- `security find-certificate` 已找不到该 signer；
- 重启 legacy daemon 后，App → privileged XPC roundtrip 仍通过；
- 说明最终用户无需安装发布证书或私钥，签名中的 leaf 足以维持 App/daemon exact-leaf identity boundary。

### C. Gatekeeper 行为

状态：✅ 行为符合预期

- 给 self-signed/unsigned outer pkg 模拟互联网 quarantine 后，`spctl -a -t install` 返回 `rejected / source=no usable signature`；
- 这是预期行为，不要求关闭 Gatekeeper；
- Apple 官方支持用户对未公证/身份不明的软件在“系统设置 → 隐私与安全性 → 仍要打开”中创建单项例外。

### D. 一键安装包构建策略

状态：🟡 实现中

新增 `EDP_SELF_SIGNED_DISTRIBUTION=1` 构建策略：

- 强制 legacy LaunchDaemon；
- 禁止 ad-hoc `-` 作为发行 signer；
- 要求 certificate-backed signature；
- 要求 `TeamIdentifier=not set`，确保不依赖 Apple Team；
- 保留现有 exact-leaf XPC peer validation；
- clean installer 继续嵌入 pinned macFUSE 与 NTFS runtime。

### E. 真实物理 EDP U 盘 raw authorization

状态：⏳ 最终阻断项，尚未执行

必须在本分支 self-signed legacy 包上实测：

1. 插入真实 EDP U 盘；
2. App 前台申请 exact-path `sys.openfile.readwrite./dev/rdiskN`；
3. `AuthorizationExternalForm` 经 XPC 传给 root daemon；
4. helper 降到 console uid + operator gid 后 `authopen -extauth O_RDWR` 成功；
5. snapshot 显示当前设备 `privilegedAccessReady=true`。

历史文档中“legacy 不能 physical raw USB”的结论来自前期未使用当前 console-user authopen 链的版本，因此必须重新实测，不能直接假定已解决。

### F. 真实挂载生命周期

状态：⏳ 等待 E

通过真实 U 盘验证：

`self-signed App → legacy XPC → FDA daemon retained raw fd → Direct MFMount macFUSE Local → volume.raw → DiskImages2 → Apple filesystem → Finder → unmount → remount`

至少验证交换区；不对真实介质执行格式化、分区或擦除。

### G. 合并门槛

只有同时满足以下条件才合并回主线：

- self-signed build gate 全部通过；
- GitHub Actions production/clean installer/XPC contract 全绿；
- 真机 physical raw authorization 通过；
- 真机交换区 mount/unmount/remount 通过；
- 不要求 Apple Development/Developer ID/TeamIdentifier；
- 最终用户不需要安装发布证书；
- 不关闭 SIP、不关闭 Gatekeeper，只允许用户对 EDP 安装包/App 做“仍要打开”单项例外。
