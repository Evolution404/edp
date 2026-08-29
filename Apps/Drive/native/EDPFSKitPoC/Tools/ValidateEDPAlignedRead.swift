import Foundation

@main
struct ValidateEDPAlignedRead {
    enum Failure: Error, CustomStringConvertible {
        case message(String)

        var description: String {
            if case .message(let message) = self {
                return message
            }
            return "aligned-read validation failed"
        }
    }

    private struct DeterministicRNG {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    static func main() throws {
        try validateSegmentedRead()
        try validateSegmentedReadProperties()
        try validateInvalidReadResults()
        try validateOffsetOverflow()
        print("RESULT=ALIGNED_READ_LOOP_OK")
    }

    private static func validateSegmentedRead() throws {
        var output = Data(count: 8192)
        var requests: [(offset: UInt64, length: Int)] = []
        var callIndex = 0

        try output.withUnsafeMutableBytes { buffer in
            try EDPAlignedRead.readFully(
                at: 8192,
                into: buffer,
                transferAlignment: 4096
            ) { requestBuffer, requestOffset, requestedLength in
                requests.append((requestOffset, requestedLength))
                let returnedLength = callIndex == 0 ? 4096 : requestedLength
                guard let destination = requestBuffer.baseAddress else {
                    throw Failure.message("segmented read received a nil destination")
                }
                memset(destination, callIndex == 0 ? 0x11 : 0x22, returnedLength)
                callIndex += 1
                return returnedLength
            }
        }

        guard requests.count == 2,
              requests[0].offset == 8192,
              requests[0].length == 8192,
              requests[1].offset == 12288,
              requests[1].length == 4096 else {
            throw Failure.message("aligned short-read request progression is wrong: \(requests)")
        }

        let bytes = [UInt8](output)
        guard bytes[..<4096].allSatisfy({ $0 == 0x11 }),
              bytes[4096...].allSatisfy({ $0 == 0x22 }) else {
            throw Failure.message("segmented read wrote bytes into the wrong destination range")
        }

        print("ALIGNED_READ_SEGMENTED_PROGRESS=OK")
    }

    private static func validateSegmentedReadProperties() throws {
        var rng = DeterministicRNG(seed: 0x4544_502d_5245_4144)
        var cases = 0

        for alignment in [UInt64(512), 4096] {
            let alignmentInt = Int(alignment)
            for _ in 0..<256 {
                let blockCount = Int(rng.next() % 32) + 1
                let byteCount = blockCount * alignmentInt
                let baseBlock = (rng.next() % 4096) + 1
                let baseOffset = baseBlock * alignment
                var output = Data(count: byteCount)
                var completed = 0
                var requestCount = 0

                try output.withUnsafeMutableBytes { buffer in
                    try EDPAlignedRead.readFully(
                        at: baseOffset,
                        into: buffer,
                        transferAlignment: alignment
                    ) { requestBuffer, requestOffset, requestedLength in
                        let expectedOffset = baseOffset + UInt64(completed)
                        let expectedRemaining = byteCount - completed
                        guard requestOffset == expectedOffset,
                              requestedLength == expectedRemaining,
                              requestedLength > 0,
                              requestedLength % alignmentInt == 0,
                              let destination = requestBuffer.baseAddress else {
                            throw Failure.message(
                                "randomized progression mismatch alignment=\(alignment) completed=\(completed) " +
                                "offset=\(requestOffset) length=\(requestedLength)"
                            )
                        }

                        let remainingBlocks = requestedLength / alignmentInt
                        let returnedBlocks = Int(rng.next() % UInt64(remainingBlocks)) + 1
                        let returnedLength = returnedBlocks * alignmentInt
                        let bytes = destination.assumingMemoryBound(to: UInt8.self)
                        for index in 0..<returnedLength {
                            bytes[index] = UInt8(truncatingIfNeeded: requestOffset + UInt64(index) + 0x5a)
                        }
                        completed += returnedLength
                        requestCount += 1
                        return returnedLength
                    }
                }

                guard completed == byteCount, requestCount >= 1 else {
                    throw Failure.message(
                        "randomized aligned read did not finish alignment=\(alignment) completed=\(completed)/\(byteCount)"
                    )
                }

                let bytes = [UInt8](output)
                for index in bytes.indices {
                    let expected = UInt8(truncatingIfNeeded: baseOffset + UInt64(index) + 0x5a)
                    guard bytes[index] == expected else {
                        throw Failure.message(
                            "randomized aligned read wrote wrong byte alignment=\(alignment) index=\(index) " +
                            "actual=\(bytes[index]) expected=\(expected)"
                        )
                    }
                }
                cases += 1
            }
        }

        print("ALIGNED_READ_SEGMENTED_PROPERTIES=OK:cases=\(cases)")
    }

    private static func validateInvalidReadResults() throws {
        try expectThrows("accepted a zero-byte device read") {
            var data = Data(count: 4096)
            try data.withUnsafeMutableBytes { buffer in
                try EDPAlignedRead.readFully(
                    at: 0,
                    into: buffer,
                    transferAlignment: 4096
                ) { _, _, _ in
                    0
                }
            }
        }

        try expectThrows("accepted a device read larger than requested") {
            var data = Data(count: 4096)
            try data.withUnsafeMutableBytes { buffer in
                try EDPAlignedRead.readFully(
                    at: 0,
                    into: buffer,
                    transferAlignment: 4096
                ) { _, _, requestedLength in
                    requestedLength + 1
                }
            }
        }

        try expectThrows("continued after an unaligned short read") {
            var data = Data(count: 4096)
            try data.withUnsafeMutableBytes { buffer in
                try EDPAlignedRead.readFully(
                    at: 0,
                    into: buffer,
                    transferAlignment: 4096
                ) { _, _, _ in
                    512
                }
            }
        }

        try expectThrows("accepted an unaligned initial offset") {
            var data = Data(count: 4096)
            try data.withUnsafeMutableBytes { buffer in
                try EDPAlignedRead.readFully(
                    at: 512,
                    into: buffer,
                    transferAlignment: 4096
                ) { _, _, requestedLength in
                    requestedLength
                }
            }
        }

        try expectThrows("accepted a non-aligned total buffer length") {
            var data = Data(count: 4097)
            try data.withUnsafeMutableBytes { buffer in
                try EDPAlignedRead.readFully(
                    at: 0,
                    into: buffer,
                    transferAlignment: 4096
                ) { _, _, requestedLength in
                    requestedLength
                }
            }
        }

        print("ALIGNED_READ_INVALID_RESULTS=OK")
    }

    private static func validateOffsetOverflow() throws {
        let maxSignedOffset = UInt64(Int64.max)
        let alignedNearMax = maxSignedOffset - (maxSignedOffset % 4096)
        var deviceCalls = 0

        try expectThrows("continued beyond off_t range") {
            var data = Data(count: 8192)
            try data.withUnsafeMutableBytes { buffer in
                try EDPAlignedRead.readFully(
                    at: alignedNearMax,
                    into: buffer,
                    transferAlignment: 4096
                ) { _, _, _ in
                    deviceCalls += 1
                    return 4096
                }
            }
        }

        guard deviceCalls == 1 else {
            throw Failure.message("off_t overflow should stop before a second device request")
        }
        print("ALIGNED_READ_OFFSET_OVERFLOW=OK")
    }

    private static func expectThrows(_ message: String, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch {
            return
        }
        throw Failure.message(message)
    }
}
