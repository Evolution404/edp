# usbcore 构建入口
.PHONY: build test test-integration lint fmt docs install bundle clean

# 默认并行构建全部 crate
build:
	cargo build --workspace

# 单元测试（纯算法层，无需 root / macFUSE）
test:
	cargo test --workspace

# 集成测试（需要 macOS + macFUSE + sudo；合成盘全链路）
test-integration:
	sudo cargo test --workspace -- --ignored

# CI 同款门禁：格式 + clippy
lint:
	cargo fmt --all -- --check
	cargo clippy --workspace --all-targets -- -D warnings

fmt:
	cargo fmt --all

# 构建并打开 rustdoc
docs:
	cargo doc --workspace --no-deps

# 安装 daemon（需要 sudo：launchd plist + /usr/local/libexec）
install:
	sudo target/release/usbcore daemon install

# 打包 .app（M4）
bundle:
	cd gui && npm ci && npx tauri build

clean:
	cargo clean
