import CryptoKit
import Darwin
import Foundation
import Security

@_silgen_name("edp_authopen_readonly_fd")
private func edpAuthOpenReadOnlyFD(
    _ path: UnsafePointer<CChar>,
    _ authorizationBytes: UnsafeRawPointer,
    _ authorizationLength: Int
) -> Int32

private enum SparseBackupError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let value): return value
        }
    }
}

private func fail(_ message: String) -> SparseBackupError { .message(message) }

private struct RawSparseExtent: Codable, Equatable {
    let offset: UInt64
    let length: UInt64
    let sha256: String
}

private struct RawSparseManifest: Codable {
    let format: String
    let formatVersion: Int
    let createdAt: String
    let sourcePath: String
    let deviceID: String?
    let vidPID: String?
    let imageFileName: String
    let logicalSize: UInt64
    let sectorSize: UInt64
    let scanChunkSize: UInt64
    let sparseBlockSize: UInt64
    let extentCount: Int
    let nonZeroBytes: UInt64
    let allocatedBytes: UInt64
    let logicalSHA256: String
    let extents: [RawSparseExtent]
}

private struct Options {
    let values: [String: String]

    init(_ arguments: ArraySlice<String>) throws {
        var parsed: [String: String] = [:]
        var iterator = arguments.makeIterator()
        while let option = iterator.next() {
            guard option.hasPrefix("--"), let value = iterator.next() else {
                throw fail("expected --name value arguments; found \(option)")
            }
            guard parsed[option] == nil else { throw fail("duplicate option: \(option)") }
            parsed[option] = value
        }
        values = parsed
    }

    func required(_ name: String) throws -> String {
        guard let value = values[name], !value.isEmpty else { throw fail("missing \(name)") }
        return value
    }

    func uint64(_ name: String, default fallback: UInt64? = nil) throws -> UInt64 {
        guard let text = values[name] else {
            if let fallback { return fallback }
            throw fail("missing \(name)")
        }
        guard let value = UInt64(text), value > 0 else { throw fail("invalid \(name): \(text)") }
        return value
    }
}

private func checkedInt(_ value: UInt64, label: String) throws -> Int {
    guard value <= UInt64(Int.max) else { throw fail("\(label) is too large") }
    return Int(value)
}

private func checkedOffset(_ value: UInt64) throws -> off_t {
    guard value <= UInt64(Int64.max) else { throw fail("offset exceeds off_t") }
    return off_t(value)
}

private func sha256Hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
}

private func exactPread(fd: Int32, buffer: UnsafeMutableRawPointer, count: Int, offset: UInt64) throws {
    var done = 0
    while done < count {
        let result = pread(fd, buffer.advanced(by: done), count - done, try checkedOffset(offset + UInt64(done)))
        if result < 0 {
            if errno == EINTR { continue }
            throw fail("pread failed at \(offset + UInt64(done)): errno=\(errno) \(String(cString: strerror(errno)))")
        }
        guard result > 0 else { throw fail("unexpected EOF at \(offset + UInt64(done))") }
        done += result
    }
}

private func exactWrite(fd: Int32, buffer: UnsafeRawPointer, count: Int, offset: UInt64) throws {
    let target = try checkedOffset(offset)
    guard lseek(fd, target, SEEK_SET) == target else {
        throw fail("lseek failed at \(offset): errno=\(errno)")
    }
    var done = 0
    while done < count {
        let result = write(fd, buffer.advanced(by: done), count - done)
        if result < 0 {
            if errno == EINTR { continue }
            throw fail("backup image write failed at \(offset + UInt64(done)): errno=\(errno)")
        }
        guard result > 0 else { throw fail("backup image write made no progress") }
        done += result
    }
}

private func allZero(_ bytes: UnsafeRawBufferPointer) -> Bool {
    let words = bytes.bindMemory(to: UInt64.self)
    for word in words where word != 0 { return false }
    let covered = words.count * MemoryLayout<UInt64>.size
    if covered < bytes.count {
        let tail = UnsafeRawBufferPointer(rebasing: bytes[covered..<bytes.count])
        for byte in tail where byte != 0 { return false }
    }
    return true
}

private func ensureRegularOutput(_ path: String) throws {
    guard !path.hasPrefix("/dev/") else {
        throw fail("refusing raw/block-device output: \(path)")
    }
    guard !FileManager.default.fileExists(atPath: path) else {
        throw fail("output already exists: \(path)")
    }
}

