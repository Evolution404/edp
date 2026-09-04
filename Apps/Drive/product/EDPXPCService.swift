import Foundation

private final class EDPSendableStringReply: @unchecked Sendable {
    private let callback: (String?) -> Void
    init(_ callback: @escaping (String?) -> Void) { self.callback = callback }
    func callAsFunction(_ value: String?) { callback(value) }
}

final class EDPXPCService: NSObject, NSXPCListenerDelegate, EDPVaultXPCProtocol, @unchecked Sendable {
    private let controller: EDPServiceController
    private let didRequestShutdown: @Sendable () -> Void
    private let shutdownLock = NSLock()
    private var shutdownPrepared = false
    private var shutdownSignaled = false

    init(controller: EDPServiceController, didRequestShutdown: @escaping @Sendable () -> Void) {
        self.controller = controller
        self.didRequestShutdown = didRequestShutdown
    }

    func healthCheck(withReply reply: @escaping (String) -> Void) {
        reply("com.edp.drive.service:running")
    }

    private func prepareShutdownAcknowledgement() {
        shutdownLock.lock()
        shutdownPrepared = true
        shutdownLock.unlock()
    }

    private func signalShutdownOnceAfterAcknowledgement() {
        shutdownLock.lock()
        let shouldSignal = shutdownPrepared && !shutdownSignaled
        if shouldSignal { shutdownSignaled = true }
        shutdownLock.unlock()
        if shouldSignal { didRequestShutdown() }
    }

    func requestRuntimePause(withReply reply: @escaping (String?) -> Void) {
        let replyBox = EDPSendableStringReply(reply)
        controller.pauseRuntimeAsync { errorMessage in
            replyBox(errorMessage)
        }
    }

    func requestRuntimeResume(withReply reply: @escaping (String?) -> Void) {
        let replyBox = EDPSendableStringReply(reply)
        controller.resumeRuntimeAsync { errorMessage in
            replyBox(errorMessage)
        }
    }

    func requestRuntimeRestart(withReply reply: @escaping (String?) -> Void) {
        let replyBox = EDPSendableStringReply(reply)
        controller.restartRuntimeAsync { errorMessage in
            replyBox(errorMessage)
        }
    }

    func requestGracefulShutdown(withReply reply: @escaping (String?) -> Void) {
        let replyBox = EDPSendableStringReply(reply)
        controller.shutdownGracefullyAsync { [weak self] errorMessage in
            if errorMessage == nil {
                self?.prepareShutdownAcknowledgement()
            }
            replyBox(errorMessage)
        }
    }

    func acknowledgeGracefulShutdownReply() {
        signalShutdownOnceAfterAcknowledgement()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard EDPXPCPeerValidator.isTrusted(newConnection) else {
            NSLog("Rejected untrusted EDP XPC peer pid=%d uid=%u", newConnection.processIdentifier, newConnection.effectiveUserIdentifier)
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func snapshot(withReply reply: @escaping (Data) -> Void) {
        reply(controller.snapshotData())
    }

    func refreshRawAccess(withReply reply: @escaping (String?) -> Void) {
        let replyBox = EDPSendableStringReply(reply)
        controller.refreshRawAccessAsync { errorMessage in
            replyBox(errorMessage)
        }
    }

    func retryTransientAutomaticMounts(withReply reply: @escaping (String?) -> Void) {
        do {
            try controller.retryTransientAutomaticMounts()
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func saveCredential(
        deviceID: String,
        partitionType: UInt32,
        password: Data,
        withReply reply: @escaping (String?) -> Void
    ) {
        let replyBox = EDPSendableStringReply(reply)
        controller.saveCredentialAsync(
            deviceID: deviceID,
            partitionType: partitionType,
            passwordData: password
        ) { errorMessage in
            replyBox(errorMessage)
        }
    }

    func deleteCredential(
        deviceID: String,
        partitionType: UInt32,
        withReply reply: @escaping (String?) -> Void
    ) {
        let replyBox = EDPSendableStringReply(reply)
        controller.deleteCredentialAsync(
            deviceID: deviceID,
            partitionType: partitionType
        ) { errorMessage in
            replyBox(errorMessage)
        }
    }

    func deleteDeviceRecord(
        deviceID: String,
        withReply reply: @escaping (String?) -> Void
    ) {
        do {
            try controller.deleteDeviceRecord(deviceID: deviceID)
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func setPartitionAutoMount(
        deviceID: String,
        partitionType: UInt32,
        enabled: Bool,
        withReply reply: @escaping (String?) -> Void
    ) {
        do {
            try controller.setPartitionAutoMount(
                deviceID: deviceID,
                partitionType: partitionType,
                enabled: enabled
            )
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func setDefaultPartitionAutoMount(
        partitionType: UInt32,
        enabled: Bool,
        withReply reply: @escaping (String?) -> Void
    ) {
        do {
            try controller.setDefaultPartitionAutoMount(
                partitionType: partitionType,
                enabled: enabled
            )
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func setDefaultPartitionAutoProbePassword(
        partitionType: UInt32,
        enabled: Bool,
        withReply reply: @escaping (String?) -> Void
    ) {
        do {
            try controller.setDefaultPartitionAutoProbePassword(
                partitionType: partitionType,
                enabled: enabled
            )
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func setDefaultProbePassword(
        partitionType: UInt32,
        password: Data,
        withReply reply: @escaping (String?) -> Void
    ) {
        do {
            try controller.setDefaultProbePassword(
                partitionType: partitionType,
                passwordData: password
            )
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func resetDefaultProbePassword(
        partitionType: UInt32,
        withReply reply: @escaping (String?) -> Void
    ) {
        do {
            try controller.resetDefaultProbePassword(partitionType: partitionType)
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func setDeviceDisplayName(
        deviceID: String,
        displayName: String,
        withReply reply: @escaping (String?) -> Void
    ) {
        do {
            try controller.setDeviceDisplayName(deviceID: deviceID, displayName: displayName)
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func setGlobalAutoMount(enabled: Bool, withReply reply: @escaping (String?) -> Void) {
        do {
            try controller.setGlobalAutoMount(enabled)
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func mountPartition(
        deviceID: String,
        partitionType: UInt32,
        withReply reply: @escaping (String?) -> Void
    ) {
        let replyBox = EDPSendableStringReply(reply)
        controller.mountPartitionAsync(
            deviceID: deviceID,
            partitionType: partitionType
        ) { errorMessage in
            replyBox(errorMessage)
        }
    }

    func unmountPartition(
        deviceID: String,
        partitionType: UInt32,
        withReply reply: @escaping (String?) -> Void
    ) {
        let replyBox = EDPSendableStringReply(reply)
        controller.unmountPartitionAsync(
            deviceID: deviceID,
            partitionType: partitionType
        ) { errorMessage in
            replyBox(errorMessage)
        }
    }

    func eject(deviceID: String, withReply reply: @escaping (String?) -> Void) {
        let replyBox = EDPSendableStringReply(reply)
        controller.ejectAsync(deviceID: deviceID) { errorMessage in
            replyBox(errorMessage)
        }
    }

    func diagnostics(withReply reply: @escaping (Data) -> Void) {
        reply(controller.diagnosticsData())
    }
}
