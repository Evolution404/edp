import CryptoKit
import Foundation

enum EDPNativeCoreError: Error, CustomStringConvertible {
    case invalidInput(String)
    case parse(String)
    case verify(String)

    var description: String {
        switch self {
        case .invalidInput(let message): return message
        case .parse(let message): return message
        case .verify(let message): return message
        }
    }
}

enum EDPCrypto {
    static func crc32Bare(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0
        for byte in bytes {
            var value = (crc ^ UInt32(byte)) & 0xff
            for _ in 0..<8 {
                value = (value & 1) != 0 ? 0xedb8_8320 ^ (value >> 1) : value >> 1
            }
            crc = value ^ (crc >> 8)
        }
        return crc
    }

    static func crcKey(_ string: String) -> [UInt8] {
        littleEndianBytes(crc32Bare(Array(string.utf8)))
    }

    static func md5(_ bytes: [UInt8]) -> [UInt8] {
        Array(Insecure.MD5.hash(data: Data(bytes)))
    }

    static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: Data(bytes)))
    }

    static func littleEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ]
    }

    static func littleEndianBytes(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
    }
}

struct EDPSM4: Sendable {
    private let roundKeys: [UInt32]

    init(key: [UInt8]) throws {
        guard key.count == 16 else {
            throw EDPNativeCoreError.invalidInput("SM4 key must be 16 bytes")
        }

        var state = [
            Self.wordBE(key, 0) ^ Self.fk[0],
            Self.wordBE(key, 4) ^ Self.fk[1],
            Self.wordBE(key, 8) ^ Self.fk[2],
            Self.wordBE(key, 12) ^ Self.fk[3],
        ]
        var keys = [UInt32]()
        keys.reserveCapacity(32)
        for index in 0..<32 {
            let next = state[0] ^ Self.keyTransform(state[1] ^ state[2] ^ state[3] ^ Self.ck[index])
            keys.append(next)
            state = [state[1], state[2], state[3], next]
        }
        roundKeys = keys
    }

    func encryptAligned(_ bytes: [UInt8]) throws -> [UInt8] {
        try cryptAligned(bytes, decrypt: false)
    }

    func decryptAligned(_ bytes: [UInt8]) throws -> [UInt8] {
        try cryptAligned(bytes, decrypt: true)
    }

