import Darwin
import Foundation

enum EDPLifecycleFailureCode: String, Equatable, Sendable {
    case rawAccessPermission
    case rawAccessUnavailable
    case deviceChanged
    case bridgeLaunchFailed
    case bridgeExtensionUnavailable
    case bridgeTimeout
    case bridgeProcessExited
    case publicationFailed
    case filesystemMountFailed
    case teardownFailed
    case cancelled
    case invalidTransition
    case unknown
}

struct EDPLifecycleFailure: Error, Equatable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    let code: EDPLifecycleFailureCode
    let detail: String

    init(code: EDPLifecycleFailureCode, detail: String) {
        self.code = code
        self.detail = detail
    }

    init(stringLiteral value: String) {
        self.init(code: .unknown, detail: value)
    }

    var description: String { detail }

    static let cancelled = EDPLifecycleFailure(
        code: .cancelled,
        detail: "mount operation cancelled"
    )

    static func classifyBridgeActivation(
        timedOut: Bool,
        logDetail: String?
    ) -> EDPLifecycleFailure {
        if timedOut {
            return EDPLifecycleFailure(
                code: .bridgeTimeout,
                detail: "operation timed out after 8 seconds"
            )
        }
        let normalized = (logDetail ?? "").lowercased()
        if normalized.contains("mount(8) returned 69")
            || normalized.contains("file system extension not found")
            || normalized.contains("file system extension not enabled") {
            return EDPLifecycleFailure(
                code: .bridgeExtensionUnavailable,
                detail: "encrypted block bridge failed"
                    + ((logDetail?.isEmpty == false) ? ": \(logDetail!)" : "")
            )
        }
        return EDPLifecycleFailure(
            code: .bridgeProcessExited,
            detail: "encrypted block bridge failed"
                + ((logDetail?.isEmpty == false) ? ": \(logDetail!)" : "")
        )
    }

    static func rawAccessTaggedCode(in detail: String) -> Int? {
        for tag in ["EDP_RAW_BROKER_OPEN_FAILED:", "EDP_RAW_LEASE_OPEN_FAILED:"] {
            guard let range = detail.range(of: tag) else { continue }
            let suffix = detail[range.upperBound...]
            let digits = suffix.prefix { $0.isNumber }
            guard !digits.isEmpty else { continue }
            if let value = Int(digits) { return value }
        }
        return nil
    }

    static func isRawAccessBusy(_ failure: EDPLifecycleFailure) -> Bool {
        rawAccessTaggedCode(in: failure.detail) == Int(EBUSY)
    }

    static func recognizedRawAccessFailure(_ error: Error) -> EDPLifecycleFailure? {
        let nsError = error as NSError
        let detail = String(describing: error)
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EPERM) {
            return EDPLifecycleFailure(code: .rawAccessPermission, detail: detail)
        }

        // The privileged helper protocol predates typed errors. Parse its
        // stable machine-readable tags once at this adapter boundary; callers
        // receive only a typed failure code from this point onward. Match the
        // complete numeric code: a validation code such as 1007 must never be
        // mistaken for EPERM merely because its decimal text begins with "1".
        let taggedCode = rawAccessTaggedCode(in: detail)
        if taggedCode == Int(EPERM)
            || detail.contains("Operation not permitted")
            || detail.contains("操作不被允许") {
            return EDPLifecycleFailure(code: .rawAccessPermission, detail: detail)
        }
        if taggedCode != nil
            || detail.contains("EDP_RAW_BROKER_") || detail.contains("EDP_RAW_LEASE_") {
            return EDPLifecycleFailure(code: .rawAccessUnavailable, detail: detail)
        }
        return nil
    }

    static func classifyRawAccess(_ error: Error) -> EDPLifecycleFailure {
        recognizedRawAccessFailure(error)
            ?? EDPLifecycleFailure(code: .rawAccessUnavailable, detail: String(describing: error))
    }
}

enum EDPFSKitMountRecoveryPolicy {
    static func shouldRecoverBridgeActivation(
        failure: EDPLifecycleFailure,
        transportStillRunning: Bool,
        bridgeMounted: Bool
    ) -> Bool {
        guard !bridgeMounted else { return false }
        switch failure.code {
        case .bridgeExtensionUnavailable:
            return true
        case .bridgeTimeout:
            return transportStillRunning
        default:
            return false
        }
    }
}

enum EDPFSKitMountLifecycleState: Equatable, Sendable {
    case idle
    case preparing(attempt: Int)
    case waitingForBridge(attempt: Int)
    case cleaningUp(attempt: Int, recoverable: Bool, failure: EDPLifecycleFailure)
    case recoveringHost(attempt: Int, failure: EDPLifecycleFailure)
    case publishing(attempt: Int)
    case mountingFilesystem(attempt: Int)
    case mounted
    case failed(EDPLifecycleFailure)
}

enum EDPFSKitMountLifecycleAction: Equatable, Sendable {
    case launchAttempt(attempt: Int)
    case waitForBridge(attempt: Int)
    case cleanup(attempt: Int, allowHostRecoveryDuringStop: Bool)
    case restartHost
    case publish(attempt: Int)
    case mountFilesystem(attempt: Int)
    case complete
    case fail(EDPLifecycleFailure)
}

struct EDPFSKitMountLifecycleMachine: Sendable {
    private(set) var state: EDPFSKitMountLifecycleState = .idle
    private(set) var recoveryBudget = 1

