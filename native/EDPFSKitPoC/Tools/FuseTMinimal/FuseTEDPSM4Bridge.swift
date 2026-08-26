import Darwin
import Foundation

private enum EDPSM4BridgeError: Error, CustomStringConvertible {
    case usage(String)
    case invalid(String)

    var description: String {
        switch self {
        case .usage(let message), .invalid(let message):
            return message
        }
    }
}

/// Adapts the existing native EDP random-access decrypt reader to the generic
/// single-file FUSE-T transport. No plaintext image is materialized: every RPC
/// read is fulfilled from O_RDONLY|O_CLOEXEC encrypted storage via pread + SM4.
private final class EDPSM4Backing: FuseTReadBacking {
    private let reader: EDPEncryptedPartitionReader
    let size: Int64

    init(cipherPath: String, key: [UInt8]) throws {
        let raw = try EDPFileRawDevice(path: cipherPath, writable: false)
        guard let byteCount = raw.sizeBytes,
              byteCount > 0,
              byteCount <= UInt64(Int64.max),
              byteCount % 16 == 0 else {
            throw EDPSM4BridgeError.invalid("encrypted backing must be positive, Int64-sized and SM4 aligned")
        }

        let descriptor = EDPVolumeDescriptor(
            partitionType: 2,
            startSector: 0,
            sizeBytes: byteCount,
            algorithm: 2,
            fileKey: key,
            passwordCRC: 0,
            keyCRC: EDPCrypto.crc32Bare(key)
        )
        reader = try EDPEncryptedPartitionReader(raw: raw, descriptor: descriptor)
        size = Int64(byteCount)
    }

    func pread(offset: Int64, length: Int) throws -> Data {
        guard offset >= 0, length >= 0 else {
            throw EDPSM4BridgeError.invalid("negative read offset/length")
        }
        guard offset < size, length > 0 else { return Data() }
        let wanted = min(Int64(length), size - offset)
        return try reader.readExact(at: UInt64(offset), length: Int(wanted))
    }
}

private struct EDPSM4Arguments {
    let cipherPath: String
    let key: [UInt8]
    let mountpoint: String
    let volumeName: String
}

private func parseHexKey(_ text: String) throws -> [UInt8] {
    guard text.count == 32 else {
        throw EDPSM4BridgeError.usage("--sm4-key must contain exactly 32 hex characters")
    }
    var output = [UInt8]()
    output.reserveCapacity(16)
    var index = text.startIndex
    for _ in 0..<16 {
        let next = text.index(index, offsetBy: 2)
        guard let value = UInt8(text[index..<next], radix: 16) else {
            throw EDPSM4BridgeError.usage("--sm4-key contains non-hex characters")
        }
        output.append(value)
        index = next
    }
    return output
}

private func parseEDPSM4Arguments() throws -> EDPSM4Arguments {
    var cipherPath: String?
    var key: [UInt8]?
    var mountpoint: String?
    var volumeName = "EDP SM4 Raw Transport"
    let args = CommandLine.arguments
    var index = 1

    while index < args.count {
        switch args[index] {
        case "--backing":
            index += 1
            guard index < args.count else { throw EDPSM4BridgeError.usage("--backing requires a path") }
            cipherPath = args[index]
        case "--sm4-key":
            index += 1
            guard index < args.count else { throw EDPSM4BridgeError.usage("--sm4-key requires a value") }
            key = try parseHexKey(args[index])
        case "--mountpoint":
            index += 1
            guard index < args.count else { throw EDPSM4BridgeError.usage("--mountpoint requires a path") }
            mountpoint = args[index]
        case "--volume-name":
            index += 1
            guard index < args.count else { throw EDPSM4BridgeError.usage("--volume-name requires a value") }
            volumeName = args[index]
        default:
            throw EDPSM4BridgeError.usage("unknown argument: \(args[index])")
        }
        index += 1
    }

    guard let cipherPath, let key, let mountpoint else {
        throw EDPSM4BridgeError.usage(
            "usage: FuseTEDPSM4Bridge --backing <encrypted-file> --sm4-key <32-hex-key> --mountpoint <dir> [--volume-name <name>]"
        )
    }
    return EDPSM4Arguments(cipherPath: cipherPath, key: key, mountpoint: mountpoint, volumeName: volumeName)
}

@main
private enum FuseTEDPSM4BridgeMain {
    static func main() {
        do {
            let args = try parseEDPSM4Arguments()
            let backing = try EDPSM4Backing(cipherPath: args.cipherPath, key: args.key)
            print("BACKING_MODE=EDP_SM4_RANDOM_ACCESS")
            print("PLAINTEXT_CACHE=none")
            fflush(stdout)
            try runFuseTBridge(backing: backing, mountpoint: args.mountpoint, volumeName: args.volumeName)
        } catch {
            fputs("FuseTEDPSM4Bridge: \(error)\n", stderr)
            exit(1)
        }
    }
}
