# EDP 格式（逆向知识浓缩）

> 状态：M0 骨架。完整逆向过程见 `u_disk/analyze/`（外部，不随本项目分发）；本文档自包含项目所需的全部格式知识。

## 磁盘布局（前 13 扇区保留区 + 数据区）

| LBA | 内容 | 加密方式 |
|---|---|---|
| 0-3 | MBR/分区表 | 明文 |
| 4 | `$$$<序列号>$$$` 标识 | 明文（EDP 盘预筛特征） |
| 7 | 旧格式 EDPF（64B 条目 ×3） | 滚动 16 位 XOR（K0 = f(device_id)） |
| 11 | PDKB 块（device_id 载体） | 魔改 AES（key = CRC32(rand‖VID‖PID‖DiskSize)） |
| 12 | 新格式 EDPF（96B 条目 ×3） | A6B0 魔改 AES（key = CRC32(device_id)） |
| 13+ | 数据分区（SM4-ECB） | file_key |

## EDPF 条目（0x60B，LBA12）

| 偏移 | 字段 |
|---|---|
| +0x00 | magic `EDPF` |
| +0x0C | partition type（1=Boot / 2=Share / 4=Encrypt） |
| +0x18 | start_sector (QWORD) |
| +0x28 | size_bytes (QWORD) |
| +0x30 | CRC32(password)（裸 CRC32） |
| +0x34 | CRC32(file_key) |
| +0x38 | wrapped salt (16B) |
| +0x58 | algo（2=SM4，唯一支持） |

## 密钥链

```
device_id（LBA11 解出或 identify 候选）
  → CRC32(device_id) ──解密──> LBA12 明文（EDPF 条目）
file_key = SM4_Decrypt(salt16, MD5("LtSWi[2f)j"))   ← 路径A（默认密码，实测闭合）
file_key = SM4_Decrypt(salt16, MD5(password))       ← 路径B（修改后密码，待实测校准）
数据分区 = SM4-ECB(file_key)
```

## 密码验证双路径（重要）

默认密码 `0000aaaa`（制盘状态）与**用户修改后**的密码逻辑不一致：

- **路径A（默认密码）**：`crc32_bare(password) == entry+0x30`，file_key 用固定种子 `LtSWi[2f)j` 解出（与密码无关）
- **路径B（修改后）**：按 UserLogin 逆向（`key_material = 用户密码`）——`SM4_Decrypt(salt, MD5(password))` 的结果需 CRC 闭环
- 实现：先 A 后 B，任一闭环即成功；路径B 暂无改密盘黄金数据，待实测校准

## device_id 三级发现

1. 调用方显式传入
2. LBA11 PDKB 标准路径（VID/PID + DiskSize；**对部分盘失效**，如本项目 disk5）
3. identify_disk 候选兜底（ioreg vendor/product/revision 拼装多候选逐个试解）

## 实测样本

| | disk4（Lexar） | disk5（SanDisk Ultra 3.0） |
|---|---|---|
| device_id | `disk&ven_lexar&prod_usb_flash_drive` | `disk&ven_sandisk&prod_ultra_usb_3.0&rev_1.00` |
| 发现路径 | LBA11 | identify 兜底 |
| key_crc | 418c1a0c | 67f6fdf1 |
| 密码 | 0000aaaa | 0000aaaa |
| 文件系统 | EXFAT（读写） | **NTFS**（开发机装「赤友 NTFS」驱动故可写；原生 macOS 只读） |
