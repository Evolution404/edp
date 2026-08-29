import Darwin
import Foundation

private enum BenchmarkError: Error, CustomStringConvertible {
    case usage(String)
    case invalid(String)
    case posix(String, Int32)

    var description: String {
        switch self {
        case .usage(let message), .invalid(let message): return message
        case .posix(let operation, let code):
            return "\(operation): \(String(cString: strerror(code))) (\(code))"
        }
    }
}

private enum BenchmarkMode: String {
    case direct
    case encrypted
}

private enum BenchmarkOperation: String {
    case read
    case write
}

private enum BenchmarkPattern: String {
    case random
    case sequential
}

private struct Arguments {
    let path: String
    let mode: BenchmarkMode
    let operation: BenchmarkOperation
    let pattern: BenchmarkPattern
    let blockSize: Int
    let operations: Int
    let spanBytes: UInt64
    let key: [UInt8]
}

private func parseHexKey(_ text: String) throws -> [UInt8] {
    guard text.count == 32 else {
        throw BenchmarkError.usage("--key must contain exactly 32 hex characters")
    }
    var output = [UInt8]()
    output.reserveCapacity(16)
    var index = text.startIndex
    for _ in 0..<16 {
        let next = text.index(index, offsetBy: 2)
        guard let byte = UInt8(text[index..<next], radix: 16) else {
            throw BenchmarkError.usage("--key contains non-hex characters")
        }
        output.append(byte)
        index = next
    }
    return output
}

private func parseArguments() throws -> Arguments {
    var values = [String: String]()
    var index = 1
    let arguments = CommandLine.arguments
    while index < arguments.count {
        let key = arguments[index]
        guard key.hasPrefix("--") else {
            throw BenchmarkError.usage("unexpected argument: \(key)")
        }
        index += 1
        guard index < arguments.count else {
            throw BenchmarkError.usage("\(key) requires a value")
        }
        guard values[key] == nil else {
            throw BenchmarkError.usage("duplicate argument: \(key)")
        }
        values[key] = arguments[index]
        index += 1
    }

    guard let path = values["--path"],
          let modeText = values["--mode"],
          let mode = BenchmarkMode(rawValue: modeText),
          let operationText = values["--operation"],
          let operation = BenchmarkOperation(rawValue: operationText),
          let patternText = values["--pattern"],
          let pattern = BenchmarkPattern(rawValue: patternText),
          let blockText = values["--block-size"],
          let blockSize = Int(blockText), blockSize > 0,
          let operationsText = values["--operations"],
          let operations = Int(operationsText), operations > 0,
          let spanText = values["--span-bytes"],
          let spanBytes = UInt64(spanText), spanBytes >= UInt64(blockSize),
          let keyText = values["--key"] else {
        throw BenchmarkError.usage(
            "usage: EDPCryptoIOBenchmark --path <file> --mode <direct|encrypted> --operation <read|write> --pattern <random|sequential> --block-size <bytes> --operations <count> --span-bytes <bytes> --key <32-hex>"
        )
    }

    return Arguments(
        path: path,
        mode: mode,
        operation: operation,
        pattern: pattern,
        blockSize: blockSize,
        operations: operations,
        spanBytes: spanBytes,
        key: try parseHexKey(keyText)
    )
}

private final class NoCacheRawDevice: EDPRawWritable {
    let sizeBytes: UInt64?
    let allowsWrites: Bool
    private let fd: Int32

    init(path: String, writable: Bool, spanBytes: UInt64) throws {
        let descriptor = Darwin.open(path, (writable ? O_RDWR : O_RDONLY) | O_CLOEXEC)
        guard descriptor >= 0 else { throw BenchmarkError.posix("open", errno) }

        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_size >= 0 else {
            let saved = errno
            Darwin.close(descriptor)
            throw BenchmarkError.posix("fstat", saved)
        }
        let fileSize = UInt64(status.st_size)
        guard spanBytes <= fileSize else {
            Darwin.close(descriptor)
            throw BenchmarkError.invalid("benchmark span exceeds file size")
        }
        guard fcntl(descriptor, F_NOCACHE, 1) != -1 else {
            let saved = errno
            Darwin.close(descriptor)
            throw BenchmarkError.posix("fcntl(F_NOCACHE)", saved)
        }
        guard fcntl(descriptor, F_RDAHEAD, 0) != -1 else {
            let saved = errno
            Darwin.close(descriptor)
            throw BenchmarkError.posix("fcntl(F_RDAHEAD)", saved)
        }

        fd = descriptor
        sizeBytes = fileSize
        allowsWrites = writable
    }

