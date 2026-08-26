import Darwin
import Foundation
import Security

@_silgen_name("edp_authopen_readonly_fd")
private func edpAuthOpenReadOnlyFD(
    _ path: UnsafePointer<CChar>,
    _ authorizationBytes: UnsafeRawPointer,
    _ authorizationLength: Int
) -> Int32

private enum AuthorizedBridgeError: Error, CustomStringConvertible {
    case usage(String)
    case invalid(String)
    case posix(String, Int32)

    var description: String {
        switch self {
        case .usage(let message), .invalid(let message):
            return message
        case .posix(let operation, let code):
            return "\(operation): \(String(cString: strerror(code))) (\(code))"
        }
    }
}

private struct AuthorizedBridgeArguments {
    let rawDevice: String
    let vidHex: String
    let pidHex: String
    let deviceSizeBytes: UInt64
    let partitionType: UInt32
    let controlFD: Int32
    let mountpoint: String
    let volumeName: String
}

private func parseAuthorizedBridgeArguments() throws -> AuthorizedBridgeArguments {
    var values = [String: String]()
    let args = CommandLine.arguments
    var index = 1
    while index < args.count {
        let key = args[index]
        guard key.hasPrefix("--") else {
            throw AuthorizedBridgeError.usage("unexpected argument: \(key)")
        }
        index += 1
        guard index < args.count else {
            throw AuthorizedBridgeError.usage("\(key) requires a value")
        }
        values[key] = args[index]
        index += 1
    }

    guard let rawDevice = values["--raw-device"],
          let vidHex = values["--vid"],
          let pidHex = values["--pid"],
          let sizeText = values["--device-size"],
          let deviceSizeBytes = UInt64(sizeText),
          let typeText = values["--partition-type"],
          let partitionType = UInt32(typeText),
          let mountpoint = values["--mountpoint"] else {
        throw AuthorizedBridgeError.usage(
            "usage: FuseTEDPAuthorizedBridge --raw-device /dev/rdiskN --vid <hex> --pid <hex> --device-size <bytes> --partition-type <2|4> [--control-fd 0] --mountpoint <dir> [--volume-name <name>]"
        )
    }
    guard [UInt32(2), 4].contains(partitionType), deviceSizeBytes > 0 else {
        throw AuthorizedBridgeError.invalid("invalid device size or partition type")
    }
    let controlFD: Int32
    if let fdText = values["--control-fd"] {
        guard let parsed = Int32(fdText), parsed >= 0 else {
            throw AuthorizedBridgeError.invalid("invalid control fd")
        }
        controlFD = parsed
    } else {
        controlFD = STDIN_FILENO
    }
    return AuthorizedBridgeArguments(
        rawDevice: rawDevice,
        vidHex: vidHex,
        pidHex: pidHex,
        deviceSizeBytes: deviceSizeBytes,
        partitionType: partitionType,
        controlFD: controlFD,
        mountpoint: mountpoint,
        volumeName: values["--volume-name"] ?? "EDP Read-Only Raw Transport"
    )
}

private func secureZero(_ bytes: inout [UInt8]) {
    bytes.withUnsafeMutableBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        memset_s(base, buffer.count, 0, buffer.count)
    }
}

private func readExactControl(fd: Int32, count: Int) throws -> Data {
    var data = Data(count: count)
    var completed = 0
    try data.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return }
        while completed < count {
            let result = Darwin.read(fd, base.advanced(by: completed), count - completed)
            if result < 0 {
                if errno == EINTR { continue }
                throw AuthorizedBridgeError.posix("read authorization payload", errno)
            }
            guard result > 0 else {
                throw AuthorizedBridgeError.invalid("control stream ended before AuthorizationExternalForm")
            }
            completed += result
        }
    }
    return data
}

private func readPasswordControl(fd: Int32, maximum: Int = 4096) throws -> [UInt8] {
    var password = [UInt8]()
    password.reserveCapacity(min(maximum, 256))
    var temporary = [UInt8](repeating: 0, count: 512)
    defer { secureZero(&temporary) }

    while password.count < maximum {
        let wanted = min(temporary.count, maximum - password.count)
        let result = temporary.withUnsafeMutableBytes { raw in
            Darwin.read(fd, raw.baseAddress, wanted)
        }
        if result < 0 {
            if errno == EINTR { continue }
            secureZero(&password)
            throw AuthorizedBridgeError.posix("read password payload", errno)
        }
        if result == 0 { break }
        password.append(contentsOf: temporary.prefix(result))
    }
    guard !password.isEmpty else {
        throw AuthorizedBridgeError.invalid("password payload is empty")
    }

    if password.count == maximum {
        var extra: UInt8 = 0
        var result: Int
        repeat {
            result = withUnsafeMutablePointer(to: &extra) { pointer in
                Darwin.read(fd, pointer, 1)
            }
        } while result < 0 && errno == EINTR
        extra = 0
        guard result == 0 else {
            secureZero(&password)
            throw AuthorizedBridgeError.invalid("password payload exceeds maximum length")
        }
    }
    return password
}

