import EDPCore
import Foundation

private struct BenchCase {
    let size: Int
    let iterations: Int
}

private let cases: [BenchCase] = [
    .init(size: 4 * 1024, iterations: 50_000),
    .init(size: 64 * 1024, iterations: 5_000),
    .init(size: 1024 * 1024, iterations: 500),
    .init(size: 64 * 1024 * 1024, iterations: 8),
]

private func formatBytes(_ bytes: Int) -> String {
    if bytes >= 1024 * 1024 { return "\(bytes / (1024 * 1024))MiB" }
    return "\(bytes / 1024)KiB"
}

private func runOne(
    name: String,
    size: Int,
    iterations: Int,
    operation: (_ input: UnsafeRawBufferPointer, _ output: UnsafeMutableRawBufferPointer) throws -> Void
) throws {
    var input = Data(count: size)
    var output = Data(count: size)
    input.withUnsafeMutableBytes { raw in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
        for index in 0..<size {
            base[index] = UInt8(truncatingIfNeeded: index &* 131 &+ 17)
        }
    }

    try input.withUnsafeBytes { inputRaw in
        try output.withUnsafeMutableBytes { outputRaw in
            for _ in 0..<8 { try operation(inputRaw, outputRaw) }
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations { try operation(inputRaw, outputRaw) }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            let totalBytes = Double(size) * Double(iterations)
            let seconds = Double(elapsed) / 1_000_000_000
            let mibPerSecond = totalBytes / (1024 * 1024) / seconds
            let nsPerByte = Double(elapsed) / totalBytes
            print(String(format: "BENCH operation=%@ block=%@ iterations=%d mib_per_s=%.2f ns_per_byte=%.4f", name, formatBytes(size), iterations, mibPerSecond, nsPerByte))
        }
    }
}

private func main() throws {
    let key = Array<UInt8>(repeating: 0x01, count: 16)
    let cipher = try EDPSM4(key: key)
    print("BACKEND=\(EDPCrypto.sm4BackendName)")

    for bench in cases {
        try runOne(name: "encrypt", size: bench.size, iterations: bench.iterations) { input, output in
            try cipher.encrypt(input: input, output: output)
        }
        try runOne(name: "decrypt", size: bench.size, iterations: bench.iterations) { input, output in
            try cipher.decrypt(input: input, output: output)
        }
    }
}

do {
    try main()
} catch {
    fputs("edp-core-bench: \(error)\n", stderr)
    exit(1)
}
