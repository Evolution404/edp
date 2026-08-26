# EDP USB Vault — FUSE-T Minimal FSKit Bridge 架构决策

日期：2026-08-26  
分支：`test/fuset-minimal-fskit-bridge`  
适用范围：macOS 26+、EDP 介质**只读** Finder 挂载路径

## 决策

**A. 推荐 FUSE-T thin bridge。**

采用前提：

1. 运行时固定 FUSE-T `1.2.7` 官方原始签名 package / appex 指纹，不自行修改第三方二进制；
2. 产品仅复用官方签名的极薄 `fuse-t.app` / `FskitSrvModule.appex`，不安装 FUSE-T 完整 core、`go-nfsv4`、全局 `libfuse`；
3. EDP 自己维护只读 Unix Domain Socket RPC backend；
4. hidden FUSE-T 卷只暴露 `/volume.raw`，最终 `/dev/diskN` 与 Finder 卷交给 Apple DiskImages、Disk Arbitration、Apple 文件系统；
5. 商业发布前必须取得适用的 FUSE-T commercial license；未取得许可时不得把“用户自己下载/产品自动下载”当作商业许可绕过；
6. CI 的 `enabledModules.plist` 写入只允许用于一次性 runner，产品必须走正常用户启用 FSKit extension 的系统流程；
7. 发布前仍必须完成物理 EDP G4-G6 与 H5b（sleep/wake、真实拔盘）最终验收。

这项决策只覆盖**只读**架构。它不替代现有 macFUSE + NTFS-3G 的 NTFS 读写研究；若产品重新要求 NTFS 写入，需要单独的写协议、文件系统写语义和安全矩阵，不能直接把本 PoC 的只读结论外推为可写方案。

---

## 1. 技术结论

完整 hosted 验证已证明：

```text
real captured EDP metadata
→ EDPReadOnlyUnlock
→ O_RDONLY|O_CLOEXEC whole-device backing
→ EDPEncryptedPartitionReader / SM4 random access
→ EDP-owned Unix socket backend
→ signed FUSE-T FSKit module
→ hidden read-only /volume.raw
→ hdiutil / Apple DiskImages
→ read-only /dev/diskN
→ Apple filesystem
→ Finder / Quick Look
```

关键事实：

- 不需要 FUSE-T core、go-nfsv4、libfuse runtime。
- 不使用 TCP/NFS/SMB 数据路径；当前 direct bridge 使用 app-group Unix socket。
- product bridge 不接受 file key；真实 metadata/password 经现有 `EDPReadOnlyUnlock` 解锁。
- 不生成完整 plaintext cache。
- backing 使用 `O_RDONLY|O_CLOEXEC`，hosted whole-device fixture 前后 metadata/hash 不变。
- final Finder volume 是 Apple HFS+/`hfs`，而非 `fuset`；FUSE-T 仅是隐藏 transport。
- Finder、Quick Look、64 MiB 大文件、graceful teardown、backend SIGKILL fail-closed、forced detach、crash recovery 均已通过 macOS 26 Actions。

主要证据：

- `docs/diagnostics/fuset-applefs-macos26-ci.txt`
- `docs/diagnostics/fuset-edp-sm4-macos26-ci.txt`
- `docs/diagnostics/fuset-edp-unlock-realmeta-macos26-ci.txt`
- `docs/diagnostics/fuset-performance-macos26-ci.txt`
- `docs/diagnostics/fuset-stability-macos26-ci.txt`

---

## 2. 性能与资源基线

正式 benchmark 固定：macOS 26.5.2 / Xcode 26.6、real-metadata product unlock、Swift optimized build、`F_NOCACHE=1`、`F_RDAHEAD=0`。

| 项目 | hosted baseline |
|---|---:|
| 4 KiB random | 7.533 MiB/s / 1928.4 IOPS |
| 64 KiB random | 37.234 MiB/s / 595.7 IOPS |
| 1 MiB random | 52.357 MiB/s / 52.4 IOPS |
| 256 MiB sequential | 45.597 MiB/s |
| bridge CPU（256 MiB sequential） | 约 4.67 CPU-s |
| bridge peak RSS | 163,808 KiB，约 160 MiB |

第 3 轮 benchmark 曾因 VFS cache 出现 GiB/s 级虚高数字，已经废弃，不作为决策依据。当前 H3 最明显的工程优化点是约 160 MiB peak RSS；它不阻塞正确性，但产品化前应继续降低分配/峰值内存。

