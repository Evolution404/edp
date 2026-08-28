import Foundation

private enum ValidationFailure: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        if case .message(let value) = self { return value }
        return "validation failed"
    }
}

private final class MemoryRawReadable: EDPRawWritable {
    private(set) var bytes: Data
    let allowsWrites: Bool
    private(set) var synchronizeCount = 0

    init(_ bytes: Data, allowsWrites: Bool = true) {
        self.bytes = bytes
        self.allowsWrites = allowsWrites
    }
    var sizeBytes: UInt64? { UInt64(bytes.count) }

    func readExact(at offset: UInt64, length: Int) throws -> Data {
        guard length >= 0,
              offset <= UInt64(Int.max),
              UInt64(length) <= UInt64(Int.max) - offset else {
            throw ValidationFailure.message("invalid memory read")
        }
        let start = Int(offset)
        let end = start + length
        guard end <= bytes.count else {
            throw ValidationFailure.message("memory read past end")
        }
        return bytes.subdata(in: start..<end)
    }

    func writeExact(at offset: UInt64, data: Data) throws {
        guard allowsWrites else {
            throw ValidationFailure.message("memory storage is read-only")
        }
        guard offset <= UInt64(Int.max),
              UInt64(data.count) <= UInt64(Int.max) - offset else {
            throw ValidationFailure.message("invalid memory write")
        }
        let start = Int(offset)
        let end = start + data.count
        guard end <= bytes.count else {
            throw ValidationFailure.message("memory write past end")
        }
        bytes.replaceSubrange(start..<end, with: data)
    }

    func synchronize() throws {
        guard allowsWrites else {
            throw ValidationFailure.message("memory storage is read-only")
        }
        synchronizeCount += 1
    }
}

