import Foundation

typealias EDPRawRecoveryProbe = @Sendable (
    PhysicalDisk,
    @escaping EDPRawAccessLeaseCompletion
) -> Void

typealias EDPRecoveryAction = @Sendable (PhysicalDisk) -> Void
typealias EDPRecoveryFailureRecorder = @Sendable (PhysicalDisk, String) -> Void

final class EDPRecoveryCoordinator: @unchecked Sendable {
    private let mediaProvider: any EDPWholeUSBMediaProviding
    private let ejectCoordinator: EDPEjectCoordinator

    init(
        mediaProvider: any EDPWholeUSBMediaProviding,
        ejectCoordinator: EDPEjectCoordinator
    ) {
        self.mediaProvider = mediaProvider
        self.ejectCoordinator = ejectCoordinator
    }

    func recoverFailedEject(
        disk: PhysicalDisk,
        errorMessage: String,
        probeRawAccess: @escaping EDPRawRecoveryProbe,
        restoreBootPolicy: @escaping EDPRecoveryAction,
        recordFailure: @escaping EDPRecoveryFailureRecorder,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        ejectCoordinator.releaseActive(deviceID: disk.deviceID)

        let finish: @Sendable () -> Void = {
            recordFailure(disk, errorMessage)
            completion(errorMessage)
        }

        guard (try? wholeUSBMediaStillMatches(
            disk,
            mediaProvider: mediaProvider
        )) == true else {
            finish()
            return
        }

        probeRawAccess(disk) { _, _ in
            restoreBootPolicy(disk)
            finish()
        }
    }
}
