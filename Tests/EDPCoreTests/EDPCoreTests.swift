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
