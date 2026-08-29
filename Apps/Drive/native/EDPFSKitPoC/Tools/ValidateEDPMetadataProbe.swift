import Foundation

@main
struct ValidateEDPMetadataProbe {
    enum ValidationError: Error, CustomStringConvertible {
        case usage
        case invalidJSON
        case invalidHex(String)
        case missingField(String)
        case recognitionFailed(String)
        case mismatch(String)

        var description: String {
            switch self {
            case .usage:
                return "usage: validate-edp-probe <fixtures/golden/disks.json>"
            case .invalidJSON:
                return "invalid golden fixture JSON"
            case .invalidHex(let value):
                return "invalid hex string: \(value.prefix(32))"
            case .missingField(let field):
                return "missing fixture field: \(field)"
            case .recognitionFailed(let name):
                return "Swift EDP recognizer rejected fixture \(name)"
            case .mismatch(let message):
                return message
            }
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
        guard CommandLine.arguments.count == 2 else {
            throw ValidationError.usage
        }

        let goldenPath = CommandLine.arguments[1]
        try validateAlignmentMath()
        try validateAlignmentProperties()
        try validateAlignmentErrorPaths()
        try validateShortReadContinuation()
        try validateLBA4SerialRules()
        try validateLBA7ShapeGuards()
        try validateLBA7GoldenFixtures(path: goldenPath)
        try validateReservedSectorProbe(goldenPath: goldenPath)
        try validateMediaClassification()
        try validateRealStandardClassification(goldenPath: goldenPath)
        print("RESULT=SWIFT_EDP_LBA7_GOLDEN_OK")
        print("RESULT=SWIFT_EDP_RESERVED_PROBE_GOLDEN_OK")
    }

    private static func validateAlignmentMath() throws {
        let sector512 = try EDPAlignedRead.window(
            byteOffset: EDPMetadataProbe.lba4ByteOffset,
            byteLength: EDPMetadataProbe.reservedProbeByteLength,
            transferAlignment: 512
        )
        guard sector512 == .init(start: 2048, length: 2048, sliceOffset: 0, sliceLength: 2048) else {
            throw ValidationError.mismatch("512-byte reserved window mismatch: \(sector512)")
        }

        let sector4096 = try EDPAlignedRead.window(
            byteOffset: EDPMetadataProbe.lba4ByteOffset,
            byteLength: EDPMetadataProbe.reservedProbeByteLength,
            transferAlignment: 4096
        )
        guard sector4096 == .init(start: 0, length: 4096, sliceOffset: 2048, sliceLength: 2048) else {
            throw ValidationError.mismatch("4096-byte reserved window mismatch: \(sector4096)")
        }

        let bounded = try EDPAlignedRead.window(
            byteOffset: 1024,
            byteLength: 512,
            transferAlignment: 512,
            sizeBytes: 1536
        )
        guard bounded == .init(start: 1024, length: 512, sliceOffset: 0, sliceLength: 512) else {
            throw ValidationError.mismatch("bounded aligned window mismatch: \(bounded)")
        }

        print("ALIGNMENT_512=OK")
        print("ALIGNMENT_4096=OK")
    }

    private static func validateAlignmentProperties() throws {
        var rng = DeterministicRNG(seed: 0x4544_502d_414c_4947)
        let alignments: [UInt64] = [1, 16, 512, 4096, 8192]
        var validated = 0

        for alignment in alignments {
            for _ in 0..<256 {
                let byteOffset = rng.next() % (2 * 1024 * 1024)
                let byteLength = (rng.next() % 32_768) + 1
                let window = try EDPAlignedRead.window(
                    byteOffset: byteOffset,
                    byteLength: byteLength,
                    transferAlignment: alignment
                )

                let targetEnd = byteOffset + byteLength
                let requestEnd = window.start + UInt64(window.length)
                guard window.start % alignment == 0,
                      UInt64(window.length) % alignment == 0,
                      window.start <= byteOffset,
                      requestEnd >= targetEnd,
                      window.sliceOffset == Int(byteOffset - window.start),
                      window.sliceLength == Int(byteLength),
                      window.sliceOffset >= 0,
                      window.sliceLength > 0,
                      window.sliceOffset + window.sliceLength <= window.length else {
                    throw ValidationError.mismatch(
                        "alignment property failed: alignment=\(alignment) offset=\(byteOffset) length=\(byteLength) window=\(window)"
                    )
                }

                let bounded = try EDPAlignedRead.window(
                    byteOffset: byteOffset,
                    byteLength: byteLength,
                    transferAlignment: alignment,
                    sizeBytes: requestEnd
                )
                guard bounded == window else {
                    throw ValidationError.mismatch(
                        "bounded alignment property changed window: alignment=\(alignment) offset=\(byteOffset) length=\(byteLength)"
                    )
                }
                validated += 1
            }
        }

        print("ALIGNED_WINDOW_PROPERTIES=OK:cases=\(validated)")
    }

