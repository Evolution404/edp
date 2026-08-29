# EDP USB Vault Full Disk Access Raw-Device 权限模型（2026-08-29）

分支：`test/self-signed-standalone-distribution`

## 目标

将产品 raw USB 权限模型从按 `/dev/rdiskN` 的短时 Authorization Services 授权，迁移到一次性 Full Disk Access（FDA）授权：

- 首次安装/首次配置时，用户为稳定签名的 `EDP USB Vault 磁盘访问` helper 开启一次“完全磁盘访问”；
- App 重启、daemon 重启、U 盘反复插拔以及 `diskN` 变化不再要求管理员密码/Touch ID；
- 不修改 AuthorizationDB，不持久化管理员凭据，不预授权一组 `/dev/rdiskN` 路径；
- raw broker 只能为已经校验的 EDP whole USB disk 提供 fd，不能成为任意 raw-device opener。

## 为什么废弃 `authopen + sys.openfile.*`

macOS 26 实机确认 `sys.openfile.` 默认 AuthorizationDB 规则包含：

```text
group = admin
timeout = 300
shared = false
authenticate-user = true
```

即使复用同一个 `AuthorizationRef`，超过 300 秒后对新的 `/dev/rdiskN` 使用 `authopen -extauth` 仍会重新要求用户认证。`authopen` 也不支持 `/dev/rdisk*` 这类 prefix/wildcard right，因此它不满足长期拔插和 `diskN` 漂移需求。

旧 `sys.openfile.readwrite./dev/rdiskN` / `AuthorizationExternalForm` 方案保留在历史诊断源码和历史文档中，仅作为实验记录，不再属于生产运行时。

## 已完成的 macOS 26 实机 PoC

### 1. 无 FDA 的 root 进程

独立 probe 以 root 身份直接执行：

```text
open(/dev/rdiskN, O_RDWR)
```

结果：

```text
EUID=0
DIRECT_RAW_OPEN=FAIL errno=1 Operation not permitted
```

证明阻塞不是普通 UNIX uid/gid 权限。

### 2. 为稳定 App 身份开启 FDA

将独立 `EDP FDA Probe.app` 加入：

`系统设置 → 隐私与安全性 → 完全磁盘访问`

之后同一 root probe：

```text
EUID=0
DIRECT_RAW_OPEN=OK char_device=yes no_read=yes no_write=yes
```

PoC 只做 `open → fstat → close`，没有读取或写入数据。

### 3. 跨进程、跨拔插、跨 diskN

验证顺序：

```text
/dev/rdisk6 成功
→ probe 退出
→ U 盘拔出
→ 使用临时磁盘镜像占用 disk4~disk7
→ U 盘重新插入成为 /dev/rdisk8
→ 新 probe 进程直接 O_RDWR open 成功
```

TCC 日志将访问主体识别为 probe 自身的 bundle identity，没有落回 `sys.openfile.readwrite./dev/rdisk8`。

### 4. system LaunchDaemon

临时 system LaunchDaemon 直接启动已获得 FDA 的 probe：

```text
EUID=0 PATH=/dev/rdisk8
DIRECT_RAW_OPEN=OK char_device=yes no_read=yes no_write=yes
last exit code = 0
```

说明最终产品可以采用“root daemon 启动稳定 FDA helper”的结构。

## 正式产品架构

```text
EDP USB 插入
    ↓
Disk Arbitration / IOKit
    ↓
只枚举 whole USB media
    ↓
console uid + operator group
edp-raw-metadata O_RDONLY
    ↓
只读 LBA 4 / 7 / 11 / 12
    ↓
识别 EDP metadata / stable device identity
    ↓
root daemon 请求 Raw Access helper
    ↓
/Applications/EDP USB Vault Raw Access.app
bundle id = com.edp.usbvault.rawaccess
    ↓
helper 再次验证：
  /dev/rdiskN whole path
  IOMedia Whole=true
  USB ancestor idVendor/idProduct
  open 前后 device node st_rdev 一致
  fd 是字符设备
  LBA4 serial marker
  LBA7 EDPF + type 1/2/4 layout
    ↓
O_RDWR fd
    ↓
固定继承为 fd 3
    ↓
helper 降权到 console uid/gid
    ↓
只允许启动 root-owned、不可由普通用户修改的 EDP transport
    ↓
EDP encrypted block transport
```

## 安全边界

生产 broker 必须同时满足：

1. 进程启动时 `geteuid() == 0`；
2. raw target 必须严格匹配 `/dev/rdisk[0-9]+`；
3. IOKit media 必须 `Whole=true`；
4. 必须存在 USB ancestor 的 `idVendor` / `idProduct`；
5. `open()` 前后 `/dev/rdiskN` 的 `st_rdev` 必须与获得的 fd 一致；
6. fd 必须为字符设备；
7. LBA4 + LBA7 双重 EDP metadata 验证通过；
8. raw fd 只允许传给白名单 EDP bridge；
9. bridge 可执行文件必须 root-owned 且 group/other 不可写；
10. 不提供任意路径 open XPC/API；
11. 不允许 internal disk；
12. 不修改 `/dev` node 的 owner/mode；
13. 不修改 AuthorizationDB；
14. 不保存管理员密码或 `AuthorizationExternalForm`。

