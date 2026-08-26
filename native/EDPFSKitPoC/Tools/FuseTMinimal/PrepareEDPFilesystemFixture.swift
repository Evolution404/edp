import Darwin
import Foundation

private enum PrepareError: Error, CustomStringConvertible {
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

private struct Arguments {
    let lba11Path: String
    let lba12Path: String
    let vidHex: String
    let pidHex: String
    let deviceSizeBytes: UInt64
    let partitionType: UInt32
    let plaintextPath: String
    let outputPath: String
    let passwordFile: String
}

private func parseArguments() throws -> Arguments {
    var values = [String: String]()
    let args = CommandLine.arguments
    var index = 1
    while index < args.count {
        let key = args[index]
        guard key.hasPrefix("--") else {
            throw PrepareError.usage("unexpected argument: \(key)")
        }
        index += 1
        guard index < args.count else {
            throw PrepareError.usage("\(key) requires a value")
        }
        values[key] = args[index]
        index += 1
    }

    guard let lba11Path = values["--lba11"],
          let lba12Path = values["--lba12"],
          let vidHex = values["--vid"],
          let pidHex = values["--pid"],
          let deviceSizeText = values["--device-size"],
          let deviceSizeBytes = UInt64(deviceSizeText),
          let partitionTypeText = values["--partition-type"],
          let partitionType = UInt32(partitionTypeText),
          let plaintextPath = values["--plaintext"],
          let outputPath = values["--output"],
          let passwordFile = values["--password-file"] else {
        throw PrepareError.usage(
            "usage: PrepareEDPFilesystemFixture --lba11 <file> --lba12 <file> --vid <hex> --pid <hex> --device-size <bytes> --partition-type <2|4> --plaintext <raw-fs> --output <sparse-edp-image> --password-file <file>"
        )
    }

    guard [UInt32(2), 4].contains(partitionType), deviceSizeBytes > 0 else {
        throw PrepareError.usage("invalid device size or partition type")
    }
    return Arguments(
        lba11Path: lba11Path,
        lba12Path: lba12Path,
        vidHex: vidHex,
        pidHex: pidHex,
        deviceSizeBytes: deviceSizeBytes,
        partitionType: partitionType,
        plaintextPath: plaintextPath,
        outputPath: outputPath,
        passwordFile: passwordFile
    )
}

private func readPassword(path: String) throws -> [UInt8] {
    var data = try Data(contentsOf: URL(fileURLWithPath: path))
    while let last = data.last, last == 0x0a || last == 0x0d {
        data.removeLast()
    }
    guard !data.isEmpty else {
        throw PrepareError.invalid("password file is empty")
    }
    return [UInt8](data)
}

private func writeAll(fd: Int32, data: Data, offset: UInt64) throws {
    guard offset <= UInt64(Int64.max) else {
        throw PrepareError.invalid("write offset exceeds off_t")
    }
    var completed = 0
    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        while completed < data.count {
            let absolute = offset + UInt64(completed)
            guard absolute <= UInt64(Int64.max) else {
                throw PrepareError.invalid("write continuation exceeds off_t")
            }
            let result = Darwin.pwrite(
                fd,
                base.advanced(by: completed),
                data.count - completed,
                off_t(absolute)
            )
            if result < 0 {
                if errno == EINTR { continue }
                throw PrepareError.posix("pwrite", errno)
            }
            guard result > 0 else {
                throw PrepareError.invalid("zero-progress pwrite")
            }
            completed += result
        }
    }
}