    private static func validateAlignmentErrorPaths() throws {
        try expectThrows("accepted zero transfer alignment") {
            _ = try EDPAlignedRead.window(byteOffset: 0, byteLength: 512, transferAlignment: 0)
        }
        try expectThrows("accepted zero byte length") {
            _ = try EDPAlignedRead.window(byteOffset: 0, byteLength: 0, transferAlignment: 512)
        }
        try expectThrows("accepted overflowing byte range") {
            _ = try EDPAlignedRead.window(
                byteOffset: UInt64.max - 31,
                byteLength: 64,
                transferAlignment: 512
            )
        }
        try expectThrows("accepted logical range beyond device size") {
            _ = try EDPAlignedRead.window(
                byteOffset: 1024,
                byteLength: 513,
                transferAlignment: 512,
                sizeBytes: 1536
            )
        }
        try expectThrows("accepted aligned expansion beyond device size") {
            _ = try EDPAlignedRead.window(
                byteOffset: 1025,
                byteLength: 1,
                transferAlignment: 512,
                sizeBytes: 1400
            )
        }
        print("ALIGNED_WINDOW_NEGATIVE_CONTROLS=OK")
    }

    private static func validateShortReadContinuation() throws {
        try EDPAlignedRead.validateContinuation(
            completed: 512,
            totalLength: 2048,
            transferAlignment: 512
        )
        try EDPAlignedRead.validateContinuation(
            completed: 4096,
            totalLength: 8192,
            transferAlignment: 4096
        )
        try EDPAlignedRead.validateContinuation(
            completed: 2048,
            totalLength: 2048,
            transferAlignment: 4096
        )

        try expectThrows("accepted unaligned 4096-byte short-read continuation") {
            try EDPAlignedRead.validateContinuation(
                completed: 512,
                totalLength: 4096,
                transferAlignment: 4096
            )
        }
        try expectThrows("accepted zero-byte short read") {
            try EDPAlignedRead.validateContinuation(
                completed: 0,
                totalLength: 4096,
                transferAlignment: 4096
            )
        }
        try expectThrows("accepted completed bytes beyond requested length") {
            try EDPAlignedRead.validateContinuation(
                completed: 4097,
                totalLength: 4096,
                transferAlignment: 4096
            )
        }

        var rng = DeterministicRNG(seed: 0x4544_502d_5348_4f52)
        var propertyCases = 0
        for alignment in [UInt64(16), 512, 4096] {
            for _ in 0..<128 {
                let totalBlocks = Int(rng.next() % 16) + 2
                let completedBlocks = Int(rng.next() % UInt64(totalBlocks - 1)) + 1
                let total = Int(alignment) * totalBlocks
                let completed = Int(alignment) * completedBlocks
                try EDPAlignedRead.validateContinuation(
                    completed: completed,
                    totalLength: total,
                    transferAlignment: alignment
                )
                try expectThrows("accepted randomized unaligned continuation") {
                    try EDPAlignedRead.validateContinuation(
                        completed: completed + 1,
                        totalLength: total,
                        transferAlignment: alignment
                    )
                }
                propertyCases += 1
            }
        }

        print("ALIGNED_SHORT_READ_CONTINUATION=OK")
        print("ALIGNED_CONTINUATION_PROPERTIES=OK:cases=\(propertyCases)")
    }

