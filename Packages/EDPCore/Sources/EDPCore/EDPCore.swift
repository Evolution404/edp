import CEDPCore
import Dispatch
import Foundation

public enum EDPCoreError: Error, CustomStringConvertible, Sendable {
    case invalidInput(String)
    case cryptoFailure(String)

    public var description: String {
        switch self {
        case .invalidInput(let message), .cryptoFailure(let message): return message
        }
    }
}

public enum EDPCrypto {
    public static func crc32Bare(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        edp_crc32_bare(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
    }

    public static func crc32Bare(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { crc32Bare($0) }
    }

    public static var sm4BackendName: String {
        String(cString: edp_sm4_backend_name())
    }
}

public enum EDPSM4ExecutionPolicy: Sendable {
    case serial
    case parallel(maxWorkers: Int)
    case automatic
}

private final class EDPSM4ParallelState: @unchecked Sendable {
    let handle: OpaquePointer
    let inputAddress: UInt
    let outputAddress: UInt
    let totalBlocks: Int
    let blocksPerWorker: Int
    let decrypt: Bool
    private let failureLock = NSLock()
    private var failed = false

    init(
        handle: OpaquePointer,
        input: UnsafeRawPointer,
        output: UnsafeMutableRawPointer,
        totalBlocks: Int,
        blocksPerWorker: Int,
        decrypt: Bool
    ) {
        self.handle = handle
        inputAddress = UInt(bitPattern: input)
        outputAddress = UInt(bitPattern: output)
        self.totalBlocks = totalBlocks
        self.blocksPerWorker = blocksPerWorker
        self.decrypt = decrypt
    }

    func run(worker: Int) {
        let firstBlock = worker * blocksPerWorker
        guard firstBlock < totalBlocks else { return }
        let endBlock = min(totalBlocks, firstBlock + blocksPerWorker)
        let byteOffset = firstBlock * 16
        let byteCount = (endBlock - firstBlock) * 16
        guard let inputBase = UnsafeRawPointer(bitPattern: inputAddress),
              let outputBase = UnsafeMutableRawPointer(bitPattern: outputAddress) else {
            recordFailure()
            return
        }
        let inputPointer = inputBase.advanced(by: byteOffset).assumingMemoryBound(to: UInt8.self)
        let outputPointer = outputBase.advanced(by: byteOffset).assumingMemoryBound(to: UInt8.self)
        let result = decrypt
            ? edp_sm4_decrypt(handle, inputPointer, outputPointer, byteCount)
            : edp_sm4_encrypt(handle, inputPointer, outputPointer, byteCount)
        if result != 0 { recordFailure() }
    }

    var hasFailure: Bool {
        failureLock.lock()
        defer { failureLock.unlock() }
        return failed
    }

    private func recordFailure() {
        failureLock.lock()
        failed = true
        failureLock.unlock()
    }
}

public final class EDPSM4: @unchecked Sendable {
    private static let fourWorkerThreshold = 64 * 1024
    private static let sixWorkerThreshold = 128 * 1024
    private let handle: OpaquePointer

    public init(key: [UInt8]) throws {
        guard key.count == 16 else {
            throw EDPCoreError.invalidInput("SM4 key must be exactly 16 bytes")
        }
        guard let context = key.withUnsafeBufferPointer({ edp_sm4_create($0.baseAddress, $0.count) }) else {
            throw EDPCoreError.cryptoFailure("unable to create SM4 context")
        }
        handle = context
    }

    deinit {
        edp_sm4_destroy(handle)
    }

    public func encrypt(
        input: UnsafeRawBufferPointer,
        output: UnsafeMutableRawBufferPointer,
        policy: EDPSM4ExecutionPolicy = .automatic
    ) throws {
        try crypt(input: input, output: output, decrypt: false, policy: policy)
    }

    public func decrypt(
        input: UnsafeRawBufferPointer,
        output: UnsafeMutableRawBufferPointer,
        policy: EDPSM4ExecutionPolicy = .automatic
    ) throws {
        try crypt(input: input, output: output, decrypt: true, policy: policy)
    }

    public func encryptInPlace(
        _ buffer: UnsafeMutableRawBufferPointer,
        policy: EDPSM4ExecutionPolicy = .automatic
    ) throws {
        try cryptInPlace(buffer, decrypt: false, policy: policy)
    }