    mutating func start() -> EDPFSKitMountLifecycleAction {
        guard state == .idle else { return .fail("mount operation already started") }
        state = .preparing(attempt: 0)
        return .launchAttempt(attempt: 0)
    }

    mutating func attemptLaunched(_ attempt: Int) -> EDPFSKitMountLifecycleAction {
        guard state == .preparing(attempt: attempt) else {
            return invalidTransition("attemptLaunched")
        }
        state = .waitingForBridge(attempt: attempt)
        return .waitForBridge(attempt: attempt)
    }

    mutating func bridgeActivated(_ attempt: Int) -> EDPFSKitMountLifecycleAction {
        guard state == .waitingForBridge(attempt: attempt) else {
            return invalidTransition("bridgeActivated")
        }
        state = .publishing(attempt: attempt)
        return .publish(attempt: attempt)
    }

    mutating func bridgeFailed(
        _ attempt: Int,
        recoverable: Bool,
        failure: EDPLifecycleFailure
    ) -> EDPFSKitMountLifecycleAction {
        guard state == .waitingForBridge(attempt: attempt) else {
            return invalidTransition("bridgeFailed")
        }
        let mayRecover = recoverable && recoveryBudget > 0
        state = .cleaningUp(attempt: attempt, recoverable: mayRecover, failure: failure)
        return .cleanup(attempt: attempt, allowHostRecoveryDuringStop: mayRecover)
    }

    mutating func cleanupFinished(
        _ attempt: Int,
        hostAlreadyRecovered: Bool
    ) -> EDPFSKitMountLifecycleAction {
        guard case .cleaningUp(let currentAttempt, let recoverable, let failure) = state,
              currentAttempt == attempt else {
            return invalidTransition("cleanupFinished")
        }
        guard recoverable else {
            state = .failed(failure)
            return .fail(failure)
        }
        if hostAlreadyRecovered {
            recoveryBudget -= 1
            let next = attempt + 1
            state = .preparing(attempt: next)
            return .launchAttempt(attempt: next)
        }
        state = .recoveringHost(attempt: attempt, failure: failure)
        return .restartHost
    }

    mutating func hostRecoveryFinished(_ succeeded: Bool) -> EDPFSKitMountLifecycleAction {
        guard case .recoveringHost(let attempt, let failure) = state else {
            return invalidTransition("hostRecoveryFinished")
        }
        guard succeeded, recoveryBudget > 0 else {
            state = .failed(failure)
            return .fail(failure)
        }
        recoveryBudget -= 1
        let next = attempt + 1
        state = .preparing(attempt: next)
        return .launchAttempt(attempt: next)
    }

    mutating func publicationFinished(_ attempt: Int) -> EDPFSKitMountLifecycleAction {
        guard state == .publishing(attempt: attempt) else {
            return invalidTransition("publicationFinished")
        }
        state = .mountingFilesystem(attempt: attempt)
        return .mountFilesystem(attempt: attempt)
    }

    mutating func filesystemMounted(_ attempt: Int) -> EDPFSKitMountLifecycleAction {
        guard state == .mountingFilesystem(attempt: attempt) else {
            return invalidTransition("filesystemMounted")
        }
        state = .mounted
        return .complete
    }

    mutating func stageFailed(_ failure: EDPLifecycleFailure) -> EDPFSKitMountLifecycleAction {
        switch state {
        case .publishing(let attempt), .mountingFilesystem(let attempt):
            state = .cleaningUp(attempt: attempt, recoverable: false, failure: failure)
            return .cleanup(attempt: attempt, allowHostRecoveryDuringStop: false)
        case .failed(let existing):
            return .fail(existing)
        case .mounted:
            return .complete
        default:
            state = .failed(failure)
            return .fail(failure)
        }
    }

    mutating func cancel() -> EDPFSKitMountLifecycleAction {
        let failure = EDPLifecycleFailure.cancelled
        switch state {
        case .idle, .preparing:
            state = .failed(failure)
            return .fail(failure)
        case .waitingForBridge(let attempt),
             .publishing(let attempt),
             .mountingFilesystem(let attempt):
            state = .cleaningUp(attempt: attempt, recoverable: false, failure: failure)
            return .cleanup(attempt: attempt, allowHostRecoveryDuringStop: false)
        case .cleaningUp, .recoveringHost:
            // Cleanup/recovery work already owns the resources. The caller uses
            // this event only after that in-flight step returns, so cancellation
            // wins over retry/recovery without launching a second cleanup.
            state = .failed(failure)
            return .fail(failure)
        case .mounted:
            return .fail(EDPLifecycleFailure(
                code: .invalidTransition,
                detail: "mount operation already completed"
            ))
        case .failed(let existing):
            return .fail(existing)
        }
    }

    private mutating func invalidTransition(_ event: String) -> EDPFSKitMountLifecycleAction {
        // Async callbacks may arrive after an operation has already reached a
        // terminal state. They are stale events, not a new lifecycle failure.
        switch state {
        case .failed(let existing):
            return .fail(existing)
        case .mounted:
            return .complete
        default:
            let failure = EDPLifecycleFailure(
                code: .invalidTransition,
                detail: "invalid FSKit mount lifecycle transition: \(event) from \(state)"
            )
            state = .failed(failure)
            return .fail(failure)
        }
    }
}
