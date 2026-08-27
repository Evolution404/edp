# Direct MFMount / Generic vs Local FSKit P0 诊断

日期：2026-08-27  
分支：`test/fuset-minimal-fskit-bridge`

## 目标

验证 EDP 内部 `volume.raw` transport 是否可以绕过 libfuse3，直接使用 macFUSE 5.3.3 `MFMount.framework` + FSKit，并同时满足：

1. transport 可以挂载；
2. `volume.raw` 读写正常；
3. DiskImages2 `CRawDiskImage` 可以 attach；
4. Finder 不枚举内部 transport。

## Direct transport

新增：

- `native/EDPFSKitPoC/Tools/MacFUSEMinimal/DirectMFMountRawTransport.c`
- `native/EDPFSKitPoC/Tools/MacFUSEMinimal/DirectMFMountAsyncShim.c`
- `.github/workflows/direct-mfmount-fskit-transport.yml`
- `.github/workflows/direct-mfmount-local-fskit-transport.yml`
- `.github/workflows/direct-mfmount-finder-ab.yml`

Direct transport 不链接 libfuse，只链接：

```text
MFMount.framework
CoreFoundation.framework
libSystem.B.dylib
```

它直接处理最小 FUSE wire protocol，只暴露：

```text
/
└── volume.raw
```

## MFMount handshake

同步调用 `MFMount()` 会形成初始化互等：挂载端等待 FUSE INIT reply，而 server 尚未开始消费 channel。macFUSE 官方 libfuse 实现同样将 `MFMount()` 放在后台线程执行。

因此 PoC 使用 `DirectMFMountAsyncShim.c`：

```text
background thread: MFMount(...)
main thread: MFChannelCopyNextMessage() -> FUSE_INIT -> replies
```

修正后成功收到：

```text
DIRECT_MFMOUNT_ASYNC_STARTED=1
DIRECT_OPCODE opcode=26 ...
DIRECT_INIT_IN major=7 minor=19 ...
DIRECT_INIT_OUT major=7 minor=19 ...
DIRECT_MFMOUNT_ASYNC_RESULT=0 errno=0
```

## Generic FSKit 基线

GitHub Actions run `33033528190` 已证明：

```text
DIRECT_MFMOUNT_NO_LIBFUSE_DEPENDENCY=1
DIRECT_MFMOUNT_MOUNTED=1
DIRECT_READ_OK=1
DIRECT_RW_OK=1
DIRECT_DISKIMAGES2_RAW_ATTACH_OK=1
DIRECT_MFMOUNT_FUNCTIONAL_OK=1
```

但 Generic 最终状态：

```text
MNT_DONTBROWSE=0
MNT_LOCAL=0
BROWSABLE=1
```

Finder 会枚举该 transport。因此 `nobrowse` 并不是被 libfuse3 丢掉；问题位于 MFMount / Generic FSKit / macOS 26 mount semantics。

## Local FSKit 结果

独立 Local probe run `33033710925`：

```text
DIRECT_LOCAL_NO_LIBFUSE_DEPENDENCY=1
DIRECT_LOCAL_MOUNTED=1
DIRECT_LOCAL_IS_FSKIT=1
DIRECT_LOCAL_READ_OK=1
DIRECT_LOCAL_RW_OK=1
DIRECT_LOCAL_DISKIMAGES2_OK=1
```

实际 mount 明确仍为 FSKit：

```text
/dev/diskN on /Volumes/EDP-Direct-Local-... (macfuse, local, ..., fskit, mounted by runner)
```

VFS / Foundation 仍报告：

```text
MNT_DONTBROWSE=0
MNT_LOCAL=1
BROWSABLE=1
```

但 Finder `name of every disk` 不枚举 Local transport。

## Generic vs Local 同机 A/B

workflow：`.github/workflows/direct-mfmount-finder-ab.yml`

run `33034136019` 在同一台 macOS 26.5.2 runner 上同时挂载 Generic 和 Local，并在两边都先验证：

```text
FSKit = yes
libfuse dependency = no
RW = OK
DiskImages2 CRawDiskImage attach = OK
```

实际状态：

```text
Generic: DONTBROWSE=0 LOCAL=0 BROWSABLE=1
Local:   DONTBROWSE=0 LOCAL=1 BROWSABLE=1
```

Finder 三次采样（初始、稳定 10 秒、Finder 重启后）均得到：

```text
Generic visible = 1 / 1 / 1
Local visible   = 0 / 0 / 0
```

因此当前硬证据为：

> Direct MFMount + macFUSE Local FSKit 在 macOS 26 hosted Finder 中可以保持内部 transport 不被 Finder 枚举，同时保留 RW 和 DiskImages2。

run `33034136019` 最终显示 failure 不是行为失败：flags 文件使用无换行 `printf`，随后 Bash `read` 在 `set -e` 下因 EOF 返回非零，在输出最终矩阵前退出。日志中的三次 `GENERIC_VISIBLE=1 / LOCAL_VISIBLE=0` 已完整记录。下一次 workflow 修正只需给 flags 行增加换行，不改变任何挂载行为。

## P0 判断

P0 的技术修复方向已经从“继续尝试 `nobrowse`”收敛为：

```text
EDP encrypted random-access block backend
        ↓
EDP-owned Direct MFMount wire transport
        ↓
macFUSE Local FSKit module
        ↓
hidden volume.raw transport
        ↓
DiskImages2 CRawDiskImage
        ↓
Apple filesystem / separately-installed FSKit filesystem provider
        ↓
Finder user volume
```

重要限制：当前正式产品仍使用 FUSE-T transport，且产品政策明确不应在没有完整迁移验证前静默引入 macFUSE runtime dependency。因此 Local MFMount 证据已足以确定 P0 的候选实现，但还不能仅凭 CI A/B 就直接把正式 runtime 改成 macFUSE。

## 正式集成 gate

进入产品默认路径前必须同时满足：

1. 把现有 `EDPReadWriteFuseBridge.c` 的 `edp_rw_*` / `edp_ro_*` encrypted block callbacks 接到 Direct MFMount wire transport，而不是回退到 libfuse；
2. 保持 privileged inherited raw-fd + control-fd password 模型不变；
3. RW、RO、DiskImages2、ExFAT/APFS 全部回归；
4. Finder A/B hard gate：Generic visible，Local invisible；
5. 实体 Mac 最终确认侧边栏只出现用户卷，不出现 `EDP * Transport`；
6. 明确安装/签名/升级策略后，才允许把 macFUSE Local runtime 设为产品依赖。

当前状态：**P0 根因与可行修复机制已确认；正式产品迁移仍在实现中。**
