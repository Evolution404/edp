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
            metrics.increment(.fskitTransientRetry)
            metrics.increment(.diskImagesAttachRecovery)
            metrics.increment(.diskImagesDetachRecovery)
            metrics.increment(.mountRetry)
            metrics.increment(.ejectAlreadyAbsentSuccess)
        }

        let snapshot = metrics.snapshot()
        precondition(snapshot.rawBusyRecoveryCount == UInt64(iterations))
        precondition(snapshot.forcedWholeUnmountCount == UInt64(iterations))
        precondition(snapshot.fskitTransientRetryCount == UInt64(iterations))
        precondition(snapshot.diskImagesAttachRecoveryCount == UInt64(iterations))
        precondition(snapshot.diskImagesDetachRecoveryCount == UInt64(iterations))
        precondition(snapshot.mountRetryCount == UInt64(iterations))
        precondition(snapshot.ejectAlreadyAbsentSuccessCount == UInt64(iterations))

        let expectedKeys: Set<String> = [
            "rawBusyRecoveryCount",
            "forcedWholeUnmountCount",
            "fskitTransientRetryCount",
            "diskImagesAttachRecoveryCount",
            "diskImagesDetachRecoveryCount",
            "mountRetryCount",
            "ejectAlreadyAbsentSuccessCount",
        ]
        precondition(Set(snapshot.jsonObject.keys) == expectedKeys)
        precondition(snapshot.jsonObject.values.allSatisfy { $0 == UInt64(iterations) })

        let activityStore = EDPActivityStore(capacity: 200)
        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            activityStore.add(
                "activity-\(index)",
                deviceID: "device-\(index % 8)",
                partitionType: UInt32(index % 3 + 1)
            )
            _ = activityStore.snapshot()
        }
        let activities = activityStore.snapshot()
        precondition(activities.count == 200)
        precondition(Set(activities.map(\.id)).count == activities.count)
        precondition(activities.allSatisfy { !$0.message.isEmpty })

        print("RESULT=DRIVE_RUNTIME_METRICS_CONTRACT_OK")
        print("RESULT=DRIVE_ACTIVITY_STORE_SENDABLE_CONTRACT_OK")
    }
}