private func openExclusive(_ path: String) throws -> Int32 {
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
    guard fd >= 0 else { throw fail("cannot create \(path): errno=\(errno)") }
    return fd
}

private func fileSize(_ fd: Int32) throws -> UInt64 {
    var status = stat()
    guard fstat(fd, &status) == 0, status.st_size >= 0 else {
        throw fail("fstat failed: errno=\(errno)")
    }
    return UInt64(status.st_size)
}

private func allocatedBytes(_ fd: Int32) throws -> UInt64 {
    var status = stat()
    guard fstat(fd, &status) == 0, status.st_blocks >= 0 else {
        throw fail("fstat allocation query failed: errno=\(errno)")
    }
    return UInt64(status.st_blocks) * 512
}

private func synchronize(_ fd: Int32) throws {
    if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
        throw fail("fsync failed: errno=\(errno)")
    }
}

private func atomicManifestWrite(_ manifest: RawSparseManifest, to path: String) throws {
    guard !path.hasPrefix("/dev/") else { throw fail("refusing manifest under /dev") }
    guard !FileManager.default.fileExists(atPath: path) else { throw fail("manifest already exists: \(path)") }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(manifest) + Data("\n".utf8)
    let temporary = path + ".partial.\(getpid())"
    try data.write(to: URL(fileURLWithPath: temporary), options: .withoutOverwriting)
    guard chmod(temporary, 0o600) == 0 else {
        try? FileManager.default.removeItem(atPath: temporary)
        throw fail("chmod failed for temporary manifest: errno=\(errno)")
    }
    guard rename(temporary, path) == 0 else {
        let saved = errno
        try? FileManager.default.removeItem(atPath: temporary)
        throw fail("manifest rename failed: errno=\(saved)")
    }
}

private func makeRawAuthorization() throws -> (AuthorizationRef, Data) {
    var reference: AuthorizationRef?
    let createStatus = AuthorizationCreate(nil, nil, [], &reference)
    guard createStatus == errAuthorizationSuccess, let reference else {
        throw fail("AuthorizationCreate failed: \(createStatus)")
    }
    let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
    let rightsStatus = "system.privilege.admin".withCString { name in
        var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
        return withUnsafeMutablePointer(to: &item) { pointer in
            var rights = AuthorizationRights(count: 1, items: pointer)
            return AuthorizationCopyRights(reference, &rights, nil, flags, nil)
        }
    }
    guard rightsStatus == errAuthorizationSuccess else {
        AuthorizationFree(reference, [])
        throw fail("AuthorizationCopyRights failed: \(rightsStatus)")
    }
    var external = AuthorizationExternalForm()
    let externalStatus = AuthorizationMakeExternalForm(reference, &external)
    guard externalStatus == errAuthorizationSuccess else {
        AuthorizationFree(reference, [])
        throw fail("AuthorizationMakeExternalForm failed: \(externalStatus)")
    }
    return (reference, withUnsafeBytes(of: external) { Data($0) })
}

private func authorizedReadOnlyFD(path: String) throws -> Int32 {
    guard path.hasPrefix("/dev/rdisk") else { throw fail("authorized source must be /dev/rdiskN") }
    let (reference, external) = try makeRawAuthorization()
    defer { AuthorizationFree(reference, []) }
    let fd = path.withCString { pathPointer in
        external.withUnsafeBytes { bytes in
            edpAuthOpenReadOnlyFD(pathPointer, bytes.baseAddress!, bytes.count)
        }
    }
    guard fd >= 0 else {
        throw fail("authopen O_RDONLY failed for \(path): errno=\(errno) \(String(cString: strerror(errno)))")
    }
    return fd
}

