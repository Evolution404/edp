# Changelog

本项目的所有显著变更记录于此。格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Added
- M0：Cargo workspace 骨架（edp-core / edp-macos / edp-proto / usbcore）
- M0：CI（macOS 全 workspace + Ubuntu edp-core 跨平台回归）、Makefile、rustfmt/clippy 门禁
- M0：文档骨架（README + docs 五篇 + CHANGELOG）
- M0：真实盘 fixture（disk4 Lexar / disk5 SanDisk）与黄金测试数据（Python 参考实现一次性离线生成，项目本身零 Python 依赖）
- edp-core：裸 CRC32（crc32_bare / crc_key / k0_from_crc）与已知值单测
