# 开发指南

## 构建环境

- macOS 13+、Xcode Command Line Tools
- Rust stable（`rustup`，本仓库 `rust-toolchain.toml` 锁定）
- Node 22+（仅 GUI / M3）
- macFUSE（集成测试与实盘验收需要）

## 常用命令

```bash
make build              # 构建全部 crate
make lint               # fmt --check + clippy -D warnings（CI 同款）
make test               # 单元测试（无需 root）
make test-integration   # 集成测试（sudo + macFUSE，合成盘全链路）
# 在线模式协议测试（无需 root / macFUSE）：启动临时 daemon + CLI 走 RPC
cargo test -p usbcore --test online_mode
make docs               # rustdoc
```

## 代码结构

见 [ARCHITECTURE.md](ARCHITECTURE.md)。约定：

- 库 crate 错误用 `thiserror`，二进制用 `anyhow`
- 日志统一 `tracing`；密钥材料一律 `SecretKey16`（zeroize，Debug 脱敏）
- 注释中文；公开 API 全 rustdoc
- Conventional Commits：`feat:` / `fix:` / `test:` / `docs:` / `refactor:` / `chore:`

## 测试数据

- `fixtures/real_disks/`：两块真实盘采集的原始扇区（**敏感，勿外传**）
- `fixtures/golden/`：Python 参考实现一次性离线生成的黄金期望值（仅数据文件，项目零 Python 依赖）
- 合成盘由集成测试运行时用 edp-core 自行构造

## 扩展指引

- 新增 algo 支持：`edp-core/src/lba12.rs` 的解包分发处加分支 + `edp_aes`/`sm4_ecb` 对应原语
- 新增 RPC 方法：`edp-proto` 类型 + `usbcore/daemon` 处理器 + `docs/PROTOCOL.md` 同步