    private static func validateLBA4SerialRules() throws {
        let valid = makeLBA4(markerOffset: 8, payload: Array("LEXAR-EDP-001".utf8))
        guard EDPMetadataProbe.lba4Serial(valid) == "LEXAR-EDP-001" else {
            throw ValidationError.mismatch("valid LBA4 serial marker was rejected")
        }

        let empty = makeLBA4(markerOffset: 0, payload: [])
        let tooLong = makeLBA4(markerOffset: 0, payload: [UInt8](repeating: 0x41, count: 97))
        let tooLate = makeLBA4(markerOffset: 65, payload: Array("serial".utf8))
        let control = makeLBA4(markerOffset: 0, payload: [0x41, 0x1f, 0x42])
        let dollar = makeLBA4(markerOffset: 0, payload: [0x41, 0x24, 0x42])

        guard EDPMetadataProbe.lba4Serial([UInt8](repeating: 0, count: 511)) == nil,
              EDPMetadataProbe.lba4Serial([UInt8](repeating: 0, count: 512)) == nil,
              EDPMetadataProbe.lba4Serial(empty) == nil,
              EDPMetadataProbe.lba4Serial(tooLong) == nil,
              EDPMetadataProbe.lba4Serial(tooLate) == nil,
              EDPMetadataProbe.lba4Serial(control) == nil,
              EDPMetadataProbe.lba4Serial(dollar) == nil else {
            throw ValidationError.mismatch("LBA4 serial parser accepted an invalid marker")
        }

        print("LBA4_SERIAL_NEGATIVE_CONTROLS=OK")
    }

    private static func validateLBA7ShapeGuards() throws {
        guard EDPMetadataProbe.recognizeOldFormatLBA7([UInt8](repeating: 0, count: 511)) == nil,
              EDPMetadataProbe.recognizeOldFormatLBA7([UInt8](repeating: 0, count: 513)) == nil,
              EDPMetadataProbe.recognizeOldFormatLBA7([UInt8](repeating: 0, count: 512)) == nil else {
            throw ValidationError.mismatch("LBA7 recognizer accepted invalid-shaped/random input")
        }
        print("LBA7_SHAPE_GUARDS=OK")
    }

    /// Keeps the Swift rolling-XOR decoder pinned byte-for-byte to the existing
    /// Rust golden fixture for every captured disk.
    private static func validateLBA7GoldenFixtures(path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let disks = root["disks"] as? [[String: Any]],
              !disks.isEmpty else {
            throw ValidationError.invalidJSON
        }

        var validated = 0
        for disk in disks {
            guard let name = disk["name"] as? String else {
                throw ValidationError.missingField("name")
            }
            guard let lba7 = disk["lba7"] as? [String: Any],
                  let cipherHex = lba7["cipher_hex"] as? String,
                  let plainHex = lba7["plain_hex"] as? String,
                  let expectedK0 = lba7["k0"] as? NSNumber else {
                throw ValidationError.missingField("\(name).lba7")
            }

            let cipher = try decodeHex(cipherHex)
            let expectedPlain = try decodeHex(plainHex)
            guard let recognition = EDPMetadataProbe.recognizeOldFormatLBA7(cipher) else {
                throw ValidationError.recognitionFailed(name)
            }

            guard recognition.k0 == expectedK0.uint16Value else {
                throw ValidationError.mismatch(
                    "\(name): K0 mismatch swift=\(recognition.k0) fixture=\(expectedK0.uint16Value)"
                )
            }
            guard recognition.plaintext == expectedPlain else {
                throw ValidationError.mismatch("\(name): decoded LBA7 plaintext differs from fixture")
            }

            validated += 1
            print("GOLDEN_LBA7_OK=\(name) k0=\(String(format: "0x%04x", recognition.k0))")
        }

        print("GOLDEN_LBA7_COUNT=\(validated)")
    }

