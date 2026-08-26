import Darwin
import Foundation

private enum EDPUnlockBridgeError: Error, CustomStringConvertible {
    case usage(String)
    case invalid(String)

    var description: String {
        switch self {
        case .usage(let message), .invalid(let message):
            return message
        }
    }
}

/// Product-style backing for the minimal FUSE-T transport.
///
/// Unlike the lower-level SM4 regression bridge, this path never accepts a
/// derived file key. It opens the whole EDP device/image read-only and executes
/// the existing LBA11 -> device ID -> LBA12 -> password/file-key -> partition
/// descriptor unlock pipeline before serving random-access decrypted bytes.
private final class EDPUnlockedBacking: FuseTReadBacking {
    private let raw: EDPFileRawDevice
    private let unlocked: EDPUnlockedReadOnlyVolume
    let size: Int64

    init(
        rawPath: String,
        vidHex: String,
        pidHex: String,
        deviceSizeBytes: UInt64,
        passwordBytes: [UInt8],
        partitionType: UInt32
    ) throws {
        raw = try EDPFileRawDevice(
            path: rawPath,
            declaredSizeBytes: deviceSizeBytes,
            writable: false
        )
        unlocked = try EDPReadOnlyUnlock.unlock(
            raw: raw,
            request: EDPReadOnlyUnlockRequest(
                vidHex: vidHex,
                pidHex: pidHex,
                deviceSizeBytes: deviceSizeBytes,
                passwordBytes: passwordBytes,
                partitionType: partitionType
            )
        )
        guard unlocked.partitionSizeBytes > 0,
              unlocked.partitionSizeBytes <= UInt64(Int64.max) else {
            throw EDPUnlockBridgeError.invalid("unlocked partition size exceeds FUSE-T bridge range")
        }
        size = Int64(unlocked.partitionSizeBytes)
    }

    var deviceID: String { unlocked.deviceID }
    var partitionType: UInt32 { unlocked.partitionType }
    var partitionStartSector: UInt64 { unlocked.partitionStartSector }
    var partitionSizeBytes: UInt64 { unlocked.partitionSizeBytes }
    var algorithm: UInt32 { unlocked.algorithm }

    func pread(offset: Int64, length: Int) throws -> Data {
        guard offset >= 0, length >= 0 else {
            throw EDPUnlockBridgeError.invalid("negative read offset/length")
        }
        guard offset < size, length > 0 else { return Data() }
        let wanted = min(Int64(length), size - offset)
        return try unlocked.block.read(at: UInt64(offset), length: Int(wanted))
    }
}

private struct EDPUnlockArguments {
    let rawPath: String
    let vidHex: String
    let pidHex: String
    let deviceSizeBytes: UInt64
    let partitionType: UInt32
    let passwordFile: String
    let mountpoint: String
    let volumeName: String
}

private func parseEDPUnlockArguments() throws -> EDPUnlockArguments {
    var values = [String: String]()
    var volumeName = "EDP Unlocked Raw Transport"
    let args = CommandLine.arguments
    var index = 1

    while index < args.count {
        let key = args[index]
        guard key.hasPrefix("--") else {
            throw EDPUnlockBridgeError.usage("unexpected argument: \(key)")
        }
        index += 1
        guard index < args.count else {
            throw EDPUnlockBridgeError.usage("\(key) requires a value")
        }
        if key == "--volume-name" {
            volumeName = args[index]
        } else {
            values[key] = args[index]
        }
        index += 1
    }

    guard let rawPath = values["--backing"],
          let vidHex = values["--vid"],
          let pidHex = values["--pid"],
          let deviceSizeText = values["--device-size"],
          let deviceSizeBytes = UInt64(deviceSizeText),
          let partitionTypeText = values["--partition-type"],
          let partitionType = UInt32(partitionTypeText),
          let passwordFile = values["--password-file"],
          let mountpoint = values["--mountpoint"] else {
        throw EDPUnlockBridgeError.usage(
            "usage: FuseTEDPUnlockBridge --backing <whole-edp-device-or-image> --vid <hex> --pid <hex> --device-size <bytes> --partition-type <2|4> --password-file <file> --mountpoint <dir> [--volume-name <name>]"
        )
    }
    guard [UInt32(2), 4].contains(partitionType), deviceSizeBytes > 0 else {
        throw EDPUnlockBridgeError.usage("invalid device size or partition type")
    }

    return EDPUnlockArguments(
        rawPath: rawPath,
        vidHex: vidHex,
        pidHex: pidHex,
        deviceSizeBytes: deviceSizeBytes,
        partitionType: partitionType,
        passwordFile: passwordFile,
        mountpoint: mountpoint,
        volumeName: volumeName
    )
}

private func consumePasswordFile(_ path: String) throws -> [UInt8] {
    let url = URL(fileURLWithPath: path)
    var data = try Data(contentsOf: url)
    defer { try? FileManager.default.removeItem(at: url) }
    while let last = data.last, last == 0x0a || last == 0x0d {
        data.removeLast()
    }
    guard !data.isEmpty else {
        throw EDPUnlockBridgeError.invalid("password file is empty")
    }
    return [UInt8](data)
}

@main
private enum FuseTEDPUnlockBridgeMain {
    static func main() {
        do {
            let args = try parseEDPUnlockArguments()
            let password = try consumePasswordFile(args.passwordFile)
            let backing = try EDPUnlockedBacking(
                rawPath: args.rawPath,
                vidHex: args.vidHex,
                pidHex: args.pidHex,
                deviceSizeBytes: args.deviceSizeBytes,
                passwordBytes: password,
                partitionType: args.partitionType
            )
            print("BACKING_MODE=EDP_UNLOCK_RANDOM_ACCESS")
            print("RAW_ACCESS=O_RDONLY|O_CLOEXEC")
            print("PLAINTEXT_CACHE=none")
            print("DEVICE_ID=\(backing.deviceID)")
            print("PARTITION_TYPE=\(backing.partitionType)")
            print("PARTITION_START_SECTOR=\(backing.partitionStartSector)")
            print("PARTITION_SIZE=\(backing.partitionSizeBytes)")
            print("ALGORITHM=\(backing.algorithm)")
            fflush(stdout)
            try runFuseTBridge(
                backing: backing,
                mountpoint: args.mountpoint,
                volumeName: args.volumeName
            )
        } catch {
            fputs("FuseTEDPUnlockBridge: \(error)\n", stderr)
            exit(1)
        }
    }
}
