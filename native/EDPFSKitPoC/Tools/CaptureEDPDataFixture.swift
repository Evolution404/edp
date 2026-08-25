import Darwin
import Foundation

private enum CaptureError: Error, CustomStringConvertible {
    case usage(String)
    case io(String)
    case metadata(String)

    var description: String {
        switch self {
        case let .usage(message), let .io(message), let .metadata(message):
            return message
        }
    }
}

private final class RawFileReader: EDPRawReadable {
    let sizeBytes: UInt64?
    private let fd: Int32
    private let path: String

    init(path: String, sizeBytes: UInt64) throws {
        self.path = path
        self.sizeBytes = sizeBytes
        fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            throw CaptureError.io("open failed for \(path): errno=\(errno)")
        }
    }

    deinit {
        Darwin.close(fd)
    }

    func readExact(at offset: UInt64, length: Int) throws -> Data {
        guard length >= 0 else {
            throw CaptureError.io("negative read length")
        }
        guard length > 0 else { return Data() }
        guard offset <= UInt64(Int64.max) else {
            throw CaptureError.io("read offset exceeds off_t range")
        }
        let (end, overflow) = offset.addingReportingOverflow(UInt64(length))
        guard !overflow, end <= sizeBytes ?? UInt64.max else {
            throw CaptureError.io("read exceeds declared device size")
        }

        var data = Data(count: length)
        var completed = 0
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else {
                throw CaptureError.io("unable to allocate read buffer")
            }
            while completed < length {
                let currentOffset = offset + UInt64(completed)
                let result = Darwin.pread(
                    fd,
                    base.advanced(by: completed),
                    length - completed,
                    off_t(currentOffset)
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw CaptureError.io(
                        "pread failed for \(path) at \(currentOffset): errno=\(errno)"
                    )
                }
                guard result > 0 else {
                    throw CaptureError.io(
                        "unexpected EOF for \(path) at \(currentOffset)"
                    )
                }
                completed += result
            }
        }
        return data
    }
}

private struct CaptureManifest: Codable {
    let schemaVersion: Int
    let sourceDevice: String
    let vid: String
    let pid: String
    let deviceSizeBytes: UInt64
    let deviceID: String
    let partitionType: UInt32
    let partitionStartSector: UInt64
    let partitionSizeBytes: UInt64
    let algorithm: UInt32
    let captureOffsetBytes: UInt64
    let captureLengthBytes: Int
    let containsFileKey: Bool
    let containsPassword: Bool
}