    /// Matches the conservative Rust `edp-core::probe` regression against the
    /// captured disk4/disk5 reserved sectors and verifies that either missing
    /// signal prevents automatic recognition.
    private static func validateReservedSectorProbe(goldenPath: String) throws {
        let goldenURL = URL(fileURLWithPath: goldenPath).standardizedFileURL
        let fixturesURL = goldenURL
            .deletingLastPathComponent() // golden
            .deletingLastPathComponent() // fixtures

        for diskName in ["disk4", "disk5"] {
            let diskURL = fixturesURL.appendingPathComponent("real_disks/\(diskName)")
            let lba4 = [UInt8](try Data(contentsOf: diskURL.appendingPathComponent("LBA4.bin")))
            let lba7 = [UInt8](try Data(contentsOf: diskURL.appendingPathComponent("LBA7.bin")))

            guard let evidence = EDPMetadataProbe.recognizeReservedSectors(lba4: lba4, lba7: lba7) else {
                throw ValidationError.recognitionFailed("\(diskName) reserved sectors")
            }
            guard evidence.partitionTypes == [1, 2, 4], !evidence.serial.isEmpty else {
                throw ValidationError.mismatch("\(diskName): invalid reserved-sector evidence")
            }

            print(
                "RESERVED_PROBE_OK=\(diskName) serial=\(evidence.serial) " +
                "k0=\(String(format: "0x%04x", evidence.lba7K0))"
            )

            let zeros = [UInt8](repeating: 0, count: 512)
            guard EDPMetadataProbe.recognizeReservedSectors(lba4: zeros, lba7: lba7) == nil,
                  EDPMetadataProbe.recognizeReservedSectors(lba4: lba4, lba7: zeros) == nil else {
                throw ValidationError.mismatch("\(diskName): recognizer accepted only one signal")
            }
        }

        print("RESERVED_PROBE_NEGATIVE_CONTROLS=OK")
    }

    private static func validateMediaClassification() throws {
        let lba4 = makeLBA4(markerOffset: 8, payload: Array("EDP-CLASSIFIER".utf8))
        let bootSectors: UInt64 = 20_417
        let bootBytes = bootSectors * 512
        let shareStart: UInt64 = 20_480
        let shareBytes: UInt64 = 117_000_000 * 512
        let secureStart: UInt64 = 117_020_480
        let secureBytes: UInt64 = 3_072

        let standardLBA7 = encodeOldFormatLBA7(makeEDPFTable(
            stride: 0x40,
            entries: [
                (1, 63, bootBytes),
                (2, shareStart, shareBytes),
                (4, secureStart, secureBytes),
            ]
        ))
        let standardLBA12 = makeEDPFTable(
            stride: 0x60,
            entries: [
                (1, 63, bootBytes),
                (2, shareStart, shareBytes),
                (4, secureStart, secureBytes),
            ]
        )
        let standardMBR = makeMBR(startSector: 63, sectorCount: bootSectors)
        guard EDPMetadataProbe.classifyMedia(
            lba0: standardMBR,
            lba4: lba4,
            lba7: standardLBA7,
            lba12Plain: standardLBA12
        ) == .standardEncrypted,
        EDPMetadataProbe.recognizeStandardEncryptedFrontMetadata(
            lba0: standardMBR,
            lba4: lba4,
            lba7: standardLBA7
        ) != nil else {
            throw ValidationError.mismatch("factory-standard EDP media was not accepted by the standard-only gates")
        }

        // Legacy `make_big_boot.py`: LBA7 is untouched; LBA12 keeps all
        // three entries and only changes entry0 Boot/type=1 -> Share/type=2.
        // The physical MBR partition is widened beyond the old Boot geometry.
        let legacyLBA12 = makeEDPFTable(
            stride: 0x60,
            entries: [
                (2, 63, bootBytes),
                (2, shareStart, shareBytes),
                (4, secureStart, secureBytes),
            ]
        )
        let legacyMBR = makeMBR(startSector: 63, sectorCount: 50 * 1024 * 1024 * 1024 / 512)
        guard EDPMetadataProbe.classifyMedia(
            lba0: legacyMBR,
            lba4: lba4,
            lba7: standardLBA7,
            lba12Plain: legacyLBA12
        ) == .legacyNoPassword,
        EDPMetadataProbe.recognizeStandardEncryptedFrontMetadata(
            lba0: legacyMBR,
            lba4: lba4,
            lba7: standardLBA7
        ) == nil else {
            throw ValidationError.mismatch("legacy no-password media was not classified/rejected correctly")
        }

        // Current conversion rewrites both EDPF tables to [Share, Encrypt]
        // and makes MBR partition 1 exactly match the plaintext Share slice.
        let currentShareSectors: UInt64 = 117_611_802
        let currentShareBytes = currentShareSectors * 512
        let currentLBA7 = encodeOldFormatLBA7(makeEDPFTable(
            stride: 0x40,
            entries: [
                (2, 63, currentShareBytes),
                (4, secureStart, secureBytes),
            ]
        ))
        let currentLBA12 = makeEDPFTable(
            stride: 0x60,
            entries: [
                (2, 63, currentShareBytes),
                (4, secureStart, secureBytes),
            ]
        )
        let currentMBR = makeMBR(startSector: 63, sectorCount: currentShareSectors)
        guard EDPMetadataProbe.classifyMedia(
            lba0: currentMBR,
            lba4: lba4,
            lba7: currentLBA7,
            lba12Plain: currentLBA12
        ) == .currentNoPassword,
        EDPMetadataProbe.recognizeStandardEncryptedFrontMetadata(
            lba0: currentMBR,
            lba4: lba4,
            lba7: currentLBA7
        ) == nil else {
            throw ValidationError.mismatch("current no-password media was not classified/rejected correctly")
        }

        var malformedMBR = standardMBR
        malformedMBR[0x1be + 12] ^= 0x01
        guard EDPMetadataProbe.classifyMedia(
            lba0: malformedMBR,
            lba4: lba4,
            lba7: standardLBA7,
            lba12Plain: standardLBA12
        ) == .unrecognizedEDP else {
            throw ValidationError.mismatch("EDP evidence with inconsistent MBR geometry was not classified as unrecognizedEDP")
        }

        let mismatchedLBA7 = encodeOldFormatLBA7(makeEDPFTable(
            stride: 0x40,
            entries: [
                (1, 64, bootBytes),
                (2, shareStart, shareBytes),
                (4, secureStart, secureBytes),
            ]
        ))
        guard EDPMetadataProbe.classifyMedia(
            lba0: standardMBR,
            lba4: lba4,
            lba7: mismatchedLBA7,
            lba12Plain: standardLBA12
        ) == .unrecognizedEDP else {
            throw ValidationError.mismatch("EDP evidence with inconsistent LBA7/LBA12 geometry was claimed as standard")
        }

        let zeros = [UInt8](repeating: 0, count: 512)
        guard EDPMetadataProbe.classifyMedia(
            lba0: zeros,
            lba4: zeros,
            lba7: zeros,
            lba12Plain: nil
        ) == .ordinaryUSB else {
            throw ValidationError.mismatch("ordinary USB fixture was not classified as ordinaryUSB")
        }
        guard EDPMetadataProbe.classifyMedia(
            lba0: zeros,
            lba4: zeros,
            lba7: zeros,
            lba12Plain: nil,
            hasLBA11Identity: true
        ) == .unrecognizedEDP else {
            throw ValidationError.mismatch("LBA11-only EDP evidence was not classified as unrecognizedEDP")
        }

        print("MEDIA_CLASS_STANDARD_ENCRYPTED=OK")
        print("MEDIA_CLASS_LEGACY_NOPWD=OK")
        print("MEDIA_CLASS_CURRENT_NOPWD=OK")
        print("MEDIA_CLASS_UNRECOGNIZED_EDP=OK")
        print("MEDIA_CLASS_ORDINARY_USB=OK")
    }

