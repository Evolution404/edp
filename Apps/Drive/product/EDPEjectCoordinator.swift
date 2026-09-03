import Foundation

final class EDPEjectCoordinator: @unchecked Sendable {
    private let ownerQueue: DispatchQueue
    private let diskArbitration: any EDPDaemonDiskArbitrating
    private let mediaProvider: any EDPWholeUSBMediaProviding
    private let metrics: EDPRuntimeMetrics
    private let logicalSuppressionPath: String?

    // Owner-queue confined. `activeUSBRegistryIDs` represents only an in-flight
    // eject transaction. `logicallyEjectedUSBRegistryIDs` is the post-success
    // tombstone that prevents a still-inserted USB generation from being
    // rediscovered/reacquired merely because the foreground App reconnects or
    // the privileged service restarts. The tombstone is released only after the
    // physical USB generation disappears or a different USB registry generation
    // is observed for the same stable device identity.
    private var activeUSBRegistryIDs = [String: UInt64]()
    private var logicallyEjectedUSBRegistryIDs = [String: UInt64]()
    private var completionWaiters = [String: [EDPDaemonMountCompletion]]()

    init(
        ownerQueue: DispatchQueue,
        diskArbitration: any EDPDaemonDiskArbitrating,
        mediaProvider: any EDPWholeUSBMediaProviding,
        metrics: EDPRuntimeMetrics = EDPRuntimeMetrics(),
        logicalSuppressionPath: String? = nil
    ) throws {
        self.ownerQueue = ownerQueue
        self.diskArbitration = diskArbitration
        self.mediaProvider = mediaProvider
        self.metrics = metrics
        self.logicalSuppressionPath = logicalSuppressionPath

        if let logicalSuppressionPath,
           FileManager.default.fileExists(atPath: logicalSuppressionPath) {
            let data = try Data(contentsOf: URL(fileURLWithPath: logicalSuppressionPath))
            logicallyEjectedUSBRegistryIDs = try JSONDecoder().decode(
                [String: UInt64].self,
                from: data
            )
        }
    }

    func isEjecting(deviceID: String) -> Bool {
        activeUSBRegistryIDs[deviceID] != nil
    }

    func isSuppressed(deviceID: String) -> Bool {
        activeUSBRegistryIDs[deviceID] != nil
            || logicallyEjectedUSBRegistryIDs[deviceID] != nil
    }

    var hasActiveEjects: Bool {
        !activeUSBRegistryIDs.isEmpty
    }

    private func persistLogicalSuppressions(_ suppressions: [String: UInt64]) throws {
        guard let logicalSuppressionPath else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try atomicWrite(
            encoder.encode(suppressions),
            to: logicalSuppressionPath,
            mode: 0o600
        )
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

    // Arm the post-eject tombstone before releasing the physical device. If the
    // tombstone cannot be persisted, the eject must not proceed: otherwise a
    // service/App restart could silently reacquire a device the user just asked
    // to eject.
    func armLogicalSuppression(disk: PhysicalDisk) throws {
        var updated = logicallyEjectedUSBRegistryIDs
        updated[disk.deviceID] = disk.usbRegistryEntryID
        try persistLogicalSuppressions(updated)
        logicallyEjectedUSBRegistryIDs = updated
        diskArbitration.suppressAutomount(usbRegistryEntryID: disk.usbRegistryEntryID)
    }

    func cancelLogicalSuppression(deviceID: String) throws {
        guard let usbRegistryEntryID = logicallyEjectedUSBRegistryIDs[deviceID] else { return }
        var updated = logicallyEjectedUSBRegistryIDs
        updated.removeValue(forKey: deviceID)
        try persistLogicalSuppressions(updated)
        logicallyEjectedUSBRegistryIDs = updated
        if activeUSBRegistryIDs[deviceID] == nil {
            diskArbitration.allowAutomount(usbRegistryEntryID: usbRegistryEntryID)
        }
    }

    // Reconcile persisted logical eject tombstones against IOKit before any
    // raw-access probe runs. Discovery is intentionally not authoritative for
    // tombstone retirement: a metadata/read failure can temporarily omit a
    // still-present USB from `disks`. Only disappearance of the exact persisted
    // USB registry generation is allowed to release suppression.
    func reconcileSuppressedGenerations(disks: [PhysicalDisk]) throws {
        for (deviceID, usbRegistryEntryID) in Array(activeUSBRegistryIDs)
        where !mediaProvider.registryEntryExists(usbRegistryEntryID) {
            activeUSBRegistryIDs.removeValue(forKey: deviceID)
            if logicallyEjectedUSBRegistryIDs[deviceID] == nil {
                diskArbitration.allowAutomount(usbRegistryEntryID: usbRegistryEntryID)
            }
        }

        var updated = logicallyEjectedUSBRegistryIDs
        var registryIDsToAllow = Set<UInt64>()
        var registryIDsToSuppress = Set<UInt64>()

        for (deviceID, suppressedUSBRegistryEntryID) in logicallyEjectedUSBRegistryIDs {
            if mediaProvider.registryEntryExists(suppressedUSBRegistryEntryID) {
                // The exact ejected physical generation is still present. Keep
                // the tombstone even when discovery omitted it, and fail closed
                // if a replacement generation with the same stable identity is
                // observed concurrently. Disk Arbitration callback suppression
                // is process-local, so re-apply it after every service restart.
                registryIDsToSuppress.insert(suppressedUSBRegistryEntryID)
                for current in disks where current.deviceID == deviceID {
                    registryIDsToSuppress.insert(current.usbRegistryEntryID)
                }
                continue
            }

            // IOKit has confirmed disappearance of the exact persisted physical
            // generation. Only now may a currently observed/new generation enter
            // normal discovery and raw-access acquisition.
            updated.removeValue(forKey: deviceID)
            registryIDsToAllow.insert(suppressedUSBRegistryEntryID)
            for current in disks where current.deviceID == deviceID {
                registryIDsToAllow.insert(current.usbRegistryEntryID)
            }
        }

        if updated != logicallyEjectedUSBRegistryIDs {
            try persistLogicalSuppressions(updated)
            logicallyEjectedUSBRegistryIDs = updated
        }
        for usbRegistryEntryID in registryIDsToAllow {
            diskArbitration.allowAutomount(usbRegistryEntryID: usbRegistryEntryID)
        }
        for usbRegistryEntryID in registryIDsToSuppress {
            diskArbitration.suppressAutomount(usbRegistryEntryID: usbRegistryEntryID)
        }
    }

    private func releaseActive(deviceID: String, allowAutomount: Bool) {
        guard let usbRegistryEntryID = activeUSBRegistryIDs.removeValue(forKey: deviceID) else {
            return
        }
        if allowAutomount {
            diskArbitration.allowAutomount(usbRegistryEntryID: usbRegistryEntryID)
        }
    }

    func releaseActive(deviceID: String) {
        releaseActive(deviceID: deviceID, allowAutomount: true)
    }

    func finishWaiters(deviceID: String, errorMessage: String?) {
        let keepSuppressed = errorMessage == nil
            && logicallyEjectedUSBRegistryIDs[deviceID] != nil
        releaseActive(deviceID: deviceID, allowAutomount: !keepSuppressed)
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