@main
struct ValidateEDPNativeCore {
    private struct DeterministicRNG {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
            return state
        }
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw ValidationFailure.message("usage: ValidateEDPNativeCore <fixtures/golden/disks.json>")
        }
        let rootData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let root = try JSONSerialization.jsonObject(with: rootData) as? [String: Any],
              let disks = root["disks"] as? [[String: Any]] else {
            throw ValidationFailure.message("invalid golden fixture JSON")
        }

        try validateCRC()
        try validateSM4()
        try validateEncryptedReader()
        try validateEncryptedWriter()
        try validateStablePhysicalDeviceID()
        try validateMetadataErrorPaths()

        var lba12Count = 0
        var lba11Count = 0
        var randomizedRealKeyDisks = 0
        for disk in disks {
            guard let name = disk["name"] as? String,
                  let deviceID = disk["device_id"] as? String,
                  let password = disk["password"] as? String else {
                throw ValidationFailure.message("golden disk is missing identity fields")
            }

            if let lba12 = disk["lba12"] as? [String: Any],
               let cipherHex = lba12["cipher_hex"] as? String,
               let plainHex = lba12["plain_hex"] as? String {
                let cipher = try hexBytes(cipherHex)
                let expectedPlain = try hexBytes(plainHex)
                let actualPlain = try EDPVolumeMetadata.decodeLBA12(cipher, deviceID: deviceID)
                try require(actualPlain == expectedPlain, "\(name): native A6B0 LBA12 decode mismatch")

                let parsed = try EDPVolumeMetadata.parseLBA12Entries(actualPlain, password: Array(password.utf8))
                let expectedEntries = (disk["entries"] as? [[String: Any]] ?? []).filter {
                    let type = number($0["partition_type"]).uint32Value
                    let algo = number($0["algo"]).uint32Value
                    return type != 1 && algo == 2
                }
                try require(parsed.count == expectedEntries.count, "\(name): LBA12 data-volume count mismatch")
                for (volume, expected) in zip(parsed, expectedEntries) {
                    try require(volume.partitionType == number(expected["partition_type"]).uint32Value, "\(name): partition type mismatch")
                    try require(volume.startSector == number(expected["start_sector"]).uint64Value, "\(name): start sector mismatch")
                    try require(volume.sizeBytes == number(expected["size_bytes"]).uint64Value, "\(name): size mismatch")
                    try require(volume.algorithm == number(expected["algo"]).uint32Value, "\(name): algorithm mismatch")
                    if let expectedKeyHex = expected["file_key_hex"] as? String {
                        try require(volume.fileKey == hexBytes(expectedKeyHex), "\(name): file key mismatch")
                    }
                }

                if (name == "disk4_real_lexar" || name == "disk5_real_sandisk"),
                   let realKey = parsed.compactMap({ $0.fileKey }).first {
                    try validateRandomizedEncryptedReads(
                        key: realKey,
                        label: name,
                        seed: deterministicSeed(for: realKey)
                    )
                    randomizedRealKeyDisks += 1
                }

                lba12Count += 1
                print("NATIVE_LBA12_GOLDEN=OK:\(name)")
            }

            if disk["device_id_source"] as? String == "lba11",
               let lba11 = disk["lba11"] as? [String: Any],
               let rawHex = lba11["cipher_hex"] as? String,
               let params = disk["lba11_params"] as? [String: Any],
               let vid = params["vid"] as? String,
               let pid = params["pid"] as? String {
                let got = EDPVolumeMetadata.deviceIDFromLBA11(
                    try hexBytes(rawHex),
                    vidHex: vid,
                    pidHex: pid,
                    sizeBytes: number(params["size_bytes"]).uint64Value
                )
                try require(got == deviceID, "\(name): native LBA11 device_id mismatch")
                lba11Count += 1
                print("NATIVE_LBA11_GOLDEN=OK:\(name)")
            }
        }

        try require(lba12Count >= 2, "expected at least two real LBA12 golden disks")
        try require(lba11Count >= 1, "expected at least one real LBA11 golden disk")
        try require(randomizedRealKeyDisks >= 2, "expected randomized reads for both captured real-disk keys")
        print("NATIVE_REAL_KEY_RANDOM_READS=OK:disks=\(randomizedRealKeyDisks):cases=\(randomizedRealKeyDisks * 512)")
        print("RESULT=SWIFT_NATIVE_CRYPTO_CORE_OK")
        print("RESULT=SWIFT_NATIVE_LBA11_LBA12_OK")
        print("RESULT=SWIFT_NATIVE_ENCRYPTED_READER_OK")
        print("RESULT=SWIFT_NATIVE_ENCRYPTED_WRITER_OK")
    }

    private static func validateStablePhysicalDeviceID() throws {
        let first = EDPVolumeMetadata.stablePhysicalDeviceID(
            metadataDeviceID: "disk&ven_fixture&prod_usb",
            vidHex: "21c4",
            pidHex: "0cd1",
            sizeBytes: 64 * 1024 * 1024
        )
        let repeated = EDPVolumeMetadata.stablePhysicalDeviceID(
            metadataDeviceID: "disk&ven_fixture&prod_usb",
            vidHex: "21c4",
            pidHex: "0cd1",
            sizeBytes: 64 * 1024 * 1024
        )
        let second = EDPVolumeMetadata.stablePhysicalDeviceID(
            metadataDeviceID: "disk&ven_fixture&prod_usb",
            vidHex: "21c4",
            pidHex: "0cd1",
            sizeBytes: 128 * 1024 * 1024
        )
        try require(first == repeated, "physical device ID must be deterministic")
        try require(first != second, "capacity must participate in physical device ID")
        print("RESULT=STABLE_PHYSICAL_DEVICE_ID_UNIQUE")
    }

    private static func validateCRC() throws {
        try require(
            EDPCrypto.crc32Bare(Array("disk&ven_lexar&prod_usb_flash_drive".utf8)) == 0x6bba_eefb,
            "Lexar CRC32 golden mismatch"
        )
        try require(
            EDPCrypto.crc32Bare(Array("0000aaaa".utf8)) == 0x0429_735d,
            "default password CRC32 golden mismatch"
        )
        try require(EDPCrypto.crc32Bare([]) == 0, "empty CRC32 baseline mismatch")
        print("NATIVE_CRC32_GOLDEN=OK")
    }

    private static func validateSM4() throws {
        let key = try hexBytes("0123456789abcdeffedcba9876543210")
        let plain = try hexBytes("0123456789abcdeffedcba9876543210")
        let expected = try hexBytes("681edf34d206965e86b3e94f536e4246")
        let cipher = try EDPSM4(key: key)
        try require(try cipher.encryptAligned(plain) == expected, "SM4 standard encryption vector mismatch")
        try require(try cipher.decryptAligned(expected) == plain, "SM4 standard decryption vector mismatch")
        try require((try cipher.encryptAligned([])).isEmpty, "SM4 empty input should remain empty")

        try expectThrows("SM4 accepted a 15-byte key") {
            _ = try EDPSM4(key: [UInt8](repeating: 0, count: 15))
        }
        try expectThrows("SM4 accepted unaligned ECB input") {
            _ = try cipher.encryptAligned([UInt8](repeating: 0, count: 15))
        }
        try expectThrows("A6B0 accepted empty key material") {
            _ = try EDPA6B0.decrypt([UInt8](repeating: 0, count: 16), keyRaw: [])
        }
        try expectThrows("A6B0 accepted unaligned input") {
            _ = try EDPA6B0.decrypt([UInt8](repeating: 0, count: 15), keyRaw: [0x01])
        }

        var entry = [UInt8](repeating: 0, count: EDPVolumeMetadata.entrySize)
        entry.replaceSubrange(0..<4, with: Array("EDPF".utf8))
        entry.replaceSubrange(0x30..<0x34, with: EDPCrypto.littleEndianBytes(UInt32(0x0429_735d)))
        entry.replaceSubrange(0x34..<0x38, with: EDPCrypto.littleEndianBytes(UInt32(0x418c_1a0c)))
        entry.replaceSubrange(0x38..<0x48, with: try hexBytes("56fd7c10288df7fd8752dc94bb2d5eee"))
        let fileKey = EDPVolumeMetadata.deriveFileKey(entry: entry, password: Array("0000aaaa".utf8))
        try require(fileKey == hexBytes("1a28e58ce2c0e3eb16877ad38586f2e2"), "real Lexar file-key unwrap mismatch")
        try require(
            EDPVolumeMetadata.deriveFileKey(entry: [UInt8](repeating: 0, count: 0x47), password: []) == nil,
            "short key entry should be rejected"
        )
        print("NATIVE_SM4_GOLDEN=OK")
        print("NATIVE_CRYPTO_NEGATIVE_PATHS=OK")
    }

    private static func validateEncryptedReader() throws {
        let key = try hexBytes("0123456789abcdeffedcba9876543210")
        let plaintext = (0..<64).map { UInt8(($0 * 7 + 3) & 0xff) }
        let cipher = try EDPSM4(key: key)
        let encrypted = try cipher.encryptAligned(plaintext)
        var backing = Data(count: 512)
        backing.append(contentsOf: encrypted)
        let raw = MemoryRawReadable(backing)
        let descriptor = EDPVolumeDescriptor(
            partitionType: 4,
            startSector: 1,
            sizeBytes: 64,
            algorithm: 2,
            fileKey: key,
            passwordCRC: 0,
            keyCRC: EDPCrypto.crc32Bare(key)
        )
        let reader = try EDPEncryptedPartitionReader(raw: raw, descriptor: descriptor)
        let actual = try reader.readExact(at: 7, length: 37)
        try require([UInt8](actual) == Array(plaintext[7..<44]), "unaligned encrypted partition read mismatch")
        try require((try reader.readExact(at: 64, length: 0)).isEmpty, "zero-length boundary read should succeed")
        try require(
            [UInt8](try reader.readExact(at: 63, length: 1)) == [plaintext[63]],
            "last-byte encrypted partition read mismatch"
        )
        try expectThrows("encrypted reader accepted out-of-bounds read") {
            _ = try reader.readExact(at: 64, length: 1)
        }
        try expectThrows("encrypted reader accepted overflowing range") {
            _ = try reader.readExact(at: UInt64.max, length: 1)
        }

        let missingKey = EDPVolumeDescriptor(
            partitionType: 4,
            startSector: 1,
            sizeBytes: 64,
            algorithm: 2,
            fileKey: nil,
            passwordCRC: 0,
            keyCRC: 0
        )
        try expectThrows("encrypted reader accepted algorithm 2 without a file key") {
            _ = try EDPEncryptedPartitionReader(raw: raw, descriptor: missingKey)
        }

        let passthroughDescriptor = EDPVolumeDescriptor(
            partitionType: 4,
            startSector: 1,
            sizeBytes: 64,
            algorithm: 0,
            fileKey: nil,
            passwordCRC: 0,
            keyCRC: 0
        )
        let passthrough = try EDPEncryptedPartitionReader(raw: raw, descriptor: passthroughDescriptor)
        let passthroughBytes = try passthrough.readExact(at: 5, length: 13)
        try require(
            [UInt8](passthroughBytes) == Array(encrypted[5..<18]),
            "non-SM4 partition should read through without decryption"
        )
        print("NATIVE_ENCRYPTED_READER_BOUNDARIES=OK")
    }

    private static func validateEncryptedWriter() throws {
        let key = try hexBytes("0123456789abcdeffedcba9876543210")
        var expected = (0..<256).map { UInt8(($0 * 11 + 5) & 0xff) }
        let cipher = try EDPSM4(key: key)
        let encrypted = try cipher.encryptAligned(expected)
        let prefix = [UInt8](repeating: 0xa5, count: 512)
        let suffix = [UInt8](repeating: 0x5a, count: 64)
        let raw = MemoryRawReadable(Data(prefix + encrypted + suffix))
        let descriptor = EDPVolumeDescriptor(
            partitionType: 2,
            startSector: 1,
            sizeBytes: UInt64(expected.count),
            algorithm: 2,
            fileKey: key,
            passwordCRC: 0,
            keyCRC: EDPCrypto.crc32Bare(key)
        )
        let reader = try EDPEncryptedPartitionReader(raw: raw, descriptor: descriptor)
        let block = try EDPEncryptedReadWriteBlockDevice(reader: reader)

        let unaligned = (0..<37).map { UInt8(0xf0 ^ $0) }
        try block.write(at: 7, data: Data(unaligned))
        expected.replaceSubrange(7..<44, with: unaligned)

        let aligned = (0..<32).map { UInt8(0x80 &+ UInt8($0)) }
        try block.write(at: 64, data: Data(aligned))
        expected.replaceSubrange(64..<96, with: aligned)

        let spanning = (0..<65).map { UInt8(($0 * 19 + 1) & 0xff) }
        try block.write(at: 127, data: Data(spanning))
        expected.replaceSubrange(127..<192, with: spanning)
        try block.write(at: UInt64(expected.count), data: Data())
        try block.synchronize()

        try require(
            [UInt8](try block.read(at: 0, length: expected.count)) == expected,
            "encrypted writer plaintext readback mismatch"
        )
        try require(raw.synchronizeCount == 1, "encrypted writer sync was not forwarded")
        try require(
            [UInt8](raw.bytes.prefix(prefix.count)) == prefix,
            "encrypted writer modified bytes before the partition"
        )
        try require(
            [UInt8](raw.bytes.suffix(suffix.count)) == suffix,
            "encrypted writer modified bytes after the partition"
        )
        let storedCipher = [UInt8](raw.bytes[512..<(512 + expected.count)])
        try require(
            try cipher.decryptAligned(storedCipher) == expected,
            "encrypted writer persisted incorrect ciphertext"
        )
        try require(storedCipher != expected, "encrypted writer stored plaintext")

        try expectThrows("encrypted writer accepted out-of-bounds write") {
            try block.write(at: UInt64(expected.count), data: Data([1]))
        }
        try expectThrows("encrypted writer accepted overflowing offset") {
            try block.write(at: UInt64.max, data: Data([1]))
        }

        let readOnlyRaw = MemoryRawReadable(raw.bytes, allowsWrites: false)
        let readOnlyReader = try EDPEncryptedPartitionReader(
            raw: readOnlyRaw,
            descriptor: descriptor
        )
        try expectThrows("read/write block accepted a read-only backing") {
            _ = try EDPEncryptedReadWriteBlockDevice(reader: readOnlyReader)
        }

        print("NATIVE_ENCRYPTED_WRITER_BOUNDARIES=OK")
        print("NATIVE_ENCRYPTED_WRITER_CIPHERTEXT_PERSISTENCE=OK")
    }

    private static func validateRandomizedEncryptedReads(
        key: [UInt8],
        label: String,
        seed: UInt64
    ) throws {
        let plaintext = (0..<8192).map { index in
            UInt8(truncatingIfNeeded: (index &* 73) ^ (index >> 3) ^ 0xa5)
        }
        let cipher = try EDPSM4(key: key)
        let encrypted = try cipher.encryptAligned(plaintext)
        let startSector: UInt64 = 3
        var backing = Data(count: Int(startSector * 512))
        backing.append(contentsOf: encrypted)

        let descriptor = EDPVolumeDescriptor(
            partitionType: 4,
            startSector: startSector,
            sizeBytes: UInt64(plaintext.count),
            algorithm: 2,
            fileKey: key,
            passwordCRC: 0,
            keyCRC: EDPCrypto.crc32Bare(key)
        )
        let reader = try EDPEncryptedPartitionReader(raw: MemoryRawReadable(backing), descriptor: descriptor)

        let boundaryOffsets = [0, 1, 15, 16, 17, 511, 512, 513, 4095, 4096, 4097, 8191, 8192]
        let boundaryLengths = [0, 1, 2, 15, 16, 17, 31, 32, 63, 64, 255, 512]
        for offset in boundaryOffsets {
            for length in boundaryLengths where offset + length <= plaintext.count {
                let actual = try reader.readExact(at: UInt64(offset), length: length)
                let expected = Data(plaintext[offset..<(offset + length)])
                try require(actual == expected, "\(label): boundary randomized reader mismatch offset=\(offset) length=\(length)")
            }
        }

        var rng = DeterministicRNG(seed: seed)
        for caseIndex in 0..<512 {
            let offset = Int(rng.next() % UInt64(plaintext.count + 1))
            let remaining = plaintext.count - offset
            let maximumLength = min(remaining, 1024)
            let length = maximumLength == 0 ? 0 : Int(rng.next() % UInt64(maximumLength + 1))
            let actual = try reader.readExact(at: UInt64(offset), length: length)
            let expected = Data(plaintext[offset..<(offset + length)])
            try require(
                actual == expected,
                "\(label): randomized reader mismatch case=\(caseIndex) offset=\(offset) length=\(length)"
            )
        }

        print("NATIVE_REAL_KEY_RANDOM_READS=OK:\(label):cases=512")
    }

    private static func validateMetadataErrorPaths() throws {
        let cylinderBytes: UInt64 = 255 * 63 * 512
        try require(EDPVolumeMetadata.chsCapacity(0) == 0, "zero CHS capacity mismatch")
        try require(
            EDPVolumeMetadata.chsCapacity(cylinderBytes + 511) == cylinderBytes,
            "CHS capacity should floor to a whole cylinder"
        )
        try require(
            EDPVolumeMetadata.deviceIDFromLBA11([0], vidHex: "1234", pidHex: "5678", sizeBytes: 1) == nil,
            "short LBA11 should be rejected"
        )
        try expectThrows("decodeLBA12 accepted a short sector") {
            _ = try EDPVolumeMetadata.decodeLBA12([UInt8](repeating: 0, count: 511), deviceID: "device")
        }
        try expectThrows("parseLBA12Entries accepted a short sector") {
            _ = try EDPVolumeMetadata.parseLBA12Entries([UInt8](repeating: 0, count: 511), password: [])
        }

        var invalidType = [UInt8](repeating: 0, count: 512)
        invalidType.replaceSubrange(0..<4, with: Array("EDPF".utf8))
        writeUInt32LE(99, to: &invalidType, at: 0x0c)
        try expectThrows("LBA12 parser accepted an invalid partition type") {
            _ = try EDPVolumeMetadata.parseLBA12Entries(invalidType, password: [])
        }

        var wrongPassword = [UInt8](repeating: 0, count: 512)
        wrongPassword.replaceSubrange(0..<4, with: Array("EDPF".utf8))
        writeUInt32LE(4, to: &wrongPassword, at: 0x0c)
        writeUInt64LE(1, to: &wrongPassword, at: 0x18)
        writeUInt64LE(512, to: &wrongPassword, at: 0x28)
        writeUInt32LE(0xdead_beef, to: &wrongPassword, at: 0x30)
        writeUInt32LE(2, to: &wrongPassword, at: 0x58)
        let skipped = try EDPVolumeMetadata.parseLBA12Entries(wrongPassword, password: Array("wrong".utf8))
        try require(skipped.isEmpty, "wrong-password LBA12 entry should be skipped")

        var unsupported = [UInt8](repeating: 0, count: 512)
        unsupported.replaceSubrange(0..<4, with: Array("EDPF".utf8))
        writeUInt32LE(4, to: &unsupported, at: 0x0c)
        writeUInt64LE(1, to: &unsupported, at: 0x18)
        writeUInt64LE(512, to: &unsupported, at: 0x28)
        writeUInt32LE(1, to: &unsupported, at: 0x34)
        writeUInt32LE(3, to: &unsupported, at: 0x58)
        try expectThrows("LBA12 parser accepted unsupported data algorithm") {
            _ = try EDPVolumeMetadata.parseLBA12Entries(unsupported, password: [])
        }

        print("NATIVE_METADATA_NEGATIVE_PATHS=OK")
    }

    private static func deterministicSeed(for key: [UInt8]) -> UInt64 {
        var seed: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key {
            seed ^= UInt64(byte)
            seed = seed &* 0x0000_0100_0000_01b3
        }
        return seed
    }

    private static func expectThrows(_ message: String, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch {
            return
        }
        throw ValidationFailure.message(message)
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() {
            throw ValidationFailure.message(message)
        }
    }

    private static func number(_ value: Any?) -> NSNumber {
        value as? NSNumber ?? 0
    }

    private static func writeUInt32LE(_ value: UInt32, to bytes: inout [UInt8], at offset: Int) {
        bytes.replaceSubrange(offset..<(offset + 4), with: EDPCrypto.littleEndianBytes(value))
    }

    private static func writeUInt64LE(_ value: UInt64, to bytes: inout [UInt8], at offset: Int) {
        bytes.replaceSubrange(offset..<(offset + 8), with: EDPCrypto.littleEndianBytes(value))
    }

    private static func hexBytes(_ value: String) throws -> [UInt8] {
        guard value.count % 2 == 0 else {
            throw ValidationFailure.message("odd-length hex string")
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                throw ValidationFailure.message("invalid hex string")
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
