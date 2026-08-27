import Darwin
import Foundation

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
    let rawFD: Int32
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
            "usage: FuseTEDPAuthorizedReadWriteBridge --raw-device /dev/rdiskN --raw-fd 3 --vid <hex> --pid <hex> --device-size <bytes> --partition-type <2|4> [--control-fd 0] --mountpoint <dir> [--volume-name <name>]"
        )
    }
    guard [UInt32(1), 2, 4].contains(partitionType), deviceSizeBytes > 0 else {
        throw AuthorizedReadWriteBridgeError.invalid("invalid device size or partition type")
    }
    let rawSuffix = rawDevice.dropFirst("/dev/rdisk".count)
    guard rawDevice.hasPrefix("/dev/rdisk"),
          !rawSuffix.isEmpty,
          rawSuffix.allSatisfy(\.isNumber) else {
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
    guard let rawFDText = values["--raw-fd"],
          let rawFD = Int32(rawFDText),
          rawFD >= 3,
          rawFD != controlFD else {
        throw AuthorizedReadWriteBridgeError.invalid("invalid inherited raw fd")
    }
    return AuthorizedReadWriteBridgeArguments(
        rawDevice: rawDevice,
        vidHex: vidHex,
        pidHex: pidHex,
        deviceSizeBytes: deviceSizeBytes,
        partitionType: partitionType,
        controlFD: controlFD,
        rawFD: rawFD,
        mountpoint: mountpoint,
        volumeName: values["--volume-name"] ?? "EDP Read-Write Raw Transport"
    )
}

private func littleEndianUInt32(_ bytes: Data, at offset: Int) -> UInt32 {
    UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}

