import Dispatch
import Foundation

@main
private enum ValidateBoundedVFS {
    private struct ValidationError: Error, CustomStringConvertible {
        let description: String
    }

    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: RuntimeNativeError?

        func set(_ error: RuntimeNativeError?) {
            lock.lock()
            value = error
            lock.unlock()
        }

        func get() -> RuntimeNativeError? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ValidationError(description: message) }
    }

    static func main() {
        do {
            let queue = DispatchQueue(label: "com.edp.drive.tests.event-vfs")
            let finished = DispatchSemaphore(value: 0)
            let result = ErrorBox()
            let started = ContinuousClock.now

            // A path that is already absent must complete from the lifecycle
            // state immediately. No sleep/poll/process launch is needed on the
            // healthy idempotent path.
            EDPNativeMountTable.unmountPathAsync(
                "/private/tmp/edp-definitely-not-a-mountpoint",
                force: true,
                requireSourceTermination: true,
                timeout: 0.1,
                on: queue
            ) { error in
                result.set(error)
                finished.signal()
            }

            try require(
                finished.wait(timeout: .now() + 1) == .success,
                "event-driven VFS no-op unmount did not complete"
            )
            try require(
                result.get() == nil,
                "event-driven VFS no-op unmount failed: \(String(describing: result.get()))"
            )
            let elapsed = started.duration(to: .now)
            try require(
                elapsed < .seconds(1),
                "event-driven VFS no-op path consumed an unexpected delay: \(elapsed)"
            )

            print("EVENT_DRIVEN_VFS_NOOP_SECONDS=\(elapsed)")
            print("RESULT=EVENT_DRIVEN_VFS_UNMOUNT_GUARD_OK")
            // Keep the historical marker for downstream release jobs while the
            // implementation contract is now event-driven rather than polling.
            print("RESULT=BOUNDED_VFS_UNMOUNT_GUARD_OK")
        } catch {
            fputs("VALIDATION_ERROR=\(error)\n", stderr)
            exit(1)
        }
    }
}
