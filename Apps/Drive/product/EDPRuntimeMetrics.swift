import Foundation

struct EDPRuntimeMetricsSnapshot: Equatable, Sendable {
    let rawBusyRecoveryCount: UInt64
    let forcedWholeUnmountCount: UInt64
    let fskitAgentRecoveryCount: UInt64
    let diskImagesAttachRecoveryCount: UInt64
    let diskImagesDetachRecoveryCount: UInt64
    let mountRetryCount: UInt64
    let ejectAlreadyAbsentSuccessCount: UInt64

    var jsonObject: [String: UInt64] {
        [
            "rawBusyRecoveryCount": rawBusyRecoveryCount,
            "forcedWholeUnmountCount": forcedWholeUnmountCount,
            "fskitAgentRecoveryCount": fskitAgentRecoveryCount,
            "diskImagesAttachRecoveryCount": diskImagesAttachRecoveryCount,
            "diskImagesDetachRecoveryCount": diskImagesDetachRecoveryCount,
            "mountRetryCount": mountRetryCount,
            "ejectAlreadyAbsentSuccessCount": ejectAlreadyAbsentSuccessCount,
        ]
    }
}

final class EDPRuntimeMetrics: @unchecked Sendable {
    enum Counter: Sendable {
        case rawBusyRecovery
        case forcedWholeUnmount
        case fskitAgentRecovery
        case diskImagesAttachRecovery
        case diskImagesDetachRecovery
        case mountRetry
        case ejectAlreadyAbsentSuccess
    }

    private let lock = NSLock()
    private var rawBusyRecoveryCount: UInt64 = 0
    private var forcedWholeUnmountCount: UInt64 = 0
    private var fskitAgentRecoveryCount: UInt64 = 0
    private var diskImagesAttachRecoveryCount: UInt64 = 0
    private var diskImagesDetachRecoveryCount: UInt64 = 0
    private var mountRetryCount: UInt64 = 0
    private var ejectAlreadyAbsentSuccessCount: UInt64 = 0

    func increment(_ counter: Counter) {
        lock.lock()
        switch counter {
        case .rawBusyRecovery:
            rawBusyRecoveryCount &+= 1
        case .forcedWholeUnmount:
            forcedWholeUnmountCount &+= 1
        case .fskitAgentRecovery:
            fskitAgentRecoveryCount &+= 1
        case .diskImagesAttachRecovery:
            diskImagesAttachRecoveryCount &+= 1
        case .diskImagesDetachRecovery:
            diskImagesDetachRecoveryCount &+= 1
        case .mountRetry:
            mountRetryCount &+= 1
        case .ejectAlreadyAbsentSuccess:
            ejectAlreadyAbsentSuccessCount &+= 1
        }
        lock.unlock()
    }

    func snapshot() -> EDPRuntimeMetricsSnapshot {
        lock.lock()
        let snapshot = EDPRuntimeMetricsSnapshot(
            rawBusyRecoveryCount: rawBusyRecoveryCount,
            forcedWholeUnmountCount: forcedWholeUnmountCount,
            fskitAgentRecoveryCount: fskitAgentRecoveryCount,
            diskImagesAttachRecoveryCount: diskImagesAttachRecoveryCount,
            diskImagesDetachRecoveryCount: diskImagesDetachRecoveryCount,
            mountRetryCount: mountRetryCount,
            ejectAlreadyAbsentSuccessCount: ejectAlreadyAbsentSuccessCount
        )
        lock.unlock()
        return snapshot
    }
}