    private static func validateRealStandardClassification(goldenPath: String) throws {
        let goldenURL = URL(fileURLWithPath: goldenPath).standardizedFileURL
        let goldenData = try Data(contentsOf: goldenURL)
        guard let root = try JSONSerialization.jsonObject(with: goldenData) as? [String: Any],
              let disks = root["disks"] as? [[String: Any]] else {
            throw ValidationError.invalidJSON
        }
        let byName = Dictionary(uniqueKeysWithValues: disks.compactMap { disk -> (String, [String: Any])? in
            guard let name = disk["name"] as? String else { return nil }
            return (name, disk)
        })
        let fixturesURL = goldenURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        for (diskDir, goldenName) in [
            ("disk4", "disk4_real_lexar"),
            ("disk5", "disk5_real_sandisk"),
        ] {
            guard let fixture = byName[goldenName],
                  let lba12 = fixture["lba12"] as? [String: Any],
                  let plainHex = lba12["plain_hex"] as? String else {
                throw ValidationError.missingField("\(goldenName).lba12.plain_hex")
            }
            let diskURL = fixturesURL.appendingPathComponent("real_disks/\(diskDir)")
            let front = try Data(contentsOf: diskURL.appendingPathComponent("lba0_16.bin"))
            guard front.count >= 512 else {
                throw ValidationError.mismatch("\(diskDir): lba0_16 fixture is too short")
            }
            let lba0 = [UInt8](front.prefix(512))
            let lba4 = [UInt8](try Data(contentsOf: diskURL.appendingPathComponent("LBA4.bin")))
            let lba7 = [UInt8](try Data(contentsOf: diskURL.appendingPathComponent("LBA7.bin")))
            let lba12Plain = try decodeHex(plainHex)

            guard EDPMetadataProbe.classifyMedia(
                lba0: lba0,
                lba4: lba4,
                lba7: lba7,
                lba12Plain: lba12Plain
            ) == .standardEncrypted else {
                throw ValidationError.mismatch("\(diskDir): real standard EDP fixture was not classified as standardEncrypted")
            }
            print("REAL_STANDARD_CLASSIFICATION_OK=\(diskDir)")
        }
    }

