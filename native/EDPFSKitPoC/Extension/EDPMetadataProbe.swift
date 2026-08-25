import Foundation

/// Conservative, passwordless EDP metadata recognition for native FSKit.
///
/// Automatic recognition requires two independent reserved-sector signals
/// instead of claiming media from a single magic value.
enum EDPMetadataProbe {
    static let legacySectorSize: UInt64 = 512
    static let lba4Index: UInt64 = 4
    static let lba7Index: UInt64 = 7
    static let lba4ByteOffset: UInt64 = lba4Index * legacySectorSize
    static let lba7ByteOffset: UInt64 = lba7Index * legacySectorSize
    static let legacySectorByteLength: UInt64 = legacySectorSize
    static let reservedProbeByteLength: UInt64 =
        (lba7Index - lba4Index + 1) * legacySectorSize

    private static let expectedPartitionTypes: [UInt32] = [1, 2, 4]
    private static let lba7EntrySize = 0x40

    enum ProbeError: Error, CustomStringConvertible {
        case invalidPhysicalBlockSize(UInt64)
        case invalidAlignedRange
        case shortRead(expected: Int, actual: Int)

        var description: String {
            switch self {
            case .invalidPhysicalBlockSize(let size):
                return "invalid physical block size: \(size)"
            case .invalidAlignedRange:
                return "reserved-sector aligned read range is not representable"
            case .shortRead(let expected, let actual):
                return "short aligned read: expected at least \(expected), got \(actual)"
            }
        }
    }

    struct ReservedSectors: Sendable {
        let lba4: [UInt8]
        let lba7: [UInt8]
    }

    struct OldFormatRecognition: Sendable {
        let k0: UInt16
        let plaintext: [UInt8]
    }

    struct Recognition: Sendable {
        let serial: String
        let lba7K0: UInt16
        let partitionTypes: [UInt32]
    }

    struct AlignedWindow: Equatable, Sendable {
        let start: UInt64
        let length: Int
        let sliceOffset: Int
        let sliceLength: Int
    }

    /// Pure arithmetic regression helper for the legacy 512-byte metadata
    /// layout on devices whose physical transfer size may be larger.
    static func alignedWindow(
        byteOffset: UInt64,
        byteLength: UInt64,
        physicalBlockSize: UInt64
    ) throws -> AlignedWindow {
        guard physicalBlockSize > 0 else {
            throw ProbeError.invalidPhysicalBlockSize(physicalBlockSize)
        }
        guard byteLength > 0,
              byteOffset <= UInt64.max - byteLength else {
            throw ProbeError.invalidAlignedRange
        }

        let targetEnd = byteOffset + byteLength
        let requestStart = (byteOffset / physicalBlockSize) * physicalBlockSize

        let remainder = targetEnd % physicalBlockSize
        let requestEnd: UInt64
        if remainder == 0 {
            requestEnd = targetEnd
        } else {
            let padding = physicalBlockSize - remainder
            guard targetEnd <= UInt64.max - padding else {
                throw ProbeError.invalidAlignedRange
            }
            requestEnd = targetEnd + padding
        }

        guard requestEnd >= requestStart else {
            throw ProbeError.invalidAlignedRange
        }

        let requestLength64 = requestEnd - requestStart
        let sliceOffset64 = byteOffset - requestStart
        guard requestLength64 <= UInt64(Int.max),
              sliceOffset64 <= UInt64(Int.max),
              byteLength <= UInt64(Int.max),
              requestStart <= UInt64(Int64.max) else {
            throw ProbeError.invalidAlignedRange
        }

        return AlignedWindow(
            start: requestStart,
            length: Int(requestLength64),
            sliceOffset: Int(sliceOffset64),
            sliceLength: Int(byteLength)
        )
    }