private func backup(sourceFD: Int32, sourcePath: String, options: Options) throws {
    let output = try options.required("--output")
    let manifestPath = try options.required("--manifest")
    let logicalSize = try options.uint64("--size")
    let sectorSize = try options.uint64("--sector-size", default: 512)
    let chunkSize = try options.uint64("--chunk-size", default: 16 * 1024 * 1024)
    let sparseBlockSize = try options.uint64("--sparse-block-size", default: 64 * 1024)
    guard sectorSize.isMultiple(of: 512), sparseBlockSize.isMultiple(of: sectorSize),
          chunkSize.isMultiple(of: sparseBlockSize) else {
        throw fail("sector, sparse-block, and chunk sizes must be aligned")
    }
    guard logicalSize.isMultiple(of: sectorSize) else { throw fail("logical size is not sector-aligned") }
    try ensureRegularOutput(output)
    guard !FileManager.default.fileExists(atPath: manifestPath) else {
        throw fail("manifest already exists: \(manifestPath)")
    }

    let partial = output + ".partial.\(getpid())"
    let outputFD = try openExclusive(partial)
    var keepPartial = false
    defer {
        close(outputFD)
        if !keepPartial { try? FileManager.default.removeItem(atPath: partial) }
    }
    guard ftruncate(outputFD, try checkedOffset(logicalSize)) == 0 else {
        throw fail("cannot set sparse image logical size: errno=\(errno)")
    }

    let bufferSize = try checkedInt(min(chunkSize, logicalSize), label: "chunk size")
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    var logicalHasher = SHA256()
    var extents: [RawSparseExtent] = []
    var activeOffset: UInt64?
    var activeLength: UInt64 = 0
    var activeHasher = SHA256()
    var nonZeroBytes: UInt64 = 0
    var processed: UInt64 = 0
    var nextProgress: UInt64 = 1024 * 1024 * 1024

    func finishExtent() {
        guard let offset = activeOffset else { return }
        extents.append(RawSparseExtent(
            offset: offset,
            length: activeLength,
            sha256: sha256Hex(activeHasher.finalize())
        ))
        activeOffset = nil
        activeLength = 0
        activeHasher = SHA256()
    }

    while processed < logicalSize {
        let currentCount = try checkedInt(min(chunkSize, logicalSize - processed), label: "read length")
        try buffer.withUnsafeMutableBytes { raw in
            try exactPread(fd: sourceFD, buffer: raw.baseAddress!, count: currentCount, offset: processed)
        }
        try buffer.withUnsafeBytes { raw in
            let current = UnsafeRawBufferPointer(rebasing: raw[..<currentCount])
            logicalHasher.update(bufferPointer: current)
            var cursor = 0
            while cursor < currentCount {
                let blockLength = min(try checkedInt(sparseBlockSize, label: "sparse block size"), currentCount - cursor)
                let block = UnsafeRawBufferPointer(rebasing: current[cursor..<(cursor + blockLength)])
                if allZero(block) {
                    finishExtent()
                    cursor += blockLength
                    continue
                }

                let runStart = cursor
                var runEnd = cursor + blockLength
                cursor = runEnd
                while cursor < currentCount {
                    let nextLength = min(try checkedInt(sparseBlockSize, label: "sparse block size"), currentCount - cursor)
                    let next = UnsafeRawBufferPointer(rebasing: current[cursor..<(cursor + nextLength)])
                    if allZero(next) { break }
                    runEnd = cursor + nextLength
                    cursor = runEnd
                }
                let run = UnsafeRawBufferPointer(rebasing: current[runStart..<runEnd])
                let absolute = processed + UInt64(runStart)
                if activeOffset == nil {
                    activeOffset = absolute
                } else if activeOffset! + activeLength != absolute {
                    finishExtent()
                    activeOffset = absolute
                }
                try exactWrite(fd: outputFD, buffer: run.baseAddress!, count: run.count, offset: absolute)
                activeHasher.update(bufferPointer: run)
                activeLength += UInt64(run.count)
                nonZeroBytes += UInt64(run.count)
            }
        }
        processed += UInt64(currentCount)
        if processed >= nextProgress || processed == logicalSize {
            let percent = Double(processed) * 100.0 / Double(logicalSize)
            FileHandle.standardError.write(Data(String(
                format: "EDP_BACKUP_PROGRESS=%llu/%llu %.2f%% nonzero=%llu\n",
                processed, logicalSize, percent, nonZeroBytes
            ).utf8))
            nextProgress += 1024 * 1024 * 1024
        }
    }
    finishExtent()
    try synchronize(outputFD)
    let allocation = try allocatedBytes(outputFD)
    guard rename(partial, output) == 0 else { throw fail("image rename failed: errno=\(errno)") }
    keepPartial = true

    let manifest = RawSparseManifest(
        format: "com.edp.usbvault.raw-sparse-backup",
        formatVersion: 1,
        createdAt: ISO8601DateFormatter().string(from: Date()),
        sourcePath: sourcePath,
        deviceID: options.values["--device-id"],
        vidPID: options.values["--vid-pid"],
        imageFileName: URL(fileURLWithPath: output).lastPathComponent,
        logicalSize: logicalSize,
        sectorSize: sectorSize,
        scanChunkSize: chunkSize,
        sparseBlockSize: sparseBlockSize,
        extentCount: extents.count,
        nonZeroBytes: nonZeroBytes,
        allocatedBytes: allocation,
        logicalSHA256: sha256Hex(logicalHasher.finalize()),
        extents: extents
    )
    do {
        try atomicManifestWrite(manifest, to: manifestPath)
    } catch {
        try? FileManager.default.removeItem(atPath: output)
        throw error
    }
    print("BACKUP_IMAGE=\(output)")
    print("BACKUP_MANIFEST=\(manifestPath)")
    print("BACKUP_LOGICAL_SIZE=\(logicalSize)")
    print("BACKUP_NONZERO_BYTES=\(nonZeroBytes)")
    print("BACKUP_ALLOCATED_BYTES=\(allocation)")
    print("BACKUP_EXTENT_COUNT=\(extents.count)")
    print("BACKUP_LOGICAL_SHA256=\(manifest.logicalSHA256)")
    print("RESULT=EDP_RAW_SPARSE_BACKUP_OK")
}

