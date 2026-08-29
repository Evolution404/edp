import Foundation

struct CoreIdentity: Sendable {
    let crc: UInt32
    let k0: UInt16
}

struct CoreField: Decodable, Hashable, Sendable {
    let off: Int
    let len: Int
    let name: String
    let desc: String
    let value: String
    let color: String
}

struct CoreSectorDecode: Decodable, Sendable {
    let ok: Bool
    let error: String?
    let decodedHex: String?
    let method: String?
    let fields: [CoreField]

    enum CodingKeys: String, CodingKey {
        case ok
        case error
        case decodedHex = "decoded_hex"
        case method
        case fields
    }
}

enum EDPCoreError: LocalizedError {
    case invalidSectorLength(Int)
    case ffiReturnedNull
    case core(String)
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .invalidSectorLength(let count): "Rust Core 只接受 512B 扇区，当前为 \(count)B"
        case .ffiReturnedNull: "Rust Core FFI 返回空指针"
        case .core(let message): message
        case .invalidJSON(let message): "Rust Core JSON 解析失败：\(message)"
        }
    }
}

enum EDPCore {
    static var version: String {
        guard let ptr = edp_core_version() else { return "core unavailable" }
        return String(cString: ptr)
    }

    static func crc32(_ data: [UInt8]) -> UInt32 {
        data.withUnsafeBufferPointer { buffer in
            edp_core_crc32(buffer.baseAddress, buffer.count)
        }
    }

    static func decodeSector(
        lba: UInt64,
        raw: [UInt8],
        identity: CoreIdentity? = nil,
        vid: String? = nil,
        pid: String? = nil,
        sizeBytes: UInt64 = 0
    ) throws -> CoreSectorDecode {
        guard raw.count == 512 else { throw EDPCoreError.invalidSectorLength(raw.count) }

        return try withOptionalCString(vid) { vidPtr in
            try withOptionalCString(pid) { pidPtr in
                try raw.withUnsafeBufferPointer { rawBuffer in
                    guard let resultPtr = edp_decode_sector_json(
                        lba,
                        rawBuffer.baseAddress,
                        rawBuffer.count,
                        identity == nil ? 0 : 1,
                        identity?.crc ?? 0,
                        identity?.k0 ?? 0,
                        vidPtr,
                        pidPtr,
                        sizeBytes
                    ) else {
                        throw EDPCoreError.ffiReturnedNull
                    }
                    defer { edp_string_free(resultPtr) }
                    let json = String(cString: resultPtr)
                    guard let data = json.data(using: .utf8) else {
                        throw EDPCoreError.invalidJSON("UTF-8 conversion failed")
                    }
                    do {
                        let decoded = try JSONDecoder().decode(CoreSectorDecode.self, from: data)
                        if !decoded.ok {
                            throw EDPCoreError.core(decoded.error ?? "未知 Rust Core 错误")
                        }
                        return decoded
                    } catch let error as EDPCoreError {
                        throw error
                    } catch {
                        throw EDPCoreError.invalidJSON(error.localizedDescription)
                    }
                }
            }
        }
    }

    private static func withOptionalCString<T>(
        _ value: String?,
        _ body: (UnsafePointer<CChar>?) throws -> T
    ) rethrows -> T {
        guard let value else { return try body(nil) }
        return try value.withCString { ptr in
            try body(ptr)
        }
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
