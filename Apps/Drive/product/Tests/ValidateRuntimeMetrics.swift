import Dispatch
import Foundation

@main
struct ValidateRuntimeMetrics {
    static func main() {
        let metrics = EDPRuntimeMetrics()
        let iterations = 1_000

        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            metrics.increment(.rawBusyRecovery)
            metrics.increment(.forcedWholeUnmount)
            metrics.increment(.fskitAgentRecovery)
            metrics.increment(.diskImagesAttachRecovery)
            metrics.increment(.diskImagesDetachRecovery)
            metrics.increment(.mountRetry)
            metrics.increment(.ejectAlreadyAbsentSuccess)
        }

        let snapshot = metrics.snapshot()
        precondition(snapshot.rawBusyRecoveryCount == UInt64(iterations))
        precondition(snapshot.forcedWholeUnmountCount == UInt64(iterations))
        precondition(snapshot.fskitAgentRecoveryCount == UInt64(iterations))
        precondition(snapshot.diskImagesAttachRecoveryCount == UInt64(iterations))
        precondition(snapshot.diskImagesDetachRecoveryCount == UInt64(iterations))
        precondition(snapshot.mountRetryCount == UInt64(iterations))
        precondition(snapshot.ejectAlreadyAbsentSuccessCount == UInt64(iterations))

        let expectedKeys: Set<String> = [
            "rawBusyRecoveryCount",
            "forcedWholeUnmountCount",
            "fskitAgentRecoveryCount",
            "diskImagesAttachRecoveryCount",
            "diskImagesDetachRecoveryCount",
            "mountRetryCount",
            "ejectAlreadyAbsentSuccessCount",
        ]
        precondition(Set(snapshot.jsonObject.keys) == expectedKeys)
        precondition(snapshot.jsonObject.values.allSatisfy { $0 == UInt64(iterations) })

        print("RESULT=DRIVE_RUNTIME_METRICS_CONTRACT_OK")
    }
}
