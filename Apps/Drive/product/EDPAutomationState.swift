import Foundation

final class EDPAutomationState: @unchecked Sendable {
    // Owner-confined by EDPServiceController.queue. This type centralizes the
    // insertion-scoped automation memory without creating a second lock domain.
    private var failedMounts = [String: String]()
    private var failedMountCodes = [String: EDPLifecycleFailureCode]()
    private var manualUnmountSuppressions = Set<String>()
    private var defaultProbeSuppressions = Set<String>()

    func failureMessage(for partitionKey: String) -> String? {
        failedMounts[partitionKey]
    }

    func failureCode(for partitionKey: String) -> EDPLifecycleFailureCode? {
        failedMountCodes[partitionKey]
    }

    func recordFailure(
        _ message: String,
        code: EDPLifecycleFailureCode?,
        for partitionKey: String
    ) {
        failedMounts[partitionKey] = message
        if let code {
            failedMountCodes[partitionKey] = code
        } else {
            failedMountCodes.removeValue(forKey: partitionKey)
        }
    }

    func clearFailure(for partitionKey: String) {
        failedMounts.removeValue(forKey: partitionKey)
        failedMountCodes.removeValue(forKey: partitionKey)
    }

    func failedMountsSnapshot() -> [String: String] {
        failedMounts
    }

    func isManualUnmountSuppressed(_ partitionKey: String) -> Bool {
        manualUnmountSuppressions.contains(partitionKey)
    }

    func suppressManualRemount(_ partitionKey: String) {
        manualUnmountSuppressions.insert(partitionKey)
    }

    func clearManualRemountSuppression(_ partitionKey: String) {
        manualUnmountSuppressions.remove(partitionKey)
    }

    func manualUnmountSuppressionsSnapshot() -> [String] {
        manualUnmountSuppressions.sorted()
    }

    func isDefaultProbeSuppressed(_ partitionKey: String) -> Bool {
        defaultProbeSuppressions.contains(partitionKey)
    }

    func suppressDefaultProbe(_ partitionKey: String) {
        defaultProbeSuppressions.insert(partitionKey)
    }

    func clearDefaultProbeSuppression(_ partitionKey: String) {
        defaultProbeSuppressions.remove(partitionKey)
    }

    func prune(connectedDeviceIDs: Set<String>) {
        failedMounts = failedMounts.filter { item in
            Self.deviceID(from: item.key).map(connectedDeviceIDs.contains) == true
        }
        failedMountCodes = failedMountCodes.filter { item in
            Self.deviceID(from: item.key).map(connectedDeviceIDs.contains) == true
        }
        manualUnmountSuppressions = manualUnmountSuppressions.filter { key in
            Self.deviceID(from: key).map(connectedDeviceIDs.contains) == true
        }
        defaultProbeSuppressions = defaultProbeSuppressions.filter { key in
            Self.deviceID(from: key).map(connectedDeviceIDs.contains) == true
        }
    }

    func removeDevice(_ deviceID: String) {
        let prefix = "\(deviceID):"
        failedMounts = failedMounts.filter { !$0.key.hasPrefix(prefix) }
        failedMountCodes = failedMountCodes.filter { !$0.key.hasPrefix(prefix) }
        manualUnmountSuppressions = manualUnmountSuppressions.filter { !$0.hasPrefix(prefix) }
        defaultProbeSuppressions = defaultProbeSuppressions.filter { !$0.hasPrefix(prefix) }
    }

    private static func deviceID(from partitionKey: String) -> String? {
        guard let separator = partitionKey.lastIndex(of: ":") else { return nil }
        return String(partitionKey[..<separator])
    }
}
