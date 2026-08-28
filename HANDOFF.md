# HANDOFF — 执行记录与交接说明

> 接手者请先读 [PLAN.md](PLAN.md)（权威计划），再读本文（做到哪了 + 怎么继续）。
> 生成日期: 2026-08-28 晚。仓库: https://github.com/Evolution404/edpopen (PRIVATE)。

## 1. 进度快照

| # | 任务 | 状态 | 备注 |
|---|---|---|---|
| 1 | 项目初始化 | ✅ 完成 | 本地 `/Users/zhangyuxi/edpopen` + GitHub 私有仓库 |
| 2 | Tauri 2 骨架 + 前端 | ✅ 完成 | 编译过；GUI 窗口未人眼走查（`cargo tauri dev`） |
| 3 | crypto.rs + 向量测试 | ✅ 完成 | 逐字节对拍全绿 |
| 4 | disk.rs + 概览页 | ✅ **真盘验证完成** | 2026-08-28 `disk6` 实测 `--analyze` 成功：124.74GB、VID/PID=21c4:0cd1、device_id=`disk&ven_lexar&prod_usb_flash_drive`、状态=Encrypted、LBA12=3 entries。raw EACCES 时 `authopen` 一次授权只读 LBA0-13 + 缓存已打通 |
| 5 | parser.rs + 扇区页 | ✅ 完成 | golden 对拍全绿（含 GBK 中文/ELABEL） |
| 6 | 盘地图页 | ✅ 完成 | 代码完整；视觉效果待 dev 走查 |
| 7 | convert.rs + 授权写入器 + 改造页 | 🟡 **授权层已重构，未真盘写入** | 5 扇 golden 对拍全绿；GUI 已改为写前五重身份复核 → unmountDisk → authopen O_RDWR SCM_RIGHTS FD → 先备份 → LBA0最后写 → sync → 同FD回读。O_RDWR FD 已用真盘做过只读 `pread` 验证，但尚未执行任何真实改造写入 |
| 8 | 字节编辑器 + 重加密 | ⬜ 未开始 | 重加密表在 PLAN §4 |
| 9 | 备份管理 + 离线模式 | ⬜ 未开始 | |
| 10 | 测试补全 + 打包 | ⬜ 未开始 | |

测试现状：`cd src-tauri && cargo test` → **13/13 绿**（含写入 sector hex 严格校验、disk0/1 在授权前拒绝）。另有 `git diff --check` 通过；`cargo tauri build --debug --no-bundle` 成功。

## 2. 当前分支与提交历史

当前开发分支：`fix/robust-device-identification`（从 `main@a07e15a` 创建）。

```
5b81448 fix: use authopen for protected raw disk reads
bcfcd10 fix: harden raw metadata reads and disk identity
a07e15a HANDOFF 补充: 历史提交残留 golden 数据的说明与清除指引
b6d13cd gitignore 补全: parse_golden/convert_golden(真实盘数据) 不入库, 并从索引移除
a9e79e8 改造页 + 提权写入器 + 交接文档(PLAN/HANDOFF)
f7b20a1 盘地图页: LBA0-13 方格网格 + 全盘区域比例条 + 尾部放大 + 图例
5b755c0 parser 全解析 + 扇区页 hexdump + 解析 golden 对拍(8/8 绿)
ee41d94 disk.rs 枚举/识别 + parser MBR·EDPF·状态判定 + 概览页 + --analyze CLI
3328712 骨架 + crypto.rs 全量对拍测试通过
e12b5e2 EDPOpen 初始提交: 项目定位与结构规划
```

`bcfcd10` 完成身份识别/错误模型/LBA11 兜底，`5b81448` 将受保护 raw 读取收敛到 macOS `authopen`。本文与 PLAN 的最终状态修订单独提交。

## 3. 模块地图（文件 → 职责 → 关键入口）

