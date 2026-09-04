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

typealias EDPTransportUnmountCompletion = @Sendable (String?) -> Void
typealias EDPTransportUnmountRequest = (
    _ mountpoint: String,
    _ completion: @escaping EDPTransportUnmountCompletion
) -> Void
typealias EDPTransportRecoveryCompletion = @Sendable (Bool) -> Void
typealias EDPTransportRecoveryRequest = (
    _ completion: @escaping EDPTransportRecoveryCompletion
) -> Void

private final class EDPTransportStopOperation: @unchecked Sendable {
    let queue: DispatchQueue
    let unmountAsync: EDPTransportUnmountRequest
    let isMounted: (String) -> Bool
    let recoverStuckProcessAsync: EDPTransportRecoveryRequest?
    let completion: @Sendable (Bool, Bool, String?) -> Void
    var waitingForProcessExit = false
    var recoveryAttempted = false
    var finished = false

    init(
        queue: DispatchQueue,
        unmountAsync: @escaping EDPTransportUnmountRequest,
        isMounted: @escaping (String) -> Bool,
        recoverStuckProcessAsync: EDPTransportRecoveryRequest?,
        completion: @escaping @Sendable (Bool, Bool, String?) -> Void
    ) {
        self.queue = queue
        self.unmountAsync = unmountAsync
        self.isMounted = isMounted
        self.recoverStuckProcessAsync = recoverStuckProcessAsync
        self.completion = completion
    }
}

typealias EDPProcessExitHandler = @Sendable () -> Void

protocol EDPTransportReadinessObserving: AnyObject, Sendable {
    func observeReady(on queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void)
}

protocol EDPManagedProcess: AnyObject {
    var isRunning: Bool { get }
    func terminate()
    func forceTerminate()
    func observeExit(on queue: DispatchQueue, _ handler: @escaping EDPProcessExitHandler)
}

extension Process: EDPManagedProcess {
    func forceTerminate() {
        guard isRunning else { return }
        _ = Darwin.kill(processIdentifier, SIGKILL)
    }

    func observeExit(on queue: DispatchQueue, _ handler: @escaping EDPProcessExitHandler) {
        guard isRunning else {
            queue.async(execute: handler)
            return
        }
        let previous = terminationHandler
        terminationHandler = { process in
            previous?(process)
            queue.async(execute: handler)
        }
    }
}

final class EDPTransportSession: @unchecked Sendable {
    let backend: EDPTransportBackend
    let mountpoint: String
    let capabilities: EDPTransportCapabilities
    private let process: any EDPManagedProcess
    private let readiness: (any EDPTransportReadinessObserving)?
    private let scheduler: any EDPLifecycleScheduling

    init(
        backend: EDPTransportBackend,
        mountpoint: String,
        capabilities: EDPTransportCapabilities,
        process: any EDPManagedProcess,
        readiness: (any EDPTransportReadinessObserving)? = nil,
        scheduler: any EDPLifecycleScheduling = EDPDispatchLifecycleScheduler.shared
    ) {
        self.backend = backend
        self.mountpoint = mountpoint
        self.capabilities = capabilities
        self.process = process
        self.readiness = readiness
        self.scheduler = scheduler
    }

    var isRunning: Bool { process.isRunning }

    func observeReady(on queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void) {
        readiness?.observeReady(on: queue, handler)
    }

    func observeExit(on queue: DispatchQueue, _ handler: @escaping EDPProcessExitHandler) {
        process.observeExit(on: queue, handler)
    }

    func stopAsync(
        on queue: DispatchQueue,
        unmountAsync: @escaping EDPTransportUnmountRequest,
        isMounted: @escaping (String) -> Bool,
        gracefulExitSeconds: TimeInterval = 5,
        recoverStuckProcessAsync: EDPTransportRecoveryRequest? = nil,
        completion: @escaping @Sendable (Bool, Bool, String?) -> Void
    ) {
        let operation = EDPTransportStopOperation(
            queue: queue,
            unmountAsync: unmountAsync,
            isMounted: isMounted,
            recoverStuckProcessAsync: recoverStuckProcessAsync,
            completion: completion
        )
        process.observeExit(on: queue) { [weak self, operation] in
            self?.processDidExit(operation)
        }
        queue.async { [weak self, operation] in
            self?.beginStop(operation, gracefulExitSeconds: gracefulExitSeconds)
        }
    }

