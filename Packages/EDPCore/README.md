# EDPCore

Shared native EDP format/crypto package for **EDP Drive** and **EDP Studio** in this monorepo.

## Scope

`EDPCore` is platform-neutral format/crypto code. It must not own macOS raw-device authorization, Disk Arbitration, XPC, macFUSE/FSKit, Finder integration, Keychain storage, or app UI.

Current shared surface:

- bare reflected EDP CRC32
- SM4-ECB context with caller-owned/in-place buffers
- low-latency single-core path for small I/O
- adaptive parallel path: serial below 64 KiB, up to 4 workers at 64 KiB, up to 6 workers from 128 KiB
- EDP A6B0 metadata decrypt and rolling XOR
- LBA4/LBA6 format decoding
- native 512-byte sector decoder for LBA0/4/6/7/8/9/11/12 with structured field semantics
- static `libEDPCore.a` + Swift module for direct `swiftc` consumers

Production App code must consume this package as the single EDP format/crypto implementation. Cross-repository revision pins and Deploy Keys are no longer part of the architecture.

## Performance contract

The encrypted filesystem hot path must remain faster than the physical USB I/O path. On the development M1 Pro, release benchmark results for the current C T-table backend are approximately:

- 64 KiB automatic 4-worker: about 0.79 GiB/s
- 128 KiB automatic 6-worker: about 1.10 GiB/s
- 256 KiB automatic 6-worker: about 1.35 GiB/s
- 1 MiB automatic 6-worker: about 1.7 GiB/s
- 64 MiB automatic 6-worker: about 2.0 GiB/s

The Swift API decrypts/encrypts caller-owned buffers in place, so the product hot path does not need `Data -> [UInt8] -> Data` conversion copies.

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/EDPCore -c release
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run --package-path Packages/EDPCore -c release edp-core-bench
```

## Direct static linking

Build the static product:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --package-path Packages/EDPCore -c release --product EDPCore
```

For Apple Silicon the outputs are under:

```text
.build/arm64-apple-macosx/release/libEDPCore.a
.build/arm64-apple-macosx/release/Modules/EDPCore.swiftmodule
```

A direct `swiftc` consumer uses the release `Modules` directory, `Sources/CEDPCore/include`, and `-L ... -lEDPCore`.
