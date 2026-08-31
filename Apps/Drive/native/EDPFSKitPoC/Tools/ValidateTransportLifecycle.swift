import Foundation

private enum ValidationFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        if case .message(let value) = self { return value }
        return "validation failed"
    }
}

private final class TransportStopResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var recovered = false
    private var error: String?

    func set(recovered: Bool, error: String?) {
        lock.lock()
        completed = true
        self.recovered = recovered
        self.error = error
        lock.unlock()
    }

    func snapshot() -> (completed: Bool, recovered: Bool, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (completed, recovered, error)
    }
}

private final class ManualLifecycleScheduler: EDPLifecycleScheduling, @unchecked Sendable {
    private struct Scheduled {
        let deadline: UInt64
        let order: UInt64
        let queue: DispatchQueue
        let operation: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var now: UInt64 = 0
    private var nextOrder: UInt64 = 0
    private var scheduled = [Scheduled]()

    var nowNanoseconds: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return now
    }

    func schedule(
        on queue: DispatchQueue,
        after delay: TimeInterval,
        _ operation: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        nextOrder &+= 1
        let nanos = UInt64(max(0, delay) * 1_000_000_000)
        scheduled.append(Scheduled(
            deadline: now &+ nanos,
            order: nextOrder,
            queue: queue,
            operation: operation
        ))
        lock.unlock()
    }

    func advance(by seconds: TimeInterval) {
        let nanos = UInt64(max(0, seconds) * 1_000_000_000)
        lock.lock()
        now &+= nanos
        lock.unlock()
        runDue()
    }

    private func runDue() {
        while true {
            let next: Scheduled?
            lock.lock()
            if let index = scheduled.indices.min(by: {
                let lhs = scheduled[$0]
                let rhs = scheduled[$1]
                return lhs.deadline == rhs.deadline ? lhs.order < rhs.order : lhs.deadline < rhs.deadline
            }), scheduled[index].deadline <= now {
                next = scheduled.remove(at: index)
            } else {
                next = nil
            }
            lock.unlock()
            guard let next else { return }
            next.queue.sync(execute: next.operation)
        }
    }
}

private let transportLifecycleScheduler = ManualLifecycleScheduler()

private extension EDPTransportSession {
    @discardableResult
    func stop(
        unmount: @escaping (String) throws -> Void,
        isMounted: @escaping (String) -> Bool,
        gracefulExitSeconds: TimeInterval = 5,
        recoverStuckProcess: (() -> Bool)? = nil
    ) throws -> Bool {
        let queue = DispatchQueue(label: "com.edp.drive.tests.transport-stop")
        let result = TransportStopResultBox()
        stopAsync(
            on: queue,
            unmount: unmount,
            isMounted: isMounted,
            gracefulExitSeconds: gracefulExitSeconds,
            recoverStuckProcess: recoverStuckProcess
        ) { recovered, _, error in
            result.set(recovered: recovered, error: error)
        }
        queue.sync {}
        for _ in 0..<240 where !result.snapshot().completed {
            transportLifecycleScheduler.advance(by: 0.05)
            queue.sync {}
        }
        let snapshot = result.snapshot()
        guard snapshot.completed else {
            throw ValidationFailure.message("virtual-time transport stop timed out")
        }
        if let error = snapshot.error {
            throw ValidationFailure.message(error)
        }
        return snapshot.recovered
    }
}

private final class FakeManagedProcess: EDPManagedProcess {
    enum ExitBehavior {
        case alreadyExited
        case exitsOnTerminate
        case exitsOnForce
        case neverExits
    }

    private let behavior: ExitBehavior
    private(set) var terminateCount = 0
    private(set) var forceTerminateCount = 0
    private var running: Bool

    init(_ behavior: ExitBehavior) {
        self.behavior = behavior
        running = behavior != .alreadyExited
    }

    var isRunning: Bool { running }

    func terminate() {
        terminateCount += 1
        if behavior == .exitsOnTerminate {
            running = false
        }
    }

    func forceTerminate() {
        forceTerminateCount += 1
        if behavior == .exitsOnForce {
            running = false
        }
    }

    func recoverFromHostReset() {
        running = false
    }
}

@main
private enum ValidateTransportLifecycle {
    static func main() throws {
        try validateAlreadyExited()
        try validateTerminateFallback()
        try validateForceTerminateFallback()
        try validateHostRecoveryAfterForceTerminate()
        try validateRecoveryFailureStillFailsClosed()
        try validateRecoverySuccessClaimWithoutExitStillFailsClosed()
        try validateNoRecoveryCallbackStillFailsClosed()
        try validateMountedTransportIsNeverKilled()
        print("RESULT=TRANSPORT_LIFECYCLE_VIRTUAL_CLOCK_OK")
        print("RESULT=TRANSPORT_LIFECYCLE_HARDENING_OK")
    }

    private static func validateAlreadyExited() throws {
        let process = FakeManagedProcess(.alreadyExited)
        let session = makeSession(process)
        let recovered = try session.stop(
            unmount: { _ in },
            isMounted: { _ in false },
            gracefulExitSeconds: 0
        )
        try require(!recovered, "already-exited process incorrectly reported host recovery")
        try require(process.terminateCount == 0, "already-exited process received SIGTERM")
        try require(process.forceTerminateCount == 0, "already-exited process received SIGKILL")
    }

