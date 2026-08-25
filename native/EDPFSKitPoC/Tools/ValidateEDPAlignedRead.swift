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

    static func main() throws {
        try validateSegmentedRead()
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
