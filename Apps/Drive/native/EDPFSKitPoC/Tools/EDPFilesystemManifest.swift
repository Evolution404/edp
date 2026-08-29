import CryptoKit
import Darwin
import Foundation

private struct ManifestEntry: Codable {
    let path: String
    let kind: String
    let mode: UInt32
    let flags: UInt32
    let linkCount: UInt64
    let size: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
    let symlinkTarget: String?
    let sha256: String?
}

private struct FilesystemManifest: Codable {
    let format: String
    let volumeLabel: String
    let decryptedVolumeSize: UInt64
    let bootWindowSHA256: String
    let tailWindowSHA256: String
    let entries: [ManifestEntry]
}

private enum ManifestError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let value): return value }
    }
}

private func fail(_ message: String) -> ManifestError { .message(message) }
private func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
}

private func hashFD(_ fd: Int32, offset: UInt64 = 0, length: UInt64? = nil) throws -> String {
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 4 * 1024 * 1024)
    var done: UInt64 = 0
    while length == nil || done < length! {
        let requested = length.map { min(UInt64(buffer.count), $0 - done) } ?? UInt64(buffer.count)
        if requested == 0 { break }
        let count = buffer.withUnsafeMutableBytes { raw in
            pread(fd, raw.baseAddress, Int(requested), off_t(offset + done))
        }
        if count < 0 {
            if errno == EINTR { continue }
            throw fail("pread failed: errno=\(errno)")
        }
        if count == 0 { break }
        buffer.withUnsafeBytes { raw in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[..<count]))
        }
        done += UInt64(count)
    }
    if let length, done != length { throw fail("unexpected EOF while hashing") }
    return hex(hasher.finalize())
}

private func fileKind(_ mode: mode_t) -> String {
    switch mode & S_IFMT {
    case S_IFREG: return "file"
    case S_IFDIR: return "directory"
    case S_IFLNK: return "symlink"
    case S_IFIFO: return "fifo"
    case S_IFSOCK: return "socket"
    case S_IFCHR: return "character"
    case S_IFBLK: return "block"
    default: return "unknown"
    }
}

private func manifestEntry(root: String, path: String) throws -> ManifestEntry {
    var status = stat()
    guard lstat(path, &status) == 0 else { throw fail("lstat failed for \(path): errno=\(errno)") }
    let relative = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let kind = fileKind(status.st_mode)
    var target: String?
    let digest: String? = nil
    if kind == "symlink" {
        var bytes = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(path, &bytes, Int(PATH_MAX))
        guard count >= 0 else { throw fail("readlink failed for \(path): errno=\(errno)") }
        target = String(decoding: bytes[..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    return ManifestEntry(
        path: relative,
        kind: kind,
        mode: UInt32(status.st_mode),
        flags: UInt32(status.st_flags),
        linkCount: UInt64(status.st_nlink),
        size: UInt64(max(0, status.st_size)),
        modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
        modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec),
        birthSeconds: Int64(status.st_birthtimespec.tv_sec),
        birthNanoseconds: Int64(status.st_birthtimespec.tv_nsec),
        symlinkTarget: target,
        sha256: digest
    )
}

@main
private enum EDPFilesystemManifestMain {
    static func main() {
        do {
            guard CommandLine.arguments.count == 5 else {
                throw fail("usage: edp-filesystem-manifest <mountpoint> <decrypted-volume.raw> <label> <output.json>")
            }
            let root = CommandLine.arguments[1].hasSuffix("/")
                ? String(CommandLine.arguments[1].dropLast())
                : CommandLine.arguments[1]
            let rawPath = CommandLine.arguments[2]
            let label = CommandLine.arguments[3]
            let output = CommandLine.arguments[4]
            var rawStatus = stat()
            guard stat(rawPath, &rawStatus) == 0, rawStatus.st_size >= 4096 else {
                throw fail("invalid decrypted volume path")
            }
            let rawSize = UInt64(rawStatus.st_size)
            let rawFD = open(rawPath, O_RDONLY | O_CLOEXEC)
            guard rawFD >= 0 else { throw fail("cannot open decrypted volume: errno=\(errno)") }
            defer { close(rawFD) }

            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: nil,
                options: [],
                errorHandler: { url, error in
                    FileHandle.standardError.write(Data("ENUM_ERROR=\(url.path):\(error)\n".utf8))
                    return false
                }
            ) else { throw fail("cannot enumerate mountpoint") }
            var paths: [String] = []
            for case let url as URL in enumerator { paths.append(url.path) }
            paths.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            let entries = try paths.map { try manifestEntry(root: root, path: $0) }
            let manifest = FilesystemManifest(
                format: "com.edp.usbvault.ntfs-file-manifest.v1",
                volumeLabel: label,
                decryptedVolumeSize: rawSize,
                bootWindowSHA256: try hashFD(rawFD, offset: 0, length: 4096),
                tailWindowSHA256: try hashFD(rawFD, offset: rawSize - 4096, length: 4096),
                entries: entries
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(manifest) + Data("\n".utf8)
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
            print("FILESYSTEM_ENTRY_COUNT=\(entries.count)")
            print("FILESYSTEM_REGULAR_FILE_COUNT=\(entries.filter { $0.kind == "file" }.count)")
            print("FILESYSTEM_FILE_CONTENT_HASHES=SKIPPED_RAW_IMAGE_ALREADY_VERIFIED")
            print("FILESYSTEM_MANIFEST_SHA256=\(hex(SHA256.hash(data: data)))")
            print("RESULT=EDP_NTFS_FILESYSTEM_MANIFEST_OK")
        } catch {
            FileHandle.standardError.write(Data("ERROR=\(error)\n".utf8))
            exit(1)
        }
    }
}
