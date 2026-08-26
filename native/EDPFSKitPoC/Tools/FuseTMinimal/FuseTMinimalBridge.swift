import Darwin
import Foundation

private let maxFrameBytes = 16 * 1024 * 1024
private let rootNodeID: Int64 = 1
private let fileNodeID: Int64 = 2
private let fileName = "volume.raw"

private enum BridgeError: Error, CustomStringConvertible {
    case usage(String)
    case posix(String, Int32)
    case protocolError(String)

    var description: String {
        switch self {
        case .usage(let message):
            return message
        case .posix(let operation, let code):
            return "\(operation): \(String(cString: strerror(code))) (\(code))"
        case .protocolError(let message):
            return message
        }
    }
}

private struct Frame {
    var metadata: [String: Any]
    var payload: Data = Data()
}

/// Minimal byte-oriented contract between the FUSE-T RPC transport and its
/// backing store. The transport does not know whether bytes come from a plain
/// file, a real raw device, or an on-demand decrypted EDP partition.
protocol FuseTReadBacking: AnyObject {
    var size: Int64 { get }
    func pread(offset: Int64, length: Int) throws -> Data
}

final class FixedBacking: FuseTReadBacking {
    let fd: Int32
    let size: Int64

    init(path: String) throws {
        fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw BridgeError.posix("open backing", errno) }

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw BridgeError.posix("fstat backing", code)
        }
        size = Int64(st.st_size)
    }

    deinit {
        Darwin.close(fd)
    }

    func pread(offset: Int64, length: Int) throws -> Data {
        guard offset >= 0, length >= 0 else {
            throw BridgeError.protocolError("negative read offset/length")
        }
        if offset >= size || length == 0 {
            return Data()
        }

        let wanted = min(Int64(length), size - offset)
        var data = Data(count: Int(wanted))
        let count = data.withUnsafeMutableBytes { rawBuffer -> Int in
            guard let base = rawBuffer.baseAddress else { return 0 }
            return Darwin.pread(fd, base, Int(wanted), off_t(offset))
        }
        guard count >= 0 else { throw BridgeError.posix("pread backing", errno) }
        guard count == Int(wanted) else {
            throw BridgeError.protocolError(
                "short backing read offset=\(offset) wanted=\(wanted) got=\(count)"
            )
        }
        return data
    }
}

final class UnixRPCServer {
    private let socketPath: String
    private let sessionID: String
    private let authToken: String
    private let backing: any FuseTReadBacking
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var nextDirectoryHandle: Int64 = 100
    private var openDirectoryHandles = Set<Int64>()

    init(socketPath: String, sessionID: String, authToken: String, backing: any FuseTReadBacking) {
        self.socketPath = socketPath
        self.sessionID = sessionID
        self.authToken = authToken
        self.backing = backing
    }

    deinit {
        if clientFD >= 0 { Darwin.close(clientFD) }
        if listenFD >= 0 { Darwin.close(listenFD) }
        unlink(socketPath)
    }