    public func decryptInPlace(
        _ buffer: UnsafeMutableRawBufferPointer,
        policy: EDPSM4ExecutionPolicy = .automatic
    ) throws {
        try cryptInPlace(buffer, decrypt: true, policy: policy)
    }

    public func encryptInPlace(
        _ data: inout Data,
        policy: EDPSM4ExecutionPolicy = .automatic
    ) throws {
        try data.withUnsafeMutableBytes { try encryptInPlace($0, policy: policy) }
    }

    public func decryptInPlace(
        _ data: inout Data,
        policy: EDPSM4ExecutionPolicy = .automatic
    ) throws {
        try data.withUnsafeMutableBytes { try decryptInPlace($0, policy: policy) }
    }

    public func encrypt(_ data: Data) throws -> Data {
        var output = data
        try encryptInPlace(&output)
        return output
    }

    public func decrypt(_ data: Data) throws -> Data {
        var output = data
        try decryptInPlace(&output)
        return output
    }

    /// Compatibility API for metadata-sized buffers. Hot I/O paths should use
    /// Data/raw-buffer in-place operations to avoid array conversion copies.
    public func encryptAligned(_ bytes: [UInt8]) throws -> [UInt8] {
        Array(try encrypt(Data(bytes)))
    }

    /// Compatibility API for metadata-sized buffers. Hot I/O paths should use
    /// Data/raw-buffer in-place operations to avoid array conversion copies.
    public func decryptAligned(_ bytes: [UInt8]) throws -> [UInt8] {
        Array(try decrypt(Data(bytes)))
    }

    private func cryptInPlace(
        _ buffer: UnsafeMutableRawBufferPointer,
        decrypt: Bool,
        policy: EDPSM4ExecutionPolicy
    ) throws {
        let input = UnsafeRawBufferPointer(buffer)
        try crypt(input: input, output: buffer, decrypt: decrypt, policy: policy)
    }

    private func crypt(
        input: UnsafeRawBufferPointer,
        output: UnsafeMutableRawBufferPointer,
        decrypt: Bool,
        policy: EDPSM4ExecutionPolicy
    ) throws {
        guard input.count == output.count else {
            throw EDPCoreError.invalidInput("SM4 input/output lengths must match")
        }
        guard input.count % 16 == 0 else {
            throw EDPCoreError.invalidInput("SM4 input length must be 16-byte aligned")
        }
        if input.isEmpty { return }

        let workers: Int
        switch policy {
        case .serial:
            workers = 1
        case .parallel(let maxWorkers):
            workers = max(1, min(maxWorkers, input.count / 16))
        case .automatic:
            let active = max(1, ProcessInfo.processInfo.activeProcessorCount)
            if input.count >= Self.sixWorkerThreshold {
                workers = min(6, active)
            } else if input.count >= Self.fourWorkerThreshold {
                workers = min(4, active)
            } else {
                workers = 1
            }
        }

        if workers <= 1 {
            try cryptSerial(input: input, output: output, decrypt: decrypt)
            return
        }

        let totalBlocks = input.count / 16
        let actualWorkers = min(workers, totalBlocks)
        let blocksPerWorker = (totalBlocks + actualWorkers - 1) / actualWorkers
        let state = EDPSM4ParallelState(
            handle: handle,
            input: input.baseAddress!,
            output: output.baseAddress!,
            totalBlocks: totalBlocks,
            blocksPerWorker: blocksPerWorker,
            decrypt: decrypt
        )

        DispatchQueue.concurrentPerform(iterations: actualWorkers) { worker in
            state.run(worker: worker)
        }

        guard !state.hasFailure else {
            throw EDPCoreError.cryptoFailure("SM4 parallel backend rejected the buffer")
        }
    }

    private func cryptSerial(
        input: UnsafeRawBufferPointer,
        output: UnsafeMutableRawBufferPointer,
        decrypt: Bool
    ) throws {
        let inputBytes = input.bindMemory(to: UInt8.self)
        let outputBytes = output.bindMemory(to: UInt8.self)
        let result = decrypt
            ? edp_sm4_decrypt(handle, inputBytes.baseAddress, outputBytes.baseAddress, inputBytes.count)
            : edp_sm4_encrypt(handle, inputBytes.baseAddress, outputBytes.baseAddress, inputBytes.count)
        guard result == 0 else {
            throw EDPCoreError.cryptoFailure("SM4 backend rejected the buffer")
        }
    }
}
