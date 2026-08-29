import AppKit
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
        if args.count >= 2, args[1] == "--prepare-ci-image" {
            try prepareCIImage(Array(args.dropFirst(2)))
            return
        }
        try capture(args)
    }

    private static func capture(_ args: [String]) throws {
        guard (6...8).contains(args.count) else {
            throw CaptureError.usage(
                "usage: CaptureEDPDataFixture <raw-device-or-image> <vid-hex> <pid-hex> <device-size-bytes> <output-dir> [partition-type=2] [capture-bytes=65536]\n" +
                "password is read from EDP_PASSWORD when set, otherwise it is requested interactively without echo"
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
        let password = try readPassword()

        try prepareOutputDirectory(outputURL)
        let raw = try RawFileReader(path: source, sizeBytes: deviceSize)

        let unlocked = try EDPReadOnlyUnlock.unlock(
            raw: raw,
            request: EDPReadOnlyUnlockRequest(
                vidHex: vid,
                pidHex: pid,
                deviceSizeBytes: deviceSize,
                passwordBytes: password,
                partitionType: partitionType
            )
        )
        guard captureBytes <= unlocked.partitionSizeBytes else {
            throw CaptureError.metadata("capture length exceeds selected partition")
        }

        let lba11 = try raw.readExact(at: EDPVolumeMetadata.lba11ByteOffset, length: 512)
        let lba12 = try raw.readExact(at: EDPVolumeMetadata.lba12ByteOffset, length: 512)
        let lba12Plain = try EDPVolumeMetadata.decodeLBA12(
            [UInt8](lba12),
            deviceID: unlocked.deviceID
        )
        let partitionStartBytes = unlocked.partitionStartSector * EDPMetadataProbe.legacySectorSize
        let ciphertext = try raw.readExact(
            at: partitionStartBytes,
            length: captureBytes
        )
        let plaintext = try unlocked.block.read(at: 0, length: captureBytes)

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
            deviceID: unlocked.deviceID,
            partitionType: unlocked.partitionType,
            partitionStartSector: unlocked.partitionStartSector,
            partitionSizeBytes: unlocked.partitionSizeBytes,
            algorithm: unlocked.algorithm,
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

        print("CAPTURE_DEVICE_ID=\(unlocked.deviceID)")
        print("CAPTURE_PARTITION_TYPE=\(unlocked.partitionType)")
        print("CAPTURE_PARTITION_START_SECTOR=\(unlocked.partitionStartSector)")
        print("CAPTURE_BYTES=\(captureBytes)")
        print("CAPTURE_OUTPUT=\(outputURL.path)")
        print("CAPTURE_SECRETS_WRITTEN=false")
        print("RESULT=EDP_REAL_DATA_FIXTURE_CAPTURED")
    }

    /// Internal CI helper. It reuses the exact same binary and native crypto
    /// implementation as the capture path so Fast Checks need only one extra
    /// Swift executable instead of compiling a second fixture-generator tool.
    private static func prepareCIImage(_ args: [String]) throws {
        guard args.count == 11 else {
            throw CaptureError.usage(
                "internal usage: --prepare-ci-image <LBA11.bin> <LBA12.bin> <vid> <pid> <device-size> <password> <partition-type> <capture-bytes> <image> <expected-plain> <expected-cipher>"
            )
        }

        let lba11 = try Data(contentsOf: URL(fileURLWithPath: args[0]))
        let lba12 = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let vid = normalizedHex4(args[2])
        let pid = normalizedHex4(args[3])
        guard lba11.count == 512, lba12.count == 512,
              let deviceSize = UInt64(args[4]),
              let partitionType = UInt32(args[6]),
              let captureBytes = Int(args[7]),
              captureBytes >= 512,
              captureBytes % 16 == 0 else {
            throw CaptureError.usage("invalid CI fixture input")
        }

        let password = Array(args[5].utf8)
        guard let deviceID = EDPVolumeMetadata.deviceIDFromLBA11(
            [UInt8](lba11),
            vidHex: vid,
            pidHex: pid,
            sizeBytes: deviceSize
        ) else {
            throw CaptureError.metadata("unable to derive CI fixture device ID")
        }

        let lba12Plain = try EDPVolumeMetadata.decodeLBA12([UInt8](lba12), deviceID: deviceID)
        let volumes = try EDPVolumeMetadata.parseLBA12Entries(lba12Plain, password: password)
        guard let descriptor = volumes.first(where: { $0.partitionType == partitionType }),
              descriptor.algorithm == 2,
              let fileKey = descriptor.fileKey,
              captureBytes <= descriptor.sizeBytes else {
            throw CaptureError.metadata("CI fixture requires a valid SM4 encrypted partition")
        }

        var plaintext = [UInt8](repeating: 0, count: captureBytes)
        for index in plaintext.indices {
            plaintext[index] = UInt8(truncatingIfNeeded: (index &* 73) &+ 41)
        }
        if plaintext.count >= 11 {
            plaintext[0] = 0xeb
            plaintext[1] = 0x76
            plaintext[2] = 0x90
            plaintext.replaceSubrange(3..<11, with: Array("EXFAT   ".utf8))
        }
        let ciphertext = try EDPSM4(key: fileKey).encryptAligned(plaintext)

        let imageURL = URL(fileURLWithPath: args[8])
        let expectedPlainURL = URL(fileURLWithPath: args[9])
        let expectedCipherURL = URL(fileURLWithPath: args[10])
        let manager = FileManager.default
        for url in [imageURL, expectedPlainURL, expectedCipherURL] {
            try? manager.removeItem(at: url)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        guard manager.createFile(atPath: imageURL.path, contents: nil) else {
            throw CaptureError.io("unable to create CI raw image")
        }

        let handle = try FileHandle(forWritingTo: imageURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: EDPVolumeMetadata.lba11ByteOffset)
        try handle.write(contentsOf: lba11)
        try handle.seek(toOffset: EDPVolumeMetadata.lba12ByteOffset)
        try handle.write(contentsOf: lba12)
        try handle.seek(toOffset: descriptor.startBytes)
        try handle.write(contentsOf: Data(ciphertext))
        try handle.synchronize()

        try Data(plaintext).write(to: expectedPlainURL, options: .atomic)
        try Data(ciphertext).write(to: expectedCipherURL, options: .atomic)

        print("PREPARED_DEVICE_ID=\(deviceID)")
        print("PREPARED_PARTITION_START_SECTOR=\(descriptor.startSector)")
        print("PREPARED_CAPTURE_BYTES=\(captureBytes)")
        print("PREPARED_IMAGE_BYTES=\(descriptor.startBytes + UInt64(captureBytes))")
        print("RESULT=EDP_CAPTURE_TEST_IMAGE_PREPARED")
    }

    private static func readPassword() throws -> [UInt8] {
        if let value = ProcessInfo.processInfo.environment["EDP_PASSWORD"], !value.isEmpty {
            return Array(value.utf8)
        }

        if ProcessInfo.processInfo.environment["EDP_PASSWORD_STDIN"] == "1" {
            guard let line = readLine(strippingNewline: true) else {
                throw CaptureError.usage("EDP password stdin is unavailable")
            }
            guard !line.isEmpty else {
                throw CaptureError.usage("EDP password must not be empty")
            }
            return Array(line.utf8)
        }

        if Darwin.isatty(STDIN_FILENO) == 1,
           let pointer = Darwin.getpass("EDP password: ") {
            let value = String(cString: pointer)
            guard !value.isEmpty else {
                throw CaptureError.usage("EDP password must not be empty")
            }
            return Array(value.utf8)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let alert = NSAlert()
        alert.messageText = "EDP USB Vault"
        alert.informativeText = "请输入 EDP U盘密码。密码只在本机内存中用于本次只读解锁。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "解锁")
        alert.addButton(withTitle: "取消")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        app.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else {
            throw CaptureError.usage("EDP password entry was cancelled")
        }
        let value = field.stringValue
        guard !value.isEmpty else {
            throw CaptureError.usage("EDP password must not be empty")
        }
        return Array(value.utf8)
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
