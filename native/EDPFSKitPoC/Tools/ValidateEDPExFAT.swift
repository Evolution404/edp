import Foundation

private enum ExFATValidationFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        if case .message(let value) = self { return value }
        return "exFAT validation failed"
    }
}

private final class ExFATMemoryRaw: EDPRawReadable {
    private let bytes: Data

    init(_ bytes: Data) {
        self.bytes = bytes
    }

    var sizeBytes: UInt64? { UInt64(bytes.count) }

    func readExact(at offset: UInt64, length: Int) throws -> Data {
        guard length >= 0,
              offset <= UInt64(Int.max),
              UInt64(length) <= UInt64(Int.max) - offset else {
            throw ExFATValidationFailure.message("invalid memory read")
        }
        let start = Int(offset)
        let end = start + length
        guard end <= bytes.count else {
            throw ExFATValidationFailure.message("memory read past end")
        }
        return bytes.subdata(in: start..<end)
    }
}

@main
struct ValidateEDPExFAT {
    private static let sectorSize = 512
    private static let sectorCount = 2048
    private static let fatOffset = 24
    private static let clusterHeapOffset = 25

    static func main() throws {
        let plain = makeSyntheticExFAT()

        let direct = try EDPExFATReader(raw: ExFATMemoryRaw(plain))
        try validate(reader: direct, prefix: "PLAIN")

        let key = Array(0..<16).map { UInt8($0 * 9 + 1) }
        let cipher = try EDPSM4(key: key)
        let encrypted = try cipher.encryptAligned([UInt8](plain))
        var backing = Data(count: sectorSize)
        backing.append(contentsOf: encrypted)

        let descriptor = EDPVolumeDescriptor(
            partitionType: 4,
            startSector: 1,
            sizeBytes: UInt64(plain.count),
            algorithm: 2,
            fileKey: key,
            passwordCRC: 0,
            keyCRC: EDPCrypto.crc32Bare(key)
        )
        let decrypted = try EDPEncryptedPartitionReader(
            raw: ExFATMemoryRaw(backing),
            descriptor: descriptor
        )
        let encryptedReader = try EDPExFATReader(raw: decrypted)
        try validate(reader: encryptedReader, prefix: "ENCRYPTED")

        print("RESULT=SWIFT_NATIVE_EXFAT_CORE_OK")
        print("RESULT=EDP_ENCRYPTED_EXFAT_CHAIN_OK")
    }

    private static func validate(reader: EDPExFATReader, prefix: String) throws {
        try require(reader.boot.bytesPerSector == 512, "\(prefix): sector size mismatch")
        try require(reader.boot.bytesPerCluster == 512, "\(prefix): cluster size mismatch")
        try require(try reader.volumeLabel() == "EDPTEST", "\(prefix): volume label mismatch")

        let root = try reader.listRootDirectory()
        try require(root.count == 2, "\(prefix): root child count mismatch")

        guard let hello = try reader.lookup(name: "hello.txt") else {
            throw ExFATValidationFailure.message("\(prefix): case-insensitive lookup failed")
        }
        try require(hello.name == "HELLO.TXT", "\(prefix): file name mismatch")
        try require(!hello.isDirectory, "\(prefix): HELLO.TXT unexpectedly directory")
        try require(hello.noFatChain, "\(prefix): HELLO.TXT should be contiguous")
        try require(
            try reader.readFile(hello, at: 0, length: 1024) == Data("Hello, FSKit!".utf8),
            "\(prefix): contiguous file read mismatch"
        )
        try require(
            try reader.readFile(hello, at: 7, length: 5) == Data("FSKit".utf8),
            "\(prefix): unaligned contiguous file read mismatch"
        )

        guard let chained = try reader.lookup(name: "CHAIN.BIN") else {
            throw ExFATValidationFailure.message("\(prefix): chained file lookup failed")
        }
        try require(!chained.noFatChain, "\(prefix): CHAIN.BIN should use FAT")
        let crossing = try reader.readFile(chained, at: 500, length: 40)
        let expected = Data((500..<540).map { UInt8(($0 * 13 + 7) & 0xff) })
        try require(crossing == expected, "\(prefix): FAT-chain boundary read mismatch")

        print("\(prefix)_EXFAT_BOOT=OK")
        print("\(prefix)_EXFAT_DIRECTORY=OK")
        print("\(prefix)_EXFAT_FILE_READ=OK")
    }

