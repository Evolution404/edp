import Foundation

/// Pure-Swift transparent I/O engine for an EDP data partition.
///
/// It mirrors the old core's block expansion behavior: arbitrary byte reads are
/// expanded to SM4's 16-byte boundary, decrypted in ECB, then sliced back to
/// the caller's requested range. Partial writes use the same aligned window as
/// an atomic read-modify-encrypt-write operation. No FSKit type is visible at
/// this layer.
final class EDPEncryptedPartitionReader: EDPRawReadable {
    private let raw: any EDPRawReadable
    private let descriptor: EDPVolumeDescriptor
    private let cipher: EDPSM4?
    private let ioLock = NSLock()

    init(raw: any EDPRawReadable, descriptor: EDPVolumeDescriptor) throws {
        self.raw = raw
        self.descriptor = descriptor
        if descriptor.algorithm == 2 {
            guard let fileKey = descriptor.fileKey else {
                throw EDPNativeCoreError.verify("encrypted partition has no file key")
            }
            cipher = try EDPSM4(key: fileKey)
        } else {
            cipher = nil
        }
    }

    var sizeBytes: UInt64? { descriptor.sizeBytes }

    var isWritable: Bool {
        (raw as? any EDPRawWritable)?.allowsWrites == true
    }

    func readExact(at offset: UInt64, length: Int) throws -> Data {
        ioLock.lock()
        defer { ioLock.unlock() }
        return try readExactUnlocked(at: offset, length: length)
    }

    func writeExact(at offset: UInt64, data: Data) throws {
        ioLock.lock()
        defer { ioLock.unlock() }

        guard let writableRaw = raw as? any EDPRawWritable,
              writableRaw.allowsWrites else {
            throw EDPNativeCoreError.invalidInput("encrypted partition backing is read-only")
        }
        let length = data.count
        let length64 = UInt64(length)
        let (end, overflow) = offset.addingReportingOverflow(length64)
        guard !overflow, end <= descriptor.sizeBytes else {
            throw EDPNativeCoreError.invalidInput("partition write exceeds volume bounds")
        }
        guard length > 0 else { return }

        guard descriptor.algorithm == 2, let cipher else {
            let (physicalOffset, physicalOverflow) = descriptor.startBytes
                .addingReportingOverflow(offset)
            guard !physicalOverflow else {
                throw EDPNativeCoreError.invalidInput("partition physical offset overflow")
            }
            try writableRaw.writeExact(at: physicalOffset, data: data)
            return
        }

        let alignedStart = offset - (offset % 16)
        let alignedEnd = try roundUp(end, to: 16)
        let expandedLength64 = alignedEnd - alignedStart
        guard expandedLength64 <= UInt64(Int.max) else {
            throw EDPNativeCoreError.invalidInput("expanded crypto write is too large")
        }
        let expandedLength = Int(expandedLength64)
        let sliceOffset = Int(offset - alignedStart)

        var plaintext: Data
        if sliceOffset == 0, length == expandedLength {
            plaintext = data
        } else {
            plaintext = try readExactUnlocked(at: alignedStart, length: expandedLength)
            plaintext.replaceSubrange(sliceOffset..<(sliceOffset + length), with: data)
        }

        let encrypted = try cipher.encryptAligned([UInt8](plaintext))
        let (physicalOffset, physicalOverflow) = descriptor.startBytes
            .addingReportingOverflow(alignedStart)
        guard !physicalOverflow else {
            throw EDPNativeCoreError.invalidInput("partition physical offset overflow")
        }
        try writableRaw.writeExact(at: physicalOffset, data: Data(encrypted))
    }

    func synchronize() throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard let writableRaw = raw as? any EDPRawWritable,
              writableRaw.allowsWrites else {
            throw EDPNativeCoreError.invalidInput("encrypted partition backing is read-only")
        }
        try writableRaw.synchronize()
    }

    private func readExactUnlocked(at offset: UInt64, length: Int) throws -> Data {
        guard length >= 0 else {
            throw EDPNativeCoreError.invalidInput("negative read length")
        }
        let length64 = UInt64(length)
        let (end, overflow) = offset.addingReportingOverflow(length64)
        guard !overflow, end <= descriptor.sizeBytes else {
            throw EDPNativeCoreError.invalidInput("partition read exceeds volume bounds")
        }
        guard length > 0 else { return Data() }

        let (absoluteBase, baseOverflow) = descriptor.startBytes.addingReportingOverflow(offset)
        guard !baseOverflow else {
            throw EDPNativeCoreError.invalidInput("partition offset overflow")
        }

        guard descriptor.algorithm == 2, let cipher else {
            return try raw.readExact(at: absoluteBase, length: length)
        }

        let alignedStart = offset - (offset % 16)
        let alignedEnd = try roundUp(end, to: 16)
        let expandedLength64 = alignedEnd - alignedStart
        guard expandedLength64 <= UInt64(Int.max) else {
            throw EDPNativeCoreError.invalidInput("expanded crypto read is too large")
        }
        let (physicalOffset, physicalOverflow) = descriptor.startBytes.addingReportingOverflow(alignedStart)
        guard !physicalOverflow else {
            throw EDPNativeCoreError.invalidInput("partition physical offset overflow")
        }

        let encrypted = try raw.readExact(at: physicalOffset, length: Int(expandedLength64))
        let plaintext = try cipher.decryptAligned([UInt8](encrypted))
        let sliceOffset = Int(offset - alignedStart)
        return Data(plaintext[sliceOffset..<(sliceOffset + length)])
    }

    private func roundUp(_ value: UInt64, to alignment: UInt64) throws -> UInt64 {
        let remainder = value % alignment
        guard remainder != 0 else { return value }
        let (rounded, overflow) = value.addingReportingOverflow(alignment - remainder)
        guard !overflow else {
            throw EDPNativeCoreError.invalidInput("crypto alignment overflow")
        }
        return rounded
    }
}
