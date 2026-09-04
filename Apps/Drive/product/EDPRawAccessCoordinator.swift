import Foundation

typealias EDPRawAccessLeaseOpening = @Sendable (PhysicalDisk) throws -> EDPRawAccessLease
typealias EDPRawAccessLeaseCompletion = @Sendable (EDPRawAccessLease?, EDPLifecycleFailure?) -> Void

final class EDPRawAccessCoordinator: @unchecked Sendable {
    private let ownerQueue: DispatchQueue
    private let diskArbitration: any EDPDaemonDiskArbitrating
    private let leaseOpener: EDPRawAccessLeaseOpening
    private let openerRunsOffOwnerQueue: Bool
    private let metrics: EDPRuntimeMetrics
    private let rawAccessQueue = DispatchQueue(
        label: "com.edp.drive.raw-access",
        qos: .userInitiated
    )

    // These collections are ownerQueue-confined. The coordinator deliberately
    // does not add a second locking domain around controller lifecycle state.
    private var leases = [String: EDPRawAccessLease]()
    private var probeWaiters = [String: [EDPRawAccessLeaseCompletion]]()
    private var readyByDeviceID = [String: Bool]()
    private var failuresByDeviceID = [String: EDPLifecycleFailure]()
    private var registryGenerationByDeviceID = [String: UInt64]()

    init(
        ownerQueue: DispatchQueue,
        diskArbitration: any EDPDaemonDiskArbitrating,
        leaseOpener: @escaping EDPRawAccessLeaseOpening,
        openerRunsOffOwnerQueue: Bool,
        metrics: EDPRuntimeMetrics = EDPRuntimeMetrics()
    ) {
        self.ownerQueue = ownerQueue
        self.diskArbitration = diskArbitration
        self.leaseOpener = leaseOpener
        self.openerRunsOffOwnerQueue = openerRunsOffOwnerQueue
        self.metrics = metrics
    }

    func lease(for disk: PhysicalDisk) -> EDPRawAccessLease? {
        guard let lease = leases[disk.deviceID],
              lease.registryEntryID == disk.registryEntryID,
              lease.rawPath == disk.rawPath else {
            return nil
        }
        return lease
    }

    func readiness(deviceID: String) -> Bool? {
        readyByDeviceID[deviceID]
    }

    func shouldAutoProbe(_ disk: PhysicalDisk) -> Bool {
        switch readiness(deviceID: disk.deviceID) {
        case nil:
            return true
        case true:
            return lease(for: disk) == nil
        case false:
            return false
        }
    }

    func markReady(deviceID: String) {
        readyByDeviceID[deviceID] = true
        failuresByDeviceID.removeValue(forKey: deviceID)
    }

    func markFailure(deviceID: String, failure: EDPLifecycleFailure) {
        readyByDeviceID[deviceID] = false
        failuresByDeviceID[deviceID] = failure
    }

    func failure(deviceID: String) -> EDPLifecycleFailure? {
        failuresByDeviceID[deviceID]
    }

    func prune(to disks: [PhysicalDisk]) {
        // A stable device identity must resolve to exactly one live physical
        // generation before a retained raw lease can remain authoritative. A
        // transient overlap between old/new USB generations is ambiguous and
        // therefore fails closed instead of trapping on duplicate dictionary
        // keys or retaining a lease for either candidate.
        var currentByDeviceID = [String: PhysicalDisk]()
        var ambiguousDeviceIDs = Set<String>()
        for disk in disks {
            if currentByDeviceID[disk.deviceID] != nil {
                currentByDeviceID.removeValue(forKey: disk.deviceID)
                ambiguousDeviceIDs.insert(disk.deviceID)
            } else if !ambiguousDeviceIDs.contains(disk.deviceID) {
                currentByDeviceID[disk.deviceID] = disk
            }
        }

        for (deviceID, disk) in currentByDeviceID {
            if let previousGeneration = registryGenerationByDeviceID[deviceID],
               previousGeneration != disk.registryEntryID {
                leases.removeValue(forKey: deviceID)?.invalidate()
                readyByDeviceID.removeValue(forKey: deviceID)
                failuresByDeviceID.removeValue(forKey: deviceID)
                registryGenerationByDeviceID.removeValue(forKey: deviceID)
            }
        }
        leases = leases.filter { deviceID, lease in
            guard let disk = currentByDeviceID[deviceID] else { return false }
            return lease.registryEntryID == disk.registryEntryID && lease.rawPath == disk.rawPath
        }
        let authoritativeDeviceIDs = Set(currentByDeviceID.keys)
        readyByDeviceID = readyByDeviceID.filter { authoritativeDeviceIDs.contains($0.key) }
        failuresByDeviceID = failuresByDeviceID.filter { authoritativeDeviceIDs.contains($0.key) }
        registryGenerationByDeviceID = registryGenerationByDeviceID.filter {
            authoritativeDeviceIDs.contains($0.key)
        }
    }