private final class AuthorizedFDRawDevice: EDPRawReadable {
    let sizeBytes: UInt64?
    private var fd: Int32

    init(rawDevice: String, declaredSizeBytes: UInt64, authorization: Data) throws {
        guard authorization.count == MemoryLayout<AuthorizationExternalForm>.size else {
            throw AuthorizedBridgeError.invalid("invalid AuthorizationExternalForm length")
        }
        let opened: Int32 = try rawDevice.withCString { path in
            try authorization.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else {
                    throw AuthorizedBridgeError.invalid("authorization payload is empty")
                }
                return edpAuthOpenReadOnlyFD(path, base, bytes.count)
            }
        }
        guard opened >= 0 else {
            throw AuthorizedBridgeError.posix("authopen O_RDONLY", errno)
        }
        fd = opened
        sizeBytes = declaredSizeBytes
    }

    deinit {
        if fd >= 0 { Darwin.close(fd) }
    }

    func readExact(at offset: UInt64, length: Int) throws -> Data {
        guard length >= 0 else { throw AuthorizedBridgeError.invalid("negative read length") }
        guard offset <= UInt64(Int64.max) else { throw AuthorizedBridgeError.invalid("read offset exceeds off_t") }
        if length == 0 { return Data() }
        if let sizeBytes {
            let (end, overflow) = offset.addingReportingOverflow(UInt64(length))
            guard !overflow, end <= sizeBytes else {
                throw AuthorizedBridgeError.invalid("raw read exceeds declared device size")
            }
        }

        var data = Data(count: length)
        var completed = 0
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while completed < length {
                let absolute = offset + UInt64(completed)
                guard absolute <= UInt64(Int64.max) else {
                    throw AuthorizedBridgeError.invalid("read continuation exceeds off_t")
                }
                let result = Darwin.pread(
                    fd,
                    base.advanced(by: completed),
                    length - completed,
                    off_t(absolute)
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw AuthorizedBridgeError.posix("pread raw EDP device", errno)
                }
                guard result > 0 else {
                    throw AuthorizedBridgeError.invalid("unexpected EOF from raw EDP device")
                }
                completed += result
            }
        }
        return data
    }
}

private final class AuthorizedEDPBacking: FuseTReadBacking {
    let size: Int64
    let unlocked: EDPUnlockedReadOnlyVolume
    private let raw: AuthorizedFDRawDevice

    init(arguments: AuthorizedBridgeArguments, authorization: Data, password: [UInt8]) throws {
        raw = try AuthorizedFDRawDevice(
            rawDevice: arguments.rawDevice,
            declaredSizeBytes: arguments.deviceSizeBytes,
            authorization: authorization
        )
        unlocked = try EDPReadOnlyUnlock.unlock(
            raw: raw,
            request: EDPReadOnlyUnlockRequest(
                vidHex: arguments.vidHex,
                pidHex: arguments.pidHex,
                deviceSizeBytes: arguments.deviceSizeBytes,
                passwordBytes: password,
                partitionType: arguments.partitionType
            )
        )
        guard unlocked.partitionSizeBytes <= UInt64(Int64.max) else {
            throw AuthorizedBridgeError.invalid("partition size exceeds supported file size")
        }
        size = Int64(unlocked.partitionSizeBytes)
    }

    func pread(offset: Int64, length: Int) throws -> Data {
        guard offset >= 0, length >= 0 else {
            throw AuthorizedBridgeError.invalid("negative virtual read")
        }
        if offset >= size || length == 0 { return Data() }
        let remaining = UInt64(size - offset)
        let wanted = Int(min(UInt64(length), remaining))
        return try unlocked.block.read(at: UInt64(offset), length: wanted)
    }
}

@main
private enum FuseTEDPAuthorizedBridgeMain {
    static func main() {
        do {
            let arguments = try parseAuthorizedBridgeArguments()
            let authorization = try readExactControl(
                fd: arguments.controlFD,
                count: MemoryLayout<AuthorizationExternalForm>.size
            )
            var password = try readPasswordControl(fd: arguments.controlFD)
            defer { secureZero(&password) }

            let backing = try AuthorizedEDPBacking(
                arguments: arguments,
                authorization: authorization,
                password: password
            )
            print("BACKING_MODE=EDP_AUTHORIZED_READONLY_RANDOM_ACCESS")
            print("RAW_ACCESS=AUTHOPEN|O_RDONLY|O_CLOEXEC")
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
                volumeName: arguments.volumeName
            )
        } catch {
            fputs("FuseTEDPAuthorizedBridge: \(error)\n", stderr)
            exit(1)
        }
    }
}
