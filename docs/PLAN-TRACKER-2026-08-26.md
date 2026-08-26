# EDP USB Vault — 计划推进追踪

日期：2026-08-26  
目标分支：`feat/macos26-native-fskit`  
关联计划：`docs/PLAN-2026-08-26-ntfs-readwrite-and-native-refactor.md`

## 追踪规则

- 每完成一个明确里程碑，更新本文件并提交、推送到 GitHub。
- 记录实际证据：commit、GitHub Actions run、关键 RESULT/ERROR 标记、真实设备只读验证结果。
- 不用“预计完成”代替实际结果；未验证的项目保持 `TODO` / `BLOCKED`。
- 真实物理写入前必须满足计划中的 raw sparse backup 与恢复验证门槛。

## 当前状态

### Phase A — NTFS 读写

- [ ] A1 NTFS mount 生命周期根因
  - 当前证据：NTFS-3G 可在 macOS 26 CI 上建立 `backend=fskit` RW mount，但 mount 建立后进入实际 I/O 前异常消失。
  - 最新失败 run：`32914814798`，commit `5d3decf`。
  - 已确认不是 `ntfs-3g.probe`、NTFS 格式识别或“无法进入 RW mount”问题。
- [ ] A2 固化正确的 NTFS-3G FSKit 启动方式
- [ ] A3 synthetic NTFS 完整 RW/remount E2E，要求同一 commit 连续 3 次通过
- [ ] A4 dirty / hibernated NTFS fail-closed
- [ ] A5 CI 与产品 NTFS mount 路径统一
- [ ] A6 raw sparse backup → 恢复验证 → 真实 EDP NTFS 读写

### Raw sparse backup 证据

- [x] 真实 EDP raw 数据区抽样确认大量未使用区域为全 0。
- [x] 256 MiB 步长抽样 442 个 4 KiB block：404 个全 0、38 个非零，零块比例约 91.4%。
- [x] 数据区相对 +8/+16/+32/+64/+96/+110 GiB 的 1 MiB window 均为全 0。
- [x] 分区起点、MFT 物理位置、尾部关键区域验证为非零，排除“读失败误判为 0”。
- [ ] 实现 raw sparse backup 工具。
- [ ] sparse backup 恢复/挂载/SHA256 验证。

### Phase B — 原生化

- [ ] B1 IOKit / IOUSBHost 替代 `ioreg`
- [ ] B2 Disk Arbitration + IOKit 替代 `diskutil list/info`
- [ ] B3 插拔事件驱动替代 2 秒轮询
- [ ] B4 Disk Arbitration 替代 `diskutil mount/unmount/eject`
- [ ] B5 移除 `/sbin/mount` / `/sbin/umount` 生产依赖
- [ ] B6 SwiftUI + XPC + ServiceManagement 替代用户可见 CLI 工作流
- [ ] B7 Keychain 替代自管 `master.key`

## 变更日志

### 2026-08-26 — Tracker 初始化

- 建立计划追踪文件。
- 下一步：执行 A1，对 `probe-edp-crypto-ntfs-readwrite.sh` 增加 NTFS PID、exit status、mount 存活窗口、根目录 I/O 和 macFUSE/FSKit 日志诊断，定位 mount 消失根因。
