import Foundation

final class EDPServiceLifecycleState: @unchecked Sendable {
    // All state is confined to EDPDaemonController's owner queue. This type is
    // deliberately lock-free so lifecycle ordering remains identical to the
    // pre-extraction controller implementation.
    private(set) var startupRecoveryComplete = false
    private(set) var startupRecoveryError: String?
    private(set) var shutdownRequested = false
    private var shutdownInProgress = false
    private var shutdownTeardownStarted = false
    private var shutdownCompletions = [EDPDaemonMountCompletion]()

    func completeStartupRecovery(errorMessage: String?) {
        startupRecoveryError = errorMessage
        startupRecoveryComplete = true
    }

    func beginShutdown(completion: @escaping EDPDaemonMountCompletion) -> Bool {
        shutdownCompletions.append(completion)
        guard !shutdownInProgress else { return false }
        shutdownRequested = true
        shutdownInProgress = true
        return true
    }

    func beginTeardownIfReady(hasActiveEjects: Bool) -> Bool {
        guard shutdownInProgress,
              !shutdownTeardownStarted,
              !hasActiveEjects else {
            return false
        }
        shutdownTeardownStarted = true
        return true
    }

    func finishShutdown() -> [EDPDaemonMountCompletion] {
        shutdownTeardownStarted = false
        shutdownInProgress = false
        let completions = shutdownCompletions
        shutdownCompletions.removeAll()
        return completions
    }
}
