import Foundation
import FSKit

/// Minimal, read-only EDP metadata recognition used by the native FSKit probe.
///
/// This deliberately mirrors the existing Rust edp-core LBA7 algorithm instead
/// of defining a new on-disk format. LBA7 is useful for initial recognition
/// because its rolling-XOR key can be recovered from the expected `EDPF` prefix
/// without a password, device ID, VID, or PID.
enum EDPMetadataProbe {
    static let legacySectorSize: UInt64 = 512
    static let lba7Index: UInt64 = 7
    static let lba7ByteOffset: UInt64 = lba7Index * legacySectorSize
    static let lba7ByteLength: UInt64 = legacySectorSize

    enum ProbeError: Error, CustomStringConvertible {
        case invalidPhysicalBlockSize(UInt64)
        case invalidAlignedRange
        case shortRead(expected: Int, actual: Int)

        var description: String {
            switch self {
            case .invalidPhysicalBlockSize(let size):
                return "invalid physical block size: \(size)"
            case .invalidAlignedRange:
                return "LBA7 aligned read range is not representable"
            case .shortRead(let expected, let actual):
                return "short aligned read: expected at least \(expected), got \(actual)"
            }
        }
    }

    struct OldFormatRecognition: Sendable {
        let k0: UInt16
        let plaintext: [UInt8]
    }

    struct AlignedWindow: Equatable, Sendable {
        let start: UInt64
        let length: Int
        let sliceOffset: Int
        let sliceLength: Int
    }

    /// Returns the physical-sector-aligned I/O request that contains a logical
    /// byte range. For LBA7 this matters on 4 KiB-sector media because byte
    /// offset 3584 itself is not a valid physical-sector-aligned read offset.
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

    /// Reads the 512-byte legacy LBA7 sector through a physical-sector-aligned
    /// FSKit request, then slices the logical LBA7 bytes out of that buffer.
    static func readLBA7(from block: FSBlockDeviceResource) throws -> [UInt8] {
        let window = try alignedWindow(
            byteOffset: lba7ByteOffset,
            byteLength: lba7ByteLength,
            physicalBlockSize: block.physicalBlockSize
        )

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: window.length,
            alignment: 4096
        )
        defer { storage.deallocate() }

        let buffer = UnsafeMutableRawBufferPointer(start: storage, count: window.length)
        let bytesRead = try block.read(
            into: buffer,
            startingAt: off_t(window.start),
            length: window.length
        )

        let requiredBytes = window.sliceOffset + window.sliceLength
        guard bytesRead >= requiredBytes else {
            throw ProbeError.shortRead(expected: requiredBytes, actual: bytesRead)
        }

        return Array(buffer[window.sliceOffset..<requiredBytes])
    }

    /// Mirrors `crates/edp-core/src/lba7.rs::recover_lba7` and
    /// `crates/edp-core/src/xor.rs::xor_decode`.
    ///
    /// The ciphertext's first little-endian word is XORed with plaintext `ED`
    /// to recover K0. A successful decode must begin with the full `EDPF` magic.
    static func recognizeOldFormatLBA7(_ raw: [UInt8]) -> OldFormatRecognition? {
        guard raw.count == Int(lba7ByteLength) else {
            return nil
        }

        let rawWord = UInt16(raw[0]) | (UInt16(raw[1]) << 8)
        let edWord = UInt16(Character("E").asciiValue!) |
            (UInt16(Character("D").asciiValue!) << 8)
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

        guard plaintext[0] == 0x45, // E
              plaintext[1] == 0x44, // D
              plaintext[2] == 0x50, // P
              plaintext[3] == 0x46  // F
        else {
            return nil
        }

        return OldFormatRecognition(k0: k0, plaintext: plaintext)
    }
}