| 文件 | 职责 | 关键函数/命令 |
|---|---|---|
| `src-tauri/src/crypto.rs` | 加密原语 | `crc32_bare` `a6b0_full/a7f0_full` `xor_rolling` `lba6_decode/lba6_checksum` `lba4_decode` |
| `src-tauri/src/parser.rs` | 解析 + 字段表 + 状态判定 | `parse_edpf(dec,stride)` `parse_mbr` `classify` `parse_elabel` `parse_lba4_info/parse_lba6_info` `lba*_fields`（FieldRow 表，扇区页着色与盘地图 tooltip 的数据源）`LBA6_TEMPLATE` |
| `src-tauri/src/disk.rs` | 盘/IO/authopen 授权 | `list_usb_disks()` `usb_vid_pid` `generate_candidates` `identify_checked/identify` `read_lba` `authopen_rdisk`；SCM_RIGHTS 接收 readonly/O_RDWR raw FD；INQUIRY 候选失败时从 LBA11 PDKB 恢复 device_id |
| `src-tauri/src/convert.rs` | 改造 + 写入器 | `convert(...)→ConvertPlan`；`write_sectors(payload)` 负责五重目标盘复核、卸载、authopen O_RDWR、备份、LBA0最后写、同FD回读；`write_sectors_run` 仅为 CLI 兼容包装 |
| `src-tauri/src/commands.rs` | Tauri 命令 | `ping` `list_disks` `analyze_disk` `read_sector` `disk_map` `convert_preview` `apply_convert` |
| `src-tauri/src/main.rs` | 入口 | GUI 默认；CLI: `--analyze <N>`、`--write-sectors <payload.json>` |
| `src/app.js` | 全部前端逻辑 | `analyzeDisk` `loadDiskMap` `loadSector/renderHexdump` `loadConvertPreview`；tooltip 通用（任何元素挂 `data-tip` 即生效） |

## 4. 关键决策与为什么

1. **统一使用 authopen FD，不再 root direct-open**：2026-08-28 真机观察到 `/dev/rdiskN` 为 `root:operator crw-r-----`；普通用户 direct-open EACCES，`osascript → root → open` 在 macOS 26 仍 EPERM。现统一由 `/usr/libexec/authopen -stdoutpipe -o <flags>` 打开 raw 设备，并通过 SCM_RIGHTS 把 FD 交给 Rust。只读链 O_RDONLY 已完成真盘 analyze；O_RDWR 在先 `unmountDisk` 后已真盘取得 FD 并仅 `pread` MBR 验证，尚未执行真实写入。
2. **写前五重盘身份复核**：真正写入前重新验证 VID/PID、总扇区数、device_id、LBA4 `labelOnlyId`、当前仍为 `Encrypted`；任一变化立即拒绝。GUI 强制要求可解析的 LBA4 唯一 ID，避免 diskN 重用/换盘误写。
3. **一个 O_RDWR FD 完成整个事务**：卸载后申请一次 authopen 读写 FD；先用该 FD 读取并落盘 LBA0-13 备份+MD5，备份成功前零写入；随后按白名单写，**LBA0 最后写**，`sync_all` 后不 reopen，直接同 FD 回读。授权取消/备份失败且零写入时自动重新挂载；若已发生部分写入则保持卸载。
4. **LBA0 最后写**：写 MBR 会触发 diskarbitrationd 重扫；不再依赖重扫后的重新 open，而是保留同一授权 FD 完成回读。
5. **改造拒绝条件**：状态判定非 Encrypted（已免密/非 cems）直接拒绝 apply——防重复改造和非 cems 盘误写。
6. **ELABEL 字节级 split**：GBK trail byte 0x40-0xFE 含 '|'（0x7C），整段解码会把「截断的 lead byte+分隔符」合成汉字吞掉管道符。这是 u_disk 仓库 681a7e6 修复的教训，Rust 版原生实现。
7. **golden 三件套**（vectors/parse_golden/convert_golden）：Python 生成 → Rust include_str! 对拍。这是本项目正确性的根基，改任何解析/加密代码后必须 cargo test 全绿才算数。
8. **SBOX/SBOX2/LBA6_TEMPLATE 用脚本从 Python 提取生成**（不手抄）——手抄 256 值必错，已用脚本+断言校验与源一致。
9. **fmt_gb 整数四舍五入**：`(bytes+5e6)/1e7 as f64 /100.0`；曾犯整数除法丢小数 bug（12474/100=124），有单测钉死。

