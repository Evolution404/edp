import Foundation

private func parseHexKey(_ text: String) throws -> [UInt8] {
    guard text.count == 32 else {
        throw EDPNativeCoreError.invalidInput("SM4 test key must be exactly 32 hex characters")
    }
    var output = [UInt8]()
    output.reserveCapacity(16)
    var index = text.startIndex
    for _ in 0..<16 {
        let next = text.index(index, offsetBy: 2)
        guard let byte = UInt8(text[index..<next], radix: 16) else {
            throw EDPNativeCoreError.invalidInput("SM4 test key contains non-hex characters")
        }
        output.append(byte)
        index = next
    }
    return output
}

@main
private enum PrepareEncryptedDiskImageMain {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("PrepareEncryptedDiskImage error: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        guard CommandLine.arguments.count == 4 else {
            FileHandle.standardError.write(Data("usage: PrepareEncryptedDiskImage <plain.img> <cipher.img> <32-hex-key>\n".utf8))
            exit(64)
        }

        let plainURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let cipherURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let key = try parseHexKey(CommandLine.arguments[3])
        let cipher = try EDPSM4(key: key)

        let input = try FileHandle(forReadingFrom: plainURL)
        defer { try? input.close() }

        FileManager.default.createFile(atPath: cipherURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: cipherURL)
        defer { try? output.close() }

        let chunkSize = 1024 * 1024
        var total: UInt64 = 0
        while true {
            guard let data = try input.read(upToCount: chunkSize), !data.isEmpty else { break }
            guard data.count % 16 == 0 else {
                throw EDPNativeCoreError.invalidInput("plaintext disk image size must be SM4-block aligned")
            }
            let encrypted = try cipher.encryptAligned([UInt8](data))
            try output.write(contentsOf: Data(encrypted))
            total += UInt64(data.count)
        }
        try output.synchronize()

        print("ENCRYPTED_DISK_BYTES=\(total)")
        print("RESULT=EDP_SM4_DISK_IMAGE_ENCRYPTED")
    }
}
