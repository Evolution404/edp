import Foundation

struct RawBrokerProbeReply: Decodable, Sendable {
    let ok: Bool
    let message: String
    let diskNumber: UInt32?
    let euid: UInt32?
    let helperIdentifier: String?
}

struct RawBrokerDisk: Decodable, Hashable, Sendable, Identifiable {
    let diskNumber: UInt32
    let sizeBytes: UInt64
    let vendor: String
    let model: String

    var id: UInt32 { diskNumber }
    var diskName: String { "disk\(diskNumber)" }
    var capacityText: String { String(format: "%.2f GB", Double(sizeBytes) / 1_000_000_000.0) }
    var displayName: String {
        let name = [vendor, model].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? "USB Disk" : name
    }
}

struct RawBrokerDiskListReply: Decodable, Sendable {
    let ok: Bool
    let message: String
    let disks: [RawBrokerDisk]
    let euid: UInt32?
    let helperIdentifier: String?
}

enum RawBrokerClientError: LocalizedError, Sendable {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

@MainActor
final class RawBrokerClient {
    private let connection: NSXPCConnection

    init() {
        let connection = NSXPCConnection(
            machServiceName: RawBrokerConstants.machServiceName,
            options: .privileged
        )
        connection.setCodeSigningRequirement(RawBrokerConstants.brokerCodeSigningRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: EDPRawBrokerProtocol.self)
        connection.resume()
        self.connection = connection
    }

    func ping(_ completion: @escaping @MainActor (Result<RawBrokerProbeReply, RawBrokerClientError>) -> Void) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            let message = error.localizedDescription
            Task { @MainActor in completion(.failure(.message(message))) }
        }) as? EDPRawBrokerProtocol else {
            completion(.failure(.message("无法创建 broker XPC proxy")))
            return
        }
        proxy.ping { text in
            let result = Self.decode(text)
            Task { @MainActor in completion(result) }
        }
    }

    func listUSBDisks(_ completion: @escaping @MainActor (Result<RawBrokerDiskListReply, RawBrokerClientError>) -> Void) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            let message = error.localizedDescription
            Task { @MainActor in completion(.failure(.message(message))) }
        }) as? EDPRawBrokerProtocol else {
            completion(.failure(.message("无法创建 broker XPC proxy")))
            return
        }
        proxy.listUSBDisks { text in
            let result: Result<RawBrokerDiskListReply, RawBrokerClientError> = Self.decodeJSON(text)
            Task { @MainActor in completion(result) }
        }
    }

    func probeReadAccess(diskNumber: UInt32, completion: @escaping @MainActor (Result<RawBrokerProbeReply, RawBrokerClientError>) -> Void) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            let message = error.localizedDescription
            Task { @MainActor in completion(.failure(.message(message))) }
        }) as? EDPRawBrokerProtocol else {
            completion(.failure(.message("无法创建 broker XPC proxy")))
            return
        }
        proxy.probeReadAccess(diskNumber) { text in
            let result = Self.decode(text)
            Task { @MainActor in completion(result) }
        }
    }

    private nonisolated static func decode(_ text: String) -> Result<RawBrokerProbeReply, RawBrokerClientError> {
        decodeJSON(text)
    }

    private nonisolated static func decodeJSON<T: Decodable>(_ text: String) -> Result<T, RawBrokerClientError> {
        do {
            let data = Data(text.utf8)
            return .success(try JSONDecoder().decode(T.self, from: data))
        } catch {
            return .failure(.message(error.localizedDescription))
        }
    }
}