    deinit { Darwin.close(fd) }

    var supportsConcurrentReads: Bool { true }

    func readExact(at offset: UInt64, length: Int) throws -> Data {
        guard length >= 0 else { throw BenchmarkError.invalid("negative read length") }
        let (end, overflow) = offset.addingReportingOverflow(UInt64(length))
        guard !overflow, end <= (sizeBytes ?? 0), end <= UInt64(Int64.max) else {
            throw BenchmarkError.invalid("read exceeds storage bounds")
        }
        guard length > 0 else { return Data() }

        var output = Data(count: length)
        try output.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var completed = 0
            while completed < length {
                let result = Darwin.pread(
                    fd,
                    base.advanced(by: completed),
                    length - completed,
                    off_t(offset + UInt64(completed))
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw BenchmarkError.posix("pread", errno)
                }
                guard result > 0 else { throw BenchmarkError.invalid("unexpected EOF") }
                completed += result
            }
        }
        return output
    }

    func readExact(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws {
        let length = buffer.count
        let (end, overflow) = offset.addingReportingOverflow(UInt64(length))
        guard !overflow, end <= (sizeBytes ?? 0), end <= UInt64(Int64.max) else {
            throw BenchmarkError.invalid("read exceeds storage bounds")
        }
        guard length > 0 else { return }
        guard let base = buffer.baseAddress else {
            throw BenchmarkError.invalid("read buffer has no storage")
        }

        var completed = 0
        while completed < length {
            let result = Darwin.pread(
                fd,
                base.advanced(by: completed),
                length - completed,
                off_t(offset + UInt64(completed))
            )
            if result < 0 {
                if errno == EINTR { continue }
                throw BenchmarkError.posix("pread", errno)
            }
            guard result > 0 else { throw BenchmarkError.invalid("unexpected EOF") }
            completed += result
        }
    }

    func writeExact(at offset: UInt64, data: Data) throws {
        guard allowsWrites else { throw BenchmarkError.invalid("storage is read-only") }
        let (end, overflow) = offset.addingReportingOverflow(UInt64(data.count))
        guard !overflow, end <= (sizeBytes ?? 0), end <= UInt64(Int64.max) else {
            throw BenchmarkError.invalid("write exceeds storage bounds")
        }
        guard !data.isEmpty else { return }

        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var completed = 0
            while completed < data.count {
                let result = Darwin.pwrite(
                    fd,
                    base.advanced(by: completed),
                    data.count - completed,
                    off_t(offset + UInt64(completed))
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw BenchmarkError.posix("pwrite", errno)
                }
                guard result > 0 else { throw BenchmarkError.invalid("zero-progress pwrite") }
                completed += result
            }
        }
    }

    func synchronize() throws {
        guard allowsWrites else { return }
        while fsync(fd) != 0 {
            if errno == EINTR { continue }
            throw BenchmarkError.posix("fsync", errno)
        }
        if fcntl(fd, F_FULLFSYNC) != 0,
           errno != EINVAL,
           errno != ENOTSUP,
           errno != EIO {
            throw BenchmarkError.posix("F_FULLFSYNC", errno)
        }
    }
}

private func deterministicWriteData(length: Int) -> Data {
    var output = [UInt8](repeating: 0, count: length)
    var state: UInt64 = 0xED40_4040_2026_0826
    for index in output.indices {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        output[index] = UInt8(truncatingIfNeeded: state ^ UInt64(index))
    }
    return Data(output)
}

