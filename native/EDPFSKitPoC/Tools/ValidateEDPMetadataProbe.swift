import Foundation

@main
struct ValidateEDPMetadataProbe {
    enum ValidationError: Error, CustomStringConvertible {
        case usage
        case invalidJSON
        case invalidHex(String)
        case missingField(String)
        case recognitionFailed(String)
        case mismatch(String)

        var description: String {
            switch self {
            case .usage:
                return "usage: validate-edp-probe <fixtures/golden/disks.json>"
            case .invalidJSON:
                return "invalid golden fixture JSON"
            case .invalidHex(let value):
                return "invalid hex string: \(value.prefix(32))"
            case .missingField(let field):
                return "missing fixture field: \(field)"
            case .recognitionFailed(let name):
                return "Swift EDP recognizer rejected fixture \(name)"
            case .mismatch(let message):
                return message
            }
        }
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw ValidationError.usage
        }

        let goldenPath = CommandLine.arguments[1]
        try validateAlignmentMath()
        try validateShortReadContinuation()
        try validateLBA7GoldenFixtures(path: goldenPath)
        try validateReservedSectorProbe(goldenPath: goldenPath)
        print("RESULT=SWIFT_EDP_LBA7_GOLDEN_OK")
        print("RESULT=SWIFT_EDP_RESERVED_PROBE_GOLDEN_OK")
    }

    private static func validateAlignmentMath() throws {
        let sector512 = try EDPAlignedRead.window(
            byteOffset: EDPMetadataProbe.lba4ByteOffset,
            byteLength: EDPMetadataProbe.reservedProbeByteLength,
            transferAlignment: 512
        )
        guard sector512 == .init(start: 2048, length: 2048, sliceOffset: 0, sliceLength: 2048) else {
            throw ValidationError.mismatch("512-byte reserved window mismatch: \(sector512)")
        }

        let sector4096 = try EDPAlignedRead.window(
            byteOffset: EDPMetadataProbe.lba4ByteOffset,
            byteLength: EDPMetadataProbe.reservedProbeByteLength,
            transferAlignment: 4096
        )
        guard sector4096 == .init(start: 0, length: 4096, sliceOffset: 2048, sliceLength: 2048) else {
            throw ValidationError.mismatch("4096-byte reserved window mismatch: \(sector4096)")
        }

        print("ALIGNMENT_512=OK")
        print("ALIGNMENT_4096=OK")
    }

    private static func validateShortReadContinuation() throws {
        try EDPAlignedRead.validateContinuation(
            completed: 512,
            totalLength: 2048,
            transferAlignment: 512
        )
        try EDPAlignedRead.validateContinuation(
            completed: 4096,
            totalLength: 8192,
            transferAlignment: 4096
        )
        try EDPAlignedRead.validateContinuation(
            completed: 2048,
            totalLength: 2048,
            transferAlignment: 4096
        )

        var rejectedUnalignedShortRead = false
        do {
            try EDPAlignedRead.validateContinuation(
                completed: 512,
                totalLength: 4096,
                transferAlignment: 4096
            )
        } catch {
            rejectedUnalignedShortRead = true
        }
        guard rejectedUnalignedShortRead else {
            throw ValidationError.mismatch("4096-byte transfer accepted an unaligned short-read continuation")
        }

        print("ALIGNED_SHORT_READ_CONTINUATION=OK")
    }

    /// Keeps the Swift rolling-XOR decoder pinned byte-for-byte to the existing
    /// Rust golden fixture for every captured disk.
    private static func validateLBA7GoldenFixtures(path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let disks = root["disks"] as? [[String: Any]],
              !disks.isEmpty else {
            throw ValidationError.invalidJSON
        }

        var validated = 0
        for disk in disks {
            guard let name = disk["name"] as? String else {
                throw ValidationError.missingField("name")
            }
            guard let lba7 = disk["lba7"] as? [String: Any],
                  let cipherHex = lba7["cipher_hex"] as? String,
                  let plainHex = lba7["plain_hex"] as? String,
                  let expectedK0 = lba7["k0"] as? NSNumber else {
                throw ValidationError.missingField("\(name).lba7")
            }

            let cipher = try decodeHex(cipherHex)
            let expectedPlain = try decodeHex(plainHex)
            guard let recognition = EDPMetadataProbe.recognizeOldFormatLBA7(cipher) else {
                throw ValidationError.recognitionFailed(name)
            }

            guard recognition.k0 == expectedK0.uint16Value else {
                throw ValidationError.mismatch(
                    "\(name): K0 mismatch swift=\(recognition.k0) fixture=\(expectedK0.uint16Value)"
                )
            }
            guard recognition.plaintext == expectedPlain else {
                throw ValidationError.mismatch("\(name): decoded LBA7 plaintext differs from fixture")
            }

            validated += 1
            print("GOLDEN_LBA7_OK=\(name) k0=\(String(format: "0x%04x", recognition.k0))")
        }

        print("GOLDEN_LBA7_COUNT=\(validated)")
    }

    /// Matches the conservative Rust `edp-core::probe` regression against the
    /// captured disk4/disk5 reserved sectors and verifies that either missing
    /// signal prevents automatic recognition.
    private static func validateReservedSectorProbe(goldenPath: String) throws {
        let goldenURL = URL(fileURLWithPath: goldenPath).standardizedFileURL
        let fixturesURL = goldenURL
            .deletingLastPathComponent() // golden
            .deletingLastPathComponent() // fixtures

        for diskName in ["disk4", "disk5"] {
            let diskURL = fixturesURL.appendingPathComponent("real_disks/\(diskName)")
            let lba4 = [UInt8](try Data(contentsOf: diskURL.appendingPathComponent("LBA4.bin")))
            let lba7 = [UInt8](try Data(contentsOf: diskURL.appendingPathComponent("LBA7.bin")))

            guard let evidence = EDPMetadataProbe.recognizeReservedSectors(lba4: lba4, lba7: lba7) else {
                throw ValidationError.recognitionFailed("\(diskName) reserved sectors")
            }
            guard evidence.partitionTypes == [1, 2, 4], !evidence.serial.isEmpty else {
                throw ValidationError.mismatch("\(diskName): invalid reserved-sector evidence")
            }

            print(
                "RESERVED_PROBE_OK=\(diskName) serial=\(evidence.serial) " +
                "k0=\(String(format: "0x%04x", evidence.lba7K0))"
            )

            let zeros = [UInt8](repeating: 0, count: 512)
            guard EDPMetadataProbe.recognizeReservedSectors(lba4: zeros, lba7: lba7) == nil,
                  EDPMetadataProbe.recognizeReservedSectors(lba4: lba4, lba7: zeros) == nil else {
                throw ValidationError.mismatch("\(diskName): recognizer accepted only one signal")
            }
        }

        print("RESERVED_PROBE_NEGATIVE_CONTROLS=OK")
    }

    private static func decodeHex(_ value: String) throws -> [UInt8] {
        guard value.count.isMultiple(of: 2) else {
            throw ValidationError.invalidHex(value)
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                throw ValidationError.invalidHex(value)
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
