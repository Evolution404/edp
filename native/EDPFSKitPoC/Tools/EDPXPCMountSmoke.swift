import Foundation

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

private func waitReply(
    _ semaphore: DispatchSemaphore,
    state: ReplyState,
    label: String,
    timeout: DispatchTime = .now() + 90
) throws {
    guard semaphore.wait(timeout: timeout) == .success else {
        throw NSError(
            domain: "com.edp.usbvault.smoke",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "\(label) timed out"]
        )
    }
    guard let captured = state.get() else {
        throw NSError(
            domain: "com.edp.usbvault.smoke",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "\(label) returned no reply"]
        )
    }
    if let error = captured {
        throw NSError(
            domain: "com.edp.usbvault.smoke",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: error]
        )
    }
}

@main
private enum EDPXPCMountSmoke {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: EDPXPCMountSmoke <device-id>\n", stderr)
            exit(64)
        }
        let deviceID = CommandLine.arguments[1]

        do {
            let connection = NSXPCConnection(
                machServiceName: edpVaultMachServiceName,
                options: .privileged
            )
            connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
            connection.resume()
            defer { connection.invalidate() }

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                fputs("XPC_ERROR=\(error.localizedDescription)\n", stderr)
            }) as? EDPVaultXPCProtocol else {
                throw NSError(
                    domain: "com.edp.usbvault.smoke",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "XPC proxy unavailable"]
                )
            }

            let accessState = ReplyState()
            let accessSemaphore = DispatchSemaphore(value: 0)
            proxy.refreshRawAccess { error in
                accessState.set(error)
                accessSemaphore.signal()
            }
            try waitReply(
                accessSemaphore,
                state: accessState,
                label: "refreshRawAccess",
                timeout: .now() + 30
            )

            let mountState = ReplyState()
            let mountSemaphore = DispatchSemaphore(value: 0)
            proxy.mountPartition(
                deviceID: deviceID,
                partitionType: EDPPartitionKind.exchange.rawValue
            ) { error in
                mountState.set(error)
                mountSemaphore.signal()
            }
            try waitReply(mountSemaphore, state: mountState, label: "mountPartition")

            print("RESULT=FDA_RAW_ACCESS_MOUNT_OK")
        } catch {
            fputs("ERROR=\(error.localizedDescription)\n", stderr)
            print("RESULT=FDA_RAW_ACCESS_MOUNT_FAILED")
            exit(1)
        }
    }
}
