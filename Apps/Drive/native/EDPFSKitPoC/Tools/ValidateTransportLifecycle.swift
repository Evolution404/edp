import Foundation

private enum ValidationFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        if case .message(let value) = self { return value }
        return "validation failed"
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
}

@main
private enum ValidateTransportLifecycle {
    static func main() throws {
        try validateAlreadyExited()
        try validateTerminateFallback()
        try validateForceTerminateFallback()
        try validateMountedTransportIsNeverKilled()
        print("RESULT=TRANSPORT_LIFECYCLE_HARDENING_OK")
    }

    private static func validateAlreadyExited() throws {
        let process = FakeManagedProcess(.alreadyExited)
        let session = makeSession(process)
        try session.stop(
            unmount: { _ in },
            isMounted: { _ in false },
            gracefulExitSeconds: 0
        )
        try require(process.terminateCount == 0, "already-exited process received SIGTERM")
        try require(process.forceTerminateCount == 0, "already-exited process received SIGKILL")
    }

    private static func validateTerminateFallback() throws {
        let process = FakeManagedProcess(.exitsOnTerminate)
        let session = makeSession(process)
        try session.stop(
            unmount: { _ in },
            isMounted: { _ in false },
            gracefulExitSeconds: 0
        )
        try require(process.terminateCount == 1, "SIGTERM fallback was not used exactly once")
        try require(process.forceTerminateCount == 0, "SIGKILL was used after successful SIGTERM")
    }

    private static func validateForceTerminateFallback() throws {
        let process = FakeManagedProcess(.exitsOnForce)
        let session = makeSession(process)
        try session.stop(
            unmount: { _ in },
            isMounted: { _ in false },
            gracefulExitSeconds: 0
        )
        try require(process.terminateCount == 1, "stuck process did not receive SIGTERM first")
        try require(process.forceTerminateCount == 1, "stuck process did not receive one SIGKILL fallback")
    }

    private static func validateMountedTransportIsNeverKilled() throws {
        let process = FakeManagedProcess(.neverExits)
        let session = makeSession(process)
        var unmountAttempted = false
        var rejected = false
        do {
            try session.stop(
                unmount: { _ in unmountAttempted = true },
                isMounted: { _ in true },
                gracefulExitSeconds: 0
            )
        } catch {
            rejected = true
        }
        try require(unmountAttempted, "mounted transport did not request VFS unmount")
        try require(rejected, "mounted transport teardown should fail closed")
        try require(process.terminateCount == 0, "mounted transport incorrectly received SIGTERM")
        try require(process.forceTerminateCount == 0, "mounted transport incorrectly received SIGKILL")
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
            process: process
        )
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw ValidationFailure.message(message)
        }
    }
}
