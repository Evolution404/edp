# HANDOFF — 执行记录与交接说明

> 接手者请先读 [PLAN.md](PLAN.md)（权威计划），再读本文（做到哪了 + 怎么继续）。
> 生成日期: 2026-08-28 晚。仓库: https://github.com/Evolution404/edpopen (PRIVATE)。

## 1. 进度快照

| # | 任务 | 状态 | 备注 |
|---|---|---|---|
| 1 | 项目初始化 | ✅ 完成 | 本地 `/Users/zhangyuxi/edpopen` + GitHub 私有仓库 |
| 2 | Tauri 2 骨架 + 前端 | ✅ 完成 | 编译过；GUI 窗口未人眼走查（`cargo tauri dev`） |
| 3 | crypto.rs + 向量测试 | ✅ 完成 | 逐字节对拍全绿 |
| 4 | disk.rs + 概览页 | 🟡 代码完成，**真盘未验证** | 盘拔出前没来得及跑 `--analyze`；逻辑与 nopwd.py 同构 |
| 5 | parser.rs + 扇区页 | ✅ 完成 | golden 对拍全绿（含 GBK 中文/ELABEL） |
| 6 | 盘地图页 | ✅ 完成 | 代码完整；视觉效果待 dev 走查 |
| 7 | convert.rs + 提权写入器 + 改造页 | 🟡 代码完成，**未真盘实测** | 5 扇 golden 对拍全绿；写入器/osascript/改造页已写，端到端授权流没跑过 |
| 8 | 字节编辑器 + 重加密 | ⬜ 未开始 | 重加密表在 PLAN §4 |
| 9 | 备份管理 + 离线模式 | ⬜ 未开始 | |
| 10 | 测试补全 + 打包 | ⬜ 未开始 | |

测试现状：`cd src-tauri && cargo test` → **9/9 绿**（单测 3 + crypto_vectors 2 + parse_golden 1 + convert_golden 1 + 其他 2）。

## 2. 提交历史（全部已推送）

```
f7b20a1 (HEAD) 盘地图页: LBA0-13 方格网格 + 全盘区域比例条 + 尾部放大 + 图例
5b755c0 parser 全解析 + 扇区页 hexdump + 解析 golden 对拍(8/8 绿)
ee41d94 disk.rs 枚举/识别 + parser MBR·EDPF·状态判定 + 概览页 + --analyze CLI
3328712 骨架 + crypto.rs 全量对拍测试通过
e12b5e2 EDPOpen 初始提交: 项目定位与结构规划
```

**未提交的工作树改动**（交接时点）：改造页前端(app.js/index.html) + `--write-sectors` 写入器(convert.rs) + convert_preview/apply_convert 命令 + **本 HANDOFF/PLAN 文档**。编译绿、测试绿、app.js 语法检查过，可直接提交。

## 3. 模块地图（文件 → 职责 → 关键入口）

| 文件 | 职责 | 关键函数/命令 |
|---|---|---|
| `src-tauri/src/crypto.rs` | 加密原语 | `crc32_bare` `a6b0_full/a7f0_full` `xor_rolling` `lba6_decode/lba6_checksum` `lba4_decode` |
| `src-tauri/src/parser.rs` | 解析 + 字段表 + 状态判定 | `parse_edpf(dec,stride)` `parse_mbr` `classify` `parse_elabel` `parse_lba4_info/parse_lba6_info` `lba*_fields`（FieldRow 表，扇区页着色与盘地图 tooltip 的数据源）`LBA6_TEMPLATE` |
| `src-tauri/src/disk.rs` | 盘/IO | `list_usb_disks()` `usb_vid_pid` `generate_candidates` `identify` `read_lba` |
| `src-tauri/src/convert.rs` | 改造 + 写入器 | `convert(raw0,raw6,raw7,raw9,raw12,crc,k0,size_gb)→ConvertPlan`；`write_sectors_run(payload,result)`（root 侧） |
| `src-tauri/src/commands.rs` | Tauri 命令 | `ping` `list_disks` `analyze_disk` `read_sector` `disk_map` `convert_preview` `apply_convert` |
| `src-tauri/src/main.rs` | 入口 | GUI 默认；CLI: `--analyze <N>`、`--write-sectors <payload.json>` |
| `src/app.js` | 全部前端逻辑 | `analyzeDisk` `loadDiskMap` `loadSector/renderHexdump` `loadConvertPreview`；tooltip 通用（任何元素挂 `data-tip` 即生效） |

## 4. 关键决策与为什么

