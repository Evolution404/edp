import Foundation

struct EDPVolumeDescriptor: Sendable {
    let partitionType: UInt32
    let startSector: UInt64
    let sizeBytes: UInt64
    let algorithm: UInt32
    let fileKey: [UInt8]?
    let passwordCRC: UInt32
    let keyCRC: UInt32

    var startBytes: UInt64 { startSector * EDPMetadataProbe.legacySectorSize }
}

enum EDPVolumeMetadata {
    static let lba11Index: UInt64 = 11
    static let lba12Index: UInt64 = 12
    static let lba11ByteOffset = lba11Index * EDPMetadataProbe.legacySectorSize
    static let lba12ByteOffset = lba12Index * EDPMetadataProbe.legacySectorSize
    static let entrySize = 0x60

    static func chsCapacity(_ sizeBytes: UInt64) -> UInt64 {
        let cylinderBytes: UInt64 = 255 * 63 * 512
        return (sizeBytes / cylinderBytes) * cylinderBytes
    }

    static func deviceIDFromLBA11(
        _ raw: [UInt8],
        vidHex: String,
        pidHex: String,
        sizeBytes: UInt64
    ) -> String? {
        guard raw.count == 512 else { return nil }
        let random = Array(raw[0..<0x100])
        let cipher = Array(raw[0x100..<0x200])
        let vid = asciiPad4(vidHex)
        let pid = asciiPad4(pidHex)

        for candidateSize in [sizeBytes, chsCapacity(sizeBytes)] {
            let material = random + vid + pid + EDPCrypto.littleEndianBytes(candidateSize)
            let key = EDPCrypto.littleEndianBytes(EDPCrypto.crc32Bare(material))
            guard let plain = try? EDPA6B0.decrypt(cipher, keyRaw: key),
                  plain.count >= 4,
                  Array(plain[0..<4]) == Array("PDKB".utf8) else {
                continue
            }
            let payload = plain.dropFirst(4)
            let end = payload.firstIndex(of: 0) ?? payload.endIndex
            let bytes = Array(payload[..<end])
            if let value = String(bytes: bytes, encoding: .utf8), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func stablePhysicalDeviceID(
        metadataDeviceID: String,
        vidHex: String,
        pidHex: String,
        sizeBytes: UInt64
    ) -> String {
        var material = Array("EDP-PHYSICAL-ID-V2\0".utf8)
        material.append(contentsOf: Array(vidHex.utf8))
        material.append(0)
        material.append(contentsOf: Array(pidHex.utf8))
        material.append(0)
        material.append(contentsOf: Array(metadataDeviceID.utf8))
        material.append(0)
        material.append(contentsOf: EDPCrypto.littleEndianBytes(sizeBytes))
        let suffix = EDPCrypto.sha256(material).prefix(10)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(metadataDeviceID)#\(suffix)"
    }

    static func decodeLBA12(_ raw: [UInt8], deviceID: String) throws -> [UInt8] {
        guard raw.count == 512 else {
            throw EDPNativeCoreError.invalidInput("LBA12 must be exactly 512 bytes")
        }
        return try EDPA6B0.decrypt(raw, keyRaw: EDPCrypto.crcKey(deviceID))
    }

    static func deriveFileKey(entry: [UInt8], password: [UInt8]) -> [UInt8]? {
        guard entry.count >= 0x48 else { return nil }
        let salt = Array(entry[0x38..<0x48])
        let storedKeyCRC = readUInt32LE(entry, 0x34)
        let storedPasswordCRC = readUInt32LE(entry, 0x30)

        if storedPasswordCRC == EDPCrypto.crc32Bare(password),
           let fixedCipher = try? EDPSharedSM4(key: EDPCrypto.md5(Array("LtSWi[2f)j".utf8))),
           let candidate = try? fixedCipher.decryptAligned(salt),
           EDPCrypto.crc32Bare(candidate) == storedKeyCRC {
            return candidate
        }

        if let passwordCipher = try? EDPSharedSM4(key: EDPCrypto.md5(password)),
           let candidate = try? passwordCipher.decryptAligned(salt),
           EDPCrypto.crc32Bare(candidate) == storedKeyCRC {
            return candidate
        }
        return nil
    }

    static func parseLBA12Entries(_ plain: [UInt8], password: [UInt8]) throws -> [EDPVolumeDescriptor] {
        guard plain.count == 512 else {
            throw EDPNativeCoreError.invalidInput("LBA12 plaintext must be exactly 512 bytes")
        }

        let passwordCRC = EDPCrypto.crc32Bare(password)
        var volumes = [EDPVolumeDescriptor]()
        var offset = 0
        while offset + entrySize <= plain.count {
            let entry = Array(plain[offset..<(offset + entrySize)])
            guard Array(entry[0..<4]) == Array("EDPF".utf8) else { break }

            let partitionType = readUInt32LE(entry, 0x0c)
            let startSector = readUInt64LE(entry, 0x18)
            let sizeBytes = readUInt64LE(entry, 0x28)
            let storedPasswordCRC = readUInt32LE(entry, 0x30)
            let keyCRC = readUInt32LE(entry, 0x34)
            let algorithm = readUInt32LE(entry, 0x58)

            guard [UInt32(1), 2, 4].contains(partitionType) else {
                throw EDPNativeCoreError.parse("invalid LBA12 partition type: \(partitionType)")
            }
            if storedPasswordCRC != 0 && storedPasswordCRC != passwordCRC {
                offset += entrySize
                continue
            }
            if partitionType == 1 {
                offset += entrySize
                continue
            }
            if algorithm != 2 {
                if storedPasswordCRC == 0 && keyCRC == 0 {
                    offset += entrySize
                    continue
                }
                throw EDPNativeCoreError.parse("unsupported EDP data algorithm: \(algorithm)")
            }
            guard let fileKey = deriveFileKey(entry: entry, password: password) else {
                throw EDPNativeCoreError.verify("file key did not pass CRC closure for partition type \(partitionType)")
            }
            guard startSector != 0,
                  sizeBytes != 0,
                  sizeBytes % EDPMetadataProbe.legacySectorSize == 0 else {
                throw EDPNativeCoreError.parse("invalid partition bounds for type \(partitionType)")
            }

            volumes.append(EDPVolumeDescriptor(
                partitionType: partitionType,
                startSector: startSector,
                sizeBytes: sizeBytes,
                algorithm: algorithm,
                fileKey: fileKey,
                passwordCRC: storedPasswordCRC,
                keyCRC: keyCRC
            ))
            offset += entrySize
        }
        return volumes
    }

    private static func asciiPad4(_ value: String) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 4)
        for (index, byte) in value.utf8.prefix(4).enumerated() {
            output[index] = byte
        }
        return output
    }

    private static func readUInt32LE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readUInt64LE(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for shift in 0..<8 {
            value |= UInt64(bytes[offset + shift]) << UInt64(shift * 8)
        }
        return value
    }
}