@main
private enum CaptureEDPDataFixture {
    static func main() {
        do {
            try run()
        } catch {
            fputs("CAPTURE_ERROR=\(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        let args = CommandLine.arguments
        guard (6...8).contains(args.count) else {
            throw CaptureError.usage(
                "usage: CaptureEDPDataFixture <raw-device-or-image> <vid-hex> <pid-hex> <device-size-bytes> <output-dir> [partition-type=2] [capture-bytes=65536]\n" +
                "set EDP_PASSWORD in the environment; the password and derived file key are never written to the output"
            )
        }

        let source = args[1]
        let vid = normalizedHex4(args[2])
        let pid = normalizedHex4(args[3])
        guard let deviceSize = UInt64(args[4]), deviceSize >= 16 * 512 else {
            throw CaptureError.usage("invalid device-size-bytes")
        }
        let outputURL = URL(fileURLWithPath: args[5], isDirectory: true)
        let partitionType = args.count >= 7 ? UInt32(args[6]) : UInt32(2)
        let captureBytes = args.count >= 8 ? Int(args[7]) : 65_536

        guard let partitionType, [UInt32(2), 4].contains(partitionType) else {
            throw CaptureError.usage("partition-type must be 2 or 4")
        }
        guard let captureBytes,
              captureBytes >= 512,
              captureBytes <= 8 * 1024 * 1024,
              captureBytes % 16 == 0 else {
            throw CaptureError.usage("capture-bytes must be 512...8388608 and a multiple of 16")
        }
        guard let passwordString = ProcessInfo.processInfo.environment["EDP_PASSWORD"],
              !passwordString.isEmpty else {
            throw CaptureError.usage("EDP_PASSWORD is required in the environment")
        }
        let password = Array(passwordString.utf8)

        try prepareOutputDirectory(outputURL)
        let raw = try RawFileReader(path: source, sizeBytes: deviceSize)

        let lba11 = try raw.readExact(at: EDPVolumeMetadata.lba11ByteOffset, length: 512)
        let lba12 = try raw.readExact(at: EDPVolumeMetadata.lba12ByteOffset, length: 512)

        guard let deviceID = EDPVolumeMetadata.deviceIDFromLBA11(
            [UInt8](lba11),
            vidHex: vid,
            pidHex: pid,
            sizeBytes: deviceSize
        ) else {
            throw CaptureError.metadata(
                "LBA11 device ID derivation failed; verify VID/PID/device size"
            )
        }

        let lba12Plain = try EDPVolumeMetadata.decodeLBA12([UInt8](lba12), deviceID: deviceID)
        let volumes = try EDPVolumeMetadata.parseLBA12Entries(lba12Plain, password: password)
        guard let descriptor = volumes.first(where: { $0.partitionType == partitionType }) else {
            throw CaptureError.metadata(
                "no decryptable EDP partition type \(partitionType) was found for this password"
            )
        }
        guard captureBytes <= descriptor.sizeBytes else {
            throw CaptureError.metadata("capture length exceeds selected partition")
        }

        let reader = try EDPEncryptedPartitionReader(raw: raw, descriptor: descriptor)
        let ciphertext = try raw.readExact(
            at: descriptor.startBytes,
            length: captureBytes
        )
        let plaintext = try reader.readExact(at: 0, length: captureBytes)

        try lba11.write(to: outputURL.appendingPathComponent("LBA11.bin"), options: .withoutOverwriting)
        try lba12.write(to: outputURL.appendingPathComponent("LBA12.bin"), options: .withoutOverwriting)
        try Data(lba12Plain).write(
            to: outputURL.appendingPathComponent("LBA12.plain.bin"),
            options: .withoutOverwriting
        )
        try ciphertext.write(
            to: outputURL.appendingPathComponent("data-head.cipher.bin"),
            options: .withoutOverwriting
        )
        try plaintext.write(
            to: outputURL.appendingPathComponent("data-head.plain.bin"),
            options: .withoutOverwriting
        )

        let manifest = CaptureManifest(
            schemaVersion: 1,
            sourceDevice: source,
            vid: vid,
            pid: pid,
            deviceSizeBytes: deviceSize,
            deviceID: deviceID,
            partitionType: descriptor.partitionType,
            partitionStartSector: descriptor.startSector,
            partitionSizeBytes: descriptor.sizeBytes,
            algorithm: descriptor.algorithm,
            captureOffsetBytes: 0,
            captureLengthBytes: captureBytes,
            containsFileKey: false,
            containsPassword: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: outputURL.appendingPathComponent("manifest.json"),
            options: .withoutOverwriting
        )

        print("CAPTURE_DEVICE_ID=\(deviceID)")
        print("CAPTURE_PARTITION_TYPE=\(descriptor.partitionType)")
        print("CAPTURE_PARTITION_START_SECTOR=\(descriptor.startSector)")
        print("CAPTURE_BYTES=\(captureBytes)")
        print("CAPTURE_OUTPUT=\(outputURL.path)")
        print("CAPTURE_SECRETS_WRITTEN=false")
        print("RESULT=EDP_REAL_DATA_FIXTURE_CAPTURED")
    }

    private static func normalizedHex4(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.hasPrefix("0x") {
            return String(lower.dropFirst(2))
        }
        return lower
    }

    private static func prepareOutputDirectory(_ url: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw CaptureError.io("output path exists and is not a directory")
            }
            let contents = try manager.contentsOfDirectory(atPath: url.path)
            guard contents.isEmpty else {
                throw CaptureError.io("output directory must be empty")
            }
        } else {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
