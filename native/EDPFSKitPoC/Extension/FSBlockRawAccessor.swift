import Foundation
import FSKit

/// Adapts FSBlockDeviceResource's sector-constrained direct I/O to the native
/// byte-oriented EDP storage boundary.
///
/// Phase 1 is intentionally read-only. Write support will add sector-level
/// read-modify-write after the native filesystem path is proven on an approved
/// macOS 26 machine.
final class FSBlockRawAccessor: EDPRawReadable {
    private let resource: FSBlockDeviceResource
    private let readLock = NSLock()

    init(resource: FSBlockDeviceResource) {
        self.resource = resource
    }

    var bsdName: String {
        resource.bsdName
    }

    var isWritable: Bool {
        resource.isWritable
    }

    var transferAlignment: UInt64 {
        max(1, max(resource.blockSize, resource.physicalBlockSize))
    }

    var sizeBytes: UInt64? {
        let (size, overflow) = resource.blockCount.multipliedReportingOverflow(by: resource.blockSize)
        return overflow ? nil : size
    }

    func readExact(at offset: UInt64, length: Int) throws -> Data {
        guard length >= 0 else {
            throw POSIXError(.EINVAL)
        }
        var data = Data(count: length)
        try data.withUnsafeMutableBytes { buffer in
            try readExact(at: offset, into: buffer)
        }
        return data
    }

    func readExact(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws {
        guard !buffer.isEmpty else {
            return
        }

        let window = try EDPAlignedRead.window(
            byteOffset: offset,
            byteLength: UInt64(buffer.count),
            transferAlignment: transferAlignment,
            sizeBytes: sizeBytes
        )

        if window.start == offset && window.length == buffer.count {
            try readAlignedFully(at: window.start, into: buffer)
            return
        }

        var expanded = Data(count: window.length)
        try expanded.withUnsafeMutableBytes { expandedBuffer in
            try readAlignedFully(at: window.start, into: expandedBuffer)
        }

        guard let destination = buffer.baseAddress else {
            throw POSIXError(.EFAULT)
        }
        expanded.withUnsafeBytes { expandedBuffer in
            guard let source = expandedBuffer.baseAddress else {
                return
            }
            memcpy(destination, source.advanced(by: window.sliceOffset), buffer.count)
        }
    }

    private func readAlignedFully(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws {
        let alignment = transferAlignment
        guard !buffer.isEmpty,
              offset % alignment == 0,
              UInt64(buffer.count) % alignment == 0,
              offset <= UInt64(Int64.max),
              let baseAddress = buffer.baseAddress else {
            throw POSIXError(.EINVAL)
        }

        readLock.lock()
        defer { readLock.unlock() }

        var completed = 0
        while completed < buffer.count {
            let (requestOffset, overflow) = offset.addingReportingOverflow(UInt64(completed))
            guard !overflow, requestOffset <= UInt64(Int64.max) else {
                throw POSIXError(.EOVERFLOW)
            }

            let remaining = buffer.count - completed
            let requestBuffer = UnsafeMutableRawBufferPointer(
                start: baseAddress.advanced(by: completed),
                count: remaining
            )
            let bytesRead = try resource.read(
                into: requestBuffer,
                startingAt: off_t(requestOffset),
                length: remaining
            )
            guard bytesRead > 0, bytesRead <= remaining else {
                throw POSIXError(.EIO)
            }

            completed += bytesRead
            try EDPAlignedRead.validateContinuation(
                completed: completed,
                totalLength: buffer.count,
                transferAlignment: alignment
            )
        }
    }
}
