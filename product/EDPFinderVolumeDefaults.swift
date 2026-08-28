import Darwin
import Foundation

enum EDPFinderVolumeDefaults {
    private static let rawDeflateBase64 = "7VlLcBRFGO6vk5AZMpAGEkkwA1sJlIBJ2AQxkUfV5qU8E2QTsgmBZXdnJAOTmbAzuyGGWCmrvAhoedLyVXryQclBxddFqxRFj4pWYVkesLR8HLRKLyoHe2Z6Q1jAkwfU+ap2v/n77+f093dv9xJC0JnTWgipIYRIJGBWQa4LSXyuARVcxj/g5Ymd5k9vp8dNw3FJiBAhQoQIEeJmBMT+XhG+ihAhQlxnfYgIjgmeCRjCTwWXzinDBEcExwTPBAyRjwouFSwJZoIjgmOCZwIWixbE4QOiZYgTCpjgiOBYOI8hQtwIwdm9OT3hjKfNuef3aPQL0JLSsnnl5XJ5Rfn++Kg9EXdTbs7pTGX3eVa/bZvpwnMqvdfQJ5Ksqsu23JRh6Vm/gKHpPMvIoGFp9kSnnbM0Z98chyxLcpLVTk21tEYbI/xrujEy1dIS5UbbndHpaVmqbli3aU/yiDlm2SfIVSsAWVA0lJPBUEwn3xUMpSReGMqXYiiSPL9CWaAOJoaGlZEkW5znfe4bdw3bcvbqWYdzklU6vH/bMra1O6t7/sGMbebGLCfJFmVSZiZnply9wzTjxv264+XOZG3T3G07hlfNUMLVj7me7xpXYtixs26XX1mSsZyj79F5XUZe7+Y1OgmDN+kVrCpeheUzC5euWLm6qbVtc6xn2657L1SyRYuXKNXKMH+JlmvcZ+jZoZST0S3NsA4NTBiaOzqYNxwjber9VmpMlxehUb5QWVO77NY6VQ0yXClQyJrIpY2jOcOdZA2S5LcRUeuVEY13bpetea1oEjsr+55Var26z/N0ZXX+rYkCa9TblX6Hj0FiqSBjsxJV+o/w2ZeZE6SsVzaoA2YqrZsy04Ji7cpGdTAfvH+Z7QgStyjVaiJjj43xITpykNahdqkHvGZ3phy3b1y3vC6dD3x3c9+wM5rK6n0TXH2iR9t5qj+lPN0r1KMZru07+dvorVfVIa+6Dk3zx7CsprZSjasDEvtU4lNkWHmDK573KhC+1FCYk4bYWvHwXiZ4CF50Qyw6e2mmklbSTXaSgyRLpsgp8gQ5TV4n58iH5HPyNfmB/Ep+BzAP5ZiPClRhGVaiERvQhnbchU70YTf2II4RjMLAYTg4hklM4TgewsM4gVN4BI/jGTyL5/A8XsareA1n8QbexXl8jE/wGS7hG3yL7/Az/sCfuEzL6FJaQ2tpPW2kTbSZttF2upFuor20jyZoih6mNh0XV3uFINtfdOU3ORtkYr2gZ64fZHX3bN22Xdn5rwmyiwv9sKqqvmVpZNXadXe0b+mYlV+g14JE5wrfV/tVMeKr3VdDkVIv+PGnLF9RCLjimB3gBfVjkhetrFzkblgp8TBhZcJcvYabO9i8wKxrapZ4SDLqm0pd63qZBx4rEWZTGzcRGMqmzTIPQVYqzOUxbhJRTXcPr+Y8k/4pfV8kl8j35Bdymet7IZagBrchylXdia3o9XUdxwAOIImDSEPDGCzYOMoVfhzTeAAzeJDr+yRX+KN4DE/iKTzNVf4CXsRLOI1XuMbfxFt4B+/jA5zDR0LtX3Gt/4ifivS7q2iefwv0m49nLdO2DolftV6K45ru5Ljey6X9P9n7SwKq8c7/PTe+/w8RIsR/+Zxf2h3v7rxyIXgNqLgIODjnYuDvLgIw5w/Dm+4iINz/w/0/3P/JXw=="
    private static let expectedSize = 8_196

    static func templateData() throws -> Data {
        guard let compressed = Data(base64Encoded: rawDeflateBase64) else {
            throw NSError(
                domain: "com.edp.usbvault.finder-defaults",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Finder default template base64 is invalid"]
            )
        }
        let decoded = try (compressed as NSData).decompressed(using: .zlib) as Data
        guard decoded.count == expectedSize,
              decoded.count >= 8,
              String(decoding: decoded[4..<8], as: UTF8.self) == "Bud1" else {
            throw NSError(
                domain: "com.edp.usbvault.finder-defaults",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Finder default template failed integrity check"]
            )
        }
        return decoded
    }

    static func seedIfMissing(at mountPoint: String, owner: (uid_t, gid_t)) throws -> Bool {
        let storePath = mountPoint + "/.DS_Store"
        if FileManager.default.fileExists(atPath: storePath) { return false }
        let decoded = try templateData()

        let fd = Darwin.open(storePath, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        if fd < 0 {
            if errno == EEXIST { return false }
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "cannot create Finder defaults at \(storePath)"]
            )
        }
        var completed = false
        defer {
            Darwin.close(fd)
            if !completed { _ = Darwin.unlink(storePath) }
        }
        let writeError: Int32? = decoded.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return EINVAL }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                if written == 0 { return EIO }
                offset += written
            }
            return nil
        }
        if let writeError {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(writeError))
        }
        if Darwin.fsync(fd) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        _ = Darwin.fchown(fd, owner.0, owner.1)
        completed = true
        return true
    }
}