    private func cryptAligned(_ bytes: [UInt8], decrypt: Bool) throws -> [UInt8] {
        guard bytes.count % 16 == 0 else {
            throw EDPNativeCoreError.invalidInput("SM4-ECB input must be 16-byte aligned")
        }
        guard !bytes.isEmpty else { return [] }

        var output = [UInt8](repeating: 0, count: bytes.count)
        bytes.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { destination in
                for offset in stride(from: 0, to: input.count, by: 16) {
                    var x0 = Self.wordBE(input, offset)
                    var x1 = Self.wordBE(input, offset + 4)
                    var x2 = Self.wordBE(input, offset + 8)
                    var x3 = Self.wordBE(input, offset + 12)

                    for index in 0..<32 {
                        let key = decrypt ? roundKeys[31 - index] : roundKeys[index]
                        let next = x0 ^ Self.roundTransform(x1 ^ x2 ^ x3 ^ key)
                        x0 = x1
                        x1 = x2
                        x2 = x3
                        x3 = next
                    }

                    Self.storeBE(x3, into: destination, at: offset)
                    Self.storeBE(x2, into: destination, at: offset + 4)
                    Self.storeBE(x1, into: destination, at: offset + 8)
                    Self.storeBE(x0, into: destination, at: offset + 12)
                }
            }
        }
        return output
    }

    private static func wordBE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    @inline(__always)
    private static func wordBE(_ bytes: UnsafeBufferPointer<UInt8>, _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    @inline(__always)
    private static func storeBE(
        _ value: UInt32,
        into bytes: UnsafeMutableBufferPointer<UInt8>,
        at offset: Int
    ) {
        bytes[offset] = UInt8(truncatingIfNeeded: value >> 24)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value)
    }

    @inline(__always)
    private static func rotateLeft(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value << amount) | (value >> (32 - amount))
    }

    @inline(__always)
    private static func tau(_ value: UInt32) -> UInt32 {
        (UInt32(sbox[Int((value >> 24) & 0xff)]) << 24)
            | (UInt32(sbox[Int((value >> 16) & 0xff)]) << 16)
            | (UInt32(sbox[Int((value >> 8) & 0xff)]) << 8)
            | UInt32(sbox[Int(value & 0xff)])
    }

    @inline(__always)
    private static func keyTransform(_ value: UInt32) -> UInt32 {
        let substituted = tau(value)
        return substituted ^ rotateLeft(substituted, by: 13) ^ rotateLeft(substituted, by: 23)
    }

    @inline(__always)
    private static func roundTransform(_ value: UInt32) -> UInt32 {
        let substituted = tau(value)
        return substituted
            ^ rotateLeft(substituted, by: 2)
            ^ rotateLeft(substituted, by: 10)
            ^ rotateLeft(substituted, by: 18)
            ^ rotateLeft(substituted, by: 24)
    }

    private static let fk: [UInt32] = [0xa3b1bac6, 0x56aa3350, 0x677d9197, 0xb27022dc]
    private static let ck: [UInt32] = [
        0x00070e15, 0x1c232a31, 0x383f464d, 0x545b6269, 0x70777e85, 0x8c939aa1, 0xa8afb6bd, 0xc4cbd2d9,
        0xe0e7eef5, 0xfc030a11, 0x181f262d, 0x343b4249, 0x50575e65, 0x6c737a81, 0x888f969d, 0xa4abb2b9,
        0xc0c7ced5, 0xdce3eaf1, 0xf8ff060d, 0x141b2229, 0x30373e45, 0x4c535a61, 0x686f767d, 0x848b9299,
        0xa0a7aeb5, 0xbcc3cad1, 0xd8dfe6ed, 0xf4fb0209, 0x10171e25, 0x2c333a41, 0x484f565d, 0x646b7279,
    ]
    private static let sbox: [UInt8] = [
        0xd6, 0x90, 0xe9, 0xfe, 0xcc, 0xe1, 0x3d, 0xb7, 0x16, 0xb6, 0x14, 0xc2, 0x28, 0xfb, 0x2c, 0x05,
        0x2b, 0x67, 0x9a, 0x76, 0x2a, 0xbe, 0x04, 0xc3, 0xaa, 0x44, 0x13, 0x26, 0x49, 0x86, 0x06, 0x99,
        0x9c, 0x42, 0x50, 0xf4, 0x91, 0xef, 0x98, 0x7a, 0x33, 0x54, 0x0b, 0x43, 0xed, 0xcf, 0xac, 0x62,
        0xe4, 0xb3, 0x1c, 0xa9, 0xc9, 0x08, 0xe8, 0x95, 0x80, 0xdf, 0x94, 0xfa, 0x75, 0x8f, 0x3f, 0xa6,
        0x47, 0x07, 0xa7, 0xfc, 0xf3, 0x73, 0x17, 0xba, 0x83, 0x59, 0x3c, 0x19, 0xe6, 0x85, 0x4f, 0xa8,
        0x68, 0x6b, 0x81, 0xb2, 0x71, 0x64, 0xda, 0x8b, 0xf8, 0xeb, 0x0f, 0x4b, 0x70, 0x56, 0x9d, 0x35,
        0x1e, 0x24, 0x0e, 0x5e, 0x63, 0x58, 0xd1, 0xa2, 0x25, 0x22, 0x7c, 0x3b, 0x01, 0x21, 0x78, 0x87,
        0xd4, 0x00, 0x46, 0x57, 0x9f, 0xd3, 0x27, 0x52, 0x4c, 0x36, 0x02, 0xe7, 0xa0, 0xc4, 0xc8, 0x9e,
        0xea, 0xbf, 0x8a, 0xd2, 0x40, 0xc7, 0x38, 0xb5, 0xa3, 0xf7, 0xf2, 0xce, 0xf9, 0x61, 0x15, 0xa1,
        0xe0, 0xae, 0x5d, 0xa4, 0x9b, 0x34, 0x1a, 0x55, 0xad, 0x93, 0x32, 0x30, 0xf5, 0x8c, 0xb1, 0xe3,
        0x1d, 0xf6, 0xe2, 0x2e, 0x82, 0x66, 0xca, 0x60, 0xc0, 0x29, 0x23, 0xab, 0x0d, 0x53, 0x4e, 0x6f,
        0xd5, 0xdb, 0x37, 0x45, 0xde, 0xfd, 0x8e, 0x2f, 0x03, 0xff, 0x6a, 0x72, 0x6d, 0x6c, 0x5b, 0x51,
        0x8d, 0x1b, 0xaf, 0x92, 0xbb, 0xdd, 0xbc, 0x7f, 0x11, 0xd9, 0x5c, 0x41, 0x1f, 0x10, 0x5a, 0xd8,
        0x0a, 0xc1, 0x31, 0x88, 0xa5, 0xcd, 0x7b, 0xbd, 0x2d, 0x74, 0xd0, 0x12, 0xb8, 0xe5, 0xb4, 0xb0,
        0x89, 0x69, 0x97, 0x4a, 0x0c, 0x96, 0x77, 0x7e, 0x65, 0xb9, 0xf1, 0x09, 0xc5, 0x6e, 0xc6, 0x84,
        0x18, 0xf0, 0x7d, 0xec, 0x3a, 0xdc, 0x4d, 0x20, 0x79, 0xee, 0x5f, 0x3e, 0xd7, 0xcb, 0x39, 0x48,
    ]
}