---

## 3. H7 — FUSE-T binary redistribution 许可

截至 2026-08-26，官方来源：

- https://github.com/macos-fuse-t/fuse-t/blob/main/License.txt
- https://www.fuse-t.org/

FUSE-T binary license 的明确边界：

- 非商业使用免费，但 binary redistribution 需要保留版权、条件与免责声明；
- **commercial use 或与 commercial software bundling 时，vendor 必须向 FUSE-T authors 获取 commercial license**；
- 官方网站同时说明 commercial license 可用于 embedding / shipping FUSE-T in a product。

因此：

- 非商业构建可以在满足 notice 条件下使用官方 binary；
- 商业产品**不是禁止采用**，但 commercial license 是发布 gate；
- 当前仓库没有商业许可合同或价格信息，不推测授权价格/期限/范围。

H7 结论：**技术上可分发；商业发布必须先完成商业授权。**

---

## 4. H8 — bundling / 自动下载

FUSE-T 官方 license 明确把 commercial **use** 与 commercial **bundling** 都纳入 commercial-license requirement。由于“commercial use”本身已触发授权条件，不能假设“不随安装包内嵌、改成应用运行时自动下载”就自动变成免费商业使用。

产品策略：

- 非商业：可考虑随包携带或由安装器下载固定 SHA 的官方包，但必须满足 binary notice 条件；
- 商业：无论 bundling 还是由 EDP 自动获取，均应先取得 FUSE-T commercial license，并以合同实际允许的分发方式为准；
- 用户完全独立安装 FUSE-T 可以降低我们“redistribution”的行为范围，但**不能仅凭这一点推导商业使用不需要许可**。

作为对照，macFUSE 当前 license 更明确写出：binary bundled with commercial software 需要 prior written permission，而且该限制**包括在 commercial software context 中 automated download / installation**。

官方 macFUSE 来源：

- https://github.com/macfuse/framework
- https://github.com/macfuse/macfuse/wiki/Open-Source-Status

H8 结论：**不存在可依赖的“商业自动下载免费绕过”方案。**

---

## 5. H9 — FUSE-T thin bridge vs macFUSE Minimal Runtime

这两条路径并非完全同一目标：当前 FUSE-T thin bridge 是只读 raw transport；仓库中的 macFUSE 基线主要解决 NTFS-3G 读写。因此性能数字只能作为工程背景，不能做不等价的胜负比较。

| 维度 | FUSE-T thin bridge（本分支） | macFUSE + NTFS-3G 既有路径 |
|---|---|---|
| 当前目标 | EDP 只读 raw transport → Apple FS | EDP 解密 raw → NTFS-3G 可读写 |
| 第三方 runtime | 仅官方签名约 1.7 MB `fuse-t.app` / FSKit appex | macFUSE Core/系统组件 + NTFS-3G runtime/source/licenses；安装链明显更多 |
| FUSE-T/macFUSE core helper | 无 libfuse、无 go-nfsv4 | macFUSE runtime 必须安装；NTFS 路径还需 NTFS-3G |
| Kernel extension | 当前 macOS 26 FSKit 实验无需 KEXT | 项目当前 macOS 26 路径也走 FSKit，但安装/注册面仍更重 |
| hidden decrypted raw | 单个自有 Unix-socket RPC FSKit transport | inner macFUSE bridge |
| 最终 Finder filesystem | Apple native filesystem | NTFS-3G/macFUSE outer filesystem |
| Finder 本地卷语义 | HFS+ final native volume 已验证 | 稳定基线曾为 `MNT_LOCAL=false`；WIP outer `local` 改善 Trash，但仍需完整回归 |
| TextEdit atomic replace | final Apple FS 层不经过 FUSE rename callback；H4 Finder/Quick Look 已通过 | macFUSE FSKit stable/WIP 中 `rename(temp, existing)` 返回 `EOPNOTSUPP`，TextEdit Cmd+S 仍是 P0 |
| hosted/read 性能 | no-cache seq 45.597 MiB/s；1 MiB random 52.357 MiB/s | WIP inner sequential read 约 55.8 MiB/s；outer NTFS fsync write约 37.8 MiB/s；测试口径不同，不能直接比较 |
| memory | bridge peak RSS 约 160 MiB，需优化 | 当前仓库没有同口径 peak-RSS 数据 |
| crash cleanup | graceful + SIGKILL recovery 已有自动 CI | 既有产品路径有 daemon/session cleanup，但物理 crash/拔盘矩阵仍需完整实机 |
| 许可 | non-commercial free；commercial use/bundling 需 commercial license | commercial bundling/integration 需付费/书面许可；license 明确涵盖 automated download/install |
| 安装 UX | 仅需要官方 FSKit app + 用户正常启用 extension | 多组件安装、系统 runtime、NTFS-3G，授权与维护面更大 |
| 维护风险 | **最大风险：Unix RPC 是通过 binary contract/黑盒验证得到，不是 FUSE-T 公共稳定 API**；必须 pin 1.2.7 + SHA + contract CI | 接口栈更公开/成熟，但组件多、Finder FSKit 语义问题更多 |

