import Darwin
import Foundation

enum EDPTransportBackend: String, Codable, CaseIterable, Sendable {
    case macFUSELocal = "macfuse-local"
}

struct EDPTransportCapabilities: Equatable, Sendable {
    let finderHidden: Bool
    let writable: Bool
    let diskImagesCompatible: Bool
    let localVolume: Bool
}

struct EDPTransportLaunchSpec: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let capabilities: EDPTransportCapabilities
}

struct EDPTransportSessionError: Error, CustomStringConvertible {
    let description: String
}

private final class EDPTransportStopOperation: @unchecked Sendable {
    let queue: DispatchQueue
    let unmount: (String) throws -> Void
    let isMounted: (String) -> Bool
    let recoverStuckProcess: (() -> Bool)?
    let completion: @Sendable (Bool, Bool, String?) -> Void
    var recoveryAttempted = false
    var finished = false

    init(
        queue: DispatchQueue,
        unmount: @escaping (String) throws -> Void,
        isMounted: @escaping (String) -> Bool,
        recoverStuckProcess: (() -> Bool)?,
        completion: @escaping @Sendable (Bool, Bool, String?) -> Void
    ) {
        self.queue = queue
        self.unmount = unmount
        self.isMounted = isMounted
        self.recoverStuckProcess = recoverStuckProcess
        self.completion = completion
    }
}

protocol EDPManagedProcess: AnyObject {
    var isRunning: Bool { get }
    func terminate()
    func forceTerminate()
}

extension Process: EDPManagedProcess {
    func forceTerminate() {
        guard isRunning else { return }
        _ = Darwin.kill(processIdentifier, SIGKILL)
    }
}

final class EDPTransportSession: @unchecked Sendable {
    let backend: EDPTransportBackend
    let mountpoint: String
    let capabilities: EDPTransportCapabilities
    private let process: any EDPManagedProcess
    private let scheduler: any EDPLifecycleScheduling

    init(
        backend: EDPTransportBackend,
        mountpoint: String,
        capabilities: EDPTransportCapabilities,
        process: any EDPManagedProcess,
        scheduler: any EDPLifecycleScheduling = EDPDispatchLifecycleScheduler.shared
    ) {
        self.backend = backend
        self.mountpoint = mountpoint
        self.capabilities = capabilities
        self.process = process
        self.scheduler = scheduler
    }

    var isRunning: Bool { process.isRunning }

    func stopAsync(
        on queue: DispatchQueue,
        unmount: @escaping (String) throws -> Void,
        isMounted: @escaping (String) -> Bool,
        gracefulExitSeconds: TimeInterval = 5,
        recoverStuckProcess: (() -> Bool)? = nil,
        completion: @escaping @Sendable (Bool, Bool, String?) -> Void
    ) {
        let operation = EDPTransportStopOperation(
            queue: queue,
            unmount: unmount,
            isMounted: isMounted,
            recoverStuckProcess: recoverStuckProcess,
            completion: completion
        )
        queue.async { [weak self, operation] in
            self?.beginStop(operation, gracefulExitSeconds: gracefulExitSeconds)
        }
    }

    private func beginStop(
        _ operation: EDPTransportStopOperation,
        gracefulExitSeconds: TimeInterval
    ) {
        do {
            if operation.isMounted(mountpoint) {
                try operation.unmount(mountpoint)
            }
            guard !operation.isMounted(mountpoint) else {
                finishStop(
                    operation,
                    recovered: false,
                    error: "transport mount remained active after VFS unmount: \(mountpoint)"
                )
                return
            }
        } catch {
            finishStop(operation, recovered: false, error: String(describing: error))
            return
        }
        waitForGracefulExit(
            operation,
            deadline: scheduler.deadline(after: gracefulExitSeconds)
        )
    }

    private func waitForGracefulExit(
        _ operation: EDPTransportStopOperation,
        deadline: UInt64
    ) {
        guard process.isRunning else {
            finishStop(operation, recovered: false, error: nil)
            return
        }
        guard scheduler.hasReached(deadline) else {
            scheduler.schedule(on: operation.queue, after: 0.05) { [weak self, operation] in
                self?.waitForGracefulExit(operation, deadline: deadline)
            }
            return
        }
        process.terminate()
        waitAfterTerminate(operation, deadline: scheduler.deadline(after: 2))
    }

    private func waitAfterTerminate(
        _ operation: EDPTransportStopOperation,
        deadline: UInt64
    ) {
        guard process.isRunning else {
            finishStop(operation, recovered: false, error: nil)
            return
        }
        guard scheduler.hasReached(deadline) else {
            scheduler.schedule(on: operation.queue, after: 0.05) { [weak self, operation] in
                self?.waitAfterTerminate(operation, deadline: deadline)
            }
            return
        }

        // The VFS mount was proven gone before escalation. A still-running
        // transport can therefore receive SIGKILL without risking a live user
        // filesystem.
        process.forceTerminate()
        waitAfterForceTerminate(operation, deadline: scheduler.deadline(after: 1))
    }

