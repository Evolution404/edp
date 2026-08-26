import Darwin
import Foundation

private enum BenchError: Error, CustomStringConvertible {
    case usage(String)
    case posix(String, Int32)
    case invalid(String)

    var description: String {
        switch self {
        case .usage(let message), .invalid(let message):
            return message
        case .posix(let operation, let code):
            return "\(operation): \(String(cString: strerror(code))) (\(code))"
        }
    }
}

private enum Pattern: String {
    case random
    case sequential
}

private struct Arguments {
    let path: String
    let pattern: Pattern
    let blockSize: Int
    let operations: Int
    let spanBytes: UInt64
}

private func parseArguments() throws -> Arguments {
    var values = [String: String]()
    let args = CommandLine.arguments
    var index = 1
    while index < args.count {
        let key = args[index]
        guard key.hasPrefix("--") else { throw BenchError.usage("unexpected argument: \(key)") }
        index += 1
        guard index < args.count else { throw BenchError.usage("\(key) requires a value") }
        values[key] = args[index]
        index += 1
    }

    guard let path = values["--path"],
          let patternText = values["--pattern"],
          let pattern = Pattern(rawValue: patternText),
          let blockText = values["--block-size"],
          let blockSize = Int(blockText),
          let operationsText = values["--operations"],
          let operations = Int(operationsText),
          let spanText = values["--span-bytes"],
          let spanBytes = UInt64(spanText),
          blockSize > 0,
          operations > 0,
          spanBytes >= UInt64(blockSize) else {
        throw BenchError.usage(
            "usage: FuseTReadBenchmark --path <file> --pattern <random|sequential> --block-size <bytes> --operations <count> --span-bytes <bytes>"
        )
    }
    return Arguments(
        path: path,
        pattern: pattern,
        blockSize: blockSize,
        operations: operations,
        spanBytes: spanBytes
    )
}

private func readFull(fd: Int32, buffer: UnsafeMutableRawPointer, length: Int, offset: UInt64) throws {
    var completed = 0
    while completed < length {
        let absolute = offset + UInt64(completed)
        guard absolute <= UInt64(Int64.max) else { throw BenchError.invalid("offset exceeds off_t") }
        let result = Darwin.pread(
            fd,
            buffer.advanced(by: completed),
            length - completed,
            off_t(absolute)
        )
        if result < 0 {
            if errno == EINTR { continue }
            throw BenchError.posix("pread", errno)
        }
        guard result > 0 else { throw BenchError.invalid("unexpected EOF") }
        completed += result
    }
}

private func runBenchmark() throws {
    let args = try parseArguments()
    let fd = Darwin.open(args.path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { throw BenchError.posix("open", errno) }
    defer { Darwin.close(fd) }

    guard Darwin.fcntl(fd, F_NOCACHE, 1) != -1 else {
        throw BenchError.posix("fcntl F_NOCACHE", errno)
    }
    guard Darwin.fcntl(fd, F_RDAHEAD, 0) != -1 else {
        throw BenchError.posix("fcntl F_RDAHEAD", errno)
    }

    var status = stat()
    guard fstat(fd, &status) == 0 else { throw BenchError.posix("fstat", errno) }
    guard status.st_size >= 0 else { throw BenchError.invalid("negative file size") }
    let fileSize = UInt64(status.st_size)
    guard args.spanBytes <= fileSize else {
        throw BenchError.invalid("benchmark span exceeds file size")
    }

    var buffer = [UInt8](repeating: 0, count: args.blockSize)
    var checksum: UInt64 = 0
    var state: UInt64 = 0x4d595df4d0f33173
    let alignment: UInt64 = 4096
    let maxStart = args.spanBytes - UInt64(args.blockSize)
    let randomSlots = maxStart / alignment + 1
    let sequentialSlots = args.spanBytes / UInt64(args.blockSize)
    guard args.pattern != .sequential || sequentialSlots > 0 else {
        throw BenchError.invalid("sequential span has no complete block")
    }

    let start = DispatchTime.now().uptimeNanoseconds
    try buffer.withUnsafeMutableBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        for operation in 0..<args.operations {
            let offset: UInt64
            switch args.pattern {
            case .random:
                state = state &* 6364136223846793005 &+ 1442695040888963407
                offset = (state % randomSlots) * alignment
            case .sequential:
                offset = UInt64(operation % Int(sequentialSlots)) * UInt64(args.blockSize)
            }
            try readFull(fd: fd, buffer: base, length: args.blockSize, offset: offset)
            checksum &+= UInt64(base.load(as: UInt8.self))
        }
    }
    let end = DispatchTime.now().uptimeNanoseconds
    let elapsed = Double(end - start) / 1_000_000_000.0
    let totalBytes = UInt64(args.blockSize) * UInt64(args.operations)
    let mib = Double(totalBytes) / (1024.0 * 1024.0)
    let throughput = mib / elapsed
    let iops = Double(args.operations) / elapsed
    print(
        String(
            format: "BENCH pattern=%@ block_bytes=%d operations=%d span_bytes=%llu total_bytes=%llu nocache=1 rdahead=0 seconds=%.6f mib_per_s=%.3f iops=%.1f checksum=%llu",
            args.pattern.rawValue,
            args.blockSize,
            args.operations,
            args.spanBytes,
            totalBytes,
            elapsed,
            throughput,
            iops,
            checksum
        )
    )
}

do {
    try runBenchmark()
} catch {
    fputs("FuseTReadBenchmark: \(error)\n", stderr)
    exit(1)
}
