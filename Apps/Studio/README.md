# EDP Studio

EDP Studio 是面向 macOS 26+ 的原生 EDP 磁盘分析、扇区查看与维护工具。正式产品使用 SwiftUI/AppKit、原生 XPC Raw Broker 和共享 `Packages/EDPCore`，当前树不再包含 Tauri/WebView/Rust 产品实现。

## 产品职责

- 识别 EDP 外置磁盘与设备身份。
- 浏览磁盘布局和 LBA0–13 元数据区域。
- 以 raw / 解码视图查看扇区和字段语义。
- 为后续编辑、备份、恢复和格式转换提供原生工作台。
- 通过 root-owned Raw Broker 获取受控 raw-device 能力，App 本身不以 root 身份运行。

## 架构

```text
Apps/Studio/native/EDPOpenNative
        │
        ├── SwiftUI / AppKit UI
        ├── Raw Broker XPC client
        └── import EDPCore
                 │
                 ▼
Packages/EDPCore
        ├── EDP crypto
        ├── metadata / identity
        └── sector decoder
```

`EDPCore` 是 EDP 格式和密码学的唯一共享真源；EDP Studio 不再维护第二份 Rust/Crypto 实现。

## 产品身份

```text
App display/product name: EDP Studio
Bundle ID:                com.edp.studio
Installed App path:       /Applications/EDP Studio.app
App executable:           /Applications/EDP Studio.app/Contents/MacOS/EDP Studio

Raw Broker ID:            com.edp.studio.rawbroker
Mach service:             com.edp.studio.rawbroker
Raw Broker path:          /Library/PrivilegedHelperTools/com.edp.studio.rawbroker
LaunchDaemon plist:       /Library/LaunchDaemons/com.edp.studio.rawbroker.plist
```

旧 `EDPOpen.app`、`com.evolution404.edpopen` 与 `com.evolution404.edpopen.rawbroker` 只存在于 Git 历史中。升级安装会先验证新的签名产物，再停用并清理旧身份。

## 统一本机签名

EDP Studio 与 EDP Drive 使用同一张长期 self-signed Code Signing 证书：

```text
Identity: EDP Project Code Signing
Certificate SHA-256: D9142CE44ABCB5DD662DF9621D48A88C88EDBCB0392D3C74EBACBB1292B7B5A7
Certificate leaf/root SHA-1: 040b5488fb2b6c02b0786e76b674cb4460658ca2
Validity: 2026-08-29 .. 2046-08-24
```

私钥只保存在当前用户 `login.keychain-db`，仓库不保存 PEM/P12。App 与 Raw Broker 使用固定 identifier + 同一 leaf certificate 的双向 XPC requirement；Broker 同时校验固定安装路径、root owner 和 group/world 不可写。

## 构建与安装

从 monorepo 根目录进入 Studio 原生工程：

```bash
cd Apps/Studio
native/EDPOpenNative/Scripts/build-native.sh
sudo /bin/bash native/EDPOpenNative/Scripts/install-native.sh
/bin/bash native/EDPOpenNative/Scripts/verify-installed-native.sh
```

Release 构建产物：

```text
EDP Studio.app
EDPStudioRawBroker
```

Xcode build phase 会直接构建 monorepo 内的 `Packages/EDPCore`，不需要跨仓库 checkout、Git revision pin 或 Deploy Key。

XPC signing contract 可单独验证：

```bash
native/EDPOpenNative/Scripts/verify-peer-signing-contract.sh
```

该测试不会修改用户 trust store 或 DefaultKeychain/SearchList。

## 历史

旧 EDPOpen 的 Tauri/WebView/Rust 实现和旧 FDA Raw Broker POC 已从当前树删除，但完整历史仍保留在 monorepo Git 图中，可通过 Git 历史追溯。当前开发只以原生 macOS 路径为准。
