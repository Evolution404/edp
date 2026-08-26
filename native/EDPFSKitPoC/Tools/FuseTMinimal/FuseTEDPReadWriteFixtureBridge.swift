import Darwin
import Foundation

private enum FixtureReadWriteBridgeError: Error, CustomStringConvertible {
    case usage(String)
    case invalid(String)

    var description: String {
        switch self {
        case .usage(let value), .invalid(let value): return value
        }
    }
}

private struct FixtureArguments {
    let container: String
    let vidHex: String
    let pidHex: String
    let deviceSizeBytes: UInt64
    let partitionType: UInt32
    let passwordFile: String
    let mountpoint: String
    let volumeName: String
}

private func parseFixtureArguments() throws -> FixtureArguments {
    var values = [String: String]()
    var index = 1
    while index < CommandLine.arguments.count {
        let key = CommandLine.arguments[index]
        guard key.hasPrefix("--") else {
            throw FixtureReadWriteBridgeError.usage("unexpected argument: \(key)")
        }
        index += 1
        guard index < CommandLine.arguments.count else {
            throw FixtureReadWriteBridgeError.usage("\(key) requires a value")
        }
        guard values[key] == nil else {
            throw FixtureReadWriteBridgeError.usage("duplicate argument: \(key)")
        }
        values[key] = CommandLine.arguments[index]
        index += 1
    }

    guard let container = values["--container"],
          let vidHex = values["--vid"],
          let pidHex = values["--pid"],
          let sizeText = values["--device-size"],
          let deviceSizeBytes = UInt64(sizeText),
          let typeText = values["--partition-type"],
          let partitionType = UInt32(typeText),
          let passwordFile = values["--password-file"],
          let mountpoint = values["--mountpoint"] else {
        throw FixtureReadWriteBridgeError.usage(
            "usage: FuseTEDPReadWriteFixtureBridge --container <whole-device.raw> --vid <hex> --pid <hex> --device-size <bytes> --partition-type <2|4> --password-file <path> --mountpoint <dir> [--volume-name <name>]"
        )
    }
    guard [UInt32(2), 4].contains(partitionType), deviceSizeBytes > 0 else {
        throw FixtureReadWriteBridgeError.invalid("invalid device size or partition type")
    }
    return FixtureArguments(
        container: container,
        vidHex: vidHex,
        pidHex: pidHex,
        deviceSizeBytes: deviceSizeBytes,
        partitionType: partitionType,
        passwordFile: passwordFile,
        mountpoint: mountpoint,
        volumeName: values["--volume-name"] ?? "EDP Encrypted Read-Write Transport"
    )
}

private func secureZero(_ bytes: inout [UInt8]) {
    bytes.withUnsafeMutableBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        memset_s(base, buffer.count, 0, buffer.count)
    }
}

private final class EDPFixtureReadWriteBacking: FuseTWriteBacking {
    let size: Int64
    let unlocked: EDPUnlockedReadWriteVolume
    private let raw: EDPFileRawDevice

    init(arguments: FixtureArguments, password: [UInt8]) throws {
        raw = try EDPFileRawDevice(
            path: arguments.container,
            declaredSizeBytes: arguments.deviceSizeBytes,
            writable: true
        )
        unlocked = try EDPReadWriteUnlock.unlock(
            raw: raw,
            request: EDPReadWriteUnlockRequest(
                vidHex: arguments.vidHex,
                pidHex: arguments.pidHex,
                deviceSizeBytes: arguments.deviceSizeBytes,
                passwordBytes: password,
                partitionType: arguments.partitionType
            )
        )
        guard unlocked.partitionSizeBytes <= UInt64(Int64.max) else {
            throw FixtureReadWriteBridgeError.invalid("partition size exceeds Int64")
        }
        size = Int64(unlocked.partitionSizeBytes)
    }

    func pread(offset: Int64, length: Int) throws -> Data {
        guard offset >= 0, length >= 0 else {
            throw FixtureReadWriteBridgeError.invalid("negative virtual read")
        }
        if offset >= size || length == 0 { return Data() }
        let wanted = Int(min(UInt64(length), UInt64(size - offset)))
        return try unlocked.block.read(at: UInt64(offset), length: wanted)
    }

    func pwrite(offset: Int64, data: Data) throws {
        guard offset >= 0 else {
            throw FixtureReadWriteBridgeError.invalid("negative virtual write")
        }
        let (end, overflow) = UInt64(offset).addingReportingOverflow(UInt64(data.count))
        guard !overflow, end <= unlocked.partitionSizeBytes else {
            throw FixtureReadWriteBridgeError.invalid("virtual write exceeds partition size")
        }
        try unlocked.block.write(at: UInt64(offset), data: data)
    }

    func synchronize() throws {
        try unlocked.block.synchronize()
    }
}

@main
private enum FuseTEDPReadWriteFixtureBridgeMain {
    static func main() {
        do {
            let arguments = try parseFixtureArguments()
            var password = [UInt8](try Data(contentsOf: URL(fileURLWithPath: arguments.passwordFile)))
            defer { secureZero(&password) }
            guard !password.isEmpty, password.count <= 4096 else {
                throw FixtureReadWriteBridgeError.invalid("invalid fixture password length")
            }
            let backing = try EDPFixtureReadWriteBacking(arguments: arguments, password: password)
            print("BACKING_MODE=EDP_FILE_FIXTURE_READWRITE_RANDOM_ACCESS")
            print("RAW_ACCESS=FILE|O_RDWR|O_CLOEXEC")
            print("CONTAINER_WRITABLE=true")
            print("PLAINTEXT_CACHE=none")
            print("DEVICE_ID=\(backing.unlocked.deviceID)")
            print("PARTITION_TYPE=\(backing.unlocked.partitionType)")
            print("PARTITION_START_SECTOR=\(backing.unlocked.partitionStartSector)")
            print("PARTITION_SIZE=\(backing.unlocked.partitionSizeBytes)")
            print("ALGORITHM=\(backing.unlocked.algorithm)")
            fflush(stdout)
            try runFuseTBridge(
                backing: backing,
                mountpoint: arguments.mountpoint,
                volumeName: arguments.volumeName,
                readOnly: false
            )
        } catch {
            fputs("FuseTEDPReadWriteFixtureBridge: \(error)\n", stderr)
            exit(1)
        }
    }
}