    private static func makeSyntheticExFAT() -> Data {
        var image = Data(count: sectorSize * sectorCount)

        image[0] = 0xeb
        image[1] = 0x76
        image[2] = 0x90
        replace(&image, at: 3, with: Array("EXFAT   ".utf8))
        putUInt64(&image, at: 64, 0)
        putUInt64(&image, at: 72, UInt64(sectorCount))
        putUInt32(&image, at: 80, UInt32(fatOffset))
        putUInt32(&image, at: 84, 1)
        putUInt32(&image, at: 88, UInt32(clusterHeapOffset))
        putUInt32(&image, at: 92, 100)
        putUInt32(&image, at: 96, 2)
        putUInt32(&image, at: 100, 0x1234_5678)
        putUInt16(&image, at: 104, 0x0100)
        putUInt16(&image, at: 106, 0)
        image[108] = 9
        image[109] = 0
        image[110] = 1
        image[111] = 0x80
        image[112] = 4
        image[510] = 0x55
        image[511] = 0xaa

        let fatBase = fatOffset * sectorSize
        putUInt32(&image, at: fatBase, 0xffff_fff8)
        putUInt32(&image, at: fatBase + 4, 0xffff_ffff)
        putUInt32(&image, at: fatBase + 2 * 4, 0xffff_ffff)
        putUInt32(&image, at: fatBase + 3 * 4, 0xffff_ffff)
        putUInt32(&image, at: fatBase + 4 * 4, 5)
        putUInt32(&image, at: fatBase + 5 * 4, 0xffff_ffff)

        let rootBase = clusterOffset(cluster: 2)
        var cursor = rootBase

        var label = [UInt8](repeating: 0, count: 32)
        label[0] = 0x83
        let labelUnits = Array("EDPTEST".utf16)
        label[1] = UInt8(labelUnits.count)
        for (index, unit) in labelUnits.enumerated() {
            label[2 + index * 2] = UInt8(truncatingIfNeeded: unit)
            label[3 + index * 2] = UInt8(truncatingIfNeeded: unit >> 8)
        }
        replace(&image, at: cursor, with: label)
        cursor += 32

        let hello = makeFileEntrySet(
            name: "HELLO.TXT",
            firstCluster: 3,
            dataLength: 13,
            noFatChain: true,
            attributes: 0x20
        )
        replace(&image, at: cursor, with: hello)
        cursor += hello.count

        let chained = makeFileEntrySet(
            name: "CHAIN.BIN",
            firstCluster: 4,
            dataLength: 700,
            noFatChain: false,
            attributes: 0x20
        )
        replace(&image, at: cursor, with: chained)
        cursor += chained.count
        image[cursor] = 0x00

        replace(&image, at: clusterOffset(cluster: 3), with: Array("Hello, FSKit!".utf8))

        let chainedBytes = (0..<700).map { UInt8(($0 * 13 + 7) & 0xff) }
        replace(&image, at: clusterOffset(cluster: 4), with: Array(chainedBytes[0..<512]))
        replace(&image, at: clusterOffset(cluster: 5), with: Array(chainedBytes[512..<700]))

        return image
    }

    private static func makeFileEntrySet(
        name: String,
        firstCluster: UInt32,
        dataLength: UInt64,
        noFatChain: Bool,
        attributes: UInt16
    ) -> [UInt8] {
        let nameUnits = Array(name.utf16)
        precondition(!nameUnits.isEmpty && nameUnits.count <= 15)

        var primary = [UInt8](repeating: 0, count: 32)
        primary[0] = 0x85
        primary[1] = 2
        putUInt16(&primary, at: 4, attributes)

        var stream = [UInt8](repeating: 0, count: 32)
        stream[0] = 0xc0
        stream[1] = noFatChain ? 0x02 : 0x00
        stream[3] = UInt8(nameUnits.count)
        putUInt64(&stream, at: 8, dataLength)
        putUInt32(&stream, at: 20, firstCluster)
        putUInt64(&stream, at: 24, dataLength)

        var fileName = [UInt8](repeating: 0, count: 32)
        fileName[0] = 0xc1
        for (index, unit) in nameUnits.enumerated() {
            fileName[2 + index * 2] = UInt8(truncatingIfNeeded: unit)
            fileName[3 + index * 2] = UInt8(truncatingIfNeeded: unit >> 8)
        }

        var set = primary + stream + fileName
        let checksum = setChecksum(set)
        putUInt16(&set, at: 2, checksum)
        return set
    }

    private static func setChecksum(_ bytes: [UInt8]) -> UInt16 {
        var checksum: UInt16 = 0
        for index in bytes.indices {
            if index == 2 || index == 3 { continue }
            checksum = ((checksum & 1) != 0 ? 0x8000 : 0) | (checksum >> 1)
            checksum = checksum &+ UInt16(bytes[index])
        }
        return checksum
    }

    private static func clusterOffset(cluster: UInt32) -> Int {
        (clusterHeapOffset + Int(cluster - 2)) * sectorSize
    }

    private static func replace(_ data: inout Data, at offset: Int, with bytes: [UInt8]) {
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    private static func putUInt16(_ data: inout Data, at offset: Int, _ value: UInt16) {
        replace(
            &data,
            at: offset,
            with: [
                UInt8(truncatingIfNeeded: value),
                UInt8(truncatingIfNeeded: value >> 8),
            ]
        )
    }

    private static func putUInt32(_ data: inout Data, at offset: Int, _ value: UInt32) {
        replace(&data, at: offset, with: EDPCrypto.littleEndianBytes(value))
    }

    private static func putUInt64(_ data: inout Data, at offset: Int, _ value: UInt64) {
        replace(&data, at: offset, with: EDPCrypto.littleEndianBytes(value))
    }

    private static func putUInt16(_ bytes: inout [UInt8], at offset: Int, _ value: UInt16) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private static func putUInt32(_ bytes: inout [UInt8], at offset: Int, _ value: UInt32) {
        let encoded = EDPCrypto.littleEndianBytes(value)
        bytes.replaceSubrange(offset..<(offset + 4), with: encoded)
    }

    private static func putUInt64(_ bytes: inout [UInt8], at offset: Int, _ value: UInt64) {
        let encoded = EDPCrypto.littleEndianBytes(value)
        bytes.replaceSubrange(offset..<(offset + 8), with: encoded)
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() {
            throw ExFATValidationFailure.message(message)
        }
    }
}