enum EDPA6B0 {
    static func decrypt(_ bytes: [UInt8], keyRaw: [UInt8], initialCounter: UInt32 = 0) throws -> [UInt8] {
        guard !keyRaw.isEmpty else {
            throw EDPNativeCoreError.invalidInput("A6B0 key material is empty")
        }
        guard bytes.count % 16 == 0 else {
            throw EDPNativeCoreError.invalidInput("A6B0 input must be 16-byte aligned")
        }

        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var counter = initialCounter
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            out.append(contentsOf: decryptBlock(Array(bytes[offset..<(offset + 16)]), keyRaw: keyRaw, counter: counter))
            counter &+= 16
        }
        return out
    }

    private static func decryptBlock(_ block: [UInt8], keyRaw: [UInt8], counter: UInt32) -> [UInt8] {
        let roundKeys = deriveRoundKeys(keyRaw: keyRaw, counter: counter)
        var state = block
        xor(&state, roundKeys[10])
        for round in stride(from: 9, through: 1, by: -1) {
            invShiftRows(&state)
            for index in state.indices {
                state[index] = invSbox[Int(state[index])]
            }
            xor(&state, roundKeys[round])
            for column in 0..<4 {
                invMixColumn(&state, offset: column * 4)
            }
        }
        invShiftRows(&state)
        for index in state.indices {
            state[index] = invSbox[Int(state[index])]
        }
        xor(&state, roundKeys[0])
        return state
    }

    private static func deriveRoundKeys(keyRaw: [UInt8], counter: UInt32) -> [[UInt8]] {
        var expanded = [UInt8](repeating: 0, count: 16)
        for index in 0..<16 {
            expanded[index] = keyRaw[index % keyRaw.count] ^ keyTable[index]
        }

        var rconIndex = 1
        while expanded.count < 176 {
            var temp = Array(expanded[(expanded.count - 4)..<expanded.count])
            if expanded.count % 16 == 0 {
                temp = [temp[1], temp[2], temp[3], temp[0]]
                temp = temp.map { sbox[Int($0)] }
                temp[0] ^= rcon[rconIndex]
                rconIndex += 1
            }
            for index in 0..<4 {
                let source = expanded[expanded.count - 16]
                expanded.append(source ^ temp[index])
            }
        }

        if counter != 0 {
            let mask = EDPCrypto.littleEndianBytes(counter) + [UInt8](repeating: 0, count: 4)
            for index in expanded.indices {
                expanded[index] ^= mask[index % 8]
            }
        }

        return (0..<11).map { round in
            Array(expanded[(round * 16)..<(round * 16 + 16)])
        }
    }

    private static func xor(_ state: inout [UInt8], _ key: [UInt8]) {
        for index in 0..<16 {
            state[index] ^= key[index]
        }
    }

    private static func invShiftRows(_ state: inout [UInt8]) {
        let old = state
        let mapping = [0, 13, 10, 7, 4, 1, 14, 11, 8, 5, 2, 15, 12, 9, 6, 3]
        for index in 0..<16 {
            state[index] = old[mapping[index]]
        }
    }

    private static func invMixColumn(_ state: inout [UInt8], offset: Int) {
        let a0 = state[offset]
        let a1 = state[offset + 1]
        let a2 = state[offset + 2]
        let a3 = state[offset + 3]
        state[offset] = gfMul(a0, 14) ^ gfMul(a1, 11) ^ gfMul(a2, 13) ^ gfMul(a3, 9)
        state[offset + 1] = gfMul(a0, 9) ^ gfMul(a1, 14) ^ gfMul(a2, 11) ^ gfMul(a3, 13)
        state[offset + 2] = gfMul(a0, 13) ^ gfMul(a1, 9) ^ gfMul(a2, 14) ^ gfMul(a3, 11)
        state[offset + 3] = gfMul(a0, 11) ^ gfMul(a1, 13) ^ gfMul(a2, 9) ^ gfMul(a3, 14)
    }

    private static func gfMul(_ lhs: UInt8, _ rhs: UInt8) -> UInt8 {
        var a = lhs
        var b = rhs
        var product: UInt8 = 0
        for _ in 0..<8 {
            if (b & 1) != 0 {
                product ^= a
            }
            let high = a & 0x80
            a = a &<< 1
            if high != 0 {
                a ^= 0x1b
            }
            b >>= 1
        }
        return product
    }

    private static let keyTable = Array("EDPSECDISK200709".utf8)
    private static let rcon: [UInt8] = [0, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36]
    private static let sbox: [UInt8] = [
        0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
        0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
        0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
        0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
        0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
        0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
        0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
        0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
        0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
        0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
        0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
        0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
        0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
        0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
        0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
        0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
    ]
    private static let invSbox: [UInt8] = {
        var inverse = [UInt8](repeating: 0, count: 256)
        for (index, value) in sbox.enumerated() {
            inverse[Int(value)] = UInt8(index)
        }
        return inverse
    }()
}