    private func beginStop(
        _ operation: EDPTransportStopOperation,
        gracefulExitSeconds: TimeInterval
    ) {
        if operation.isMounted(mountpoint) {
            guard process.isRunning else {
                finishStop(
                    operation,
                    recovered: false,
                    error: "transport process already exited while VFS mount remains active: \(mountpoint)"
                )
                return
            }
            operation.unmountAsync(mountpoint) { [weak self, operation] errorMessage in
                guard let self else { return }
                operation.queue.async { [weak self, operation] in
                    self?.continueAfterUnmount(
                        operation,
                        gracefulExitSeconds: gracefulExitSeconds,
                        errorMessage: errorMessage
                    )
                }
            }
            return
        }
        continueAfterUnmount(
            operation,
            gracefulExitSeconds: gracefulExitSeconds,
            errorMessage: nil
        )
    }

    private func continueAfterUnmount(
        _ operation: EDPTransportStopOperation,
        gracefulExitSeconds: TimeInterval,
        errorMessage: String?
    ) {
        guard !operation.finished else { return }
        if let errorMessage {
            finishStop(operation, recovered: false, error: errorMessage)
            return
        }
        guard !operation.isMounted(mountpoint) else {
            finishStop(
                operation,
                recovered: false,
                error: "transport mount remained active after VFS unmount: \(mountpoint)"
            )
            return
        }
        beginProcessExitWait(operation, gracefulExitSeconds: gracefulExitSeconds)
    }

    private func beginProcessExitWait(
        _ operation: EDPTransportStopOperation,
        gracefulExitSeconds: TimeInterval
    ) {
        guard process.isRunning else {
            finishStop(operation, recovered: false, error: nil)
            return
        }
        operation.waitingForProcessExit = true
        scheduler.schedule(on: operation.queue, after: max(0, gracefulExitSeconds)) { [weak self, operation] in
            self?.gracefulExitTimeout(operation)
        }
    }

    private func processDidExit(_ operation: EDPTransportStopOperation) {
        guard !operation.finished, operation.waitingForProcessExit else { return }
        finishStop(operation, recovered: operation.recoveryAttempted, error: nil)
    }

    private func gracefulExitTimeout(_ operation: EDPTransportStopOperation) {
        guard !operation.finished, operation.waitingForProcessExit else { return }
        guard process.isRunning else {
            finishStop(operation, recovered: false, error: nil)
            return
        }
        process.terminate()
        scheduler.schedule(on: operation.queue, after: 2) { [weak self, operation] in
            self?.terminateTimeout(operation)
        }
    }

    private func terminateTimeout(_ operation: EDPTransportStopOperation) {
        guard !operation.finished, operation.waitingForProcessExit else { return }
        guard process.isRunning else {
            finishStop(operation, recovered: false, error: nil)
            return
        }

        // The VFS mount was proven gone before escalation. A still-running
        // transport can therefore receive SIGKILL without risking a live user
        // filesystem.
        process.forceTerminate()
        scheduler.schedule(on: operation.queue, after: 1) { [weak self, operation] in
            self?.forceTerminateTimeout(operation)
        }
    }

    private func forceTerminateTimeout(_ operation: EDPTransportStopOperation) {
        guard !operation.finished, operation.waitingForProcessExit else { return }
        guard process.isRunning else {
            finishStop(operation, recovered: false, error: nil)
            return
        }

        guard !operation.recoveryAttempted,
              let recover = operation.recoverStuckProcessAsync else {
            finishStop(
                operation,
                recovered: false,
                error: "transport process did not exit after SIGKILL: \(mountpoint)"
            )
            return
        }
        operation.recoveryAttempted = true
        recover { [weak self, operation] recovered in
            guard let self else { return }
            operation.queue.async {
                guard !operation.finished else { return }
                guard recovered else {
                    self.finishStop(
                        operation,
                        recovered: false,
                        error: "transport process did not exit after SIGKILL and host recovery was refused: \(self.mountpoint)"
                    )
                    return
                }
                guard self.process.isRunning else {
                    self.finishStop(operation, recovered: true, error: nil)
                    return
                }
                self.scheduler.schedule(on: operation.queue, after: 2) { [weak self, operation] in
                    self?.hostRecoveryTimeout(operation)
                }
            }
        }
    }

    private func hostRecoveryTimeout(_ operation: EDPTransportStopOperation) {
        guard !operation.finished, operation.waitingForProcessExit else { return }
        guard process.isRunning else {
            finishStop(operation, recovered: true, error: nil)
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
