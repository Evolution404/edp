import Darwin
import Foundation
import Security

@_silgen_name("edp_authopen_readwrite_fd")
private func edpAuthOpenReadWriteFD(
    _ path: UnsafePointer<CChar>,
    _ authorizationBytes: UnsafeRawPointer,
    _ authorizationLength: Int
) -> Int32

private enum AuthorizedReadWriteBridgeError: Error, CustomStringConvertible {
    case usage(String)
    case invalid(String)
    case posix(String, Int32)

    var description: String {
        switch self {
        case .usage(let message), .invalid(let message): return message
        case .posix(let operation, let code):
            return "\(operation): \(String(cString: strerror(code))) (\(code))"
        }
    }
}

private struct AuthorizedReadWriteBridgeArguments {
    let rawDevice: String
    let vidHex: String
    let pidHex: String
    let deviceSizeBytes: UInt64
    let partitionType: UInt32
    let controlFD: Int32
    let mountpoint: String
    let volumeName: String
}

private func parseArguments() throws -> AuthorizedReadWriteBridgeArguments {
    var values = [String: String]()
    let arguments = CommandLine.arguments
    var index = 1
    while index < arguments.count {
        let key = arguments[index]
        guard key.hasPrefix("--") else {
            throw AuthorizedReadWriteBridgeError.usage("unexpected argument: \(key)")
        }
        index += 1
        guard index < arguments.count else {
            throw AuthorizedReadWriteBridgeError.usage("\(key) requires a value")
        }
        guard values[key] == nil else {
            throw AuthorizedReadWriteBridgeError.usage("duplicate argument: \(key)")
        }
        values[key] = arguments[index]
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
        throw AuthorizedReadWriteBridgeError.usage(
            "usage: FuseTEDPAuthorizedReadWriteBridge --raw-device /dev/rdiskN --vid <hex> --pid <hex> --device-size <bytes> --partition-type <2|4> [--control-fd 0] --mountpoint <dir> [--volume-name <name>]"
        )
    }
    guard [UInt32(2), 4].contains(partitionType), deviceSizeBytes > 0 else {
        throw AuthorizedReadWriteBridgeError.invalid("invalid device size or partition type")
    }
    guard rawDevice.hasPrefix("/dev/rdisk") else {
        throw AuthorizedReadWriteBridgeError.invalid("raw device must be /dev/rdiskN")
    }
    let controlFD: Int32
    if let fdText = values["--control-fd"] {
        guard let parsed = Int32(fdText), parsed >= 0 else {
            throw AuthorizedReadWriteBridgeError.invalid("invalid control fd")
        }
        controlFD = parsed
    } else {
        controlFD = STDIN_FILENO
    }
    return AuthorizedReadWriteBridgeArguments(
        rawDevice: rawDevice,
        vidHex: vidHex,
        pidHex: pidHex,
        deviceSizeBytes: deviceSizeBytes,
        partitionType: partitionType,
        controlFD: controlFD,
        mountpoint: mountpoint,
        volumeName: values["--volume-name"] ?? "EDP Read-Write Raw Transport"
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
                throw AuthorizedReadWriteBridgeError.posix("read authorization payload", errno)
            }
            guard result > 0 else {
                throw AuthorizedReadWriteBridgeError.invalid(
                    "control stream ended before AuthorizationExternalForm"
                )
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
            throw AuthorizedReadWriteBridgeError.posix("read password payload", errno)
        }
        if result == 0 { break }
        password.append(contentsOf: temporary.prefix(result))
    }
    guard !password.isEmpty else {
        throw AuthorizedReadWriteBridgeError.invalid("password payload is empty")
    }
    if password.count == maximum {
        var extra: UInt8 = 0
        var result: Int
        repeat {
            result = withUnsafeMutablePointer(to: &extra) { Darwin.read(fd, $0, 1) }
        } while result < 0 && errno == EINTR
        extra = 0
        guard result == 0 else {
            secureZero(&password)
            throw AuthorizedReadWriteBridgeError.invalid("password payload exceeds maximum length")
        }
    }
    return password
}

private final class AuthorizedFDReadWriteRawDevice: EDPRawWritable {
    let sizeBytes: UInt64?
    let allowsWrites = true
    private var fd: Int32