    func listen() throws {
        unlink(socketPath)
        listenFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw BridgeError.posix("socket", errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let utf8 = Array(socketPath.utf8CString)
        guard utf8.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw BridgeError.protocolError("Unix socket path is too long: \(socketPath)")
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            for (index, byte) in utf8.enumerated() {
                bytes[index] = UInt8(bitPattern: byte)
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { throw BridgeError.posix("bind", errno) }
        guard chmod(socketPath, 0o600) == 0 else { throw BridgeError.posix("chmod socket", errno) }
        guard Darwin.listen(listenFD, 4) == 0 else { throw BridgeError.posix("listen", errno) }
    }

    func serveOneConnection() throws {
        clientFD = Darwin.accept(listenFD, nil, nil)
        guard clientFD >= 0 else { throw BridgeError.posix("accept", errno) }
        print("FUSE-T RPC connected")

        while true {
            let frame: Frame
            do {
                frame = try readFrame(fd: clientFD)
            } catch is EOFError {
                return
            }

            let response = try handle(frame)
            try writeFrame(fd: clientFD, frame: response)
        }
    }

    private func handle(_ frame: Frame) throws -> Frame {
        guard let requestID = integer(frame.metadata["request_id"]),
              let method = frame.metadata["method"] as? String else {
            throw BridgeError.protocolError("request missing request_id/method")
        }

        switch method {
        case "handshake":
            guard frame.metadata["auth_token"] as? String == authToken else {
                return errorFrame(requestID: requestID, code: EACCES, message: "authentication failed")
            }
            return okFrame(requestID: requestID, fields: ["session_id": sessionID])

        case "ping":
            return okFrame(requestID: requestID)

        case "get_root_attributes":
            return okFrame(requestID: requestID, fields: ["root_attrs": rootAttributes()])

        case "statfs":
            let blockSize: Int64 = 4096
            let blocks = max(Int64(1), (backing.size + blockSize - 1) / blockSize)
            return okFrame(
                requestID: requestID,
                fields: [
                    "block_size": blockSize,
                    "io_size": 1024 * 1024,
                    "blocks": blocks,
                    "free_blocks": 0,
                    "files": 2,
                    "free_files": 0,
                ]
            )

        case "lookup":
            if integer(frame.metadata["parent_id"]) == rootNodeID,
               frame.metadata["name"] as? String == fileName {
                return okFrame(requestID: requestID, fields: ["lookup_item": fileAttributes()])
            }
            return errorFrame(requestID: requestID, code: ENOENT, message: "No such file or directory")

        case "get_attributes":
            switch integer(frame.metadata["node_id"]) {
            case rootNodeID:
                return okFrame(requestID: requestID, fields: ["item_attrs": rootAttributes()])
            case fileNodeID:
                return okFrame(requestID: requestID, fields: ["item_attrs": fileAttributes()])
            default:
                return errorFrame(requestID: requestID, code: ENOENT, message: "No such file or directory")
            }

        case "open":
            guard integer(frame.metadata["node_id"]) == fileNodeID else {
                return errorFrame(requestID: requestID, code: ENOENT, message: "No such file or directory")
            }
            let modes = integer(frame.metadata["open_modes"]) ?? 0
            guard modes == 0 || modes == 1 else {
                return errorFrame(requestID: requestID, code: EROFS, message: "Read-only filesystem")
            }
            return okFrame(requestID: requestID, fields: ["handle_id": 200])

        case "read":
            guard integer(frame.metadata["node_id"]) == fileNodeID else {
                return errorFrame(requestID: requestID, code: ENOENT, message: "No such file or directory")
            }
            guard let offset = integer(frame.metadata["offset"]),
                  let length64 = integer(frame.metadata["length"]),
                  offset >= 0,
                  length64 >= 0,
                  length64 <= Int64(maxFrameBytes) else {
                return errorFrame(requestID: requestID, code: EINVAL, message: "Invalid read range")
            }
            let data = try backing.pread(offset: offset, length: Int(length64))
            return Frame(metadata: ["request_id": requestID, "ok": true], payload: data)

        case "close":
            return okFrame(requestID: requestID)

        case "open_directory":
            guard integer(frame.metadata["node_id"]) == rootNodeID else {
                return errorFrame(requestID: requestID, code: ENOTDIR, message: "Not a directory")
            }
            let handle = nextDirectoryHandle
            nextDirectoryHandle += 1
            openDirectoryHandles.insert(handle)
            return okFrame(requestID: requestID, fields: ["handle_id": handle])

        case "enumerate_directory":
            guard let handle = integer(frame.metadata["handle_id"]),
                  openDirectoryHandles.contains(handle) else {
                return errorFrame(requestID: requestID, code: EBADF, message: "Bad directory handle")
            }
            let cookie = integer(frame.metadata["cookie"]) ?? 0
            let verifier = integer(frame.metadata["verifier"]) ?? 1
            if cookie == 0 {
                var item = fileAttributes()
                item["cookie"] = 1
                return okFrame(
                    requestID: requestID,
                    fields: ["dir_items": [item], "next_cookie": 1, "verifier": verifier]
                )
            }
            return okFrame(
                requestID: requestID,
                fields: ["dir_items": [], "next_cookie": cookie, "verifier": verifier]
            )

        case "close_directory":
            if let handle = integer(frame.metadata["handle_id"]) {
                openDirectoryHandles.remove(handle)
            }
            return okFrame(requestID: requestID)

        case "list_xattrs":
            return okFrame(requestID: requestID, fields: ["xattr_names": []])

        case "get_xattr":
            return errorFrame(requestID: requestID, code: ENOATTR, message: "Attribute not found")

        case "synchronize":
            return okFrame(requestID: requestID)

        case "write", "set_attributes", "set_xattr", "remove_xattr", "create_file",
             "create_directory", "remove_file", "remove_directory", "rename", "create_symlink":
            return errorFrame(requestID: requestID, code: EROFS, message: "Read-only filesystem")

        default:
            return errorFrame(requestID: requestID, code: EOPNOTSUPP, message: "Unsupported RPC method \(method)")
        }
    }

    private func rootAttributes() -> [String: Any] {
        attributes(nodeID: rootNodeID, parentID: rootNodeID, name: "/", type: "directory", mode: 0o555, size: 0, links: 2)
    }

    private func fileAttributes() -> [String: Any] {
        attributes(nodeID: fileNodeID, parentID: rootNodeID, name: fileName, type: "file", mode: 0o444, size: backing.size, links: 1)
    }

    private func attributes(
        nodeID: Int64,
        parentID: Int64,
        name: String,
        type: String,
        mode: Int,
        size: Int64,
        links: Int
    ) -> [String: Any] {
        [
            "node_id": nodeID,
            "parent_id": parentID,
            "name": name,
            "type": type,
            "mode": mode,
            "uid": getuid(),
            "gid": getgid(),
            "link_count": links,
            "size": size,
            "alloc_size": size,
            "modify_time_sec": 0,
            "modify_time_nsec": 0,
            "change_time_sec": 0,
            "change_time_nsec": 0,
            "access_time_sec": 0,
            "access_time_nsec": 0,
            "birth_time_sec": 0,
            "birth_time_nsec": 0,
        ]
    }
}

private func integer(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber { return number.int64Value }
    if let value = value as? Int64 { return value }
    if let value = value as? Int { return Int64(value) }
    return nil
}

private func okFrame(requestID: Int64, fields: [String: Any] = [:]) -> Frame {
    var metadata: [String: Any] = ["request_id": requestID, "ok": true]
    for (key, value) in fields { metadata[key] = value }
    return Frame(metadata: metadata)
}

private func errorFrame(requestID: Int64, code: Int32, message: String) -> Frame {
    Frame(
        metadata: [
            "request_id": requestID,
            "ok": false,
            "errno": Int(code),
            "error": message,
        ]
    )
}

private func readFrame(fd: Int32) throws -> Frame {
    let header = try readExact(fd: fd, count: 8)
    let metadataLength = Int(readBEUInt32(header, offset: 0))
    let payloadLength = Int(readBEUInt32(header, offset: 4))
    guard metadataLength <= maxFrameBytes,
          payloadLength <= maxFrameBytes,
          metadataLength + payloadLength <= maxFrameBytes else {
        throw BridgeError.protocolError("frame exceeds 16 MiB contract")
    }
    let metadataData = try readExact(fd: fd, count: metadataLength)
    let payload = try readExact(fd: fd, count: payloadLength)
    let object = try JSONSerialization.jsonObject(with: metadataData)
    guard let metadata = object as? [String: Any] else {
        throw BridgeError.protocolError("frame metadata is not a JSON object")
    }
    return Frame(metadata: metadata, payload: payload)
}

private func writeFrame(fd: Int32, frame: Frame) throws {
    let metadata = try JSONSerialization.data(withJSONObject: frame.metadata, options: [.sortedKeys])
    guard metadata.count <= maxFrameBytes,
          frame.payload.count <= maxFrameBytes,
          metadata.count + frame.payload.count <= maxFrameBytes else {
        throw BridgeError.protocolError("response frame exceeds 16 MiB contract")
    }

    var output = Data()
    appendBEUInt32(UInt32(metadata.count), to: &output)
    appendBEUInt32(UInt32(frame.payload.count), to: &output)
    output.append(metadata)
    output.append(frame.payload)
    try writeAll(fd: fd, data: output)
}

private func readExact(fd: Int32, count: Int) throws -> Data {
    if count == 0 { return Data() }
    var data = Data(count: count)
    var offset = 0
    while offset < count {
        let result = data.withUnsafeMutableBytes { rawBuffer -> Int in
            guard let base = rawBuffer.baseAddress else { return 0 }
            return Darwin.read(fd, base.advanced(by: offset), count - offset)
        }
        if result == 0 { throw EOFError() }
        if result < 0 {
            if errno == EINTR { continue }
            throw BridgeError.posix("read RPC frame", errno)
        }
        offset += result
    }
    return data
}

private struct EOFError: Error {}

private func writeAll(fd: Int32, data: Data) throws {
    var offset = 0
    while offset < data.count {
        let written = data.withUnsafeBytes { rawBuffer -> Int in
            guard let base = rawBuffer.baseAddress else { return 0 }
            return Darwin.write(fd, base.advanced(by: offset), data.count - offset)
        }
        if written < 0 {
            if errno == EINTR { continue }
            throw BridgeError.posix("write RPC frame", errno)
        }
        guard written > 0 else { throw BridgeError.protocolError("zero-progress RPC write") }
        offset += written
    }
}

private func readBEUInt32(_ data: Data, offset: Int) -> UInt32 {
    data.withUnsafeBytes { rawBuffer in
        let base = rawBuffer.baseAddress!.advanced(by: offset)
        return UInt32(base.loadUnaligned(as: UInt32.self).bigEndian)
    }
}

private func appendBEUInt32(_ value: UInt32, to data: inout Data) {
    var be = value.bigEndian
    withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
}

private struct Arguments {
    let backing: String
    let mountpoint: String
    let volumeName: String
}

private func parseArguments() throws -> Arguments {
    var backing: String?
    var mountpoint: String?
    var volumeName = "EDP FUSE-T Bridge"
    var index = 1
    let args = CommandLine.arguments
    while index < args.count {
        switch args[index] {
        case "--backing":
            index += 1
            guard index < args.count else { throw BridgeError.usage("--backing requires a path") }
            backing = args[index]
        case "--mountpoint":
            index += 1
            guard index < args.count else { throw BridgeError.usage("--mountpoint requires a path") }
            mountpoint = args[index]
        case "--volume-name":
            index += 1
            guard index < args.count else { throw BridgeError.usage("--volume-name requires a value") }
            volumeName = args[index]
        default:
            throw BridgeError.usage("unknown argument: \(args[index])")
        }
        index += 1
    }
    guard let backing, let mountpoint else {
        throw BridgeError.usage("usage: FuseTMinimalBridge --backing <file> --mountpoint <dir> [--volume-name <name>]")
    }
    return Arguments(backing: backing, mountpoint: mountpoint, volumeName: volumeName)
}

func runFuseTBridge(backing: any FuseTReadBacking, mountpoint: String, volumeName: String) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(atPath: mountpoint, withIntermediateDirectories: true)

    let groupSocketDirectory = fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.org.fuset.fskit-srv/s", isDirectory: true)
    try fileManager.createDirectory(at: groupSocketDirectory, withIntermediateDirectories: true)
    chmod(groupSocketDirectory.path, 0o700)

    let sessionID = "edp-fuset-\(UUID().uuidString.lowercased())"
    let authToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let socketPath = groupSocketDirectory.appendingPathComponent("\(sessionID.prefix(20)).sock").path
    let sessionDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(sessionID, isDirectory: true)
    try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: false)
    let sessionURL = sessionDirectory.appendingPathComponent("session.json")

