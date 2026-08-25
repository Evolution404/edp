import Foundation

/// Filesystem-agnostic logical block view exposed by the EDP crypto layer.
///
/// This protocol intentionally knows nothing about macFUSE, DiskImages2,
/// FSKit, partitions inside the decrypted volume, or any concrete filesystem.
/// The first product milestone is read-only; write/flush are added only after
/// real-device read-only mounting is proven safe.
protocol EDPBlockReadable: AnyObject {
    var sizeBytes: UInt64 { get }

    func read(at offset: UInt64, length: Int) throws -> Data
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

        let reader = try EDPEncryptedPartitionReader(raw: raw, descriptor: descriptor)
        let block = try EDPEncryptedReadOnlyBlockDevice(reader: reader)
        return EDPUnlockedReadOnlyVolume(
            deviceID: deviceID,
            partitionType: descriptor.partitionType,
            partitionStartSector: descriptor.startSector,
            partitionSizeBytes: descriptor.sizeBytes,
            algorithm: descriptor.algorithm,
            block: block
        )
    }
}
