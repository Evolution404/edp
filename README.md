# EDP

EDP 是面向 macOS 26+ 的 EDP 加密 U 盘原生工具套件。仓库采用 monorepo，两个 App 共用同一个 EDP 格式/密码学核心。

> **AI / 开发交接首读：** `docs/HANDOFF-2026-08-29.md`。开始工作前先 `git fetch` 并以实际 `main` 为准；不要从旧 FUSE-T / NTFS-3G / authopen 文档恢复已淘汰架构。

## 产品

### EDP Drive

路径：`Apps/Drive`

菜单栏常驻应用，负责 EDP U 盘识别、凭据管理、启动区/交换区/保密区挂载、Finder 集成和安全推出。

正式数据链：

```text
physical factory-standard encrypted EDP USB
  -> LBA0/4/7/11/12 fail-closed classification
  -> FDA embedded-service retained raw fd
  -> Packages/EDPCore
  -> macFUSE Local FSKit
  -> DiskImages2
  -> Apple filesystem stack
  -> Finder
```

### EDP Studio

路径：`Apps/Studio`

原生 SwiftUI/AppKit 磁盘分析与维护工具，负责磁盘地图、扇区查看、EDP 元数据解析以及后续编辑/备份/恢复能力。

当前产品路径不使用 Tauri、WebView 或 Rust runtime。

### EDPCore

路径：`Packages/EDPCore`

EDP 格式和密码学的唯一共享真源，包括：

- CRC32 bare
- SM4 高吞吐 block transform
- EDP A6B0/A7F0 与 rolling XOR
- device identity / metadata
- LBA/sector decode
- 共享 golden/unit tests

两个 App 不再各自维护第二份密码学实现。

## 目录

```text
Apps/
  Drive/
  Studio/
Packages/
  EDPCore/
.github/workflows/
```

原 `edp-usb-vault`、`edpopen`、`edp-core` 三个仓库的历史均保留在本仓库 Git 图中；必要的 tag-only / PR-only 历史也已附着到 monorepo。三个旧 GitHub 仓库均已删除，当前唯一开发真源是 `Evolution404/edp`。

## 品牌与产品身份

两个产品统一为：

- **EDP Drive**：`com.edp.drive`，内嵌后台服务 `com.edp.drive.service`；系统中只有 `/Applications/EDP Drive.app` 一个 Drive App。
- **EDP Studio**：`com.edp.studio`，Raw Broker / Mach service 为 `com.edp.studio.rawbroker`，安装到 `/Applications/EDP Studio.app`。

旧 `com.edp.usbvault.*`、`com.evolution404.edpopen*`、`EDP USB Vault.app`、`EDPOpen.app` 仅用于升级清理和历史追溯，不再是当前产品身份。

## 统一本机签名

两个 App 使用同一张长期 self-signed Code Signing 证书：

```text
Identity: EDP Project Code Signing
Certificate SHA-256: D9142CE44ABCB5DD662DF9621D48A88C88EDBCB0392D3C74EBACBB1292B7B5A7
Certificate leaf/root SHA-1: 040b5488fb2b6c02b0786e76b674cb4460658ca2
```

私钥只存在本机 `login.keychain-db`，仓库不保存 PEM、P12、密码或任何私钥材料。

## 本机构建

EDPCore：

```bash
swift test --package-path Packages/EDPCore -c release
```

EDP Drive：

```bash
cd Apps/Drive
EDP_APP_SIGN_IDENTITY="EDP Project Code Signing" \
EDP_SELF_SIGNED_DISTRIBUTION=1 \
EDP_SERVICE_MODE=legacy \
./installer/build-native-installer.sh artifacts
```

EDP Studio：

```bash
cd Apps/Studio
native/EDPStudioNative/Scripts/build-native.sh
```

## 开发原则

依赖方向固定为：

```text
Packages/EDPCore
       ↑
       ├── Apps/Drive
       └── Apps/Studio
```

禁止 `EDPCore` 反向依赖任一 App，也禁止 Drive 与 Studio 直接引用彼此的产品代码。平台无关的 EDP 格式语义、密码算法、key derivation 和 sector decode 应优先进入 `Packages/EDPCore`。
