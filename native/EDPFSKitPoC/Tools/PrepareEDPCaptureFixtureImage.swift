import Foundation

private enum PreparationError: Error, CustomStringConvertible {
    case usage(String)
    case invalid(String)

    var description: String {
        switch self {
        case let .usage(message), let .invalid(message):
            return message
        }
    }
}

@main
private enum PrepareEDPCaptureFixtureImage {
    static func main() {
        do {
            try run()
        } catch {
            fputs("PREPARE_CAPTURE_IMAGE_ERROR=\(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        let args = CommandLine.arguments
        guard args.count == 12 else {
            throw PreparationError.usage(
                "usage: PrepareEDPCaptureFixtureImage <LBA11.bin> <LBA12.bin> <vid-hex> <pid-hex> <device-size-bytes> <password> <partition-type> <capture-bytes> <output-image> <expected-plain> <expected-cipher>"
            )
        }

        let lba11URL = URL(fileURLWithPath: args[1])
        let lba12URL = URL(fileURLWithPath: args[2])
        let vid = normalizedHex(args[3])
        let pid = normalizedHex(args[4])
        guard let deviceSize = UInt64(args[5]),
              let partitionType = UInt32(args[7]),
              let captureBytes = Int(args[8]),
              captureBytes >= 512,
              captureBytes % 16 == 0 else {
            throw PreparationError.usage("invalid numeric argument")
        }
        let password = Array(args[6].utf8)
        let imageURL = URL(fileURLWithPath: args[9])
        let expectedPlainURL = URL(fileURLWithPath: args[10])
        let expectedCipherURL = URL(fileURLWithPath: args[11])

        let lba11 = try Data(contentsOf: lba11URL)
        let lba12 = try Data(contentsOf: lba12URL)
        guard lba11.count == 512, lba12.count == 512 else {
            throw PreparationError.invalid("LBA11/LBA12 fixtures must each be 512 bytes")
        }

        guard let deviceID = EDPVolumeMetadata.deviceIDFromLBA11(
            [UInt8](lba11),
            vidHex: vid,
            pidHex: pid,
            sizeBytes: deviceSize
        ) else {
            throw PreparationError.invalid("unable to derive device ID from LBA11")
        }

        let lba12Plain = try EDPVolumeMetadata.decodeLBA12([UInt8](lba12), deviceID: deviceID)
        let volumes = try EDPVolumeMetadata.parseLBA12Entries(lba12Plain, password: password)
        guard let descriptor = volumes.first(where: { $0.partitionType == partitionType }) else {
            throw PreparationError.invalid("requested partition type not present in LBA12 fixture")
        }
        guard descriptor.algorithm == 2 else {
            throw PreparationError.invalid("capture-image preparation currently requires SM4 partition algorithm 2")
        }
        guard captureBytes <= descriptor.sizeBytes else {
            throw PreparationError.invalid("capture length exceeds selected partition")
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

        let ciphertext = try EDPSM4(key: descriptor.fileKey).encryptAligned(plaintext)

        let manager = FileManager.default
        for url in [imageURL, expectedPlainURL, expectedCipherURL] {
            try? manager.removeItem(at: url)
            try manager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        guard manager.createFile(atPath: imageURL.path, contents: nil) else {
            throw PreparationError.invalid("unable to create synthetic raw image")
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

    private static func normalizedHex(_ value: String) -> String {
        let lower = value.lowercased()
        return lower.hasPrefix("0x") ? String(lower.dropFirst(2)) : lower
    }
}
