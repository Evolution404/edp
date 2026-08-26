import Darwin
import Foundation

private enum RPCTestError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private struct ClientFrame {
    var metadata: [String: Any]
    var payload = Data()
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw RPCTestError.failed(message) }
}

private final class ServerBox: @unchecked Sendable {
    let server: UnixRPCServer
    let finished = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var error: String?

    init(server: UnixRPCServer) { self.server = server }

    func run() {
        do {
            try server.serveOneConnection()
        } catch {
            lock.lock()
            self.error = String(describing: error)
            lock.unlock()
        }
        finished.signal()
    }
}

private func appendBEUInt32(_ value: UInt32, to data: inout Data) {
    var be = value.bigEndian
    withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
}

private func readBEUInt32(_ data: Data, offset: Int) -> UInt32 {
    data.withUnsafeBytes { rawBuffer in
        UInt32(rawBuffer.baseAddress!.advanced(by: offset).loadUnaligned(as: UInt32.self).bigEndian)
    }
}

private func writeAll(fd: Int32, data: Data) throws {
    var offset = 0
    while offset < data.count {
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return Darwin.write(fd, base.advanced(by: offset), data.count - offset)
        }
        if written < 0 {
            if errno == EINTR { continue }
            throw RPCTestError.failed("client write failed errno=\(errno)")
        }
        guard written > 0 else { throw RPCTestError.failed("zero-progress client write") }
        offset += written
    }
}

private func readExact(fd: Int32, count: Int) throws -> Data {
    if count == 0 { return Data() }
    var data = Data(count: count)
    var offset = 0
    while offset < count {
        let got = data.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return Darwin.read(fd, base.advanced(by: offset), count - offset)
        }
        if got < 0 {
            if errno == EINTR { continue }
            throw RPCTestError.failed("client read failed errno=\(errno)")
        }
        guard got > 0 else { throw RPCTestError.failed("unexpected EOF") }
        offset += got
    }
    return data
}

private func sendFrame(fd: Int32, metadata: [String: Any], payload: Data = Data()) throws -> ClientFrame {
    let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
    var frame = Data()
    appendBEUInt32(UInt32(metadataData.count), to: &frame)
    appendBEUInt32(UInt32(payload.count), to: &frame)
    frame.append(metadataData)
    frame.append(payload)
    try writeAll(fd: fd, data: frame)

    let header = try readExact(fd: fd, count: 8)
    let metadataLength = Int(readBEUInt32(header, offset: 0))
    let payloadLength = Int(readBEUInt32(header, offset: 4))
    let responseMetadata = try readExact(fd: fd, count: metadataLength)
    let responsePayload = try readExact(fd: fd, count: payloadLength)
    guard let object = try JSONSerialization.jsonObject(with: responseMetadata) as? [String: Any] else {
        throw RPCTestError.failed("response metadata is not an object")
    }
    return ClientFrame(metadata: object, payload: responsePayload)
}

private func number(_ value: Any?) -> Int64? {
    (value as? NSNumber)?.int64Value
}

private func expectOK(_ frame: ClientFrame, requestID: Int64) throws {
    try require(number(frame.metadata["request_id"]) == requestID, "response request id mismatch")
    try require((frame.metadata["ok"] as? Bool) == true, "expected ok response: \(frame.metadata)")
}

private func expectError(_ frame: ClientFrame, requestID: Int64, code: Int32) throws {
    try require(number(frame.metadata["request_id"]) == requestID, "error response request id mismatch")
    try require((frame.metadata["ok"] as? Bool) == false, "expected error response")
    try require(number(frame.metadata["errno"]) == Int64(code), "expected errno \(code), got \(String(describing: frame.metadata["errno"]))")
}

private func connectUnix(path: String) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw RPCTestError.failed("socket failed errno=\(errno)") }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let utf8 = Array(path.utf8CString)
    guard utf8.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        Darwin.close(fd)
        throw RPCTestError.failed("socket path too long")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        for (index, byte) in utf8.enumerated() { raw[index] = UInt8(bitPattern: byte) }
    }
    let result = withUnsafePointer(to: &address) { pointer -> Int32 in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        let code = errno
        Darwin.close(fd)
        throw RPCTestError.failed("connect failed errno=\(code)")
    }
    return fd
}

private func deterministicBytes(count: Int, seed: UInt64) -> Data {
    var state = seed
    return Data((0..<count).map { index in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return UInt8(truncatingIfNeeded: (state >> 24) ^ UInt64(index))
    })
}

