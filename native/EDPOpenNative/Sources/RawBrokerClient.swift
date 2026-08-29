import Foundation

struct RawBrokerProbeReply: Decodable, Sendable {
    let ok: Bool
    let message: String
    let diskNumber: UInt32?
    let euid: UInt32?
    let helperIdentifier: String?
}

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

    deinit {
        connection.invalidate()
    }

    func ping(_ completion: @escaping (Result<RawBrokerProbeReply, Error>) -> Void) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            completion(.failure(error))
        }) as? EDPRawBrokerProtocol else {
            completion(.failure(NSError(domain: "EDPOpen.RawBroker", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建 broker XPC proxy"])))
            return
        }
        proxy.ping { text in
            completion(Self.decode(text))
        }
    }

    func probeReadAccess(diskNumber: UInt32, completion: @escaping (Result<RawBrokerProbeReply, Error>) -> Void) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            completion(.failure(error))
        }) as? EDPRawBrokerProtocol else {
            completion(.failure(NSError(domain: "EDPOpen.RawBroker", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建 broker XPC proxy"])))
            return
        }
        proxy.probeReadAccess(diskNumber) { text in
            completion(Self.decode(text))
        }
    }

    private static func decode(_ text: String) -> Result<RawBrokerProbeReply, Error> {
        do {
            let data = Data(text.utf8)
            return .success(try JSONDecoder().decode(RawBrokerProbeReply.self, from: data))
        } catch {
            return .failure(error)
        }
    }
}