@main
private enum PrepareEDPFilesystemFixtureMain {
    static func main() {
        do {
            try run()
        } catch {
            fputs("PrepareEDPFilesystemFixture: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        let args = try parseArguments()
        let lba11 = try Data(contentsOf: URL(fileURLWithPath: args.lba11Path))
        let lba12 = try Data(contentsOf: URL(fileURLWithPath: args.lba12Path))
        guard lba11.count == 512, lba12.count == 512 else {
            throw PrepareError.invalid("LBA11/LBA12 must both be exactly 512 bytes")
        }

        let password = try readPassword(path: args.passwordFile)
        guard let deviceID = EDPVolumeMetadata.deviceIDFromLBA11(
            [UInt8](lba11),
            vidHex: args.vidHex,
            pidHex: args.pidHex,
            sizeBytes: args.deviceSizeBytes
        ) else {
            throw PrepareError.invalid("real LBA11 metadata did not validate")
        }
        let lba12Plain = try EDPVolumeMetadata.decodeLBA12([UInt8](lba12), deviceID: deviceID)
        let descriptors = try EDPVolumeMetadata.parseLBA12Entries(lba12Plain, password: password)
        guard let descriptor = descriptors.first(where: { $0.partitionType == args.partitionType }),
              descriptor.algorithm == 2,
              let fileKey = descriptor.fileKey else {
            throw PrepareError.invalid("selected real metadata partition did not unlock as SM4")
        }

        let plaintextURL = URL(fileURLWithPath: args.plaintextPath)
        let attributes = try FileManager.default.attributesOfItem(atPath: plaintextURL.path)
        guard let fileSize = attributes[.size] as? NSNumber else {
            throw PrepareError.invalid("unable to determine plaintext size")
        }
        let plaintextSize = fileSize.uint64Value
        guard plaintextSize > 0,
              plaintextSize <= descriptor.sizeBytes,
              plaintextSize % 16 == 0 else {
            throw PrepareError.invalid("plaintext filesystem must be positive, fit the partition, and be SM4 aligned")
        }

        let (partitionEnd, overflow) = descriptor.startBytes.addingReportingOverflow(descriptor.sizeBytes)
        guard !overflow, partitionEnd <= args.deviceSizeBytes,
              args.deviceSizeBytes <= UInt64(Int64.max) else {
            throw PrepareError.invalid("real metadata partition bounds exceed declared device size")
        }

        let outputURL = URL(fileURLWithPath: args.outputPath)
        try? FileManager.default.removeItem(at: outputURL)
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw PrepareError.invalid("unable to create sparse EDP image")
        }

        let outputFD = Darwin.open(outputURL.path, O_RDWR | O_CLOEXEC)
        guard outputFD >= 0 else { throw PrepareError.posix("open output", errno) }
        defer { Darwin.close(outputFD) }
        guard Darwin.ftruncate(outputFD, off_t(args.deviceSizeBytes)) == 0 else {
            throw PrepareError.posix("ftruncate sparse EDP image", errno)
        }

        try writeAll(fd: outputFD, data: lba11, offset: EDPVolumeMetadata.lba11ByteOffset)
        try writeAll(fd: outputFD, data: lba12, offset: EDPVolumeMetadata.lba12ByteOffset)

        let cipher = try EDPSM4(key: fileKey)
        let input = try FileHandle(forReadingFrom: plaintextURL)
        defer { try? input.close() }
        let chunkSize = 1024 * 1024
        var logicalOffset: UInt64 = 0
        while logicalOffset < plaintextSize {
            let remaining = plaintextSize - logicalOffset
            let wanted = Int(min(UInt64(chunkSize), remaining))
            let plain = try input.read(upToCount: wanted) ?? Data()
            guard plain.count == wanted, plain.count % 16 == 0 else {
                throw PrepareError.invalid("unexpected plaintext short read or unaligned chunk")
            }
            let encrypted = try cipher.encryptAligned([UInt8](plain))
            try writeAll(
                fd: outputFD,
                data: Data(encrypted),
                offset: descriptor.startBytes + logicalOffset
            )
            logicalOffset += UInt64(wanted)
        }

        while Darwin.fsync(outputFD) != 0 {
            if errno == EINTR { continue }
            throw PrepareError.posix("fsync output", errno)
        }

        print("PREPARED_DEVICE_ID=\(deviceID)")
        print("PREPARED_PARTITION_TYPE=\(descriptor.partitionType)")
        print("PREPARED_PARTITION_START_SECTOR=\(descriptor.startSector)")
        print("PREPARED_PARTITION_SIZE_BYTES=\(descriptor.sizeBytes)")
        print("PREPARED_PLAINTEXT_BYTES=\(plaintextSize)")
        print("PREPARED_DEVICE_SIZE_BYTES=\(args.deviceSizeBytes)")
        print("PREPARED_SECRET_OUTPUT=false")
        print("RESULT=EDP_REAL_METADATA_FILESYSTEM_FIXTURE_READY")
    }
}