    func prepareForPhysicalEject(deviceID: String) {
        if let lease = leases.removeValue(forKey: deviceID) {
            lease.invalidate()
        }
        readyByDeviceID[deviceID] = false
        failuresByDeviceID.removeValue(forKey: deviceID)
    }

    func removeDevice(deviceID: String) {
        if let lease = leases.removeValue(forKey: deviceID) {
            lease.invalidate()
        }
        readyByDeviceID.removeValue(forKey: deviceID)
        failuresByDeviceID.removeValue(forKey: deviceID)
        registryGenerationByDeviceID.removeValue(forKey: deviceID)
    }

    func invalidateAll() {
        for lease in leases.values { lease.invalidate() }
        leases.removeAll()
        readyByDeviceID.removeAll()
        failuresByDeviceID.removeAll()
        registryGenerationByDeviceID.removeAll()
    }

    func readyDeviceIDs() -> [String] {
        readyByDeviceID.filter { $0.value }.map(\.key).sorted()
    }

    func errorsSnapshot() -> [String: String] {
        failuresByDeviceID.mapValues { "\($0.code.rawValue): \($0.description)" }
    }

    func probeAsync(
        for disk: PhysicalDisk,
        temporarilyUnmount: Bool,
        generationMatches: @escaping @Sendable (PhysicalDisk) -> Bool,
        onBusyRecovery: @escaping @Sendable (PhysicalDisk) -> Void,
        completion: @escaping EDPRawAccessLeaseCompletion
    ) {
        if let retained = lease(for: disk) {
            markReady(deviceID: disk.deviceID)
            completion(retained, nil)
            return
        }
        if probeWaiters[disk.deviceID] != nil {
            probeWaiters[disk.deviceID, default: []].append(completion)
            return
        }
        probeWaiters[disk.deviceID] = [completion]

        let openLease: @Sendable () -> Void = { [weak self] in
            self?.launchOpenAttempt(
                for: disk,
                allowBusyRecovery: true,
                generationMatches: generationMatches,
                onBusyRecovery: onBusyRecovery
            )
        }

        guard temporarilyUnmount,
              EDPNativeMountTable.hasMountedBSDPrefix(disk.bsdName) else {
            openLease()
            return
        }
        diskArbitration.unmountWholeAsync(
            disk.bsdName,
            expectedRegistryEntryID: disk.registryEntryID
        ) { [weak self] error in
            guard let self else { return }
            self.ownerQueue.async {
                if let error {
                    self.finishProbe(
                        disk: disk,
                        lease: nil,
                        failure: EDPLifecycleFailure(
                            code: .teardownFailed,
                            detail: String(describing: error)
                        )
                    )
                    return
                }
                openLease()
            }
        }
    }

    func requireLeaseAsync(
        for disk: PhysicalDisk,
        isEjecting: Bool,
        generationMatches: @escaping @Sendable (PhysicalDisk) -> Bool,
        onBusyRecovery: @escaping @Sendable (PhysicalDisk) -> Void,
        completion: @escaping EDPRawAccessLeaseCompletion
    ) {
        guard !isEjecting else {
            completion(nil, EDPLifecycleFailure(
                code: .deviceChanged,
                detail: "EDP device was safely ejected; physically reinsert it before mounting"
            ))
            return
        }
        if let retained = lease(for: disk) {
            completion(retained, nil)
            return
        }
        probeAsync(
            for: disk,
            temporarilyUnmount: true,
            generationMatches: generationMatches,
            onBusyRecovery: onBusyRecovery,
            completion: completion
        )
    }