private func offsetSequence(arguments: Arguments) throws -> [UInt64] {
    let maxStart = arguments.spanBytes - UInt64(arguments.blockSize)
    let alignment: UInt64 = 4096
    let randomSlots = maxStart / alignment + 1
    let sequentialSlots = arguments.spanBytes / UInt64(arguments.blockSize)
    if arguments.pattern == .sequential, sequentialSlots == 0 {
        throw BenchmarkError.invalid("sequential span has no complete block")
    }

    var state: UInt64 = 0x4d59_5df4_d0f3_3173
    var offsets = [UInt64]()
    offsets.reserveCapacity(arguments.operations)
    for operation in 0..<arguments.operations {
        switch arguments.pattern {
        case .random:
            state = state &* 6364136223846793005 &+ 1442695040888963407
            offsets.append((state % randomSlots) * alignment)
        case .sequential:
            offsets.append(UInt64(operation % Int(sequentialSlots)) * UInt64(arguments.blockSize))
        }
    }
    return offsets
}

private func descriptor(sizeBytes: UInt64, key: [UInt8]) -> EDPVolumeDescriptor {
    EDPVolumeDescriptor(
        partitionType: 2,
        startSector: 0,
        sizeBytes: sizeBytes,
        algorithm: 2,
        fileKey: key,
        passwordCRC: 0,
        keyCRC: EDPCrypto.crc32Bare(key)
    )
}

private func run() throws {
    let arguments = try parseArguments()
    let writable = arguments.operation == .write
    let raw = try NoCacheRawDevice(
        path: arguments.path,
        writable: writable,
        spanBytes: arguments.spanBytes
    )
    let offsets = try offsetSequence(arguments: arguments)
    let writeData = deterministicWriteData(length: arguments.blockSize)
    var readData = Data(count: arguments.blockSize)
    var checksum: UInt64 = 0

    let start = DispatchTime.now().uptimeNanoseconds
    switch (arguments.mode, arguments.operation) {
    case (.direct, .read):
        for offset in offsets {
            try readData.withUnsafeMutableBytes { buffer in
                try raw.readExact(at: offset, into: buffer)
            }
            checksum &+= UInt64(readData.first ?? 0)
            checksum &+= UInt64(readData.last ?? 0)
        }
    case (.direct, .write):
        for offset in offsets {
            try raw.writeExact(at: offset, data: writeData)
        }
        try raw.synchronize()
    case (.encrypted, .read):
        let reader = try EDPEncryptedPartitionReader(
            raw: raw,
            descriptor: descriptor(sizeBytes: arguments.spanBytes, key: arguments.key)
        )
        let block = try EDPEncryptedReadOnlyBlockDevice(reader: reader)
        for offset in offsets {
            try readData.withUnsafeMutableBytes { buffer in
                try block.read(at: offset, into: buffer)
            }
            checksum &+= UInt64(readData.first ?? 0)
            checksum &+= UInt64(readData.last ?? 0)
        }
    case (.encrypted, .write):
        let reader = try EDPEncryptedPartitionReader(
            raw: raw,
            descriptor: descriptor(sizeBytes: arguments.spanBytes, key: arguments.key)
        )
        let block = try EDPEncryptedReadWriteBlockDevice(reader: reader)
        for offset in offsets {
            try block.write(at: offset, data: writeData)
        }
        try block.synchronize()
    }
    let end = DispatchTime.now().uptimeNanoseconds

    let seconds = Double(end - start) / 1_000_000_000.0
    let totalBytes = UInt64(arguments.blockSize) * UInt64(arguments.operations)
    let mib = Double(totalBytes) / (1024.0 * 1024.0)
    let throughput = mib / seconds
    let iops = Double(arguments.operations) / seconds

    print(
        String(
            format: "CRYPTO_IO_BENCH mode=%@ operation=%@ pattern=%@ block_bytes=%d operations=%d span_bytes=%llu total_bytes=%llu nocache=1 rdahead=0 durable_sync=%d seconds=%.6f mib_per_s=%.3f iops=%.1f checksum=%llu",
            arguments.mode.rawValue,
            arguments.operation.rawValue,
            arguments.pattern.rawValue,
            arguments.blockSize,
            arguments.operations,
            arguments.spanBytes,
            totalBytes,
            writable ? 1 : 0,
            seconds,
            throughput,
            iops,
            checksum
        )
    )
}

@main
private enum EDPCryptoIOBenchmarkMain {
    static func main() {
        do {
            try run()
        } catch {
            fputs("EDPCryptoIOBenchmark: \(error)\n", stderr)
            exit(1)
        }
    }
}
