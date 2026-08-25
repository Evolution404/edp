import Foundation

private enum ValidationFailure: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        if case .message(let value) = self { return value }
        return "validation failed"
    }
}

private final class MemoryRawReadable: EDPRawReadable {
    let bytes: Data
    init(_ bytes: Data) { self.bytes = bytes }
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
}

@main
struct ValidateEDPNativeCore {
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

        var lba12Count = 0
        var lba11Count = 0
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
        print("RESULT=SWIFT_NATIVE_CRYPTO_CORE_OK")
        print("RESULT=SWIFT_NATIVE_LBA11_LBA12_OK")
        print("RESULT=SWIFT_NATIVE_ENCRYPTED_READER_OK")
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
        print("NATIVE_CRC32_GOLDEN=OK")
    }

    private static func validateSM4() throws {
        let key = try hexBytes("0123456789abcdeffedcba9876543210")
        let plain = try hexBytes("0123456789abcdeffedcba9876543210")
        let expected = try hexBytes("681edf34d206965e86b3e94f536e4246")
        let cipher = try EDPSM4(key: key)
        try require(try cipher.encryptAligned(plain) == expected, "SM4 standard encryption vector mismatch")
        try require(try cipher.decryptAligned(expected) == plain, "SM4 standard decryption vector mismatch")

        var entry = [UInt8](repeating: 0, count: EDPVolumeMetadata.entrySize)
        entry.replaceSubrange(0..<4, with: Array("EDPF".utf8))
        entry.replaceSubrange(0x30..<0x34, with: EDPCrypto.littleEndianBytes(UInt32(0x0429_735d)))
        entry.replaceSubrange(0x34..<0x38, with: EDPCrypto.littleEndianBytes(UInt32(0x418c_1a0c)))
        entry.replaceSubrange(0x38..<0x48, with: try hexBytes("56fd7c10288df7fd8752dc94bb2d5eee"))
        let fileKey = EDPVolumeMetadata.deriveFileKey(entry: entry, password: Array("0000aaaa".utf8))
        try require(fileKey == hexBytes("1a28e58ce2c0e3eb16877ad38586f2e2"), "real Lexar file-key unwrap mismatch")
        print("NATIVE_SM4_GOLDEN=OK")
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
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() {
            throw ValidationFailure.message(message)
        }
    }

    private static func number(_ value: Any?) -> NSNumber {
        value as? NSNumber ?? 0
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
