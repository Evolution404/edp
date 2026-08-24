# 性能基准与验收状态

测试日期：2026-08-24，Apple Silicon macOS，macFUSE 5.2.0。所有吞吐均使用确定性不可压缩数据；`read-write` 在读取阶段逐块校验。HIKSEMI 通过厂商、VID/PID 和序列号 `7A6726BC6646D8C2` 三重确认后才允许裸写。

## HIKSEMI 裸设备基线

| 负载 | 写入 | 读取 | 写 P95 / P99 | 读 P95 / P99 | 校验 |
|---|---:|---:|---:|---:|---|
| 32 GiB，1 MiB，QD1，顺序 | 96.8 MB/s | 196.2 MB/s | 22.2 / 206.0 ms | 6.7 / 9.7 ms | 通过 |
| 4 GiB，1 MiB，QD4，顺序 | 232.2 MB/s | 383.8 MB/s | 17.5 / 31.4 ms | 13.2 / 16.8 ms | 通过 |
| 1 GiB，4 KiB，QD8，随机 | 2,198 IOPS | 5,112 IOPS | 5.9 / 10.1 ms | 3.0 / 6.3 ms | 通过 |

32 GiB QD1 揭示了闪存持续写入的真实稳态：短时缓存阶段接近 200 MB/s，但垃圾回收导致 P99 达到 206 ms。不能用短文件结果替代此基线。

## 原生文件系统基线

HIKSEMI 重新格式化为 ExFAT 后：

- 4 GiB、1 MiB、QD1 顺序文件读写约 303/316 MB/s。
- 1 GiB、4 KiB、QD8 随机持久化写约 1,007 IOPS，读约 5,697 IOPS，完整校验通过。
- 测试文件删除后，`fsck_exfat` 返回文件系统正常。

## EDP 实盘结果

Lexar EDP 交换区使用 iBoysoft NTFS。只创建并删除独立隐藏测试文件，没有裸写或重新格式化数据盘。

| 指标 | 优化前 | 优化后 |
|---|---:|---:|
| 1 GiB 顺序冷读 | 20.9 MB/s | 178.2 MB/s（重新挂载，校验通过） |
| 1 GiB 持久化顺序写 | 未建立同口径基线 | 135.9 MB/s |
| 自动挂载总耗时 | 3.700 s | 最好 0.660 s |
| 正常卸载 | — | 1.43–1.48 s |
| 1 MiB SM4 加/解密 | 约 296 MB/s（旧批量后端） | 711/678 MB/s |

本轮定位并修复了自动与手动挂载竞态：同一个 Lexar 交换区此前可能同时创建两个 bridge（`/Volumes/交换区` 与 `/Volumes/交换区 1`），竞争同一裸设备时实测仅有 37.4/43.6 MB/s。现在同盘同分区的挂载请求幂等返回现有 session，自动与手动挂载共用同一物理盘进行中锁。

最终 1 GiB 读取完成确定性数据逐块校验；iBoysoft 不支持文件级 `fsync`，诊断工具使用 macOS `sync` 屏障并将耗时计入写吞吐。bridge 正常卸载仍直接对底层裸设备执行一次持久化屏障。

严格冷读需要分两阶段执行，避免紧接写入后命中 bridge 页缓存：

```bash
# 第一阶段：创建确定性测试文件并持久化写入
target/release/usbcore perf file '/Volumes/交换区/.edp-vault-benchmark.tmp' \
  --mode write --gib 1 --block-kib 1024 --queue-depth 1 \
  --access-pattern sequential --filesystem iboysoft-ntfs \
  --layer mounted-filesystem --destructive --json

# 正常卸载交换区并重新挂载后执行第二阶段
target/release/usbcore perf file '/Volumes/交换区/.edp-vault-benchmark.tmp' \
  --mode read --verify --gib 1 --block-kib 1024 --queue-depth 1 \
  --access-pattern sequential --filesystem iboysoft-ntfs \
  --layer mounted-filesystem --json
```

`read-write` 模式仍适合单次写入加即时读取校验，但即时读取不再标注为冷读。

## 尚未通过的验收门槛

当前不能宣告“同盘同文件系统原生速度 85%”已经通过：HIKSEMI 尚未制作同格式的 EDP+iBoysoft NTFS 测试卷，因此缺少严格的同盘 A/B 对照。Finder 路径仍受 SMAppService 调度、DiskImages 和 iBoysoft 请求模型影响。

若同盘 A/B 后仍低于 85%，下一架构门槛是替换 DiskImages/文件系统驱动之间的虚拟块设备后端，而不是放宽落盘语义或增加不安全的延迟写回。