    let descriptor: [String: Any] = [
        "session_id": sessionID,
        "socket_path": socketPath,
        "auth_token": authToken,
        "namedattr": false,
        "readonly": true,
        "volume_name": volumeName,
    ]
    let descriptorData = try JSONSerialization.data(withJSONObject: descriptor, options: [.sortedKeys])
    try descriptorData.write(to: sessionURL, options: .atomic)
    chmod(sessionURL.path, 0o600)

    let server = UnixRPCServer(socketPath: socketPath, sessionID: sessionID, authToken: authToken, backing: backing)
    try server.listen()

    defer {
        try? fileManager.removeItem(at: sessionDirectory)
        unlink(socketPath)
    }

    let mount = Process()
    mount.executableURL = URL(fileURLWithPath: "/sbin/mount")
    mount.arguments = ["-o", "nobrowse,rdonly", "-t", "fuset", sessionURL.path, mountpoint]
    mount.standardOutput = FileHandle.standardOutput
    mount.standardError = FileHandle.standardError
    mount.terminationHandler = { process in
        fputs("mount process exited status=\(process.terminationStatus)\n", stderr)
    }
    try mount.run()

    print("SESSION_ID=\(sessionID)")
    print("SESSION_JSON=\(sessionURL.path)")
    print("SOCKET=\(socketPath)")
    print("MOUNTPOINT=\(mountpoint)")
    print("BACKING_SIZE=\(backing.size)")
    fflush(stdout)

    try server.serveOneConnection()
}

#if !FUSET_BRIDGE_LIBRARY
do {
    let args = try parseArguments()
    let backing = try FixedBacking(path: args.backing)
    try runFuseTBridge(backing: backing, mountpoint: args.mountpoint, volumeName: args.volumeName)
} catch {
    fputs("FuseTMinimalBridge: \(error)\n", stderr)
    exit(1)
}
#endif
