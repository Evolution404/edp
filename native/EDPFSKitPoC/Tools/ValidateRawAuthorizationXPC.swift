import Foundation
import Security

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

private func makeRawAuthorization() throws -> (AuthorizationRef, Data) {
    var created: AuthorizationRef?
    let createStatus = AuthorizationCreate(nil, nil, [], &created)
    guard createStatus == errAuthorizationSuccess, let created else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(createStatus))
    }

    let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
    let status = "system.privilege.admin".withCString { rightName in
        var item = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
        return withUnsafeMutablePointer(to: &item) { itemPointer in
            var rights = AuthorizationRights(count: 1, items: itemPointer)
            return AuthorizationCopyRights(created, &rights, nil, flags, nil)
        }
    }
    guard status == errAuthorizationSuccess else {
        AuthorizationFree(created, [])
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }

    var external = AuthorizationExternalForm()
    let externalStatus = AuthorizationMakeExternalForm(created, &external)
    guard externalStatus == errAuthorizationSuccess else {
        AuthorizationFree(created, [])
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(externalStatus))
    }
    return (created, withUnsafeBytes(of: external) { Data($0) })
}

@main
struct ValidateRawAuthorizationXPC {
    static func main() throws {
        let (authorizationRef, externalForm) = try makeRawAuthorization()
        defer { AuthorizationFree(authorizationRef, []) }

        let connection = NSXPCConnection(machServiceName: edpVaultMachServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
        let semaphore = DispatchSemaphore(value: 0)
        let box = ReplyBox()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            box.setMessage(error.localizedDescription)
            semaphore.signal()
        }) as? EDPVaultXPCProtocol else {
            throw NSError(domain: "EDPValidateRawAuthorization", code: 1)
        }
        connection.resume()
        proxy.grantRawAccess(authorization: externalForm) { errorMessage in
            box.setMessage(errorMessage)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            connection.invalidate()
            throw NSError(domain: "EDPValidateRawAuthorization", code: 2)
        }
        if let message = box.snapshot().0 {
            connection.invalidate()
            throw NSError(domain: "EDPValidateRawAuthorization", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
        }

        let snapshotSemaphore = DispatchSemaphore(value: 0)
        proxy.snapshot { data in
            box.setData(data)
            snapshotSemaphore.signal()
        }
        guard snapshotSemaphore.wait(timeout: .now() + 10) == .success,
              let data = box.snapshot().1 else {
            connection.invalidate()
            throw NSError(domain: "EDPValidateRawAuthorization", code: 4)
        }
        connection.invalidate()
        let snapshot = try JSONDecoder().decode(EDPXPCSnapshot.self, from: data)
        print("RAW_AUTH_DEVICE_COUNT=\(snapshot.devices.count)")
        for device in snapshot.devices {
            print("RAW_AUTH_DEVICE=\(device.bsdName)|ready=\(device.rawAccessReady)|authorized=\(device.authorized)|mounted=\(device.mounted)")
        }
        guard snapshot.devices.contains(where: { $0.rawAccessReady }) else {
            throw NSError(domain: "EDPValidateRawAuthorization", code: 5)
        }
        print("RESULT=RAW_AUTHORIZATION_XPC_OK")
    }
}
