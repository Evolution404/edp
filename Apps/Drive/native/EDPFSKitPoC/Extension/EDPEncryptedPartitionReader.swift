import Dispatch
import Foundation

private final class EDPEncryptedReadParallelState: @unchecked Sendable {
    let raw: any EDPRawReadable
    let cipher: EDPSharedSM4
    let physicalOffset: UInt64
    let outputAddress: UInt
    let totalBlocks: Int
    let blocksPerWorker: Int
    private let errorLock = NSLock()
    private var firstError: Error?

    init(
        raw: any EDPRawReadable,
        cipher: EDPSharedSM4,
        physicalOffset: UInt64,
        output: UnsafeMutableRawPointer,
        byteCount: Int,
        workers: Int
    ) {
        self.raw = raw
        self.cipher = cipher
        self.physicalOffset = physicalOffset
        outputAddress = UInt(bitPattern: output)
        totalBlocks = byteCount / 16
        let minimumBlocksPerWorker = (totalBlocks + workers - 1) / workers
        let alignmentBlocks = 4096 / 16
        blocksPerWorker = ((minimumBlocksPerWorker + alignmentBlocks - 1) / alignmentBlocks)
            * alignmentBlocks
    }

    func run(worker: Int) {
        guard currentError == nil else { return }
        let firstBlock = worker * blocksPerWorker
        guard firstBlock < totalBlocks else { return }
        let endBlock = min(totalBlocks, firstBlock + blocksPerWorker)
        let byteOffset = firstBlock * 16
        let byteCount = (endBlock - firstBlock) * 16
        guard let base = UnsafeMutableRawPointer(bitPattern: outputAddress) else {
            record(EDPNativeCoreError.invalidInput("parallel read output buffer is unavailable"))
            return
        }
        let (chunkOffset, overflow) = physicalOffset.addingReportingOverflow(UInt64(byteOffset))
        guard !overflow else {
            record(EDPNativeCoreError.invalidInput("parallel read physical offset overflow"))
            return
        }
        let slice = UnsafeMutableRawBufferPointer(
            start: base.advanced(by: byteOffset),
            count: byteCount
        )
        do {
            try raw.readExact(at: chunkOffset, into: slice)
            try cipher.decryptInPlace(slice, serial: true)
        } catch {
            record(error)
        }
    }

    var currentError: Error? {
        errorLock.lock()
        defer { errorLock.unlock() }
        return firstError
    }

    private func record(_ error: Error) {
        errorLock.lock()
        if firstError == nil { firstError = error }
        errorLock.unlock()
    }
}

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
    private let cipher: EDPSharedSM4?
    private let writeLock = NSLock()

    init(raw: any EDPRawReadable, descriptor: EDPVolumeDescriptor) throws {
        self.raw = raw
        self.descriptor = descriptor
        if descriptor.algorithm == 2 {
            guard let fileKey = descriptor.fileKey else {
                throw EDPNativeCoreError.verify("encrypted partition has no file key")
            }
            cipher = try EDPSharedSM4(key: fileKey)
        } else {
            cipher = nil
        }
    }

    var sizeBytes: UInt64? { descriptor.sizeBytes }

    var isWritable: Bool {
        (raw as? any EDPRawWritable)?.allowsWrites == true
    }

    func readExact(at offset: UInt64, length: Int) throws -> Data {
        try readExactUnlocked(at: offset, length: length)
    }

    func readExact(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws {
        let length = buffer.count
        let (end, overflow) = offset.addingReportingOverflow(UInt64(length))
        guard !overflow, end <= descriptor.sizeBytes else {
            throw EDPNativeCoreError.invalidInput("partition read exceeds volume bounds")
        }
        guard length > 0 else { return }

        let (absoluteBase, baseOverflow) = descriptor.startBytes.addingReportingOverflow(offset)
        guard !baseOverflow else {
            throw EDPNativeCoreError.invalidInput("partition offset overflow")
        }

        guard descriptor.algorithm == 2, let cipher else {
            try raw.readExact(at: absoluteBase, into: buffer)
            return
        }

        if offset % 16 == 0, length % 16 == 0 {
            let workers = concurrentReadWorkerCount(for: length)
            if workers > 1,
               raw.supportsConcurrentReads,
               absoluteBase % 512 == 0,
               length % 512 == 0,
               let base = buffer.baseAddress {
                let state = EDPEncryptedReadParallelState(
                    raw: raw,
                    cipher: cipher,
                    physicalOffset: absoluteBase,
                    output: base,
                    byteCount: length,
                    workers: workers
                )
                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                    state.run(worker: worker)
                }
                if let error = state.currentError { throw error }
            } else {
                try raw.readExact(at: absoluteBase, into: buffer)
                try cipher.decryptInPlace(buffer)
            }
            return
        }

        let data = try readExactUnlocked(at: offset, length: length)
        _ = data.copyBytes(to: buffer.bindMemory(to: UInt8.self))
    }

    func writeExact(at offset: UInt64, data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }

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

        try cipher.encryptInPlace(&plaintext)
        let (physicalOffset, physicalOverflow) = descriptor.startBytes
            .addingReportingOverflow(alignedStart)
        guard !physicalOverflow else {
            throw EDPNativeCoreError.invalidInput("partition physical offset overflow")
        }
        try writableRaw.writeExact(at: physicalOffset, data: plaintext)
    }

    func synchronize() throws {
        writeLock.lock()
        defer { writeLock.unlock() }
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

        var plaintext = try raw.readExact(at: physicalOffset, length: Int(expandedLength64))
        try cipher.decryptInPlace(&plaintext)
        let sliceOffset = Int(offset - alignedStart)
        if sliceOffset == 0, length == plaintext.count {
            return plaintext
        }
        return plaintext.subdata(in: sliceOffset..<(sliceOffset + length))
    }

    private func concurrentReadWorkerCount(for length: Int) -> Int {
        let active = max(1, ProcessInfo.processInfo.activeProcessorCount)
        if length >= 1024 * 1024 { return min(6, active) }
        if length >= 256 * 1024 { return min(4, active) }
        if length >= 128 * 1024 { return min(2, active) }
        return 1
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