    private func launchOpenAttempt(
        for disk: PhysicalDisk,
        allowBusyRecovery: Bool,
        generationMatches: @escaping @Sendable (PhysicalDisk) -> Bool,
        onBusyRecovery: @escaping @Sendable (PhysicalDisk) -> Void
    ) {
        let performOpen: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            let result: Result<EDPRawAccessLease, EDPLifecycleFailure>
            do {
                result = .success(try self.leaseOpener(disk))
            } catch {
                result = .failure(userFacingRawAccessFailure(error))
            }
            let handle: @Sendable () -> Void = { [weak self] in
                self?.handleOpenResult(
                    disk: disk,
                    result: result,
                    allowBusyRecovery: allowBusyRecovery,
                    generationMatches: generationMatches,
                    onBusyRecovery: onBusyRecovery
                )
            }
            if self.openerRunsOffOwnerQueue {
                self.ownerQueue.async(execute: handle)
            } else {
                // Injected regression openers historically execute synchronously
                // on the controller queue; preserve that deterministic contract.
                handle()
            }
        }
        if openerRunsOffOwnerQueue {
            rawAccessQueue.async(execute: performOpen)
        } else {
            performOpen()
        }
    }

    private func handleOpenResult(
        disk: PhysicalDisk,
        result: Result<EDPRawAccessLease, EDPLifecycleFailure>,
        allowBusyRecovery: Bool,
        generationMatches: @escaping @Sendable (PhysicalDisk) -> Bool,
        onBusyRecovery: @escaping @Sendable (PhysicalDisk) -> Void
    ) {
        guard generationMatches(disk) else {
            if case .success(let lease) = result { lease.invalidate() }
            finishProbe(
                disk: disk,
                lease: nil,
                failure: EDPLifecycleFailure(
                    code: .deviceChanged,
                    detail: "EDP device changed while raw access was being prepared"
                )
            )
            return
        }

        switch result {
        case .success(let lease):
            finishProbe(disk: disk, lease: lease, failure: nil)
        case .failure(let failure):
            guard allowBusyRecovery, EDPLifecycleFailure.isRawAccessBusy(failure) else {
                finishProbe(disk: disk, lease: nil, failure: failure)
                return
            }

            metrics.increment(.rawBusyRecovery)
            onBusyRecovery(disk)
            metrics.increment(.forcedWholeUnmount)
            diskArbitration.forceUnmountWholeAsync(
                disk.bsdName,
                expectedRegistryEntryID: disk.registryEntryID
            ) { [weak self] error in
                guard let self else { return }
                self.ownerQueue.async {
                    guard generationMatches(disk) else {
                        self.finishProbe(
                            disk: disk,
                            lease: nil,
                            failure: EDPLifecycleFailure(
                                code: .deviceChanged,
                                detail: "EDP device changed during raw busy recovery"
                            )
                        )
                        return
                    }
                    if let error {
                        self.finishProbe(
                            disk: disk,
                            lease: nil,
                            failure: EDPLifecycleFailure(
                                code: .teardownFailed,
                                detail: "EDP raw busy recovery failed: \(error)"
                            )
                        )
                        return
                    }
                    self.launchOpenAttempt(
                        for: disk,
                        allowBusyRecovery: false,
                        generationMatches: generationMatches,
                        onBusyRecovery: onBusyRecovery
                    )
                }
            }
        }
    }

    private func finishProbe(
        disk: PhysicalDisk,
        lease: EDPRawAccessLease?,
        failure: EDPLifecycleFailure?
    ) {
        registryGenerationByDeviceID[disk.deviceID] = disk.registryEntryID
        if let lease {
            leases[disk.deviceID] = lease
            markReady(deviceID: disk.deviceID)
        } else {
            leases.removeValue(forKey: disk.deviceID)
            markFailure(
                deviceID: disk.deviceID,
                failure: failure ?? EDPLifecycleFailure(
                    code: .rawAccessUnavailable,
                    detail: "raw access probe failed"
                )
            )
        }
        let callbacks = probeWaiters.removeValue(forKey: disk.deviceID) ?? []
        for callback in callbacks { callback(lease, failure) }
    }
}