1. **读免提权/写才提权**：实测 macOS 给热插拔盘 `/dev/rdiskN` owner=当前用户（只读）。分析全链无授权框；仅写入时 osascript 拉起自身 `--write-sectors`（一次授权）。写入器白名单 LBA≤13，防 payload 篡改扩大破坏面。
2. **LBA0 最后写**：写 MBR 触发 diskarbitrationd 重扫锁盘（EBUSY），nopwd.py 实测踩坑定案。写入器 open 有 15×0.2s 重试。
3. **备份先行且 chown 回用户**：root 写入器先备份 LBA0-13（md5 旁置）再写，文件 chown 回发起用户，否则用户删不动。
4. **改造拒绝条件**：状态判定非 Encrypted（已免密/非 cems）直接拒绝 apply——防重复改造和非 cems 盘误写。
5. **ELABEL 字节级 split**：GBK trail byte 0x40-0xFE 含 '|'（0x7C），整段解码会把「截断的 lead byte+分隔符」合成汉字吞掉管道符。这是 u_disk 仓库 681a7e6 修复的教训，Rust 版原生实现。
6. **golden 三件套**（vectors/parse_golden/convert_golden）：Python 生成 → Rust include_str! 对拍。这是本项目正确性的根基，改任何解析/加密代码后必须 cargo test 全绿才算数。
7. **SBOX/SBOX2/LBA6_TEMPLATE 用脚本从 Python 提取生成**（不手抄）——手抄 256 值必错，已用脚本+断言校验与源一致。
8. **fmt_gb 整数四舍五入**：`(bytes+5e6)/1e7 as f64 /100.0`；曾犯整数除法丢小数 bug（12474/100=124），有单测钉死。

## 5. 已知坑（接手必读）

- **shell cwd 会被重置**（本会话曾因此在错误仓库执行 git reset——已修复无损失）。跨目录 git 操作务必显式 `cd`。
- `plist::Value::from_reader` 需要 `Seek`——`&[u8]` 要包 `std::io::Cursor`。
- vectors.json **不含 LBA0**（只 4/6/7/8/9/11/12）；convert_golden.json 专门补了 `raw0` 字段。
- 盘状态判定的边界：2 条 entry 且 MBR 首分区是 Boot 小分区 → 判 Encrypted（自愈恢复态，可重改造）。
- `read_sector` 的 LBA11 解密：CHS 口径判断 `sz % (255*63*512)==0 && sz != sizes[0]` 有瑕疵（物理字节恰好整除 CHS 单元时会标错口径名）——只影响显示文案不影响解密结果，接手可顺手修。
- `disk_map` 尾部区域用 CHS 基准（`total/16065*16065`），与 u_disk 采集脚本口径一致；sectormanage 理论口径用物理 size，两者在多数盘上重合。
- 空盘时 `list_disks` 返回空、`analyze_disk` 报「无法识别」——这是正确行为，不是 bug。
- tauri.conf.json 的 `bundle.icon` 为空数组，`generate_context!` 仍要求 `icons/icon.png` 存在（已放占位图标）。
- **历史提交残留**：parse_golden.json/convert_golden.json 曾误入 a9e79e8/5b755c0 两个历史提交（真实盘扇区 hex，私有库风险低）；b6d13cd 起已移出索引并 gitignore。若仓库将来转公开，须先用 `git filter-repo` 清历史。**生成脚本在 tools/，任何机器可重生成 golden。**
- u_disk 主仓库有完整项目记忆（`~/.claude/projects/-Users-zhangyuxi-Desktop-u-disk/memory/MEMORY.md`），逆向结论的原始出处都在那里。

## 6. 接手后怎么干活

```bash
cd /Users/zhangyuxi/edpopen
git status && git log --oneline -3        # 应见 §2 的未提交改动
git add -A && git commit -m "改造页+写入器+交接文档" && git push

# 开发循环
cd src-tauri && cargo test                # 9/9 必须绿
cargo run -- --analyze 4                  # 插盘后 CLI 验证(任务4收尾)
cargo tauri dev                           # GUI 走查(五页签)
# 提权写入真盘测试(任务7收尾): GUI 改造页点写入, 或手工:
#   1. cargo run -- --analyze 4 确认 status=encrypted
#   2. GUI 操作(会弹系统授权框); 备份落在 ~/Library/Application Support/EDPOpen/backups
#   3. 写后 --analyze 4 应变 nopwd; 还原用备份文件 --write-sectors 走同一写入器
```

优先级：任务 7 真盘实测 → 任务 4 真盘验证 → 任务 8 编辑器 → 任务 9 → 任务 10 打包。详见 PLAN §6。

## 7. 环境快照

- rustc 1.97.1 / cargo 1.97.1 / node v26.4.0 / npm 11.17.0 / Xcode CLT（/Library/Developer/CommandLineTools）
- `cargo tauri` CLI v2 已装（~/.cargo/bin）
- gh 已登录 Evolution404；仓库 PRIVATE
- 对拍基准在 u_disk 仓库（路径见 PLAN §1），sudo 密码问用户（不要写进任何文件）
