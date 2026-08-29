import Darwin
import Foundation

enum EDPFinderVolumeDefaults {
    private static let rawDeflateBase64 = "7dnBitNAHAbwSbdqaiuM4h70FFg8KEWyexdit4gnLbbU1VVi0g7uwOxMyUza3S2FnnbxrL6IBx9FPPksTpwpWwo+gO73g8k3mczQ/NNCSkIICTrleJeQkFw22rKbC0KiJnFqPuu2BfY4AQAAgH/elouwut8/sPf9W7gkAFdOUO/2ux33J//vk2xLfC5dBn685rO+Npeu9ROfS5eBH6/5rPsMfVKfkc/E59KlP8mgtjp5n6FP/8lB5DPBFwwAAAAAAAAAAFeWe7f/OJ/pSS5Ubvd+5RPBtYnjn0Ftq37t+o2wcbPRsK2Z0rv7SpqMS1b0j9Ssz8csz4qUbvcKNuVs1sskG3LNcy64OT2s5vQyc2TnHK7Nf/+nbzJT6o4/MsjyoV3v+koJO+vday7HatZRpRzrRpjS+/P57l7cjuxm0Y7msdWOqu1iEd6Lnw8+yLPzz1++urJWTwlJa6Peb65eoaerer+v6v1xWW+zldLbo0yMSpEZ9lSIPj9j+oCPlKx6b7UqzL4S5bE8MOzEVGMppaVmr5hdwKesa5fplN6prsrLieFK6iErtM1wJ4ndqQxkdsx2kkdur0GDcPvh3pNnb6Q6WZxfbNSx+W7mk6tj2i+kUPIjcU9jqxFthDmdsBe2RPy8AQAAAAAAAAAAAAAAAAD+f78B"
    private static let expectedSize = 16_388
    private static let boundsPlaceholder = "{{120, 120}, {0000, 0000}}"
    private static let fallbackWindowSize = CGSize(width: 920, height: 587)

    static func preferredWindowSize(for uid: uid_t) -> CGSize? {
        guard let account = getpwuid(uid), let homeCString = account.pointee.pw_dir else {
            return nil
        }
        let home = String(cString: homeCString)
        let preferencesURL = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Preferences/com.apple.finder.plist")
        guard let data = try? Data(contentsOf: preferencesURL),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let preferences = root as? [String: Any],
              let computerView = preferences["ComputerViewSettings"] as? [String: Any],
              let windowState = computerView["WindowState"] as? [String: Any],
              let bounds = windowState["WindowBounds"] as? String else {
            return nil
        }
        let rect = NSRectFromString(bounds)
        guard rect.size.width.isFinite,
              rect.size.height.isFinite,
              rect.size.width >= 400,
              rect.size.height >= 300,
              rect.size.width <= 9_999,
              rect.size.height <= 9_999 else {
            return nil
        }
        return rect.size
    }

    static func templateData(windowSize: CGSize) throws -> Data {
        guard let compressed = Data(base64Encoded: rawDeflateBase64) else {
            throw NSError(
                domain: "com.edp.drive.finder-defaults",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Finder default template base64 is invalid"]
            )
        }
        var decoded = try (compressed as NSData).decompressed(using: .zlib) as Data
        guard decoded.count == expectedSize,
              decoded.count >= 8,
              String(decoding: decoded[4..<8], as: UTF8.self) == "Bud1" else {
            throw NSError(
                domain: "com.edp.drive.finder-defaults",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Finder default template failed integrity check"]
            )
        }

        let width = min(max(Int(windowSize.width.rounded()), 400), 9_999)
        let height = min(max(Int(windowSize.height.rounded()), 300), 9_999)
        let replacement = String(format: "{{120, 120}, {%04d, %04d}}", width, height)
        let placeholder = Data(boundsPlaceholder.utf8)
        guard placeholder.count == replacement.utf8.count,
              let range = decoded.range(of: placeholder) else {
            throw NSError(
                domain: "com.edp.drive.finder-defaults",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Finder default window bounds placeholder is missing"]
            )
        }
        decoded.replaceSubrange(range, with: replacement.utf8)
        return decoded
    }

    static func templateData(for owner: (uid_t, gid_t)) throws -> Data {
        try templateData(windowSize: preferredWindowSize(for: owner.0) ?? fallbackWindowSize)
    }

    static func seedIfMissing(at mountPoint: String, owner: (uid_t, gid_t)) throws -> Bool {
        let storePath = mountPoint + "/.DS_Store"
        if FileManager.default.fileExists(atPath: storePath) { return false }
        let decoded = try templateData(for: owner)

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