    private static func validateTerminateFallback() throws {
        let process = FakeManagedProcess(.exitsOnTerminate)
        let session = makeSession(process)
        let recovered = try session.stop(
            unmount: { _ in },
            isMounted: { _ in false },
            gracefulExitSeconds: 0
        )
        try require(!recovered, "SIGTERM exit incorrectly reported host recovery")
        try require(process.terminateCount == 1, "SIGTERM fallback was not used exactly once")
        try require(process.forceTerminateCount == 0, "SIGKILL was used after successful SIGTERM")
    }

    private static func validateForceTerminateFallback() throws {
        let process = FakeManagedProcess(.exitsOnForce)
        let session = makeSession(process)
        var recoveryAttempted = false
        let recovered = try session.stop(
            unmount: { _ in },
            isMounted: { _ in false },
            gracefulExitSeconds: 0,
            recoverStuckProcess: {
                recoveryAttempted = true
                return true
            }
        )
        try require(!recovered, "SIGKILL exit incorrectly reported host recovery")
        try require(!recoveryAttempted, "host recovery ran after successful SIGKILL")
        try require(process.terminateCount == 1, "stuck process did not receive SIGTERM first")
        try require(process.forceTerminateCount == 1, "stuck process did not receive one SIGKILL fallback")
    }

    private static func validateHostRecoveryAfterForceTerminate() throws {
        let process = FakeManagedProcess(.neverExits)
        let session = makeSession(process)
        var recoveryCount = 0
        let recovered = try session.stop(
            unmount: { _ in },
            isMounted: { _ in false },
            gracefulExitSeconds: 0,
            recoverStuckProcess: {
                recoveryCount += 1
                process.recoverFromHostReset()
                return true
            }
        )
        try require(recovered, "successful host reset was not reported to the caller")
        try require(process.terminateCount == 1, "host recovery did not follow SIGTERM")
        try require(process.forceTerminateCount == 1, "host recovery did not follow SIGKILL")
        try require(recoveryCount == 1, "stuck transport host recovery was not invoked exactly once")
        try require(!process.isRunning, "host recovery did not release the stuck transport")
    }

    private static func validateRecoveryFailureStillFailsClosed() throws {
        let process = FakeManagedProcess(.neverExits)
        let session = makeSession(process)
        var recoveryCount = 0
        var rejected = false
        do {
            try session.stop(
                unmount: { _ in },
                isMounted: { _ in false },
                gracefulExitSeconds: 0,
                recoverStuckProcess: {
                    recoveryCount += 1
                    return false
                }
            )
        } catch {
            rejected = true
        }
        try require(rejected, "failed host recovery incorrectly reported teardown success")
        try require(recoveryCount == 1, "failed host recovery was not invoked exactly once")
        try require(process.isRunning, "failed host recovery unexpectedly changed fake process state")
    }

    private static func validateRecoverySuccessClaimWithoutExitStillFailsClosed() throws {
        let process = FakeManagedProcess(.neverExits)
        let session = makeSession(process)
        var recoveryCount = 0
        var rejected = false
        do {
            _ = try session.stop(
                unmount: { _ in },
                isMounted: { _ in false },
                gracefulExitSeconds: 0,
                recoverStuckProcess: {
                    recoveryCount += 1
                    return true
                }
            )
        } catch {
            rejected = true
        }
        try require(rejected, "host recovery success claim hid a still-running transport")
        try require(recoveryCount == 1, "host recovery success claim was not bounded to one attempt")
        try require(process.isRunning, "fake transport unexpectedly exited")
    }

    private static func validateNoRecoveryCallbackStillFailsClosed() throws {
        let process = FakeManagedProcess(.neverExits)
        let session = makeSession(process)
        var rejected = false
        do {
            _ = try session.stop(
                unmount: { _ in },
                isMounted: { _ in false },
                gracefulExitSeconds: 0
            )
        } catch {
            rejected = true
        }
        try require(rejected, "stuck transport without recovery callback incorrectly succeeded")
        try require(process.terminateCount == 1, "stuck transport without recovery skipped SIGTERM")
        try require(process.forceTerminateCount == 1, "stuck transport without recovery skipped SIGKILL")
    }

    private static func validateMountedTransportIsNeverKilled() throws {
        let process = FakeManagedProcess(.neverExits)
        let session = makeSession(process)
        var unmountAttempted = false
        var recoveryAttempted = false
        var rejected = false
        do {
            try session.stop(
                unmount: { _ in unmountAttempted = true },
                isMounted: { _ in true },
                gracefulExitSeconds: 0,
                recoverStuckProcess: {
                    recoveryAttempted = true
                    return true
                }
            )
        } catch {
            rejected = true
        }
        try require(unmountAttempted, "mounted transport did not request VFS unmount")
        try require(rejected, "mounted transport teardown should fail closed")
        try require(process.terminateCount == 0, "mounted transport incorrectly received SIGTERM")
        try require(process.forceTerminateCount == 0, "mounted transport incorrectly received SIGKILL")
        try require(!recoveryAttempted, "mounted transport incorrectly attempted FSKit host recovery")
    }

    private static func makeSession(_ process: FakeManagedProcess) -> EDPTransportSession {
        EDPTransportSession(
            backend: .macFUSELocal,
            mountpoint: "/Volumes/.edp-lifecycle-validator",
            capabilities: EDPTransportCapabilities(
                finderHidden: true,
                writable: true,
                diskImagesCompatible: true,
                localVolume: true
            ),
            process: process,
            scheduler: transportLifecycleScheduler
        )
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw ValidationFailure.message(message)
        }
    }
}
