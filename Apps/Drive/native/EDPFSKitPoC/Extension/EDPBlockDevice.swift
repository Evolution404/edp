import Foundation

/// Filesystem-agnostic logical block view exposed by the EDP crypto layer.
///
/// This protocol intentionally knows nothing about macFUSE, DiskImages2,
/// FSKit, partitions inside the decrypted volume, or any concrete filesystem.
/// Read-only and explicit read/write product modes share this boundary while
/// preserving separate unlock and C-ABI entry points.
protocol EDPBlockReadable: AnyObject {
    var sizeBytes: UInt64 { get }

    func read(at offset: UInt64, length: Int) throws -> Data
    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws
}

extension EDPBlockReadable {
    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws {
        let data = try read(at: offset, length: buffer.count)
        guard data.count == buffer.count else {
            throw EDPNativeCoreError.verify("block read returned an unexpected byte count")
        }
        _ = data.copyBytes(to: buffer.bindMemory(to: UInt8.self))
    }
}

protocol EDPBlockWritable: EDPBlockReadable {
    func write(at offset: UInt64, data: Data) throws
    func synchronize() throws
    func forceDurability() throws
}

extension EDPBlockWritable {
    func forceDurability() throws {
        try synchronize()
    }
}

/// Adapts the existing encrypted-partition reader to the product block-view
/// contract without changing its crypto semantics.
final class EDPEncryptedReadOnlyBlockDevice: EDPBlockReadable {
    private let reader: EDPEncryptedPartitionReader

    init(reader: EDPEncryptedPartitionReader) throws {
        guard let sizeBytes = reader.sizeBytes else {
            throw EDPNativeCoreError.invalidInput("EDP encrypted partition has no logical size")
        }
        self.reader = reader
        self.sizeBytes = sizeBytes
    }

    let sizeBytes: UInt64

    func read(at offset: UInt64, length: Int) throws -> Data {
        try reader.readExact(at: offset, length: length)
    }

    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws {
        try reader.readExact(at: offset, into: buffer)
    }
}

/// Read/write block view. All overlapping crypto read-modify-write operations
/// are serialized by `EDPEncryptedPartitionReader`.
final class EDPEncryptedReadWriteBlockDevice: EDPBlockWritable {
    private let reader: EDPEncryptedPartitionReader

    init(reader: EDPEncryptedPartitionReader) throws {
        guard let sizeBytes = reader.sizeBytes else {
            throw EDPNativeCoreError.invalidInput("EDP encrypted partition has no logical size")
        }
        guard reader.isWritable else {
            throw EDPNativeCoreError.invalidInput("EDP encrypted partition is not writable")
        }
        self.reader = reader
        self.sizeBytes = sizeBytes
    }

    let sizeBytes: UInt64

    func read(at offset: UInt64, length: Int) throws -> Data {
        try reader.readExact(at: offset, length: length)
    }

    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws {
        try reader.readExact(at: offset, into: buffer)
    }

    func write(at offset: UInt64, data: Data) throws {
        try reader.writeExact(at: offset, data: data)
    }

    func synchronize() throws {
        try reader.synchronize()
    }

    func forceDurability() throws {
        try reader.forceDurability()
    }
}

/// Plain read/write block view for the ordinary startup FAT partition.  The
/// daemon owns one retained whole-device descriptor, so the startup volume is
/// sliced from that same descriptor instead of depending on macOS to keep a
/// physical `diskNs1` child node published after whole-disk raw access begins.
final class EDPPlaintextReadWriteBlockDevice: EDPBlockWritable {
    private let raw: any EDPRawWritable
    private let startBytes: UInt64

    init(raw: any EDPRawWritable, startSector: UInt64, sizeBytes: UInt64) throws {
        guard raw.allowsWrites else {
            throw EDPNativeCoreError.invalidInput("raw EDP device was opened read-only")
        }
        let (startBytes, startOverflow) = startSector.multipliedReportingOverflow(
            by: EDPMetadataProbe.legacySectorSize
        )
        let (endBytes, endOverflow) = startBytes.addingReportingOverflow(sizeBytes)
        guard !startOverflow,
              !endOverflow,
              sizeBytes > 0,
              let rawSize = raw.sizeBytes,
              endBytes <= rawSize else {
            throw EDPNativeCoreError.invalidInput("startup partition exceeds raw device bounds")
        }
        self.raw = raw
        self.startBytes = startBytes
        self.sizeBytes = sizeBytes
    }

    let sizeBytes: UInt64

    func read(at offset: UInt64, length: Int) throws -> Data {
        guard length >= 0 else {
            throw EDPNativeCoreError.invalidInput("negative startup partition read length")
        }
        let (end, overflow) = offset.addingReportingOverflow(UInt64(length))
        guard !overflow, end <= sizeBytes else {
            throw EDPNativeCoreError.invalidInput("startup partition read exceeds bounds")
        }
        return try raw.readExact(at: startBytes + offset, length: length)
    }

    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws {
        let (end, overflow) = offset.addingReportingOverflow(UInt64(buffer.count))
        guard !overflow, end <= sizeBytes else {
            throw EDPNativeCoreError.invalidInput("startup partition read exceeds bounds")
        }
        try raw.readExact(at: startBytes + offset, into: buffer)
    }

