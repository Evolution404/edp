# Direct MFMount / Generic FSKit P0 诊断

日期：2026-08-27  
分支：`test/fuset-minimal-fskit-bridge`

## 目标

验证 EDP 内部 `volume.raw` transport 是否可以绕过 libfuse3，直接使用 macFUSE 5.3.3 `MFMount.framework` + FSKit，并同时满足：

1. transport 可以挂载；
2. `volume.raw` 读写正常；
3. DiskImages2 `CRawDiskImage` 可以 attach；
4. transport 必须 `MNT_DONTBROWSE=1` / `volumeIsBrowsable=false`，从 Finder 隐藏。

## 实现

新增：

- `native/EDPFSKitPoC/Tools/MacFUSEMinimal/DirectMFMountRawTransport.c`
- `native/EDPFSKitPoC/Tools/MacFUSEMinimal/DirectMFMountAsyncShim.c`
- `.github/workflows/direct-mfmount-fskit-transport.yml`

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

## 决定性 Generic FSKit 结果

GitHub Actions：

- run `33033528190`
- job `98391138930`
- head `07aae3f2320340585033572c0dd58bd65f451d18`

功能链全部成功：

```text
DIRECT_MFMOUNT_NO_LIBFUSE_DEPENDENCY=1
DIRECT_MFMOUNT_MOUNTED=1
DIRECT_READ_OK=1
DIRECT_RW_OK=1
DIRECT_DISKIMAGES2_RAW_ATTACH_OK=1
DIRECT_MFMOUNT_FUNCTIONAL_OK=1
```

实际 mount：

```text
macfuse://... on /Volumes/EDP-Direct-... (macfuse, nodev, nosuid, noowners, noatime, fskit, mounted by runner)
```

因此已证明：

> EDP 的最小 `volume.raw` transport 可以完全绕过 libfuse3，直接使用 MFMount.framework + Generic FSKit，并支持真实读、写和 DiskImages2 raw attach。

## P0 结果：失败

MFMount 明确收到：

```text
nobrowse,volname=EDP Direct MFMount
```

但最终 VFS / Foundation 状态为：

```text
FSTYPE=macfuse
FLAGS=0x10200018
MNT_DONTBROWSE=0
MNT_LOCAL=0
BROWSABLE=1
VOLUME_NAME=EDP Direct MFMount
LOCAL=0
TYPE=macfuse
```

最终：

```text
RESULT=DIRECT_MFMOUNT_FUNCTIONAL_ONLY DONTBROWSE=0 BROWSABLE=1
```

### 结论

Direct MFMount **技术上成功，但不能解决 P0**。

这同时排除了“`nobrowse` 是被 libfuse3 丢掉”的假设。因为在完全不链接 libfuse 的 Direct 路径中，`nobrowse` 仍未成为 `MNT_DONTBROWSE`。

当前根因进一步下移到：

```text
MFMount / macFUSE Generic FSKit module / macOS 26 FSKit mount semantics
```

而不是：

```text
EDP raw transport / libfuse3 wrapper
```

## 下一项受控实验

正在运行独立 Direct MFMount `local,nobrowse` 对照：

- workflow：`.github/workflows/direct-mfmount-local-fskit-transport.yml`
- 首轮 run：`33033710925`

该实验仍要求 mount line 明确包含 `fskit`，并保持：

```text
RW OK
DiskImages2 attach OK
MNT_DONTBROWSE=1
volumeIsBrowsable=false
Finder actual disk list 不出现 transport
```

若 Local FSKit 同样得到 `MNT_DONTBROWSE=0 / BROWSABLE=1`，则 macFUSE FSKit 的 no-browse P0 路线基本可以关闭，下一步应改 transport 暴露架构，而不是继续堆叠 Finder/DA mount workaround。