private func loadManifest(_ path: String) throws -> RawSparseManifest {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let manifest = try JSONDecoder().decode(RawSparseManifest.self, from: data)
    guard manifest.format == "com.edp.usbvault.raw-sparse-backup", manifest.formatVersion == 1 else {
        throw fail("unsupported sparse manifest format")
    }
    guard manifest.extentCount == manifest.extents.count else { throw fail("manifest extent count mismatch") }
    var expectedMinimum: UInt64 = 0
    var nonZeroBytes: UInt64 = 0
    for extent in manifest.extents {
        guard extent.length > 0, extent.offset >= expectedMinimum,
              extent.offset <= manifest.logicalSize,
              extent.length <= manifest.logicalSize - extent.offset,
              extent.sha256.count == 64 else {
            throw fail("invalid or overlapping manifest extent at \(extent.offset)")
        }
        expectedMinimum = extent.offset + extent.length
        nonZeroBytes += extent.length
    }
    guard nonZeroBytes == manifest.nonZeroBytes else { throw fail("manifest non-zero byte total mismatch") }
    return manifest
}

private func hashLogicalImage(fd: Int32, size: UInt64, chunkSize: UInt64) throws -> String {
    var hasher = SHA256()
    let bufferSize = try checkedInt(min(chunkSize, size), label: "verify chunk size")
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    var offset: UInt64 = 0
    while offset < size {
        let count = try checkedInt(min(chunkSize, size - offset), label: "verify length")
        try buffer.withUnsafeMutableBytes { raw in
            try exactPread(fd: fd, buffer: raw.baseAddress!, count: count, offset: offset)
        }
        buffer.withUnsafeBytes { raw in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[..<count]))
        }
        offset += UInt64(count)
    }
    return sha256Hex(hasher.finalize())
}

@discardableResult
private func verify(image: String, manifestPath: String) throws -> RawSparseManifest {
    let manifest = try loadManifest(manifestPath)
    let fd = open(image, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { throw fail("cannot open image \(image): errno=\(errno)") }
    defer { close(fd) }
    guard try fileSize(fd) == manifest.logicalSize else { throw fail("image logical size mismatch") }

    var extentBuffer = [UInt8](repeating: 0, count: 16 * 1024 * 1024)
    for extent in manifest.extents {
        var hasher = SHA256()
        var done: UInt64 = 0
        while done < extent.length {
            let count = try checkedInt(min(UInt64(extentBuffer.count), extent.length - done), label: "extent verify length")
            try extentBuffer.withUnsafeMutableBytes { raw in
                try exactPread(fd: fd, buffer: raw.baseAddress!, count: count, offset: extent.offset + done)
            }
            extentBuffer.withUnsafeBytes { raw in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[..<count]))
            }
            done += UInt64(count)
        }
        guard sha256Hex(hasher.finalize()) == extent.sha256 else {
            throw fail("extent SHA256 mismatch at \(extent.offset)")
        }
    }
    let logicalHash = try hashLogicalImage(fd: fd, size: manifest.logicalSize, chunkSize: manifest.scanChunkSize)
    guard logicalHash == manifest.logicalSHA256 else { throw fail("logical image SHA256 mismatch") }
    print("VERIFIED_IMAGE=\(image)")
    print("VERIFIED_LOGICAL_SIZE=\(manifest.logicalSize)")
    print("VERIFIED_EXTENT_COUNT=\(manifest.extentCount)")
    print("VERIFIED_LOGICAL_SHA256=\(logicalHash)")
    print("RESULT=EDP_RAW_SPARSE_VERIFY_OK")
    return manifest
}