    static func recognizeReservedSectors(lba4: [UInt8], lba7: [UInt8]) -> Recognition? {
        guard let serial = lba4Serial(lba4),
              let oldFormat = recognizeOldFormatLBA7(lba7) else {
            return nil
        }

        for (index, expectedType) in expectedPartitionTypes.enumerated() {
            let entryOffset = index * lba7EntrySize
            guard oldFormat.plaintext.count >= entryOffset + lba7EntrySize,
                  oldFormat.plaintext[entryOffset] == 0x45,
                  oldFormat.plaintext[entryOffset + 1] == 0x44,
                  oldFormat.plaintext[entryOffset + 2] == 0x50,
                  oldFormat.plaintext[entryOffset + 3] == 0x46,
                  readUInt32LE(oldFormat.plaintext, at: entryOffset + 0x0c) == expectedType,
                  readUInt64LE(oldFormat.plaintext, at: entryOffset + 0x18) != 0,
                  readUInt64LE(oldFormat.plaintext, at: entryOffset + 0x28) != 0 else {
                return nil
            }
        }

        return Recognition(
            serial: serial,
            lba7K0: oldFormat.k0,
            partitionTypes: expectedPartitionTypes
        )
    }

    /// Extracts the plaintext `$$$serial$$$` marker from LBA4 with conservative
    /// bounds so random media is not claimed accidentally.
    static func lba4Serial(_ raw: [UInt8]) -> String? {
        guard raw.count == Int(legacySectorByteLength) else {
            return nil
        }

        let delimiter: [UInt8] = [0x24, 0x24, 0x24]
        guard let markerStart = firstDelimiter(in: raw, delimiter: delimiter, from: 0),
              markerStart <= 64 else {
            return nil
        }

        let payloadStart = markerStart + delimiter.count
        guard let markerEnd = firstDelimiter(
            in: raw,
            delimiter: delimiter,
            from: payloadStart
        ) else {
            return nil
        }

        let payloadLength = markerEnd - payloadStart
        guard (1...96).contains(payloadLength) else {
            return nil
        }

        let payload = Array(raw[payloadStart..<markerEnd])
        guard payload.allSatisfy({ byte in
            byte != 0x24 && (byte == 0x20 || (0x21...0x7e).contains(byte))
        }) else {
            return nil
        }

        return String(bytes: payload, encoding: .utf8)
    }

    /// Decodes the legacy LBA7 rolling-XOR format natively in Swift.
    static func recognizeOldFormatLBA7(_ raw: [UInt8]) -> OldFormatRecognition? {
        guard raw.count == Int(legacySectorByteLength) else {
            return nil
        }

        let rawWord = UInt16(raw[0]) | (UInt16(raw[1]) << 8)
        let edWord: UInt16 = 0x4445 // little-endian bytes "ED"
        let k0 = rawWord ^ edWord

        var plaintext = raw
        var key = UInt32(k0)

        for i in 0..<(plaintext.count / 2) {
            let offset = i * 2
            let cipherWord = UInt16(plaintext[offset]) |
                (UInt16(plaintext[offset + 1]) << 8)
            let plainWord = cipherWord ^ UInt16(truncatingIfNeeded: key)
            plaintext[offset] = UInt8(truncatingIfNeeded: plainWord)
            plaintext[offset + 1] = UInt8(truncatingIfNeeded: plainWord >> 8)

            key = (key + 0x100 - UInt32(i) - 1) & 0xffff
        }

        guard plaintext[0] == 0x45,
              plaintext[1] == 0x44,
              plaintext[2] == 0x50,
              plaintext[3] == 0x46 else {
            return nil
        }

        return OldFormatRecognition(k0: k0, plaintext: plaintext)
    }

    private static func firstDelimiter(
        in bytes: [UInt8],
        delimiter: [UInt8],
        from start: Int
    ) -> Int? {
        guard !delimiter.isEmpty,
              start >= 0,
              start <= bytes.count - delimiter.count else {
            return nil
        }

        for index in start...(bytes.count - delimiter.count) {
            if Array(bytes[index..<(index + delimiter.count)]) == delimiter {
                return index
            }
        }
        return nil
    }

    private static func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) |
            (UInt32(bytes[offset + 1]) << 8) |
            (UInt32(bytes[offset + 2]) << 16) |
            (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readUInt64LE(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for shift in 0..<8 {
            value |= UInt64(bytes[offset + shift]) << UInt64(shift * 8)
        }
        return value
    }
}
