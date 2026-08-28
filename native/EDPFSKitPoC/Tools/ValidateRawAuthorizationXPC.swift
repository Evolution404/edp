import Foundation

private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var message: String?
    private var data: Data?

    func setMessage(_ value: String?) {
        lock.lock(); message = value; lock.unlock()
    }

    func setData(_ value: Data) {
        lock.lock(); data = value; lock.unlock()
    }

    func snapshot() -> (String?, Data?) {
        lock.lock(); defer { lock.unlock() }
        return (message, data)
    }
}

@main
struct ValidateRawAuthorizationXPC {
    static func main() throws {
        let connection = NSXPCConnection(
            machServiceName: edpVaultMachServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
        let semaphore = DispatchSemaphore(value: 0)
        let box = ReplyBox()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            box.setMessage(error.localizedDescription)
            semaphore.signal()
        }) as? EDPVaultXPCProtocol else {
            throw NSError(domain: "EDPValidateRawAccess", code: 1)
        }
        connection.resume()

        proxy.refreshRawAccess { errorMessage in
            box.setMessage(errorMessage)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            connection.invalidate()
            throw NSError(domain: "EDPValidateRawAccess", code: 2)
        }
        if let message = box.snapshot().0 {
            connection.invalidate()
            throw NSError(
                domain: "EDPValidateRawAccess",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let snapshotSemaphore = DispatchSemaphore(value: 0)
        proxy.snapshot { data in
            box.setData(data)
            snapshotSemaphore.signal()
        }
        guard snapshotSemaphore.wait(timeout: .now() + 10) == .success,
              let data = box.snapshot().1 else {
            connection.invalidate()
            throw NSError(domain: "EDPValidateRawAccess", code: 4)
        }
        connection.invalidate()
        let snapshot = try JSONDecoder().decode(EDPXPCSnapshot.self, from: data)
        print("RAW_ACCESS_DEVICE_COUNT=\(snapshot.devices.count)")
        for device in snapshot.devices {
            print("RAW_ACCESS_DEVICE=\(device.bsdName)|ready=\(device.privilegedAccessReady)|authorized=\(device.authorized)|mounted=\(device.mounted)")
        }
        guard snapshot.devices.filter(\.connected).allSatisfy(\.privilegedAccessReady) else {
            throw NSError(domain: "EDPValidateRawAccess", code: 5)
        }
        print("RESULT=FDA_RAW_ACCESS_XPC_OK")
    }
}