    private func waitAfterForceTerminate(
        _ operation: EDPTransportStopOperation,
        deadline: UInt64
    ) {
        guard process.isRunning else {
            finishStop(operation, recovered: false, error: nil)
            return
        }
        guard scheduler.hasReached(deadline) else {
            scheduler.schedule(on: operation.queue, after: 0.05) { [weak self, operation] in
                self?.waitAfterForceTerminate(operation, deadline: deadline)
            }
            return
        }

        guard !operation.recoveryAttempted,
              let recover = operation.recoverStuckProcess else {
            finishStop(
                operation,
                recovered: false,
                error: "transport process did not exit after SIGKILL: \(mountpoint)"
            )
            return
        }
        operation.recoveryAttempted = true
        guard recover() else {
            finishStop(
                operation,
                recovered: false,
                error: "transport process did not exit after SIGKILL and host recovery was refused: \(mountpoint)"
            )
            return
        }
        waitAfterHostRecovery(operation, deadline: scheduler.deadline(after: 2))
    }

    private func waitAfterHostRecovery(
        _ operation: EDPTransportStopOperation,
        deadline: UInt64
    ) {
        guard process.isRunning else {
            finishStop(operation, recovered: true, error: nil)
            return
        }
        guard scheduler.hasReached(deadline) else {
            scheduler.schedule(on: operation.queue, after: 0.05) { [weak self, operation] in
                self?.waitAfterHostRecovery(operation, deadline: deadline)
            }
            return
        }
        finishStop(
            operation,
            recovered: false,
            error: "transport process remained after host recovery: \(mountpoint)"
        )
    }

    private func finishStop(
        _ operation: EDPTransportStopOperation,
        recovered: Bool,
        error: String?
    ) {
        guard !operation.finished else { return }
        operation.finished = true
        operation.completion(recovered, operation.recoveryAttempted, error)
    }
}

struct EDPTransportRequest: Sendable {
    let binaryRoot: String
    let rawDevice: String
    let rawFD: Int32
    let vid: String
    let pid: String
    let deviceSize: UInt64
    let partitionType: UInt32
    let controlFD: Int32
    let mountpoint: String
    let volumeName: String
    let readOnly: Bool
}

enum EDPTransportSelectionError: Error, CustomStringConvertible {
    case backendCannotHideTransport(EDPTransportBackend)
    case backendCannotWrite(EDPTransportBackend)

    var description: String {
        switch self {
        case .backendCannotHideTransport(let backend):
            return "EDP transport backend \(backend.rawValue) does not satisfy Finder-hidden product policy"
        case .backendCannotWrite(let backend):
            return "EDP transport backend \(backend.rawValue) does not satisfy writable product policy"
        }
    }
}

enum EDPTransportProvider {
    static func selectedBackend() -> EDPTransportBackend {
        .macFUSELocal
    }

    static func capabilities(for backend: EDPTransportBackend) -> EDPTransportCapabilities {
        switch backend {
        case .macFUSELocal:
            return EDPTransportCapabilities(
                finderHidden: true,
                writable: true,
                diskImagesCompatible: true,
                localVolume: true
            )
        }
    }

    static func executableName(for backend: EDPTransportBackend, readOnly: Bool) -> String {
        switch backend {
        case .macFUSELocal:
            return readOnly ? "edp-mfmount-local-readonly" : "edp-mfmount-local-readwrite"
        }
    }

    static func launchSpec(
        for backend: EDPTransportBackend,
        request: EDPTransportRequest,
        requireFinderHidden: Bool
    ) throws -> EDPTransportLaunchSpec {
        let capabilities = capabilities(for: backend)
        if requireFinderHidden && !capabilities.finderHidden {
            throw EDPTransportSelectionError.backendCannotHideTransport(backend)
        }
        if !request.readOnly && !capabilities.writable {
            throw EDPTransportSelectionError.backendCannotWrite(backend)
        }

        let commonArguments = [
            "--raw-device", request.rawDevice,
            "--raw-fd", String(request.rawFD),
            "--vid", request.vid,
            "--pid", request.pid,
            "--device-size", String(request.deviceSize),
            "--partition-type", String(request.partitionType),
            "--control-fd", String(request.controlFD),
            "--mountpoint", request.mountpoint,
            "--volume-name", request.volumeName,
            "--read-only", request.readOnly ? "1" : "0",
        ]

        let executable = request.binaryRoot + "/" + executableName(
            for: backend,
            readOnly: request.readOnly
        )
        switch backend {
        case .macFUSELocal:
            return EDPTransportLaunchSpec(
                executable: executable,
                arguments: commonArguments,
                environment: ["EDP_MFMOUNT_OPTIONS": "local,nobrowse"],
                capabilities: capabilities
            )
        }
    }
}
