import Foundation
import FSKit

/// Adapts FSBlockDeviceResource's sector-constrained direct I/O to the
/// arbitrary byte ranges expected by the EDP core RawIo abstraction.
///
/// Phase 1 is intentionally read-only. Write support will add sector-level
/// read-modify-write only after the native block-resource callback is proven on
/// an approved macOS 26 machine.
final class FSBlockRawAccessor {
    private let resource: FSBlockDeviceResource

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

        let length = UInt64(buffer.count)
        let (requestedEnd, overflow) = offset.addingReportingOverflow(length)
        guard !overflow else {
            throw POSIXError(.EOVERFLOW)
        }
        if let sizeBytes, requestedEnd > sizeBytes {
            throw POSIXError(.EINVAL)
        }

        let alignment = transferAlignment
        let alignedStart = offset - (offset % alignment)
        let alignedEnd = try roundUp(requestedEnd, to: alignment)
        if let sizeBytes, alignedEnd > sizeBytes {
            throw POSIXError(.EINVAL)
        }

        if alignedStart == offset && alignedEnd == requestedEnd {
            try readAligned(at: alignedStart, into: buffer)
            return
        }

        let expandedLength = alignedEnd - alignedStart
        guard expandedLength <= UInt64(Int.max) else {
            throw POSIXError(.EOVERFLOW)
        }

        var expanded = Data(count: Int(expandedLength))
        try expanded.withUnsafeMutableBytes { expandedBuffer in
            try readAligned(at: alignedStart, into: expandedBuffer)
        }

        let sliceStart = Int(offset - alignedStart)
        guard let destination = buffer.baseAddress else {
            throw POSIXError(.EFAULT)
        }
        expanded.withUnsafeBytes { expandedBuffer in
            guard let source = expandedBuffer.baseAddress else {
                return
            }
            memcpy(destination, source.advanced(by: sliceStart), buffer.count)
        }
    }

    private func readAligned(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws {
        let alignment = transferAlignment
        guard offset % alignment == 0,
              UInt64(buffer.count) % alignment == 0,
              offset <= UInt64(Int64.max) else {
            throw POSIXError(.EINVAL)
        }

        let bytesRead = try resource.read(
            into: buffer,
            startingAt: off_t(offset),
            length: buffer.count
        )
        guard bytesRead == buffer.count else {
            // RawIo::pread_exact requires exact completion. Reissuing a short
            // direct-I/O remainder could violate the device's sector alignment,
            // so treat a partial transfer as an I/O error instead.
            throw POSIXError(.EIO)
        }
    }

    private func roundUp(_ value: UInt64, to alignment: UInt64) throws -> UInt64 {
        let remainder = value % alignment
        guard remainder != 0 else {
            return value
        }
        let (rounded, overflow) = value.addingReportingOverflow(alignment - remainder)
        guard !overflow else {
            throw POSIXError(.EOVERFLOW)
        }
        return rounded
    }
}
