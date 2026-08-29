import Foundation

public extension EDPCrypto {
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

    static func crc32Bare(_ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBytes { crc32Bare($0) }
    }

    static func crcKey(_ string: String) -> [UInt8] {
        littleEndianBytes(crc32Bare(Array(string.utf8)))
    }
}

public enum EDPA6B0 {
    public static func decrypt(
        _ bytes: [UInt8],
        keyRaw: [UInt8],
        initialCounter: UInt32 = 0
    ) throws -> [UInt8] {
        guard !keyRaw.isEmpty else {
            throw EDPCoreError.invalidInput("A6B0 key material is empty")
        }
        guard bytes.count % 16 == 0 else {
            throw EDPCoreError.invalidInput("A6B0 input must be 16-byte aligned")
        }

        var output = [UInt8]()
        output.reserveCapacity(bytes.count)
        var counter = initialCounter
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            output.append(
                contentsOf: decryptBlock(
                    Array(bytes[offset..<(offset + 16)]),
                    keyRaw: keyRaw,
                    counter: counter
                )
            )
            counter &+= 16
        }
        return output
    }

    private static func decryptBlock(
        _ block: [UInt8],
        keyRaw: [UInt8],
        counter: UInt32
    ) -> [UInt8] {
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
        for index in 0..<16 { state[index] ^= key[index] }
    }

    private static func invShiftRows(_ state: inout [UInt8]) {
        let old = state
        let mapping = [0, 13, 10, 7, 4, 1, 14, 11, 8, 5, 2, 15, 12, 9, 6, 3]
        for index in 0..<16 { state[index] = old[mapping[index]] }
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
            if (b & 1) != 0 { product ^= a }
            let high = a & 0x80
            a = a &<< 1
            if high != 0 { a ^= 0x1b }
            b >>= 1
        }
        return product
    }

    private static let keyTable = Array("EDPSECDISK200709".utf8)
    private static let rcon: [UInt8] = [0, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36]
    private static let sbox: [UInt8] = [
        0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
        0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
        0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
        0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
        0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
        0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
        0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
        0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
        0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
        0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
        0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
        0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
        0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
        0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
        0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
        0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
    ]
    private static let invSbox: [UInt8] = {
        var inverse = [UInt8](repeating: 0, count: 256)
        for (index, value) in sbox.enumerated() { inverse[Int(value)] = UInt8(index) }
        return inverse
    }()
}

public enum EDPRollingXOR {
    public static func apply(_ data: [UInt8], k0: UInt16) -> [UInt8] {
        var result = data
        var key = k0
        for index in 0..<(result.count / 2) {
            let offset = index * 2
            let word = UInt16(result[offset]) | (UInt16(result[offset + 1]) << 8)
            let transformed = word ^ key
            result[offset] = UInt8(truncatingIfNeeded: transformed)
            result[offset + 1] = UInt8(truncatingIfNeeded: transformed >> 8)
            key = key &+ 0x100 &- UInt16(truncatingIfNeeded: index + 1)
        }
        return result
    }
}

public enum EDPLBA4 {
    public static func parseSerial(_ raw: [UInt8]) -> UInt64? {
        let head = raw.prefix(64)
        guard head.count >= 6 else { return nil }
        var index = head.startIndex
        while index + 3 <= head.endIndex {
            if Array(head[index..<(index + 3)]) == Array("$$$".utf8) {
                var end = index + 3
                while end + 3 <= head.endIndex {
                    if Array(head[end..<(end + 3)]) == Array("$$$".utf8) {
                        let digits = head[(index + 3)..<end]
                        guard !digits.isEmpty,
                              digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                              let string = String(bytes: digits, encoding: .utf8) else {
                            break
                        }
                        return UInt64(string)
                    }
                    end += 1
                }
            }
            index += 1
        }
        return nil
    }

    public static func k0(serial: UInt64) -> UInt16 {
        UInt16(truncatingIfNeeded: (serial & 0xffff) ^ ((serial >> 16) & 0xffff))
    }

    public static func decode(_ raw: [UInt8]) -> (bytes: [UInt8], serial: UInt64)? {
        guard raw.count >= 512, let serial = parseSerial(raw) else { return nil }
        let key = k0(serial: serial)
        let region = Array(raw[0x18..<(0x18 + 0x1e8)])
        var decoded = EDPRollingXOR.apply(region, k0: key)
        for index in region.indices where region[index] == 0 { decoded[index] = 0 }
        var output = Array(raw[0..<0x18])
        output.append(contentsOf: decoded)
        return (output, serial)
    }
}

public enum EDPLBA6 {
    public static let k0: UInt16 = 0x4daa

    public static func decode(_ raw: [UInt8]) throws -> [UInt8] {
        guard raw.count >= 512 else {
            throw EDPCoreError.invalidInput("LBA6 must contain at least 512 bytes")
        }
        var output = EDPRollingXOR.apply(Array(raw[0..<0x1fc]), k0: k0)
        output.append(contentsOf: raw[0x1fc..<0x200])
        return output
    }
}
