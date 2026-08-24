# macFUSE FSKit local backend 挂载故障 — 完整诊断报告(2026-08-25)

## 摘要

macOS 15.7.7 (24G720, Apple Silicon) + macFUSE 5.3.3 的 FSKit local backend 上,任何
FUSE 挂载(官方 demo 与自有实现均同)在 `activateVolume` 成功返回 error:0 之后、
最终挂载协商(fskitd LiveFiles mount service)阶段于 ~15ms 内被拒,回滚后以
`MFDaemon.MountError Code=4` 报告。经二进制元数据核实,Code=4 的真实含义是
**`fileSystemExtensionRequiresApproval`**(非旧结论 activatingDeviceFailed)。
501 与 root 发起结果完全相同;PlugKit 显示 extension 已启用(`+`)。
官方 GitHub issue #1181 的成功案例运行于 15.7.5 — 高度怀疑 15.7.6/15.7.7 加严了
FSKit 挂载授权模型。EDP 应用层无法修复。

附带发现两个独立系统 bug:
1. `fskitd` 在块设备移除(IOKit notification)路径存在 `dispatch_sync` 死锁崩溃;
2. macFUSE 回滚 detach 恒定失败,在 fskitd 崩溃污染过的系统上会遗留永久 orphan
   Disk Image 并最终把 `diskarbitrationd` 拖入挂死。

## 环境

- macOS 15.7.7 Build 24G720,Apple Silicon(MacBookPro18,3)
- macFUSE 5.3.3(`io.macfuse.app.launchservice.daemon`,MFDaemon 闭源)
- FSKit extension:`io.macfuse.app.fsmodule.macfuse-local`(PlugKit 状态 `+`)
- 测试用户 UID=501 GID=20
- 官方 baseline:macfuse/demo 的 LoopbackFS-libfuse3-C(libfuse 3.18.2),
  ad-hoc 签名 + 官方 entitlements,命令含
  `-o backend=fskit,modules=subdir,subdir=<src>,uid=501,gid=20,volname=…`

## MFDaemon 错误码权威表

提取方法:解析 `/Library/PrivilegedHelperTools/io.macfuse.app.launchservice.daemon`
(arm64 slice)`__TEXT,__swift5_fieldmd` 的 FieldDescriptor,按 case 声明顺序即
NSError code(Swift enum→NSError 桥接的 discriminant)。MFDaemon 闭源,此为唯一权威来源。

| Enum | Code=0 | Code=1 | Code=2 | Code=3 | Code=4 |
|---|---|---|---|---|---|
| `MFDaemon.Broker.Error` | overridden | **timeout**(10s advertise deadline) | | | |
| `MFDaemon.MountError` | activatingDeviceFailed | mountCommandFailed | illegalArguments | fileSystemExtensionNotFound | **fileSystemExtensionRequiresApproval** |
| `MFDaemon.DiskImage.Error` | createFailed | attachFailed | **detachFailed** | attachDeviceLookupFailed | |
| `MFDaemon.ActivateDeviceError` | attachingDeviceFailed | initializingDeviceFailed | | | |
| `MFDaemon.DeactivateDeviceError` | detachingDeviceFailed | removingDiskImageFailed | | | |

MountError 为 multi-payload enum(kind=3),Code=5=initializingVolumeFailed,Code=6=unknown。

## 故障演进时间线(2026-08-24 晚,系统被污染后)

1. `23:09` 运行过 `macfuse install --components file-system-extensions --force`
   (重注册 extension;PlugKit 记录 Timestamp 刷新为 23:11:15)。
2. `23:41:25` 起 daemon 每次挂载报 `MountError Code=4`
   (=`fileSystemExtensionRequiresApproval`),回滚 `detachFailed`(Code=2)。
3. 每次失败遗留一个存活的 root `diskimages-helper` + 4KB DMG(disk4…disk11 共 8 个;
   `hdiutil info` 显示每 image 的持有 PID 即对应 helper,均对各自 /dev/diskN 发起
   Disk Arbitration `disk claim`)。
4. `fskitd` 崩溃(见下),死后 `diskarbitrationd` 留有未消化的
   `queued solicitation … disk fskit additions changed`,随后:
   - `diskutil list`(全盘枚举)永久挂死,单盘 `diskutil info` 正常;
   - `hdiutil detach /dev/diskN`(含 `-force`)主线程死等 mach reply
     (sample 栈:`mach_msg2_trap`,见 logs/hdiutil-detach-hang-sample.txt)。
5. 后续尝试全部退化为 `Broker.Error Code=1`(advertise timeout):extension 不再被
   拉起,而虚拟设备冷创建本身耗 6.3s + fskitd/fskit_agent 冷启动,10 秒 deadline 不够。
6. 重启后系统恢复干净(`hdiutil images:0`,diskutil list 正常)。

## fskitd 崩溃(独立 bug,证据:DiagnosticReports fskitd-2026-08-23-192351.ips / fskitd-2026-08-24-131809.ips)

```
EXC_BREAKPOINT (SIGTRAP), faulting thread:
  __DISPATCH_WAIT_FOR_QUEUE__            (libdispatch)
  _dispatch_sync_f_slow                  (libdispatch)
  -[FSBlockDeviceResource(Private) terminate]   (FSKit)
  -[FSBlockDeviceResource dealloc]              (FSKit)
  deviceNotificationCallback                    (FSKit/IOKit)
```

