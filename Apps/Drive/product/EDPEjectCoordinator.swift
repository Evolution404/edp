import Foundation

final class EDPEjectCoordinator: @unchecked Sendable {
    private let ownerQueue: DispatchQueue
    private let diskArbitration: any EDPDaemonDiskArbitrating
    private let mediaProvider: any EDPWholeUSBMediaProviding
    private let metrics: EDPRuntimeMetrics

    // Owner-queue confined. The active registry map is intentionally separate
    // from completion waiters because the physical USB generation can disappear
    // before the in-flight eject callback fans out its terminal result.
    private var activeUSBRegistryIDs = [String: UInt64]()
    private var completionWaiters = [String: [EDPDaemonMountCompletion]]()

    init(
        ownerQueue: DispatchQueue,
        diskArbitration: any EDPDaemonDiskArbitrating,
        mediaProvider: any EDPWholeUSBMediaProviding,
        metrics: EDPRuntimeMetrics = EDPRuntimeMetrics()
    ) {
        self.ownerQueue = ownerQueue
        self.diskArbitration = diskArbitration
        self.mediaProvider = mediaProvider
        self.metrics = metrics
    }

    func isEjecting(deviceID: String) -> Bool {
        activeUSBRegistryIDs[deviceID] != nil
    }

    var hasActiveEjects: Bool {
        !activeUSBRegistryIDs.isEmpty
    }

    func joinIfActive(
        deviceID: String,
        completion: @escaping EDPDaemonMountCompletion
    ) -> Bool {
        guard activeUSBRegistryIDs[deviceID] != nil else { return false }
        completionWaiters[deviceID, default: []].append(completion)
        return true
    }

    @discardableResult
    func begin(
        disk: PhysicalDisk,
        completion: @escaping EDPDaemonMountCompletion
    ) -> Bool {
        if joinIfActive(deviceID: disk.deviceID, completion: completion) {
            return false
        }
        activeUSBRegistryIDs[disk.deviceID] = disk.usbRegistryEntryID
        completionWaiters[disk.deviceID] = [completion]
        diskArbitration.suppressAutomount(usbRegistryEntryID: disk.usbRegistryEntryID)
        return true
    }

    func releaseDisconnectedGenerations() {
        for (deviceID, usbRegistryEntryID) in activeUSBRegistryIDs
        where !mediaProvider.registryEntryExists(usbRegistryEntryID) {
            activeUSBRegistryIDs.removeValue(forKey: deviceID)
            diskArbitration.allowAutomount(usbRegistryEntryID: usbRegistryEntryID)
        }
    }

    func releaseActive(deviceID: String) {
        guard let usbRegistryEntryID = activeUSBRegistryIDs.removeValue(forKey: deviceID) else {
            return
        }
        diskArbitration.allowAutomount(usbRegistryEntryID: usbRegistryEntryID)
    }

    func finishWaiters(deviceID: String, errorMessage: String?) {
        releaseActive(deviceID: deviceID)
        let callbacks = completionWaiters.removeValue(forKey: deviceID) ?? []
        for callback in callbacks {
            callback(errorMessage)
        }
    }

    func performPhysicalEjectAsync(
        disk: PhysicalDisk,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        let originalGenerationPresent: @Sendable () -> Bool = { [mediaProvider] in
            mediaProvider.registryEntryExists(disk.usbRegistryEntryID)
        }
        let ejectNow: @Sendable () -> Void = { [weak self] in
            guard let self else {
                completion("EDP eject coordinator was released")
                return
            }
            // USB disappearance is already the desired terminal state. Never
            // send Disk Arbitration work to a stale/reused BSD name.
            guard originalGenerationPresent() else {
                self.metrics.increment(.ejectAlreadyAbsentSuccess)
                completion(nil)
                return
            }
            self.diskArbitration.ejectAsync(
                disk.bsdName,
                expectedRegistryEntryID: disk.registryEntryID
            ) { [weak self] error in
                guard let self else { return }
                self.ownerQueue.async {
                    if error != nil, !originalGenerationPresent() {
                        self.metrics.increment(.ejectAlreadyAbsentSuccess)
                        completion(nil)
                    } else {
                        completion(error.map { String(describing: $0) })
                    }
                }
            }
        }

        guard originalGenerationPresent() else {
            metrics.increment(.ejectAlreadyAbsentSuccess)
            completion(nil)
            return
        }
        guard EDPNativeMountTable.hasMountedBSDPrefix(disk.bsdName) else {
            ejectNow()
            return
        }
        diskArbitration.unmountWholeAsync(
            disk.bsdName,
            expectedRegistryEntryID: disk.registryEntryID
        ) { [weak self] error in
            guard let self else { return }
            self.ownerQueue.async {
                if let error {
                    completion(
                        originalGenerationPresent()
                            ? String(describing: error)
                            : nil
                    )
                    return
                }
                ejectNow()
            }
        }
    }
}
