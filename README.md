# edp-core

Shared native EDP format/crypto core for `edp-usb-vault` and `edpopen`.

## Scope

`edp-core` is platform-neutral format/crypto code. It must not own macOS raw-device authorization, Disk Arbitration, XPC, macFUSE/FSKit, Finder integration, Keychain storage, or app UI.

Current v0.1 performance-critical surface:

- bare reflected EDP CRC32
- SM4-ECB context with caller-owned/in-place buffers
- low-latency single-core path for small I/O
- automatic 4-worker parallel path for buffers >= 256 KiB
- static `libEDPCore.a` + Swift module for direct `swiftc` consumers

The legacy metadata/A6B0/A7F0/rolling-XOR implementations remain in the two products only as migration references until their golden vectors are moved here and the duplicate implementations are deleted.

## Performance contract

The encrypted filesystem hot path must remain faster than the physical USB I/O path. On the development M1 Pro, release benchmark results for the current C T-table backend are approximately:

- 64 KiB single-core: 437 MiB/s
- 1 MiB automatic 4-worker: 1.49 GiB/s
- 64 MiB automatic 4-worker: 1.62 GiB/s

The Swift API decrypts/encrypts caller-owned buffers in place, so the product hot path does not need `Data -> [UInt8] -> Data` conversion copies.

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -c release
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run -c release edp-core-bench
```

## Direct static linking

Build the static product:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release --product EDPCore
```

For Apple Silicon the outputs are under:

```text
.build/arm64-apple-macosx/release/libEDPCore.a
.build/arm64-apple-macosx/release/Modules/EDPCore.swiftmodule
```

A direct `swiftc` consumer uses the release `Modules` directory, `Sources/CEDPCore/include`, and `-L ... -lEDPCore`.