H9 结论：

- **只读目标：FUSE-T thin bridge 明显更薄，Apple 文件系统作为 final mount 也规避了 outer FUSE Finder 语义问题。**
- **读写 NTFS目标：当前 thin bridge 不能直接替代 macFUSE + NTFS-3G。**
- 许可上两者都不是“商业免费随包分发”；FUSE-T 不是因为许可而技术淘汰，而是必须在商业发布前签商业授权。

仓库 macFUSE 对照证据：

- `docs/diagnostics/2026-08-26-ntfs-finder-semantics-handoff.md`
- `docs/diagnostics/2026-08-26-clean-exfat-ntfs-installer-handoff.md`

---

## 6. H10 — 最终产品架构

最终选择：**A. 推荐 FUSE-T thin bridge。**

理由按优先级排序：

1. A-F 已证明 1.7 MB 级官方 FSKit bridge 足以承载 hidden single-file raw transport；完整 core/helper 可移除。
2. G 已证明 existing EDP metadata/password/file-key/SM4 random-access reader 可直接接入，不需要 plaintext image cache。
3. 最终 Finder 卷由 Apple 文件系统驱动提供，避免让用户直接面对 FUSE-T transport，也避免 macFUSE/NTFS-3G outer layer 的 network/local/Trash/TextEdit FUSE 语义成为**只读**产品阻塞。
4. H1-H6 已覆盖 no-cache read、Finder、Quick Look、64 MiB 大文件、正常退出、SIGKILL、forced detach 与 stale-session cleanup。
5. 许可有明确 commercial-license 路径，因此应作为 release gate，而不是把技术架构判为不可用。

### 必须保留的 release gates

- **G4/G5/G6 physical**：macOS 26 实机真实 `/dev/rdiskN`、真实 EDP 文件系统 Finder 读取、真实介质前后零写入证据。
- **H5b physical**：sleep/wake、安全 eject、真实拔盘、异常拔盘。
- **License**：如果是 commercial use/shipping/bundling，发布前取得 FUSE-T commercial license；没有许可时不得商业发布该 binary 路径。
- **Version pin**：固定 FUSE-T 1.2.7 package SHA-256 `6a29c747e61a86a405a189efc3de42812d73147135f93a1bb0624c1e7b90e654`；升级任何 FUSE-T 版本必须重跑 binary contract + E/F/G/H 核心测试。
- **Authorization**：用户正常启用 FSKit extension；产品不得写 Apple `enabledModules.plist` 绕过系统授权。
- **Memory**：160 MiB peak RSS 建议在正式发布前优化并设置 regression budget。

### 不进入 production 的实验残留

- CI-only `enabledModules.plist` injection；
- FUSE-T full core / go-nfsv4；
- 临时 Python protocol probes；
- 任何 plaintext full-image cache；
- 对 FUSE-T signed app/appex 的修改或重签；
- 直接依赖卷内 filesystem type 的 EDP 业务分支。

---

## 7. 后续执行顺序

```text
1. 将 thin bridge 从 PoC 目录收敛为 product read-only runtime adapter
2. 加正式安装/启用检测：只检查官方 bundle/签名/FSKit enablement，不绕过授权
3. 把 FUSE-T package/version/SHA 与 binary-contract tests 固化为 supply-chain gate
4. 优化 H3 160 MiB peak RSS
5. 收口 C7 directory EOF、C8 xattr、C9/D6 mutation fail-closed matrix
6. macOS 26 实机完成 physical G4-G6 + H5b
7. 商业发布场景取得 commercial license 后再构建 release artifact
```

在完成第 6、7 项以前，当前状态应表述为：**技术架构决策完成、hosted 验证通过；物理介质和商业发布 gate 尚未关闭。**