## 5. 已知坑（接手必读）

- **shell cwd 会被重置**（本会话曾因此在错误仓库执行 git reset——已修复无损失）。跨目录 git 操作务必显式 `cd`。
- `plist::Value::from_reader` 需要 `Seek`——`&[u8]` 要包 `std::io::Cursor`。
- vectors.json **不含 LBA0**（只 4/6/7/8/9/11/12）；convert_golden.json 专门补了 `raw0` 字段。
- 盘状态判定的边界：2 条 entry 且 MBR 首分区是 Boot 小分区 → 判 Encrypted（自愈恢复态，可重改造）。
- `disk_map` 尾部区域用 CHS 基准（`total/16065*16065`），与 u_disk 采集脚本口径一致；sectormanage 理论口径用物理 size，两者在多数盘上重合。
- 空盘/设备离线时 `list_disks` 返回空是正确行为。2026-08-28 调试中设备曾从 `disk4` 离线，重新出现后变为 `disk6`；不要缓存裸 `diskN` 身份，也不要把离线期间的空 ioreg 输出误判成解析回归。
- 严格入口（概览/改造计划）使用 `identify_checked`，会保留“读盘权限/VID-PID/容量/LBA11/EDPF”具体错误；扇区页等可选解密仍用宽松 `identify()`。
- **不要用 sudo/root 直接 open raw 盘代替 authopen**：本机 macOS 26 已实测 root 子进程仍可得到 EPERM；readonly 与 O_RDWR 都应通过 authopen SCM_RIGHTS FD。O_RDWR 必须先卸载整盘，否则 authopen 会失败。
- tauri.conf.json 的 `bundle.icon` 为空数组，`generate_context!` 仍要求 `icons/icon.png` 存在（已放占位图标）。
- **历史提交残留**：parse_golden.json/convert_golden.json 曾误入 a9e79e8/5b755c0 两个历史提交（真实盘扇区 hex，私有库风险低）；b6d13cd 起已移出索引并 gitignore。若仓库将来转公开，须先用 `git filter-repo` 清历史。**生成脚本在 tools/，任何机器可重生成 golden。**
- u_disk 主仓库有完整项目记忆（`~/.claude/projects/-Users-zhangyuxi-Desktop-u-disk/memory/MEMORY.md`），逆向结论的原始出处都在那里。

## 6. 接手后怎么干活

```bash
cd /Users/zhangyuxi/edpopen
git switch fix/robust-device-identification
git status && git log --oneline -5

# 开发循环
cd src-tauri && cargo test                # 当前 13/13 必须绿
diskutil list external physical           # 先确认当前 diskN，盘号会随重插变化
cargo run -- --analyze 6                  # 2026-08-28 真盘基线：成功；raw EACCES 时由 authopen 请求只读授权
cargo tauri dev                           # GUI 走查(五页签)
# 任务7真盘写入验收（当前尚未执行真实写入）:
#   1. 每次先 diskutil list external physical 获取最新 diskN，再 --analyze 确认 status=encrypted
#   2. GUI 改造页重新预览；apply 会再次核验 VID/PID+容量+device_id+LBA4唯一ID+Encrypted
#   3. 授权后写入核心自动 unmount → authopen O_RDWR → 备份 → 写 → 同FD回读
#   4. 成功后再 --analyze 当前盘号，应变 nopwd；备份落在 ~/Library/Application Support/EDPOpen/backups
```

优先级：任务4已完成；下一步是 **任务7真盘写入闭环**（先确认当前 diskN 与 `status=encrypted`，再执行备份→写入→回读）→ 任务8编辑器 → 任务9 → 任务10打包。

## 7. 环境快照

- rustc 1.97.1 / cargo 1.97.1 / node v26.4.0 / npm 11.17.0 / Xcode CLT（/Library/Developer/CommandLineTools）
- `cargo tauri` CLI v2 已装（~/.cargo/bin）
- gh 已登录 Evolution404；仓库 PRIVATE
- 对拍基准在 u_disk 仓库（路径见 PLAN §1），sudo 密码问用户（不要写进任何文件）
