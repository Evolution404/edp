import Foundation

/// Pure alignment rules shared by the FSKit block-device adapter and CI.
/// Keeping this logic outside FSKit makes the exact production byte-window
/// calculation and aligned short-read loop testable before an extension is
/// approved on a real machine.
enum EDPAlignedRead {
    struct Window: Equatable, Sendable {
        let start: UInt64
        let length: Int
        let sliceOffset: Int
        let sliceLength: Int
    }

    typealias ReadOperation = (
        _ buffer: UnsafeMutableRawBufferPointer,
        _ byteOffset: UInt64,
        _ length: Int
    ) throws -> Int

    static func window(
        byteOffset: UInt64,
        byteLength: UInt64,
        transferAlignment: UInt64,
        sizeBytes: UInt64? = nil
    ) throws -> Window {
        guard transferAlignment > 0, byteLength > 0 else {
            throw POSIXError(.EINVAL)
        }

        let (targetEnd, endOverflow) = byteOffset.addingReportingOverflow(byteLength)
        guard !endOverflow else {
            throw POSIXError(.EOVERFLOW)
        }
        if let sizeBytes, targetEnd > sizeBytes {
            throw POSIXError(.EINVAL)
        }

        let requestStart = byteOffset - (byteOffset % transferAlignment)
        let remainder = targetEnd % transferAlignment
        let requestEnd: UInt64
        if remainder == 0 {
            requestEnd = targetEnd
        } else {
            let (rounded, overflow) = targetEnd.addingReportingOverflow(transferAlignment - remainder)
            guard !overflow else {
                throw POSIXError(.EOVERFLOW)
            }
            requestEnd = rounded
        }

        if let sizeBytes, requestEnd > sizeBytes {
            throw POSIXError(.EINVAL)
        }
        guard requestEnd >= requestStart else {
            throw POSIXError(.EOVERFLOW)
        }

        let requestLength = requestEnd - requestStart
        let sliceOffset = byteOffset - requestStart
        guard requestLength <= UInt64(Int.max),
              sliceOffset <= UInt64(Int.max),
              byteLength <= UInt64(Int.max),
              requestStart <= UInt64(Int64.max) else {
            throw POSIXError(.EOVERFLOW)
        }

        return Window(
            start: requestStart,
            length: Int(requestLength),
            sliceOffset: Int(sliceOffset),
            sliceLength: Int(byteLength)
        )
    }

    /// Executes the exact aligned-read loop used by the FSKit adapter. A short
    /// read is retried only when the next request still starts on the device's
    /// transfer boundary. Zero, oversized, or unaligned-progress reads are I/O
    /// errors rather than opportunities to issue an invalid block request.
    static func readFully(
        at byteOffset: UInt64,
        into buffer: UnsafeMutableRawBufferPointer,
        transferAlignment: UInt64,
        read: ReadOperation
    ) throws {
        guard transferAlignment > 0,
              !buffer.isEmpty,
              byteOffset % transferAlignment == 0,
              UInt64(buffer.count) % transferAlignment == 0,
              byteOffset <= UInt64(Int64.max),
              let baseAddress = buffer.baseAddress else {
            throw POSIXError(.EINVAL)
        }

        var completed = 0
        while completed < buffer.count {
            let (requestOffset, overflow) = byteOffset.addingReportingOverflow(UInt64(completed))
            guard !overflow, requestOffset <= UInt64(Int64.max) else {
                throw POSIXError(.EOVERFLOW)
            }

            let remaining = buffer.count - completed
            let requestBuffer = UnsafeMutableRawBufferPointer(
                start: baseAddress.advanced(by: completed),
                count: remaining
            )
            let bytesRead = try read(requestBuffer, requestOffset, remaining)
            guard bytesRead > 0, bytesRead <= remaining else {
                throw POSIXError(.EIO)
            }

            completed += bytesRead
            try validateContinuation(
                completed: completed,
                totalLength: buffer.count,
                transferAlignment: transferAlignment
            )
        }
    }

    /// Validates whether a synchronous block-device short read can be
    /// continued without violating the device's transfer alignment.
    static func validateContinuation(
        completed: Int,
        totalLength: Int,
        transferAlignment: UInt64
    ) throws {
        guard transferAlignment > 0,
              totalLength > 0,
              completed > 0,
              completed <= totalLength else {
            throw POSIXError(.EIO)
        }

        if completed < totalLength && UInt64(completed) % transferAlignment != 0 {
            throw POSIXError(.EIO)
        }
    }
}