    init(rawDevice: String, declaredSizeBytes: UInt64, authorization: Data) throws {
        guard authorization.count == MemoryLayout<AuthorizationExternalForm>.size else {
            throw AuthorizedReadWriteBridgeError.invalid("invalid AuthorizationExternalForm length")
        }
        let opened: Int32 = try rawDevice.withCString { path in
            try authorization.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else {
                    throw AuthorizedReadWriteBridgeError.invalid("authorization payload is empty")
                }
                return edpAuthOpenReadWriteFD(path, base, bytes.count)
            }
        }
        guard opened >= 0 else {
            throw AuthorizedReadWriteBridgeError.posix("authopen O_RDWR", errno)
        }
        fd = opened
        sizeBytes = declaredSizeBytes
    }

    deinit {
        if fd >= 0 { Darwin.close(fd) }
    }

    func readExact(at offset: UInt64, length: Int) throws -> Data {
        try validateRange(offset: offset, length: length, operation: "read")
        if length == 0 { return Data() }
        var data = Data(count: length)
        var completed = 0
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while completed < length {
                let absolute = offset + UInt64(completed)
                let result = Darwin.pread(
                    fd,
                    base.advanced(by: completed),
                    length - completed,
                    off_t(absolute)
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw AuthorizedReadWriteBridgeError.posix("pread raw EDP device", errno)
                }
                guard result > 0 else {
                    throw AuthorizedReadWriteBridgeError.invalid("unexpected EOF from raw EDP device")
                }
                completed += result
            }
        }
        return data
    }

    func writeExact(at offset: UInt64, data: Data) throws {
        try validateRange(offset: offset, length: data.count, operation: "write")
        var completed = 0
        while completed < data.count {
            let result = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.pwrite(
                    fd,
                    base.advanced(by: completed),
                    data.count - completed,
                    off_t(offset + UInt64(completed))
                )
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw AuthorizedReadWriteBridgeError.posix("pwrite raw EDP device", errno)
            }
            guard result > 0 else {
                throw AuthorizedReadWriteBridgeError.invalid("zero-progress raw EDP write")
            }
            completed += result
        }
    }

    func synchronize() throws {
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
            throw AuthorizedReadWriteBridgeError.posix("sync raw EDP device", errno)
        }
    }

    private func validateRange(offset: UInt64, length: Int, operation: String) throws {
        guard length >= 0, offset <= UInt64(Int64.max) else {
            throw AuthorizedReadWriteBridgeError.invalid("invalid raw \(operation) range")
        }
        let (end, overflow) = offset.addingReportingOverflow(UInt64(length))
        guard !overflow, end <= (sizeBytes ?? UInt64.max), end <= UInt64(Int64.max) else {
            throw AuthorizedReadWriteBridgeError.invalid(
                "raw \(operation) exceeds declared device size"
            )
        }
    }
}

private final class AuthorizedEDPReadWriteBacking: FuseTWriteBacking {
    let size: Int64
    let unlocked: EDPUnlockedReadWriteVolume
    private let raw: AuthorizedFDReadWriteRawDevice

    init(
        arguments: AuthorizedReadWriteBridgeArguments,
        authorization: Data,
        password: [UInt8]
    ) throws {
        raw = try AuthorizedFDReadWriteRawDevice(
            rawDevice: arguments.rawDevice,
            declaredSizeBytes: arguments.deviceSizeBytes,
            authorization: authorization
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
            throw AuthorizedReadWriteBridgeError.invalid(
                "partition size exceeds supported file size"
            )
        }
        size = Int64(unlocked.partitionSizeBytes)
    }

    func pread(offset: Int64, length: Int) throws -> Data {
        guard offset >= 0, length >= 0 else {
            throw AuthorizedReadWriteBridgeError.invalid("negative virtual read")
        }
        if offset >= size || length == 0 { return Data() }
        let wanted = Int(min(UInt64(length), UInt64(size - offset)))
        return try unlocked.block.read(at: UInt64(offset), length: wanted)
    }

    func pwrite(offset: Int64, data: Data) throws {
        guard offset >= 0 else {
            throw AuthorizedReadWriteBridgeError.invalid("negative virtual write")
        }
        let (end, overflow) = UInt64(offset).addingReportingOverflow(UInt64(data.count))
        guard !overflow, end <= unlocked.partitionSizeBytes else {
            throw AuthorizedReadWriteBridgeError.invalid("virtual write exceeds partition size")
        }
        try unlocked.block.write(at: UInt64(offset), data: data)
    }

    func synchronize() throws {
        try unlocked.block.synchronize()
    }
}

@main
private enum FuseTEDPAuthorizedReadWriteBridgeMain {
    static func main() {
        do {
            let arguments = try parseArguments()
            let authorization = try readExactControl(
                fd: arguments.controlFD,
                count: MemoryLayout<AuthorizationExternalForm>.size
            )
            var password = try readPasswordControl(fd: arguments.controlFD)
            defer { secureZero(&password) }

            let backing = try AuthorizedEDPReadWriteBacking(
                arguments: arguments,
                authorization: authorization,
                password: password
            )
            print("BACKING_MODE=EDP_AUTHORIZED_READWRITE_RANDOM_ACCESS")
            print("RAW_ACCESS=AUTHOPEN|O_RDWR|O_CLOEXEC")
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
            fputs("FuseTEDPAuthorizedReadWriteBridge: \(error)\n", stderr)
            exit(1)
        }
    }
}