    private static func makeEDPFTable(
        stride: Int,
        entries: [(type: UInt32, start: UInt64, size: UInt64)]
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 512)
        for (index, entry) in entries.prefix(3).enumerated() {
            let offset = index * stride
            bytes.replaceSubrange(offset..<(offset + 4), with: Array("EDPF".utf8))
            writeUInt32LE(entry.type, into: &bytes, at: offset + 0x0c)
            writeUInt64LE(entry.start, into: &bytes, at: offset + 0x18)
            writeUInt64LE(entry.size, into: &bytes, at: offset + 0x28)
        }
        return bytes
    }

    private static func encodeOldFormatLBA7(_ plaintext: [UInt8], k0: UInt16 = 0x8541) -> [UInt8] {
        var cipher = plaintext
        var key = UInt32(k0)
        for i in 0..<(cipher.count / 2) {
            let offset = i * 2
            let plainWord = UInt16(plaintext[offset]) | (UInt16(plaintext[offset + 1]) << 8)
            let cipherWord = plainWord ^ UInt16(truncatingIfNeeded: key)
            cipher[offset] = UInt8(truncatingIfNeeded: cipherWord)
            cipher[offset + 1] = UInt8(truncatingIfNeeded: cipherWord >> 8)
            key = (key + 0x100 - UInt32(i) - 1) & 0xffff
        }
        return cipher
    }

    private static func makeMBR(startSector: UInt64, sectorCount: UInt64) -> [UInt8] {
        precondition(startSector <= UInt64(UInt32.max) && sectorCount <= UInt64(UInt32.max))
        var bytes = [UInt8](repeating: 0, count: 512)
        let offset = 0x1be
        bytes[offset + 4] = 0x07
        writeUInt32LE(UInt32(startSector), into: &bytes, at: offset + 8)
        writeUInt32LE(UInt32(sectorCount), into: &bytes, at: offset + 12)
        bytes[510] = 0x55
        bytes[511] = 0xaa
        return bytes
    }

    private static func writeUInt32LE(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        for shift in 0..<4 {
            bytes[offset + shift] = UInt8(truncatingIfNeeded: value >> UInt32(shift * 8))
        }
    }

    private static func writeUInt64LE(_ value: UInt64, into bytes: inout [UInt8], at offset: Int) {
        for shift in 0..<8 {
            bytes[offset + shift] = UInt8(truncatingIfNeeded: value >> UInt64(shift * 8))
        }
    }

    private static func makeLBA4(markerOffset: Int, payload: [UInt8]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 512)
        let marker: [UInt8] = [0x24, 0x24, 0x24]
        let total = marker.count + payload.count + marker.count
        guard markerOffset >= 0, markerOffset + total <= bytes.count else {
            return bytes
        }
        bytes.replaceSubrange(markerOffset..<(markerOffset + marker.count), with: marker)
        let payloadStart = markerOffset + marker.count
        bytes.replaceSubrange(payloadStart..<(payloadStart + payload.count), with: payload)
        let markerEnd = payloadStart + payload.count
        bytes.replaceSubrange(markerEnd..<(markerEnd + marker.count), with: marker)
        return bytes
    }

    private static func expectThrows(_ message: String, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch {
            return
        }
        throw ValidationError.mismatch(message)
    }

    private static func decodeHex(_ value: String) throws -> [UInt8] {
        guard value.count.isMultiple(of: 2) else {
            throw ValidationError.invalidHex(value)
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                throw ValidationError.invalidHex(value)
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