GitHub Actions 的 DiskImages2 synthetic physical fixture 只有测试编译时定义：

```text
-D EDP_ALLOW_SYNTHETIC_RAW_FIXTURE=1
```

正式安装器从不定义该宏，默认值固定为 `0`。

## 稳定代码身份与 FDA 连续性

FDA 必须绑定稳定 App identity，不能使用 ad-hoc 发布包。

正式 self-signed 分发必须保证：

```text
main App:  com.edp.usbvault.app
raw helper: com.edp.usbvault.rawaccess
daemon: stable signed edp-vaultctl / embedded daemon
```

并且三者使用同一张稳定 certificate-backed self-signed code-signing certificate。自 2026-08-29 起，本机长期统一 identity 固定为：

```text
Identity: EDP Project Code Signing
Certificate SHA-256: D9142CE44ABCB5DD662DF9621D48A88C88EDBCB0392D3C74EBACBB1292B7B5A7
Certificate root (DR SHA-1): 040b5488fb2b6c02b0786e76b674cb4460658ca2
Validity: 2026-08-29 .. 2046-08-24
```

`edp-usb-vault` 与 `/Users/zhangyuxi/edpopen` 共用这一张证书；不再使用 Apple Development identity 作为本机产品签名身份。私钥只持久化在用户 `login.keychain-db`，仓库不保存私钥/P12。

当前实机 self-signed designated requirement 形式为：

```text
identifier "com.edp.usbvault.app"
and certificate root = H"040b5488fb2b6c02b0786e76b674cb4460658ca2"
```

因此 helper 在固定 bundle id + 同一 certificate root 下升级时，可维持稳定 designated requirement。构建器已经增加发布 gate：self-signed 模式下主 App、Raw Access helper、daemon 的 certificate root 必须完全一致，否则拒绝出包。

ad-hoc 包只允许用于结构/CI 验证；其 designated requirement 是 CDHash，不能作为 FDA 跨升级模型。

## UI / 首次配置

App 不再提供“每次插盘启用磁盘访问”按钮，也不再创建 `AuthorizationRef`。

首次配置流程：

1. 安装 App、daemon、macFUSE Local 与 Raw Access helper；
2. 用户在“完全磁盘访问”中添加并开启 `EDP USB Vault 磁盘访问`；
3. 插入 EDP U 盘；
4. daemon 自动 probe FDA；
5. 成功后 `privilegedAccessReady=true`；
6. 之后自动挂载按设备策略运行。

权限缺失时只记录一次失败，不在 UI polling 周期中反复触发认证或弹窗；用户可在设置中“重新检测权限”。

## 已完成实现

- [x] App 删除运行期 `AuthorizationRef` / `AuthorizationExternalForm`；
- [x] XPC 删除 `grantRawAccess(rawPath:authorization:)`；
- [x] daemon 发现路径改为无交互 O_RDONLY metadata helper；
- [x] `EDPConsoleExec.c` 改为 FDA raw broker；
- [x] broker 增加 whole USB、EDP metadata、open 前后 device-node 一致性校验；
- [x] 新增 `EDP USB Vault Raw Access.app`；
- [x] installer 将 helper 安装到 `/Applications` 并设为 root:wheel、不可由普通用户写；
- [x] App 增加 Full Disk Access 设置入口与权限状态；
- [x] clean installer 移除旧 `edp-readwrite-fuse` / `edp-raw-sparse` authopen runtime；
- [x] GitHub Actions synthetic fixture 仅使用编译期测试宏；
- [x] self-signed 构建 gate 强制 App/helper/daemon 使用同一 certificate root；
- [x] Swift 6 strict / C `-Werror` / model / native IOKit API 本地回归通过；
- [x] clean installer 的 SMAppService 与 legacy 两种结构验证通过。

## 尚未完成的最终验收

以下必须使用稳定 certificate-backed self-signed 包实机完成后，才能宣称“只在首次安装/设置授权一次”正式闭环：

- [ ] 安装 0.7.x self-signed 包；
- [ ] 为 `com.edp.usbvault.rawaccess` 开启一次 FDA；
- [ ] 真实 EDP U 盘交换区 mount → RW → unmount；
- [ ] U 盘拔插后无需管理员/Touch ID；
- [ ] 强制 diskN 改变后仍无需授权；
- [ ] 等待超过 300 秒后再次挂载仍无需授权；
- [ ] App 重启后无需授权；
- [ ] daemon 重启后无需授权；
- [ ] Mac 重启后无需授权；
- [ ] 使用同一 certificate root 升级一个版本，FDA 仍保留；
- [ ] Finder 首次窗口样式/尺寸回归同时通过。

在上述验收前，不合并回稳定分支。