private func secureZero(_ bytes: inout [UInt8]) {
    bytes.withUnsafeMutableBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        memset_s(base, buffer.count, 0, buffer.count)
    }
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

    init(rawDevice: String, inheritedFD: Int32, declaredSizeBytes: UInt64) throws {
        guard fcntl(inheritedFD, F_GETFD) >= 0 else {
            throw AuthorizedReadWriteBridgeError.posix("inherited raw fd", errno)
        }
        var status = stat()
        guard fstat(inheritedFD, &status) == 0, (status.st_mode & S_IFMT) == S_IFCHR else {
            throw AuthorizedReadWriteBridgeError.invalid("inherited fd is not a raw character device")
        }
        // The root-owned launcher validates the exact whole-disk path before
        // opening fd 3. This process independently revalidates the media type
        // here and the EDP identity/size/partition metadata during unlock.
        _ = rawDevice
        fd = inheritedFD
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
        password: [UInt8]
    ) throws {
        raw = try AuthorizedFDReadWriteRawDevice(
            rawDevice: arguments.rawDevice,
            inheritedFD: arguments.rawFD,
            declaredSizeBytes: arguments.deviceSizeBytes
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

private final class AuthorizedEDPBootBacking: FuseTWriteBacking {
    let size: Int64
    let startSector: UInt64
    let deviceID: String
    private let raw: AuthorizedFDReadWriteRawDevice
    private let byteOffset: UInt64

    init(arguments: AuthorizedReadWriteBridgeArguments) throws {
        raw = try AuthorizedFDReadWriteRawDevice(
            rawDevice: arguments.rawDevice,
            inheritedFD: arguments.rawFD,
            declaredSizeBytes: arguments.deviceSizeBytes
        )
        let lba4 = try raw.readExact(
            at: EDPMetadataProbe.lba4ByteOffset,
            length: Int(EDPMetadataProbe.legacySectorByteLength)
        )
        let lba7 = try raw.readExact(
            at: EDPMetadataProbe.lba7ByteOffset,
            length: Int(EDPMetadataProbe.legacySectorByteLength)
        )
        guard EDPMetadataProbe.recognizeReservedSectors(
            lba4: [UInt8](lba4),
            lba7: [UInt8](lba7)
        ) != nil else {
            throw AuthorizedReadWriteBridgeError.invalid("raw device is not recognized EDP media")
        }
        let lba11 = try raw.readExact(
            at: EDPVolumeMetadata.lba11ByteOffset,
            length: Int(EDPMetadataProbe.legacySectorByteLength)
        )
        guard let verifiedDeviceID = EDPVolumeMetadata.deviceIDFromLBA11(
            [UInt8](lba11),
            vidHex: arguments.vidHex,
            pidHex: arguments.pidHex,
            sizeBytes: arguments.deviceSizeBytes
        ) else {
            throw AuthorizedReadWriteBridgeError.invalid("EDP device identity verification failed")
        }
        deviceID = verifiedDeviceID

        let mbr = try raw.readExact(at: 0, length: 512)
        guard mbr[510] == 0x55, mbr[511] == 0xaa else {
            throw AuthorizedReadWriteBridgeError.invalid("physical disk has no valid MBR signature")
        }
        let fatTypes: Set<UInt8> = [0x01, 0x04, 0x06, 0x0b, 0x0c, 0x0e]
        var selected: (start: UInt64, sectors: UInt64)?
        for index in 0..<4 {
            let entry = 446 + index * 16
            let type = mbr[entry + 4]
            let start = UInt64(littleEndianUInt32(mbr, at: entry + 8))
            let sectors = UInt64(littleEndianUInt32(mbr, at: entry + 12))
            if fatTypes.contains(type), start > 0, sectors > 0 {
                selected = (start, sectors)
                break
            }
        }
        guard let selected else {
            throw AuthorizedReadWriteBridgeError.invalid("EDP startup FAT partition was not found")
        }
        let (endSector, sectorOverflow) = selected.start.addingReportingOverflow(selected.sectors)
        let (endBytes, byteOverflow) = endSector.multipliedReportingOverflow(by: UInt64(512))
        guard !sectorOverflow, !byteOverflow, endBytes <= arguments.deviceSizeBytes,
              selected.sectors <= UInt64(Int64.max) / 512 else {
            throw AuthorizedReadWriteBridgeError.invalid("EDP startup partition exceeds device bounds")
        }
        startSector = selected.start
        byteOffset = selected.start * 512
        size = Int64(selected.sectors * 512)
    }

    func pread(offset: Int64, length: Int) throws -> Data {
        guard offset >= 0, length >= 0 else {
            throw AuthorizedReadWriteBridgeError.invalid("negative startup partition read")
        }
        if offset >= size || length == 0 { return Data() }
        let wanted = Int(min(Int64(length), size - offset))
        return try raw.readExact(at: byteOffset + UInt64(offset), length: wanted)
    }

    func pwrite(offset: Int64, data: Data) throws {
        guard offset >= 0 else {
            throw AuthorizedReadWriteBridgeError.invalid("negative startup partition write")
        }
        let (end, overflow) = offset.addingReportingOverflow(Int64(data.count))
        guard !overflow, end <= size else {
            throw AuthorizedReadWriteBridgeError.invalid("startup partition write exceeds bounds")
        }
        try raw.writeExact(at: byteOffset + UInt64(offset), data: data)
    }

    func synchronize() throws {
        try raw.synchronize()
    }
}

@main
private enum FuseTEDPAuthorizedReadWriteBridgeMain {
    static func main() {
        do {
            let arguments = try parseArguments()
            print("BACKING_MODE=EDP_PRIVILEGED_FD_READWRITE_RANDOM_ACCESS")
            print("RAW_ACCESS=ROOT_LAUNCHER_INHERITED_FD|O_RDWR")
            print("PLAINTEXT_CACHE=none")
            if arguments.partitionType == 1 {
                let backing = try AuthorizedEDPBootBacking(arguments: arguments)
                print("DEVICE_ID=\(backing.deviceID)")
                print("PARTITION_TYPE=1")
                print("PARTITION_START_SECTOR=\(backing.startSector)")
                print("PARTITION_SIZE=\(backing.size)")
                print("ALGORITHM=PLAINTEXT_MBR_SLICE")
                fflush(stdout)
                try runFuseTBridge(
                    backing: backing,
                    mountpoint: arguments.mountpoint,
                    volumeName: arguments.volumeName,
                    readOnly: false
                )
            } else {
                var password = try readPasswordControl(fd: arguments.controlFD)
                defer { secureZero(&password) }
                let backing = try AuthorizedEDPReadWriteBacking(
                    arguments: arguments,
                    password: password
                )
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
            }
        } catch {
            fputs("FuseTEDPAuthorizedReadWriteBridge: \(error)\n", stderr)
            exit(1)
        }
    }
}
