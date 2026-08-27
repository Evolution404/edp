import Foundation

private enum MatrixError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw MatrixError.failed(message) }
}

private func deterministicBytes(count: Int, seed: UInt64) -> Data {
    var state = seed ^ 0x9E37_79B9_7F4A_7C15
    var bytes = [UInt8](repeating: 0, count: count)
    for index in bytes.indices {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        bytes[index] = UInt8(truncatingIfNeeded: state ^ UInt64(index &* 131))
    }
    return Data(bytes)
}

private func encrypt(_ plaintext: Data, key: [UInt8]) throws -> Data {
    try require(plaintext.count % 16 == 0, "fixture must be SM4 aligned")
    let cipher = try EDPSM4(key: key)
    return Data(try cipher.encryptAligned([UInt8](plaintext)))
}

private func makeDescriptor(size: Int, key: [UInt8]) -> EDPVolumeDescriptor {
    EDPVolumeDescriptor(
        partitionType: 2,
        startSector: 0,
        sizeBytes: UInt64(size),
        algorithm: 2,
        fileKey: key,
        passwordCRC: 0,
        keyCRC: EDPCrypto.crc32Bare(key)
    )
}

private func makeWritableBlock(path: String, size: Int, key: [UInt8]) throws -> EDPEncryptedReadWriteBlockDevice {
    let raw = try EDPFileRawDevice(path: path, declaredSizeBytes: UInt64(size), writable: true)
    let reader = try EDPEncryptedPartitionReader(raw: raw, descriptor: makeDescriptor(size: size, key: key))
    return try EDPEncryptedReadWriteBlockDevice(reader: reader)
}

private func expectThrow(_ label: String, _ body: () throws -> Void) throws {
    do {
        try body()
        throw MatrixError.failed("\(label) unexpectedly succeeded")
    } catch is MatrixError {
        throw MatrixError.failed("\(label) unexpectedly succeeded")
    } catch {
        print("EXPECTED_FAILURE=\(label):\(error)")
    }
}

private struct ConcurrentWriteCase: Sendable {
    let offset: Int
    let length: Int
    let seed: UInt64
}

private final class SendableBlockBox: @unchecked Sendable {
    let block: EDPEncryptedReadWriteBlockDevice
    init(_ block: EDPEncryptedReadWriteBlockDevice) { self.block = block }
}

private final class ConcurrentErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ error: Error) {
        lock.lock()
        messages.append(String(describing: error))
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}

