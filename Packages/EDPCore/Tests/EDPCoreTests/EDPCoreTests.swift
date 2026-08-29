import EDPCore
import Foundation
import Testing

private func bytes(_ hex: String) -> [UInt8] {
    stride(from: 0, to: hex.count, by: 2).map { offset in
        let start = hex.index(hex.startIndex, offsetBy: offset)
        let end = hex.index(start, offsetBy: 2)
        return UInt8(hex[start..<end], radix: 16)!
    }
}

@Test func crc32KnownVector() {
    let data = Data("disk&ven_lexar&prod_usb_flash_drive".utf8)
    #expect(EDPCrypto.crc32Bare(data) == 0x6bba_eefb)
}

@Test func sm4StandardVector() throws {
    let key = bytes("0123456789abcdeffedcba9876543210")
    let plain = Data(bytes("0123456789abcdeffedcba9876543210"))
    let expected = Data(bytes("681edf34d206965e86b3e94f536e4246"))
    let cipher = try EDPSM4(key: key)
    #expect(try cipher.encrypt(plain) == expected)
    #expect(try cipher.decrypt(expected) == plain)
}

@Test func sm4InPlaceRoundTripAndFourWayTail() throws {
    let key = Array(0..<16).map(UInt8.init)
    var data = Data((0..<(16 * 9)).map { UInt8(truncatingIfNeeded: $0 * 13 + 7) })
    let original = data
    let cipher = try EDPSM4(key: key)
    try cipher.encryptInPlace(&data)
    #expect(data != original)
    try cipher.decryptInPlace(&data)
    #expect(data == original)
}

@Test func sm4AutomaticParallelMatchesSerial() throws {
    let cipher = try EDPSM4(key: Array(0..<16).map(UInt8.init))
    let source = Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ 11) })
    var serial = source
    var automatic = source
    try serial.withUnsafeMutableBytes { try cipher.encryptInPlace($0, policy: .serial) }
    try automatic.withUnsafeMutableBytes { try cipher.encryptInPlace($0, policy: .automatic) }
    #expect(serial == automatic)
    try automatic.withUnsafeMutableBytes { try cipher.decryptInPlace($0, policy: .automatic) }
    #expect(automatic == source)
}

@Test func sm4RejectsUnalignedBuffer() throws {
    let cipher = try EDPSM4(key: [UInt8](repeating: 0, count: 16))
    var data = Data(count: 15)
    #expect(throws: EDPCoreError.self) {
        try cipher.encryptInPlace(&data)
    }
}

@Test func rollingXORSelfInverse() {
    let plain = (0..<512).map { UInt8(truncatingIfNeeded: $0 * 13 + 1) }
    let encrypted = EDPRollingXOR.apply(plain, k0: 0x8541)
    #expect(EDPRollingXOR.apply(encrypted, k0: 0x8541) == plain)
}

@Test func lba0SectorFieldsContainSignature() throws {
    var raw = [UInt8](repeating: 0, count: 512)
    raw[0x1be + 4] = 0x0e
    raw[0x1be + 8] = 63
    raw[0x1be + 12] = 0xc1
    raw[0x1be + 13] = 0x4f
    raw[0x1fe] = 0x55
    raw[0x1ff] = 0xaa
    let decoded = try EDPSectorDecoder.decode(lba: 0, raw: raw)
    #expect(decoded.decoded == nil)
    #expect(decoded.fields.contains(where: { $0.name == "55AA" && $0.off == 0x1fe }))
    #expect(decoded.fields.contains(where: { $0.name == "分区表项0" }))
}

@Test func zeroLBA9IsIdentityView() throws {
    let raw = [UInt8](repeating: 0, count: 512)
    let decoded = try EDPSectorDecoder.decode(lba: 9, raw: raw)
    #expect(decoded.decoded == raw)
    #expect(decoded.method == "全零扇区(raw)")
    #expect(decoded.fields.first?.color == "zero")
}

@Test func lba4SerialAndDecode() throws {
    let serial: UInt64 = 1_625_940_067
    var raw = [UInt8](repeating: 0, count: 512)
    let header = Array("$$$\(serial)$$$".utf8)
    raw.replaceSubrange(0..<header.count, with: header)
    let key = EDPLBA4.k0(serial: serial)
    var decodedRegion = [UInt8](repeating: 0, count: 0x1e8)
    decodedRegion[0] = 0x12
    decodedRegion[1] = 0x34
    let encodedRegion = EDPRollingXOR.apply(decodedRegion, k0: key)
    raw.replaceSubrange(0x18..<(0x18 + 0x1e8), with: encodedRegion)
    guard let decoded = EDPLBA4.decode(raw) else {
        Issue.record("LBA4 decode unexpectedly failed")
        return
    }
    #expect(decoded.serial == serial)
    #expect(decoded.bytes[0x18] == 0x12)
    #expect(decoded.bytes[0x19] == 0x34)
}
