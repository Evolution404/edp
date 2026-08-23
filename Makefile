# usbcore 构建入口
.PHONY: build test test-integration lint fmt docs install bundle gui clean

# 默认并行构建全部内核 crate（GUI 独立，见 gui 目标）
build:
	cargo build --workspace

# 单元测试（纯算法层，无需 root / macFUSE）
test:
	cargo test --workspace

# 集成测试（需要 macOS + macFUSE + sudo；合成盘全链路）
test-integration:
	sudo cargo test --workspace -- --ignored

# CI 同款门禁：格式 + clippy（内核 workspace）
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

# GUI：前端依赖 + 前端构建 + Rust 后端（独立 workspace）
gui:
	cd gui && npm ci && npm run build && cargo build --manifest-path src-tauri/Cargo.toml

# 打包 .app（产物在 gui/src-tauri/target/release/bundle/；usbcore 一并装入 .app）
bundle:
	cargo build --release -p usbcore
	cd gui && npm ci && npx tauri build
	cp target/release/usbcore "gui/src-tauri/target/release/bundle/macos/EDP USB Client.app/Contents/MacOS/usbcore"

clean:
	cargo clean