private func restore(image: String, manifestPath: String, output: String) throws {
    let manifest = try verify(image: image, manifestPath: manifestPath)
    try ensureRegularOutput(output)
    let sourceFD = open(image, O_RDONLY | O_CLOEXEC)
    guard sourceFD >= 0 else { throw fail("cannot reopen source image: errno=\(errno)") }
    defer { close(sourceFD) }

    let partial = output + ".partial.\(getpid())"
    let outputFD = try openExclusive(partial)
    var keepPartial = false
    defer {
        close(outputFD)
        if !keepPartial { try? FileManager.default.removeItem(atPath: partial) }
    }
    guard ftruncate(outputFD, try checkedOffset(manifest.logicalSize)) == 0 else {
        throw fail("cannot set restored logical size: errno=\(errno)")
    }
    var buffer = [UInt8](repeating: 0, count: 16 * 1024 * 1024)
    for extent in manifest.extents {
        var done: UInt64 = 0
        while done < extent.length {
            let count = try checkedInt(min(UInt64(buffer.count), extent.length - done), label: "restore length")
            try buffer.withUnsafeMutableBytes { raw in
                try exactPread(fd: sourceFD, buffer: raw.baseAddress!, count: count, offset: extent.offset + done)
                try exactWrite(fd: outputFD, buffer: raw.baseAddress!, count: count, offset: extent.offset + done)
            }
            done += UInt64(count)
        }
    }
    try synchronize(outputFD)
    let allocation = try allocatedBytes(outputFD)
    guard rename(partial, output) == 0 else { throw fail("restored image rename failed: errno=\(errno)") }
    keepPartial = true
    _ = try verify(image: output, manifestPath: manifestPath)
    print("RESTORED_IMAGE=\(output)")
    print("RESTORED_ALLOCATED_BYTES=\(allocation)")
    print("RESULT=EDP_RAW_SPARSE_RESTORE_OK")
}

private func usage() {
    print("""
    Usage:
      edp-raw-sparse backup --source <file> --size <bytes> --output <image> --manifest <json> [options]
      edp-raw-sparse backup-authorized --source /dev/rdiskN --size <bytes> --output <image> --manifest <json> [options]
      edp-raw-sparse verify --image <image> --manifest <json>
      edp-raw-sparse restore --image <image> --manifest <json> --output <restored-image>

    Options: --sector-size 512 --chunk-size 16777216 --sparse-block-size 65536
             --device-id <id> --vid-pid <vid:pid>

    restore always targets a new regular file and refuses every /dev/* path.
    backup-authorized obtains an O_RDONLY fd through authopen; it has no raw write mode.
    """)
}

@main
private enum EDPRawSparseMain {
    static func main() {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count >= 2 else { usage(); exit(64) }
            let command = arguments[1]
            let options = try Options(arguments.dropFirst(2))
            switch command {
            case "backup", "backup-authorized":
                let source = try options.required("--source")
                let fd: Int32
                if command == "backup-authorized" {
                    fd = try authorizedReadOnlyFD(path: source)
                } else {
                    fd = open(source, O_RDONLY | O_CLOEXEC)
                    guard fd >= 0 else { throw fail("cannot open source \(source): errno=\(errno)") }
                }
                defer { close(fd) }
                try backup(sourceFD: fd, sourcePath: source, options: options)
            case "verify":
                _ = try verify(
                    image: options.required("--image"),
                    manifestPath: options.required("--manifest")
                )
            case "restore":
                try restore(
                    image: options.required("--image"),
                    manifestPath: options.required("--manifest"),
                    output: options.required("--output")
                )
            case "help", "--help", "-h":
                usage()
            default:
                usage()
                exit(64)
            }
        } catch {
            FileHandle.standardError.write(Data("ERROR=\(error)\n".utf8))
            exit(1)
        }
    }
}
