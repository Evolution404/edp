import Foundation
import Security

private final class ReplyState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?? = nil

    func set(_ error: String?) {
        lock.lock()
        value = error
        lock.unlock()
    }

    func get() -> String?? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func makeRawAuthorization(rawPath: String) throws -> (AuthorizationRef, Data) {
    var created: AuthorizationRef?
    let createStatus = AuthorizationCreate(nil, nil, [], &created)
    guard createStatus == errAuthorizationSuccess, let authorization = created else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(createStatus))
    }

    do {
        let rightName = "sys.openfile.readwrite.\(rawPath)"
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
        let rightStatus = rightName.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                return AuthorizationCopyRights(authorization, &rights, nil, flags, nil)
            }
        }
        guard rightStatus == errAuthorizationSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(rightStatus))
        }

        var external = AuthorizationExternalForm()
        let externalStatus = AuthorizationMakeExternalForm(authorization, &external)
        guard externalStatus == errAuthorizationSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(externalStatus))
        }
        return (authorization, withUnsafeBytes(of: external) { Data($0) })
    } catch {
        AuthorizationFree(authorization, [])
        throw error
    }
}

private func waitReply(_ semaphore: DispatchSemaphore, state: ReplyState, label: String) throws {
    guard semaphore.wait(timeout: .now() + 90) == .success else {
        throw NSError(domain: "com.edp.usbvault.smoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(label) timed out"])
    }
    guard let captured = state.get() else {
        throw NSError(domain: "com.edp.usbvault.smoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(label) returned no reply"])
    }
    if let error = captured {
        throw NSError(domain: "com.edp.usbvault.smoke", code: 3, userInfo: [NSLocalizedDescriptionKey: error])
    }
}

@main
private enum EDPXPCMountSmoke {
    static func main() {
        guard CommandLine.arguments.count == 3 else {
            fputs("usage: EDPXPCMountSmoke <diskN> <device-id>\n", stderr)
            exit(64)
        }
        let bsdName = CommandLine.arguments[1]
        let deviceID = CommandLine.arguments[2]
        let rawPath = "/dev/r\(bsdName)"

        do {
            let authorization = try makeRawAuthorization(rawPath: rawPath)
            defer { AuthorizationFree(authorization.0, []) }

            let connection = NSXPCConnection(machServiceName: edpVaultMachServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
            connection.resume()
            defer { connection.invalidate() }

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                fputs("XPC_ERROR=\(error.localizedDescription)\n", stderr)
            }) as? EDPVaultXPCProtocol else {
                throw NSError(domain: "com.edp.usbvault.smoke", code: 4, userInfo: [NSLocalizedDescriptionKey: "XPC proxy unavailable"])
            }

            let grantState = ReplyState()
            let grantSemaphore = DispatchSemaphore(value: 0)
            proxy.grantRawAccess(authorization: authorization.1) { error in
                grantState.set(error)
                grantSemaphore.signal()
            }
            try waitReply(grantSemaphore, state: grantState, label: "grantRawAccess")

            let mountState = ReplyState()
            let mountSemaphore = DispatchSemaphore(value: 0)
            proxy.retryMount(deviceID: deviceID) { error in
                mountState.set(error)
                mountSemaphore.signal()
            }
            try waitReply(mountSemaphore, state: mountState, label: "retryMount")

            print("RESULT=EXACT_RAW_AUTH_MOUNT_OK")
        } catch {
            fputs("ERROR=\(error.localizedDescription)\n", stderr)
            print("RESULT=EXACT_RAW_AUTH_MOUNT_FAILED")
            exit(1)
        }
    }
}
