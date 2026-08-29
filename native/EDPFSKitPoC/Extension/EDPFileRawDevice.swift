import Darwin
import Foundation

/// File-descriptor-backed raw storage adapter used by block-bridge regression
/// tests and product user-space raw-device plumbing.
///
/// `pread`/`pwrite` keep I/O position-independent. Higher-layer crypto locking
/// serializes overlapping read-modify-write windows.
final class EDPFileRawDevice: EDPRawWritable {
    private let fd: Int32
    private let byteCount: UInt64
    private let writable: Bool

    init(
        path: String,
        declaredSizeBytes: UInt64? = nil,
        writable: Bool = false
    ) throws {
        let descriptor = Darwin.open(path, (writable ? O_RDWR : O_RDONLY) | O_CLOEXEC)
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
        self.writable = writable
    }

    init(
        fileDescriptor: Int32,
        declaredSizeBytes: UInt64,
        writable: Bool
    ) throws {
        guard fileDescriptor >= 0, declaredSizeBytes > 0 else {
            throw EDPNativeCoreError.invalidInput("invalid inherited raw file descriptor")
        }
        let flags = Darwin.fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0 else {
            throw EDPNativeCoreError.invalidInput("fcntl(F_GETFL) failed for inherited raw fd: errno=\(errno)")
        }
        let accessMode = flags & O_ACCMODE
        if writable && accessMode == O_RDONLY {
            throw EDPNativeCoreError.invalidInput("inherited raw fd is not writable")
        }
        let duplicated = Darwin.dup(fileDescriptor)
        guard duplicated >= 0 else {
            throw EDPNativeCoreError.invalidInput("dup failed for inherited raw fd: errno=\(errno)")
        }
        fd = duplicated
        byteCount = declaredSizeBytes
        self.writable = writable
    }

    deinit {
        Darwin.close(fd)
    }

    var sizeBytes: UInt64? { byteCount }
    var supportsConcurrentReads: Bool { true }
    var allowsWrites: Bool { writable }

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

    func readExact(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws {
        let length = buffer.count
        let length64 = UInt64(length)
        let (end, overflow) = offset.addingReportingOverflow(length64)
        guard !overflow, end <= byteCount else {
            throw EDPNativeCoreError.invalidInput("raw read exceeds storage bounds")
        }
        guard length > 0 else { return }
        guard offset <= UInt64(Int64.max), let base = buffer.baseAddress else {
            throw EDPNativeCoreError.invalidInput("invalid raw read buffer or offset")
        }

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

    func writeExact(at offset: UInt64, data: Data) throws {
        guard writable else {
            throw EDPNativeCoreError.invalidInput("raw storage was opened read-only")
        }
        let length = data.count
        let length64 = UInt64(length)
        let (end, overflow) = offset.addingReportingOverflow(length64)
        guard !overflow, end <= byteCount else {
            throw EDPNativeCoreError.invalidInput("raw write exceeds storage bounds")
        }
        guard length > 0 else { return }
        guard offset <= UInt64(Int64.max) else {
            throw EDPNativeCoreError.invalidInput("raw write offset exceeds off_t range")
        }

        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var completed = 0
            while completed < length {
                let absoluteOffset = offset + UInt64(completed)
                guard absoluteOffset <= UInt64(Int64.max) else {
                    throw EDPNativeCoreError.invalidInput(
                        "raw write continuation exceeds off_t range"
                    )
                }
                let result = Darwin.pwrite(
                    fd,
                    base.advanced(by: completed),
                    length - completed,
                    off_t(absoluteOffset)
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw EDPNativeCoreError.invalidInput("pwrite failed: errno=\(errno)")
                }
                if result == 0 {
                    throw EDPNativeCoreError.verify("zero-byte result during exact raw write")
                }
                completed += result
            }
        }
    }

    func synchronize() throws {
        guard writable else { return }
        while Darwin.fsync(fd) != 0 {
            if errno == EINTR { continue }
            throw EDPNativeCoreError.invalidInput("fsync failed: errno=\(errno)")
        }

        #if os(macOS)
        if Darwin.fcntl(fd, F_FULLFSYNC) != 0,
           errno != EINVAL,
           errno != ENOTSUP {
            throw EDPNativeCoreError.invalidInput("F_FULLFSYNC failed: errno=\(errno)")
        }
        #endif
    }
}