private func exerciseWritable(path: String, socketPath: String) throws {
    let backing = try FixedReadWriteBacking(path: path)
    let server = UnixRPCServer(
        socketPath: socketPath,
        sessionID: "rw-session",
        authToken: "rw-token",
        backing: backing,
        readOnly: false
    )
    try server.listen()
    let box = ServerBox(server: server)
    DispatchQueue.global(qos: .userInitiated).async { box.run() }
    let fd = try connectUnix(path: socketPath)

    var requestID: Int64 = 1
    var response = try sendFrame(fd: fd, metadata: [
        "request_id": requestID, "method": "handshake", "auth_token": "rw-token",
    ])
    try expectOK(response, requestID: requestID)
    try require(response.metadata["session_id"] as? String == "rw-session", "handshake session mismatch")

    requestID += 1
    response = try sendFrame(fd: fd, metadata: [
        "request_id": requestID, "method": "open", "node_id": 2, "open_modes": 2,
    ])
    try expectOK(response, requestID: requestID)

    let replacement = deterministicBytes(count: 4097, seed: 0x4040_2026)
    requestID += 1
    response = try sendFrame(fd: fd, metadata: [
        "request_id": requestID, "method": "write", "node_id": 2,
        "offset": 4095, "length": replacement.count,
    ], payload: replacement)
    try expectOK(response, requestID: requestID)
    try require(number(response.metadata["write_size"]) == Int64(replacement.count), "write_size contract missing")

    requestID += 1
    response = try sendFrame(fd: fd, metadata: [
        "request_id": requestID, "method": "read", "node_id": 2,
        "offset": 4095, "length": replacement.count,
    ])
    try expectOK(response, requestID: requestID)
    try require(response.payload == replacement, "RPC read-after-write mismatch")

    requestID += 1
    response = try sendFrame(fd: fd, metadata: [
        "request_id": requestID, "method": "write", "node_id": 2,
        "offset": 65_535, "length": 2,
    ], payload: Data([0xaa, 0xbb]))
    try expectError(response, requestID: requestID, code: ENOSPC)

    requestID += 1
    response = try sendFrame(fd: fd, metadata: [
        "request_id": requestID, "method": "write", "node_id": 2,
        "offset": 0, "length": 2,
    ], payload: Data([0xaa]))
    try expectError(response, requestID: requestID, code: EINVAL)

    for method in ["create_file", "create_directory", "remove_file", "remove_directory", "rename", "truncate", "set_xattr", "remove_xattr"] {
        requestID += 1
        response = try sendFrame(fd: fd, metadata: [
            "request_id": requestID, "method": method, "node_id": 2,
        ])
        try expectError(response, requestID: requestID, code: EPERM)
    }

    requestID += 1
    response = try sendFrame(fd: fd, metadata: [
        "request_id": requestID, "method": "set_attributes", "node_id": 2, "size": 65_536,
    ])
    try expectOK(response, requestID: requestID)

    requestID += 1
    response = try sendFrame(fd: fd, metadata: [
        "request_id": requestID, "method": "set_attributes", "node_id": 2, "size": 65_535,
    ])
    try expectError(response, requestID: requestID, code: EINVAL)

    requestID += 1
    response = try sendFrame(fd: fd, metadata: ["request_id": requestID, "method": "synchronize"])
    try expectOK(response, requestID: requestID)

    requestID += 1
    response = try sendFrame(fd: fd, metadata: [
        "request_id": requestID, "method": "close", "node_id": 2, "handle_id": 200,
    ])
    try expectOK(response, requestID: requestID)

    Darwin.close(fd)
    try require(box.finished.wait(timeout: .now() + 3) == .success, "RW server did not exit after client close")
    box.lock.lock(); let serverError = box.error; box.lock.unlock()
    try require(serverError == nil, "RW server failed: \(serverError ?? "")")

    let persisted = try Data(contentsOf: URL(fileURLWithPath: path))
    try require(persisted.subdata(in: 4095..<(4095 + replacement.count)) == replacement, "RPC synchronized bytes not persisted")
    print("RESULT=RPC_RW_WRITE_READ_SYNC_PERSISTENCE_PASS")
    print("RESULT=RPC_RW_FIXED_NAMESPACE_MUTATIONS_FAIL_CLOSED")
    print("RESULT=RPC_RW_RANGE_VALIDATION_PASS")
}

private func exerciseReadOnly(path: String, socketPath: String) throws {
    let backing = try FixedBacking(path: path)
    let server = UnixRPCServer(
        socketPath: socketPath,
        sessionID: "ro-session",
        authToken: "ro-token",
        backing: backing,
        readOnly: true
    )
    try server.listen()
    let box = ServerBox(server: server)
    DispatchQueue.global(qos: .userInitiated).async { box.run() }
    let fd = try connectUnix(path: socketPath)

    var requestID: Int64 = 100
    var response = try sendFrame(fd: fd, metadata: [
        "request_id": requestID, "method": "handshake", "auth_token": "ro-token",
    ])
    try expectOK(response, requestID: requestID)

    requestID += 1
    response = try sendFrame(fd: fd, metadata: [
        "request_id": requestID, "method": "open", "node_id": 2, "open_modes": 2,
    ])
    try expectError(response, requestID: requestID, code: EROFS)

    requestID += 1
    response = try sendFrame(fd: fd, metadata: [
        "request_id": requestID, "method": "write", "node_id": 2,
        "offset": 0, "length": 1,
    ], payload: Data([0xff]))
    try expectError(response, requestID: requestID, code: EROFS)

    for method in ["create_file", "remove_file", "rename", "truncate", "set_xattr", "remove_xattr"] {
        requestID += 1
        response = try sendFrame(fd: fd, metadata: [
            "request_id": requestID, "method": method, "node_id": 2,
        ])
        try expectError(response, requestID: requestID, code: EROFS)
    }

    Darwin.close(fd)
    try require(box.finished.wait(timeout: .now() + 3) == .success, "RO server did not exit after client close")
    box.lock.lock(); let serverError = box.error; box.lock.unlock()
    try require(serverError == nil, "RO server failed: \(serverError ?? "")")
    print("RESULT=RPC_RO_WRITE_AND_MUTATION_EROFS_PASS")
}

@main
private enum ValidateFuseTRPCReadWriteMain {
    static func main() {
        do {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("edp-rpc-rw-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }

            let backingURL = directory.appendingPathComponent("backing.raw")
            let initial = deterministicBytes(count: 65_536, seed: 0xED40_4040)
            try initial.write(to: backingURL)

            try exerciseWritable(path: backingURL.path, socketPath: directory.appendingPathComponent("rw.sock").path)
            try exerciseReadOnly(path: backingURL.path, socketPath: directory.appendingPathComponent("ro.sock").path)
            print("RESULT=FUSET_THIN_RPC_READWRITE_CONTRACT_PASS")
        } catch {
            FileHandle.standardError.write(Data("ValidateFuseTRPCReadWrite: \(error)\n".utf8))
            exit(1)
        }
    }
}