块设备(如 macFUSE 的临时 Disk Image)被移除时,FSKit 在 IOKit 移除回调里
`dispatch_sync` 到自身队列触发死锁检测断言 → fskitd 被 trap 杀死。
即:macFUSE 挂载失败的回滚 detach 本身会触发 fskitd 崩溃,级联污染
diskarbitrationd 与 DiskImages 子系统。

## 干净系统单次 baseline(2026-08-25 06:22,UID 501 发起)

完整日志:`logs/system-baseline-uid501.log`。关键序列:

```
06:22:58.216  installer: extension already registered
06:22:58.269  daemon: Mount volume / Advertise server / Activate virtual device
06:22:59.904  Activated device (1.6s) → daemon: Mount <private>
06:22:59.937  mount[2344] 连 fskitd:"Incomming connection, entitled 0"
              initiator = com.apple.mount(SecTaskCopySigningIdentifier)
06:22:59.939  applyResource kind 1 → fskit_agent 拉起 extension pid 2345/2346
06:22:59.965  FSBlockDeviceResource openWithBSDName 成功
06:23:00.039  extension Create FileSystem → checkIn 成功
06:23:00.054  loadResource → configureUserClient error:null
06:23:00.085  Channel created / Connection to file system extension established
06:23:00.099  activateVolume:start
06:23:00.100  activateVolume ... error:0        ← 卷激活成功
06:23:00.101  LiveFiles mount service accepting connection(挂载协商开始)
06:23:00.117  canStartDeactivateTask            ← 15ms 后协商失败,开始拆除
06:23:00.119  deactivateVolume → Connection invalidated
06:23:00.131  MFDaemon.MountError Code=4        ← fileSystemExtensionRequiresApproval
06:23:00.164  Failed to detach Code=2
06:23:00.167  Remove disk image(兜底成功,无 orphan)
```

fskitd 侧无任何可见错误日志(消息均 `<private>`);mount(8) 进程仅两行连接日志无错误。

## root 发起 A/B(同日 06:26,sudo)

- daemon 侧结果与 501 完全一致:`MountError Code=4`,无 orphan。
- **客户端侧新增直接证据**(LoopbackFS3 stderr):
  `MFMount: MFMount(_:_:_:_:): File system extension not enabled`
  `fuse: mount failed with error: 4`
  即 MFMount 客户端本地预检在 root 上下文直接判定 "extension not enabled"。
- 推论:approval/enabled 判定至少存在于两处(MFMount 客户端预检、fskitd 挂载协商),
  且均不认可,而 GUI(501 Login Items/PlugKit)显示已启用。

## 结论

1. 失败层:**fskitd LiveFiles 挂载协商的授权检查**(activateVolume 成功之后)。
2. 与发起者特权无关(501 == root),与 EDP/libfuse 参数/macfuse daemon 无关。
3. 版本特定嫌疑:15.7.5 官方案例可成功,15.7.7 稳定失败 — 疑似 15.7.6/15.7.7 变更。
4. PlugKit 的 `+` 启用状态与 FSKit 挂载授权判定不同步(或判定依据不同的
   per-context 状态)。
5. 附带:fskitd detach-path 死锁崩溃 + macFUSE detachFailed 是故障级联的放大器。

## 遗留问题(开放)

1. fskitd LiveFiles 挂载协商具体检查什么授权?(initiatorAuditToken /
   authorizingAuditToken 的 `applyResource:targetBundle:instanceID:initiatorAuditToken:
   authorizingAuditToken:isProbe:usingBlock:` 语义)
2. 15.7.6/15.7.7 的 FSKit 安全公告内容?是否有对应 CVE 修复改变了授权行为?
3. ad-hoc 签名 + 官方 entitlements 的 FUSE 客户端是否是触发条件之一?
   (issue #1181 成功案例的签名方式未确认)
4. MFMount 客户端预检 "not enabled" 读取的是哪个状态源?为何 root 上下文恒为否定?
5. 可能的 workaround(不触及 SIP/Recovery/FDA):是否存在让 FSKit 授权认可
   该挂载链的合法途径?

## 复现

```bash
./scripts/test-fskit-post-reboot-baseline.sh   # 单次官方 baseline,判定只看 mount table
```

脚本遵守:macOS /bin/bash、无 GNU timeout(perl alarm watchdog)、trap EXIT INT TERM、
不 stat 异常挂载点内文件、前后 hdiutil image 计数。

## 日志文件

- `logs/system-baseline-uid501.log` — 干净系统 501 baseline 全程(io.macfuse +
  FSKit + DiskArbitration,debug 级)
- `logs/server-baseline-uid501.log` — 501 客户端 stderr(空:客户端预检未报错)
- `logs/system-rootab.log` — root A/B 同 predicate
- `logs/server-rootab-stderr.log` — root 客户端 stderr(含
  "File system extension not enabled" 直接证据)
- `logs/fskitd-crash-stack-2026-08-24.txt` — fskitd 崩溃栈提取
- `logs/hdiutil-detach-hang-sample.txt` — orphan detach 挂死时的 hdiutil sample 栈
