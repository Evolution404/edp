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
                return "Swift LBA7 recognizer rejected golden disk \(name)"
            case .mismatch(let message):
                return message
            }
        }
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw ValidationError.usage
        }

        try validateAlignmentMath()
        try validateGoldenFixtures(path: CommandLine.arguments[1])
        print("RESULT=SWIFT_EDP_LBA7_GOLDEN_OK")
    }

    private static func validateAlignmentMath() throws {
        let sector512 = try EDPMetadataProbe.alignedWindow(
            byteOffset: EDPMetadataProbe.lba7ByteOffset,
            byteLength: EDPMetadataProbe.lba7ByteLength,
            physicalBlockSize: 512
        )
        guard sector512 == .init(start: 3584, length: 512, sliceOffset: 0, sliceLength: 512) else {
            throw ValidationError.mismatch("512-byte aligned LBA7 window mismatch: \(sector512)")
        }

        let sector4096 = try EDPMetadataProbe.alignedWindow(
            byteOffset: EDPMetadataProbe.lba7ByteOffset,
            byteLength: EDPMetadataProbe.lba7ByteLength,
            physicalBlockSize: 4096
        )
        guard sector4096 == .init(start: 0, length: 4096, sliceOffset: 3584, sliceLength: 512) else {
            throw ValidationError.mismatch("4096-byte aligned LBA7 window mismatch: \(sector4096)")
        }

        print("ALIGNMENT_512=OK")
        print("ALIGNMENT_4096=OK")
    }

    private static func validateGoldenFixtures(path: String) throws {
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
