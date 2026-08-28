# EDPOpen 项目计划

> 本文档是项目的权威计划。执行进度与接手指南见 [HANDOFF.md](HANDOFF.md)。

## 1. 项目定位

cems 加密 U 盘分析与免密改造的桌面工具。Tauri 2 架构（Rust 后端 + WebView 前端，原生 JS 无框架无构建）。

**对拍基准**（不复制进本仓库，路径按本机）：
- `/Users/zhangyuxi/Desktop/u_disk/nopwd_tool/nopwd.py` — 免密改造 CLI（加密盘→免密盘 5 扇改造，内网实测成功）
- `/Users/zhangyuxi/Desktop/u_disk/analyze/scripts/read_metadata.py` — 元数据解析 CLI（1116 行）
- `/Users/zhangyuxi/Desktop/u_disk/nopwd_tool/backup/` — 6 个真实盘的 LBA0-13 备份（测试向量来源，含 .md5）

**原则**：Rust 的一切输出与 Python 版逐字节对拍；真实盘数据不入库（.gitignore 已排除 *.bin/*.img/vectors.json/parse_golden.json/convert_golden.json）。

## 2. 架构

```
src/                    前端(原生 JS)
  index.html            单页: 盘选择条 + 五页签(概览/盘地图/扇区/改造/备份)
  app.js                页签/tooltip/hexdump/盘地图/改造页逻辑
  style.css             深色主题, 7 类语义色
src-tauri/
  src/crypto.rs         加密原语(全部从 nopwd.py 移植, 向量对拍)
  src/parser.rs         MBR/EDPF/LBA4·6·8·9·11 解析 + FieldRow 字段表 + 状态判定
  src/disk.rs           盘枚举(diskutil)/ioreg INQUIRY/device_id 两候选识别/扇区读
  src/convert.rs        免密改造 5 扇生成 + --write-sectors 提权写入器
  src/commands.rs       Tauri 命令门面(analyze_disk/read_sector/disk_map/convert_preview/apply_convert)
  tests/                向量与 golden 对拍测试(见 §5)
tools/                  golden 生成脚本(Python, 调用对拍基准)
```

**权限模型**（macOS 实测结论）：
- 热插拔 USB 盘 `/dev/rdiskN` owner=当前用户只读 → **读盘（分析/浏览/备份）无需提权**
- 写盘通过 `osascript ... with administrator privileges` 拉起本程序自身二进制的
  `--write-sectors <payload.json>` 子命令（系统标准授权框，每次写入一次）
- 写入器安全约束：LBA 白名单 `[0,4,6,7,8,9,11,12,13]`；先备份 LBA0-14 → 写序铁律
  （**LBA0 最后写**，改 MBR 触发重扫锁盘）→ 逐扇回读校验 → chown 备份回用户

## 3. 功能清单

1. **盘选择**：USB 外置盘枚举 + device_id 自动识别（两候选 LBA7 EDPF magic 判真）+ 状态判定
   （标准加密盘 / 免密盘 / 已改造 / 非 cems）
2. **盘地图页**（核心可视化）：LBA0-13 十四宫格（语义色 + hover 释义 + 点击跳扇区）、
   全盘区域比例条（Share/Encrypt/空档/尾部，hover 显示 LBA 范围与含义）、尾部五区放大条、图例
3. **扇区页**：hexdump（offset+hex+ascii）+ 字段级着色（7 类语义色）+ hover 字段释义 +
   raw/dec 视图切换 + LBA 快速跳转/前后导航
4. **改造页**：预览（状态/布局/写入清单）→ 确认 → 授权写入 → 回读校验结果展示
5. **字节级编辑器**（待做）：hexdump 点击字节修改/diff 高亮/撤销/导出；**加密感知保存**——
   解密视图编辑明文，保存按 LBA 规则重加密（见 §4 重加密表）；敏感区（表尾终止符/LBA12 尾 144B/
   LBA11 rand）修改标红警示
6. **备份管理页**（待做）：列表（LBA4 labelOnlyId 终验匹配，同型号多盘不混淆）/ 还原（MD5 校验）
7. **离线模式**（待做）：拖入备份 .bin 或 dd 镜像全流程分析（规则文件名自动提取 vid/pid/secs/device_id）

## 4. 关键算法与规则（全部实测/逆向定案，勿凭直觉改）

| 项 | 规则 |
|---|---|
| CRC32 bare | init=0, poly 0xEDB88320 反射, **无 final-xor** |
| AES 变体 A6B0/a7f0 | key16=CRC32×4 ^ "EDPSECDISK200709"；counter=块号×16；counter 8B XOR 进**全部 44 轮密钥字** |
| 滚动 XOR | 16 位小端字；第 i 字 key = k0 − i(i+1)/2（非线性递减） |
| LBA7 K0 | low16(CRC32(device_id)) ^ high16(...)，整扇滚动 XOR |
| LBA12 | A6B0 仅前 368B；**尾 144B 为原始密文原样保留**（清零会触发内网 LBA0 自愈） |
| LBA6 | 固定 K0=0x4DAA；0x1FC 校验和=密文 CRC32 的 ROL1×10（对密文算，写入在加密后） |
| LBA11 | key=crc32(rand256+VID4+PID4+DiskSize8LE)；**DiskSize 双口径**（物理字节/CHS 255×63 取整，两种都试） |
| LBA4 | serial($$$头)→K0；0x18 起解 488B；**原始 0 字节保持 0**（未加密零填充） |
| EDPF 表尾终止符 | LBA7@0xC0 / LBA12@0x120，**不清零铁律**（清零→客户端结构异常→LBA0 自愈） |
| LBA7 type4 entry | 3072B 是 Region A(IIR) 指针，非加密分区大小，**写真实位置会破坏判定** |
| 0x1CA(LBA6) | 128480=A 盘实测模板值（语义未定案，非"免密标记"）；原始加密盘=Boot 扇数 |
| 盘状态判定 | LBA12 3条=标准加密盘；2条+MBR首分区==entry0(Share)大小=免密；2条+MBR Boot 小分区=自愈恢复态 |
| 备份命名 | `disk{N}_{总扇区}_vid{}_pid{}_{device_id含&}_lid{labelOnlyId}_{时间戳}.bin`；labelOnlyId=LBA4 头明文，**每盘唯一**（device_id/容量/VID/PID 同型号盘全同） |
| 容量显示 | GB(10^9) 两位小数四舍五入（整数运算防浮点误差） |
| device_id 两候选 | BOT(usbstor)含 &rev_ 长版 / UAS 短版；按当前传输模式排序后 LBA7 EDPF magic 判真 |

### 字节编辑器重加密表（保存时按 LBA）

| LBA | 明文视图 | 保存动作 |
|---|---|---|
| 0 | MBR raw | 直接写 |
| 4 | K0(serial) 滚动 XOR | 重 XOR（serial 改变则提示 key 变化） |
| 6 | K0=0x4DAA XOR | 重 XOR + 0x1FC 校验和重算（对新密文） |
| 7 | K0(device_id) XOR | 重 XOR |
| 8 | A6B0 前 368B + 尾 144B raw | 前 368B 重 A6B0 + 尾 raw 拼接 |
| 9 | A6B0 前 128B + XOR0x88 32B + 其余 raw | 分段重加密 |
| 11 | 前 256B rand(raw) + 后 256B A6B0 | 后半重 A6B0（rand/vid/pid/size 未动则 key 不变） |
| 12 | A6B0 前 368B（含终止符区）+ 尾 144B raw | 前 368B 重 A6B0 + 尾 raw 拼接 |
| 其他 | raw | 直接写 |

## 5. 测试体系

三个 golden/向量文件（gitignore，本地生成）+ 生成脚本 + cargo test：

```bash
# 重生成（在对拍基准可用的机器上）
python3 tools/gen_vectors.py --nopwd <nopwd.py> --read-metadata <read_metadata.py> \
    --backup <backup目录> --out src-tauri/tests/vectors.json
python3 tools/gen_parse_golden.py --nopwd ... --read-metadata ... --backup ... \
    --out src-tauri/tests/parse_golden.json
python3 tools/gen_convert_golden.py --nopwd ... --backup ... \
    --out src-tauri/tests/convert_golden.json

cd src-tauri && cargo test    # 当前 9/9 绿
```

| 测试 | 覆盖 |
|---|---|
| crypto 单测×3 | CRC32 已知值 / AES 往返 / XOR 自逆 |
| crypto_vectors×2 | 6 盘 × LBA4/6/7/8/9/11/12 raw↔dec 逐字节对拍；重加密还原原始密文 + LBA6 校验和与盘上一致 |
| parse_golden×1 | 6 盘解析金标准（LBA4 三件套 / LBA6 全字段含 GBK 中文 / ELABEL 全 KV / EDPF entries） |
| convert_golden×1 | 6 盘免密改造 5 扇与 nopwd.py --dir 产物逐字节一致 |

**待补测试**（原计划）：编辑重加密对拍（明文改 1 字节→重加密 vs Python 等价脚本）、真盘写入→还原闭环、提权三分支、非 cems 盘拒绝、多盘同插。

## 6. 剩余任务（优先级序）

1. **任务7 收尾**：改造页真盘端到端（授权→写入→回读）实测
2. **任务4 收尾**：disk.rs 真盘验证（enumerate/identify/read 链路，插盘后 `cargo run -- --analyze 4`）
3. **任务8**：字节级编辑器 + 加密感知重加密（表见 §4）+ 敏感区警示 + 重加密对拍测试
4. **任务9**：备份管理页（lid 终验匹配/MD5/还原走 --write-sectors）+ 离线拖拽模式
   （文件名规则 `disk\d+_(\d+)_vid(..)_pid(..)_(.+?)_lid(\d+)_(\d{8}_\d{6})\.bin` 提取参数）
5. **任务10**：打包 .app（tauri build，未签名首次右键打开；`cargo tauri icon` 生成正式图标替换占位）
6. GUI 整体验证：`cargo tauri dev` 五页签走查（盘地图着色/hover/跳转、扇区 hexdump、改造流程）

## 7. 风险与对策

- osascript 授权被管控 → 兜底提示终端命令 `sudo <app> --write-sectors <payload>`
- 未签名 app → README 注明右键打开
- GBK 解码用 encoding_rs；ELABEL 解析必须**字节级 split("||") 再逐段解码**（GBK trail byte 含 '|'，整段解码会吞管道符导致字段粘连）
- identify 每扇区查看都会跑 ioreg/diskutil（无缓存）——如卡顿再做 Identity 缓存
