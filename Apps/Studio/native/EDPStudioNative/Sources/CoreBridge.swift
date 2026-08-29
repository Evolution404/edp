import EDPCore
import Foundation

struct CoreIdentity: Sendable {
    let crc: UInt32
    let k0: UInt16
}

struct CoreField: Hashable, Sendable {
    let off: Int
    let len: Int
    let name: String
    let desc: String
    let value: String
    let color: String

    init(_ field: EDPSectorField) {
        off = field.off
        len = field.len
        name = field.name
        desc = field.desc
        value = field.value
        color = field.color
    }
}

struct CoreSectorDecode: Sendable {
    let decodedHex: String?
    let method: String?
    let fields: [CoreField]
}

enum EDPOpenCoreError: LocalizedError {
    case invalidSectorLength(Int)
    case core(String)

    var errorDescription: String? {
        switch self {
        case .invalidSectorLength(let count):
            "EDP Core 只接受 512B 扇区，当前为 \(count)B"
        case .core(let message):
            message
        }
    }
}

enum EDPOpenCore {
    static var version: String {
        "edp-core/\(EDPCoreVersion.current)"
    }

    static func crc32(_ data: [UInt8]) -> UInt32 {
        EDPCrypto.crc32Bare(data)
    }

    static func decodeSector(
        lba: UInt64,
        raw: [UInt8],
        identity: CoreIdentity? = nil,
        vid: String? = nil,
        pid: String? = nil,
        sizeBytes: UInt64 = 0
    ) throws -> CoreSectorDecode {
        guard raw.count == EDPSectorDecoder.sectorSize else {
            throw EDPOpenCoreError.invalidSectorLength(raw.count)
        }

        do {
            let decoded = try EDPSectorDecoder.decode(
                lba: lba,
                raw: raw,
                context: EDPSectorDecodeContext(
                    identity: identity.map { EDPSectorIdentity(crc: $0.crc, k0: $0.k0) },
                    vid: vid,
                    pid: pid,
                    sizeBytes: sizeBytes == 0 ? nil : sizeBytes
                )
            )
            return CoreSectorDecode(
                decodedHex: decoded.decoded.map(hex),
                method: decoded.method,
                fields: decoded.fields.map(CoreField.init)
            )
        } catch let error as EDPCoreError {
            throw EDPOpenCoreError.core(error.description)
        } catch {
            throw EDPOpenCoreError.core(error.localizedDescription)
        }
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

extension CoreField {
    var semantic: ByteSemantic {
        switch color {
        case "magic": .magic
        case "part": .partition
        case "key": .keyMaterial
        case "label": .label
        case "cipher": .ciphertext
        case "checksum": .checksum
        case "warn": .warning
        default: .normal
        }
    }
}

extension String {
    var decodedHexBytes: [UInt8]? {
        guard count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count / 2)
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: 2)
            guard let byte = UInt8(self[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
