import Darwin
import Foundation

/// File-descriptor-backed raw storage adapter used by hosted block-bridge
/// regression tests and by future user-space raw-device plumbing.
///
/// `pread` keeps reads position-independent and safe for concurrent callers.
final class EDPFileRawDevice: EDPRawReadable {
    private let fd: Int32
    private let byteCount: UInt64

    init(path: String, declaredSizeBytes: UInt64? = nil) throws {
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw EDPNativeCoreError.invalidInput("open failed for raw storage: errno=\(errno)")
        }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            let savedErrno = errno
            Darwin.close(descriptor)
            throw EDPNativeCoreError.invalidInput("fstat failed for raw storage: errno=\(savedErrno)")
        }
        guard status.st_size >= 0 else {
            Darwin.close(descriptor)
            throw EDPNativeCoreError.invalidInput("raw storage reports a negative size")
        }

        let statSize = UInt64(status.st_size)
        if let declaredSizeBytes {
            guard declaredSizeBytes > 0 else {
                Darwin.close(descriptor)
                throw EDPNativeCoreError.invalidInput("declared raw storage size must be positive")
            }
            byteCount = declaredSizeBytes
        } else {
            guard statSize > 0 else {
                Darwin.close(descriptor)
                throw EDPNativeCoreError.invalidInput(
                    "raw storage size is unavailable; a declared size is required for device nodes"
                )
            }
            byteCount = statSize
        }
        fd = descriptor
    }

    deinit {
        Darwin.close(fd)
    }

    var sizeBytes: UInt64? { byteCount }

    func readExact(at offset: UInt64, length: Int) throws -> Data {
        guard length >= 0 else {
            throw EDPNativeCoreError.invalidInput("negative raw read length")
        }
        let length64 = UInt64(length)
        let (end, overflow) = offset.addingReportingOverflow(length64)
        guard !overflow, end <= byteCount else {
            throw EDPNativeCoreError.invalidInput("raw read exceeds storage bounds")
        }
        guard length > 0 else { return Data() }
        guard offset <= UInt64(Int64.max) else {
            throw EDPNativeCoreError.invalidInput("raw read offset exceeds off_t range")
        }

        var output = Data(count: length)
        try output.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var completed = 0
            while completed < length {
                let absoluteOffset = offset + UInt64(completed)
                guard absoluteOffset <= UInt64(Int64.max) else {
                    throw EDPNativeCoreError.invalidInput("raw read continuation exceeds off_t range")
                }
                let result = Darwin.pread(
                    fd,
                    base.advanced(by: completed),
                    length - completed,
                    off_t(absoluteOffset)
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw EDPNativeCoreError.invalidInput("pread failed: errno=\(errno)")
                }
                if result == 0 {
                    throw EDPNativeCoreError.verify("unexpected EOF during exact raw read")
                }
                completed += result
            }
        }
        return output
    }
}