    func write(at offset: UInt64, data: Data) throws {
        let (end, overflow) = offset.addingReportingOverflow(UInt64(data.count))
        guard !overflow, end <= sizeBytes else {
            throw EDPNativeCoreError.invalidInput("startup partition write exceeds bounds")
        }
        try raw.writeExact(at: startBytes + offset, data: data)
    }

    func synchronize() throws {
        try raw.synchronize()
    }

    func forceDurability() throws {
        try raw.forceDurability()
    }
}

struct EDPUnlockedBootVolume {
    let deviceID: String
    let partitionStartSector: UInt64
    let partitionSizeBytes: UInt64
    let block: EDPPlaintextReadWriteBlockDevice
}

enum EDPBootUnlock {
    private static let fatPartitionTypes: Set<UInt8> = [
        0x01, 0x04, 0x06, 0x0b, 0x0c, 0x0e,
    ]

    static func unlock(
        raw: any EDPRawWritable,
        vidHex: String,
        pidHex: String,
        deviceSizeBytes: UInt64
    ) throws -> EDPUnlockedBootVolume {
        guard raw.allowsWrites,
              deviceSizeBytes >= 16 * EDPMetadataProbe.legacySectorSize else {
            throw EDPNativeCoreError.invalidInput("invalid writable EDP raw device")
        }

        let sectorSize = Int(EDPMetadataProbe.legacySectorSize)
        let mbr = try raw.readExact(at: 0, length: sectorSize)
        let lba4 = try raw.readExact(at: EDPMetadataProbe.lba4ByteOffset, length: sectorSize)
        let lba7 = try raw.readExact(at: EDPMetadataProbe.lba7ByteOffset, length: sectorSize)
        guard EDPMetadataProbe.recognizeStandardEncryptedFrontMetadata(
            lba0: [UInt8](mbr),
            lba4: [UInt8](lba4),
            lba7: [UInt8](lba7)
        ) != nil else {
            throw EDPNativeCoreError.verify("raw device is not factory-standard encrypted EDP media")
        }

        let lba11 = try raw.readExact(
            at: EDPVolumeMetadata.lba11ByteOffset,
            length: sectorSize
        )
        guard let metadataDeviceID = EDPVolumeMetadata.deviceIDFromLBA11(
            [UInt8](lba11),
            vidHex: vidHex,
            pidHex: pidHex,
            sizeBytes: deviceSizeBytes
        ) else {
            throw EDPNativeCoreError.verify("EDP startup device identity validation failed")
        }

        guard mbr.count == sectorSize,
              mbr[510] == 0x55,
              mbr[511] == 0xaa else {
            throw EDPNativeCoreError.parse("physical EDP disk has no valid MBR signature")
        }

        var selected: (startSector: UInt64, sectorCount: UInt64)?
        for index in 0..<4 {
            let entryOffset = 446 + index * 16
            let partitionType = mbr[entryOffset + 4]
            let startSector = UInt64(readUInt32LE(mbr, at: entryOffset + 8))
            let sectorCount = UInt64(readUInt32LE(mbr, at: entryOffset + 12))
            if fatPartitionTypes.contains(partitionType),
               startSector > 0,
               sectorCount > 0 {
                selected = (startSector, sectorCount)
                break
            }
        }
        guard let selected else {
            throw EDPNativeCoreError.parse("EDP startup FAT partition was not found in MBR")
        }

        let (sizeBytes, sizeOverflow) = selected.sectorCount.multipliedReportingOverflow(
            by: EDPMetadataProbe.legacySectorSize
        )
        let (endSector, endSectorOverflow) = selected.startSector.addingReportingOverflow(
            selected.sectorCount
        )
        let (endBytes, endBytesOverflow) = endSector.multipliedReportingOverflow(
            by: EDPMetadataProbe.legacySectorSize
        )
        guard !sizeOverflow,
              !endSectorOverflow,
              !endBytesOverflow,
              endBytes <= deviceSizeBytes else {
            throw EDPNativeCoreError.parse("EDP startup partition exceeds declared device bounds")
        }

        let block = try EDPPlaintextReadWriteBlockDevice(
            raw: raw,
            startSector: selected.startSector,
            sizeBytes: sizeBytes
        )
        return EDPUnlockedBootVolume(
            deviceID: metadataDeviceID,
            partitionStartSector: selected.startSector,
            partitionSizeBytes: sizeBytes,
            block: block
        )
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

struct EDPReadOnlyUnlockRequest: Sendable {
    let vidHex: String
    let pidHex: String
    let deviceSizeBytes: UInt64
    let passwordBytes: [UInt8]
    let partitionType: UInt32
}

struct EDPUnlockedReadOnlyVolume {
    let deviceID: String
    let partitionType: UInt32
    let partitionStartSector: UInt64
    let partitionSizeBytes: UInt64
    let algorithm: UInt32
    let block: EDPEncryptedReadOnlyBlockDevice
}

enum EDPReadOnlyUnlock {
    static func unlock(
        raw: EDPRawReadable,
        request: EDPReadOnlyUnlockRequest
    ) throws -> EDPUnlockedReadOnlyVolume {
        let resolved = try EDPUnlockCore.resolve(raw: raw, request: request)
        let reader = try EDPEncryptedPartitionReader(
            raw: raw,
            descriptor: resolved.descriptor
        )
        let block = try EDPEncryptedReadOnlyBlockDevice(reader: reader)
        return EDPUnlockedReadOnlyVolume(
            deviceID: resolved.deviceID,
            partitionType: resolved.descriptor.partitionType,
            partitionStartSector: resolved.descriptor.startSector,
            partitionSizeBytes: resolved.descriptor.sizeBytes,
            algorithm: resolved.descriptor.algorithm,
            block: block
        )
    }
}

private struct EDPResolvedUnlock {
    let deviceID: String
    let descriptor: EDPVolumeDescriptor
}

private enum EDPUnlockCore {
    static func resolve(
        raw: EDPRawReadable,
        request: EDPReadOnlyUnlockRequest
    ) throws -> EDPResolvedUnlock {
        guard [UInt32(2), 4].contains(request.partitionType) else {
            throw EDPNativeCoreError.invalidInput("partition type must be 2 or 4")
        }
        guard request.deviceSizeBytes >= 16 * EDPMetadataProbe.legacySectorSize else {
            throw EDPNativeCoreError.invalidInput("declared device size is too small")
        }
        guard !request.passwordBytes.isEmpty else {
            throw EDPNativeCoreError.invalidInput("password must not be empty")
        }

        let sectorSize = Int(EDPMetadataProbe.legacySectorSize)
        let lba11 = try raw.readExact(
            at: EDPVolumeMetadata.lba11ByteOffset,
            length: sectorSize
        )
        let lba12 = try raw.readExact(
            at: EDPVolumeMetadata.lba12ByteOffset,
            length: sectorSize
        )

        guard let deviceID = EDPVolumeMetadata.deviceIDFromLBA11(
            [UInt8](lba11),
            vidHex: request.vidHex,
            pidHex: request.pidHex,
            sizeBytes: request.deviceSizeBytes
        ) else {
            throw EDPNativeCoreError.verify(
                "LBA11 device identity validation failed for supplied VID/PID/device size"
            )
        }

        let lba12Plain = try EDPVolumeMetadata.decodeLBA12(
            [UInt8](lba12),
            deviceID: deviceID
        )
        let volumes = try EDPVolumeMetadata.parseLBA12Entries(
            lba12Plain,
            password: request.passwordBytes
        )
        guard let descriptor = volumes.first(where: {
            $0.partitionType == request.partitionType
        }) else {
            throw EDPNativeCoreError.verify(
                "no decryptable EDP partition type \(request.partitionType) was found"
            )
        }

        let (partitionEnd, overflow) = descriptor.startBytes.addingReportingOverflow(
            descriptor.sizeBytes
        )
        guard !overflow, partitionEnd <= request.deviceSizeBytes else {
            throw EDPNativeCoreError.parse(
                "EDP partition bounds exceed the declared physical device size"
            )
        }

        return EDPResolvedUnlock(
            deviceID: deviceID,
            descriptor: descriptor
        )
    }
}

typealias EDPReadWriteUnlockRequest = EDPReadOnlyUnlockRequest

struct EDPUnlockedReadWriteVolume {
    let deviceID: String
    let partitionType: UInt32
    let partitionStartSector: UInt64
    let partitionSizeBytes: UInt64
    let algorithm: UInt32
    let block: EDPEncryptedReadWriteBlockDevice
}

enum EDPReadWriteUnlock {
    static func unlock(
        raw: any EDPRawWritable,
        request: EDPReadWriteUnlockRequest
    ) throws -> EDPUnlockedReadWriteVolume {
        guard raw.allowsWrites else {
            throw EDPNativeCoreError.invalidInput("raw EDP device was opened read-only")
        }
        let resolved = try EDPUnlockCore.resolve(raw: raw, request: request)
        let reader = try EDPEncryptedPartitionReader(
            raw: raw,
            descriptor: resolved.descriptor
        )
        let block = try EDPEncryptedReadWriteBlockDevice(reader: reader)
        return EDPUnlockedReadWriteVolume(
            deviceID: resolved.deviceID,
            partitionType: resolved.descriptor.partitionType,
            partitionStartSector: resolved.descriptor.startSector,
            partitionSizeBytes: resolved.descriptor.sizeBytes,
            algorithm: resolved.descriptor.algorithm,
            block: block
        )
    }
}