@main
private enum ValidateEDPReadWriteMatrixMain {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("ValidateEDPReadWriteMatrix: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        let size = 4 * 1024 * 1024
        let key: [UInt8] = [
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
            0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
        ]
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edp-rw-matrix-\(UUID().uuidString).cipher")
        defer { try? FileManager.default.removeItem(at: temp) }

        var expected = deterministicBytes(count: size, seed: 0xED40_4040_2026_0826)
        let initialCipher = try encrypt(expected, key: key)
        try initialCipher.write(to: temp, options: .atomic)
        let initialCipherHash = EDPCrypto.sha256([UInt8](initialCipher))

        do {
            let active = try makeWritableBlock(path: temp.path, size: size, key: key)

            try require(try active.read(at: 0, length: size) == expected, "initial full decrypt mismatch")
            try require(try active.read(at: 15, length: 33) == expected.subdata(in: 15..<48), "cross-SM4 read mismatch")
            try require(try active.read(at: UInt64(size - 1), length: 1) == expected.subdata(in: (size - 1)..<size), "tail read mismatch")
            try require(try active.read(at: 7, length: 0).isEmpty, "zero-length read mismatch")

            struct WriteCase {
                let name: String
                let offset: Int
                let length: Int
                let seed: UInt64
            }
            let cases = [
                WriteCase(name: "head-1B", offset: 0, length: 1, seed: 1),
                WriteCase(name: "unaligned-31B", offset: 1, length: 31, seed: 2),
                WriteCase(name: "cross-sm4-33B", offset: 15, length: 33, seed: 3),
                WriteCase(name: "cross-4K-4097B", offset: 4095, length: 4097, seed: 4),
                WriteCase(name: "unaligned-7777B", offset: 65531, length: 7777, seed: 5),
                WriteCase(name: "aligned-4K", offset: 512 * 3, length: 4096, seed: 6),
                WriteCase(name: "aligned-64K", offset: 512 * 41, length: 64 * 1024, seed: 7),
                WriteCase(name: "unaligned-64K", offset: 1024 * 1024 + 5, length: 64 * 1024 - 17, seed: 8),
                WriteCase(name: "aligned-1MiB", offset: 2 * 1024 * 1024, length: 1024 * 1024, seed: 9),
                WriteCase(name: "tail-1B", offset: size - 1, length: 1, seed: 10),
            ]

            for item in cases {
                let replacement = deterministicBytes(count: item.length, seed: item.seed)
                let beforeLeft = item.offset > 0 ? expected[item.offset - 1] : nil
                let rightIndex = item.offset + item.length
                let beforeRight = rightIndex < expected.count ? expected[rightIndex] : nil
                try active.write(at: UInt64(item.offset), data: replacement)
                expected.replaceSubrange(item.offset..<(item.offset + item.length), with: replacement)
                let readBack = try active.read(at: UInt64(item.offset), length: item.length)
                try require(readBack == replacement, "read-after-write mismatch: \(item.name)")
                if let beforeLeft {
                    try require(try active.read(at: UInt64(item.offset - 1), length: 1).first == beforeLeft,
                                "left neighbor corrupted: \(item.name)")
                }
                if let beforeRight {
                    try require(try active.read(at: UInt64(rightIndex), length: 1).first == beforeRight,
                                "right neighbor corrupted: \(item.name)")
                }
                print("WRITE_CASE_PASS=\(item.name):offset=\(item.offset):length=\(item.length)")
            }

            // Exercise the shared crypto RMW lock under concurrent callers. All
            // ranges are intentionally disjoint but unaligned to SM4 boundaries,
            // so corruption would expose an unsafe read-modify-encrypt-write path.
            var concurrentCases = [ConcurrentWriteCase]()
            for index in 0..<8 {
                let offset = 1_310_725 + index * 24_576
                let length = 16_385 + (index % 3) * 17
                let seed = UInt64(0xC000_0000) + UInt64(index)
                concurrentCases.append(ConcurrentWriteCase(
                    offset: offset,
                    length: length,
                    seed: seed
                ))
            }
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "edp.crypto.rw.matrix", attributes: .concurrent)
            let blockBox = SendableBlockBox(active)
            let errorBox = ConcurrentErrorBox()
            for item in concurrentCases {
                group.enter()
                queue.async {
                    defer { group.leave() }
                    do {
                        let payload = deterministicBytes(count: item.length, seed: item.seed)
                        try blockBox.block.write(at: UInt64(item.offset), data: payload)
                    } catch {
                        errorBox.append(error)
                    }
                }
            }
            try require(group.wait(timeout: .now() + 10) == .success, "concurrent writes timed out")
            let concurrentErrors = errorBox.snapshot()
            try require(concurrentErrors.isEmpty, "concurrent writes failed: \(concurrentErrors)")
            for item in concurrentCases {
                let payload = deterministicBytes(count: item.length, seed: item.seed)
                expected.replaceSubrange(item.offset..<(item.offset + item.length), with: payload)
                try require(
                    try active.read(at: UInt64(item.offset), length: item.length) == payload,
                    "concurrent write readback mismatch offset=\(item.offset)"
                )
            }
            try require(try active.read(at: 0, length: size) == expected, "full plaintext mismatch after concurrent writes")
            print("RESULT=RW_CONCURRENT_UNALIGNED_WRITES_SERIALIZED_PASS")

            let cipherBeforeZeroWrite = try Data(contentsOf: temp)
            try active.write(at: 123, data: Data())
            try require(try Data(contentsOf: temp) == cipherBeforeZeroWrite, "zero-length write changed ciphertext")

            try expectThrow("read-past-end") {
                _ = try active.read(at: UInt64(size - 1), length: 2)
            }
            try expectThrow("write-past-end") {
                try active.write(at: UInt64(size - 1), data: Data([1, 2]))
            }
            try expectThrow("write-offset-past-end") {
                try active.write(at: UInt64(size + 1), data: Data([1]))
            }

            try active.synchronize()
            let finalCipher = try Data(contentsOf: temp)
            try require(EDPCrypto.sha256([UInt8](finalCipher)) != initialCipherHash,
                        "ciphertext did not change after writes")
            try require(finalCipher != expected, "ciphertext leaked plaintext")
            try require(try active.read(at: 0, length: size) == expected, "full plaintext mismatch before close")
        }

        // The previous block/raw/reader graph is now out of scope. This is a real
        // descriptor close/reopen persistence check, not a second handle while the
        // first writer remains alive.
        let reopened = try makeWritableBlock(path: temp.path, size: size, key: key)
        try require(try reopened.read(at: 0, length: size) == expected, "persistence mismatch after true reopen")
        print("RESULT=RW_CIPHER_PERSISTENCE_AFTER_TRUE_REOPEN")

        let readOnlyRaw = try EDPFileRawDevice(path: temp.path, declaredSizeBytes: UInt64(size), writable: false)
        let readOnlyReader = try EDPEncryptedPartitionReader(
            raw: readOnlyRaw,
            descriptor: makeDescriptor(size: size, key: key)
        )
        try expectThrow("readonly-backing-upgrade") {
            _ = try EDPEncryptedReadWriteBlockDevice(reader: readOnlyReader)
        }

        print("RESULT=RW_RANDOM_AND_BOUNDARY_MATRIX_PASS")
        print("RESULT=RW_RMW_NEIGHBORS_PRESERVED")
        print("RESULT=RW_BOUNDS_AND_ZERO_LENGTH_PASS")
        print("RESULT=RW_READONLY_BACKING_CANNOT_UPGRADE")
        print("RESULT=EDP_ENCRYPTED_READWRITE_MATRIX_PASS")
    }
}
