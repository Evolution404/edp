import Darwin
import Foundation
import Security

#if EDP_REGRESSION_TESTS
private final class EDPRegressionAsyncResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func set(_ value: String?) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func snapshot() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
#endif

typealias EDPDaemonMountCompletion = @Sendable (String?) -> Void

protocol EDPDaemonMountManaging: AnyObject {
    func recoverPersistedSessionsAsync(completion: @escaping EDPDaemonMountCompletion)
    func contains(_ disk: PhysicalDisk, _ type: UInt32) -> Bool
    func mountedPhysicalDisks() -> Set<String>
    func isMounted(deviceID: String) -> Bool
    func mountedSummaries() -> [[String: String]]
    func summary(deviceID: String, partitionType: UInt32) -> [String: String]?
    func lastFailureCode(deviceID: String, partitionType: UInt32) -> EDPLifecycleFailureCode?
    func lifecycleJournalSnapshot() -> [EDPLifecycleJournalEntry]
    func mountAsync(
        disk: PhysicalDisk,
        partitionType: UInt32,
        password: [UInt8],
        rawFD: Int32,
        completion: @escaping EDPDaemonMountCompletion
    )
    func unmountAsync(
        deviceID: String,
        partitionType: UInt32,
        completion: @escaping EDPDaemonMountCompletion
    )
    func ejectAsync(deviceID: String, completion: @escaping EDPDaemonMountCompletion)
    func recordPhysicalEjectResult(
        deviceID: String,
        failureCode: EDPLifecycleFailureCode?
    )
    func recordShutdownCoalesced()
    @discardableResult
    func removeMissing(availableDisks: [String: String], graceSeconds: TimeInterval) -> Bool
    func unmountAllAsync(completion: @escaping EDPDaemonMountCompletion)
}

extension EDPDaemonMountManaging {
    func lastFailureCode(deviceID: String, partitionType: UInt32) -> EDPLifecycleFailureCode? {
        _ = deviceID
        _ = partitionType
        return nil
    }

    func lifecycleJournalSnapshot() -> [EDPLifecycleJournalEntry] { [] }

    func recordPhysicalEjectResult(
        deviceID: String,
        failureCode: EDPLifecycleFailureCode?
    ) {
        _ = deviceID
        _ = failureCode
    }

    func recordShutdownCoalesced() {}
}

private final class EDPMountCoordinator: EDPDaemonMountManaging, @unchecked Sendable {
    private var sessions = [String: MountSession]()
    private var missingSince = [String: Date]()
    private let binaryRoot: String
    private let diskArbitration: EDPDiskArbitrationController
    private let blockPublisher: any EDPBlockDevicePublisher
    private let scheduler: any EDPLifecycleScheduling
    private let journal: EDPLifecycleJournal
    private let metrics: EDPRuntimeMetrics
    private let remountQuiescenceSeconds: TimeInterval
    private let lifecycleQueue = DispatchQueue(label: "com.edp.drive.mount-lifecycle", qos: .userInitiated)
    private let filesystemOperationQueue = DispatchQueue(
        label: "com.edp.drive.filesystem-operation",
        qos: .userInitiated
    )
    private let lifecycleQueueKey = DispatchSpecificKey<UInt8>()
    private var activeMountOperations = Set<String>()
    private var activeMountOperationBoxes = [String: EDPFSKitMountOperationBox]()
    private var cancelledMountOperations = Set<String>()
    private var mountWaiters = [String: [EDPDaemonMountCompletion]]()
    private var lastMountFailureCodes = [String: EDPLifecycleFailureCode]()
    private var unmountWaiters = [String: [EDPDaemonMountCompletion]]()
    private var unmountJournalContexts = [String: EDPLifecycleOperationContext]()
    private var ejectWaiters = [String: [EDPDaemonMountCompletion]]()
    private var ejectJournalContexts = [String: EDPLifecycleOperationContext]()
    private var shutdownWaiters = [EDPDaemonMountCompletion]()
    private var shutdownJournalContext: EDPLifecycleOperationContext?
    private var remountQuiescence = EDPRemountQuiescenceGate()

    init(
        scheduler: any EDPLifecycleScheduling = EDPDispatchLifecycleScheduler.shared,
        journal: EDPLifecycleJournal = EDPLifecycleJournal(),
        metrics: EDPRuntimeMetrics = EDPRuntimeMetrics(),
        remountQuiescenceSeconds: TimeInterval = 3.0
    ) throws {
        self.scheduler = scheduler
        self.journal = journal
        self.metrics = metrics
        self.remountQuiescenceSeconds = max(0, remountQuiescenceSeconds)
        if let configuredRoot = ProcessInfo.processInfo.environment["EDP_RUNTIME_BIN_ROOT"], !configuredRoot.isEmpty {
            binaryRoot = configuredRoot
        } else {
            binaryRoot = URL(fileURLWithPath: CommandLine.arguments[0])
                .resolvingSymlinksInPath().deletingLastPathComponent().path
        }
        diskArbitration = try EDPDiskArbitrationController()
        blockPublisher = EDPDiskImages2Publisher(
            binaryRoot: binaryRoot,
            diskArbitration: diskArbitration,
            metrics: metrics
        )
        lifecycleQueue.setSpecific(key: lifecycleQueueKey, value: 1)
    }

    private func lifecycleSync<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: lifecycleQueueKey) != nil {
            return try body()
        }
        return try lifecycleQueue.sync(execute: body)
    }

    private func makeLifecycleContext(
        operation: String,
        deviceID: String,
        partitionType: UInt32? = nil
    ) -> EDPLifecycleOperationContext {
        EDPLifecycleOperationContext(
            operation: operation,
            deviceID: deviceID,
            partitionType: partitionType,
            startedAtNanoseconds: scheduler.nowNanoseconds
        )
    }

    private func makeLifecycleContext(
        operation: String,
        sessionKey: String
    ) -> EDPLifecycleOperationContext {
        guard let separator = sessionKey.lastIndex(of: ":"),
              let partitionType = UInt32(sessionKey[sessionKey.index(after: separator)...]) else {
            return makeLifecycleContext(operation: operation, deviceID: sessionKey)
        }
        return makeLifecycleContext(
            operation: operation,
            deviceID: String(sessionKey[..<separator]),
            partitionType: partitionType
        )
    }

    private func recordLifecycle(
        _ context: EDPLifecycleOperationContext,
        state: String,
        event: String,
        attempt: Int? = nil,
        recoveryBudget: Int? = nil,
        ownedResources: [String] = [],
        diagnosticCode: EDPLifecycleFailureCode? = nil
    ) {
        journal.record(
            context: context,
            scheduler: scheduler,
            state: state,
            event: event,
            attempt: attempt,
            recoveryBudget: recoveryBudget,
            ownedResources: ownedResources,
            diagnosticCode: diagnosticCode?.rawValue
        )
    }

    func recoverPersistedSessionsAsync(completion: @escaping EDPDaemonMountCompletion) {
        lifecycleQueue.async { [weak self] in
            guard let self else {
                completion("mount manager was released")
                return
            }
            let path = dataRoot + "/sessions.json"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
                completion(nil)
                return
            }
            self.recoverPersistedSessionItems(items, index: 0) { errorMessage in
                if errorMessage == nil {
                    try? FileManager.default.removeItem(atPath: path)
                }
                completion(errorMessage)
            }
        }
    }

    private func recoverPersistedSessionItems(
        _ items: [[String: String]],
        index: Int,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        guard index < items.count else {
            completion(nil)
            return
        }
        let item = items[index]
        let advance: @Sendable () -> Void = { [weak self] in
            guard let self else {
                completion("mount manager was released")
                return
            }
            self.recoverPersistedSessionItems(items, index: index + 1, completion: completion)
        }

        if let mountpoint = item["mountpoint"], !mountpoint.isEmpty {
            do {
                try EDPNativeMountTable.unmountPath(mountpoint)
            } catch {
                NSLog(
                    "EDP persisted-session recovery stopped at user mount %@: %@",
                    mountpoint,
                    String(describing: error)
                )
                advance()
                return
            }
            guard !EDPNativeMountTable.isMountpoint(mountpoint) else {
                NSLog("EDP persisted-session recovery kept active user mount %@", mountpoint)
                advance()
                return
            }
            try? FileManager.default.removeItem(atPath: mountpoint)
            if remountQuiescenceSeconds > 0 {
                scheduler.schedule(
                    on: lifecycleQueue,
                    after: remountQuiescenceSeconds
                ) { [weak self] in
                    self?.continueRecoverPersistedSessionItem(
                        item,
                        advance: advance,
                        completion: completion
                    )
                }
                return
            }
        }

        continueRecoverPersistedSessionItem(
            item,
            advance: advance,
            completion: completion
        )
    }

    private func continueRecoverPersistedSessionItem(
        _ item: [String: String],
        advance: @escaping @Sendable () -> Void,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        if let exposed = item["exposedBSD"], !exposed.isEmpty {
            let backingPath = item["bridgeMount"].map { $0 + "/volume.raw" }
            blockPublisher.unpublishAsync(
                EDPPublishedBlockDevice(bsdName: exposed, backingPath: backingPath)
            ) { [weak self] errorMessage in
                guard let self else {
                    completion("mount manager was released")
                    return
                }
                self.lifecycleQueue.async {
                    if let errorMessage {
                        NSLog(
                            "EDP persisted-session recovery kept published device %@: %@",
                            exposed,
                            errorMessage
                        )
                        advance()
                        return
                    }
                    self.recoverPersistedBridge(item, advance: advance)
                }
            }
            return
        }
        recoverPersistedBridge(item, advance: advance)
    }

    private func recoverPersistedBridge(
        _ item: [String: String],
        advance: @escaping @Sendable () -> Void
    ) {
        guard let bridge = item["bridgeMount"], !bridge.isEmpty else {
            advance()
            return
        }
        guard EDPNativeMountTable.isMountpoint(bridge) else {
            finishRecoverPersistedBridge(bridge, advance: advance)
            return
        }
        EDPMacFUSEScratchImageCleanup.cleanupOrphanAsync(mountedAt: bridge) { [weak self] _ in
            guard let self else { return }
            self.lifecycleQueue.async {
                self.finishRecoverPersistedBridge(bridge, advance: advance)
            }
        }
    }

    private func finishRecoverPersistedBridge(
        _ bridge: String,
        advance: @escaping @Sendable () -> Void
    ) {
        do {
            try EDPNativeMountTable.unmountPath(bridge)
            if EDPNativeMountTable.isMountpoint(bridge) {
                try EDPNativeMountTable.unmountPath(bridge, force: true)
            }
        } catch {
            NSLog(
                "EDP persisted-session recovery kept transport mount %@: %@",
                bridge,
                String(describing: error)
            )
            advance()
            return
        }
        guard !EDPNativeMountTable.isMountpoint(bridge) else {
            NSLog("EDP persisted-session recovery kept active transport mount %@", bridge)
            advance()
            return
        }
        try? FileManager.default.removeItem(atPath: bridge)
        advance()
    }

    private func key(_ disk: PhysicalDisk, _ type: UInt32) -> String {
        "\(disk.deviceID):\(type)"
    }

    func contains(_ disk: PhysicalDisk, _ type: UInt32) -> Bool {
        lifecycleSync { sessions[key(disk, type)] != nil || activeMountOperations.contains(key(disk, type)) }
    }

    func lastFailureCode(deviceID: String, partitionType: UInt32) -> EDPLifecycleFailureCode? {
        lifecycleSync { lastMountFailureCodes["\(deviceID):\(partitionType)"] }
    }

    func lifecycleJournalSnapshot() -> [EDPLifecycleJournalEntry] {
        journal.snapshot()
    }

    func mountedPhysicalDisks() -> Set<String> {
        lifecycleSync { Set(sessions.values.map(\.physicalBSD)) }
    }

    func isMounted(deviceID: String) -> Bool {
        lifecycleSync {
            sessions.values.contains { $0.deviceID == deviceID }
                || activeMountOperations.contains { $0.hasPrefix("\(deviceID):") }
        }
    }

    func mountedSummaries() -> [[String: String]] {
        lifecycleSync {
            sessions.values.map {
                [
                    "deviceID": $0.deviceID,
                    "physicalBSD": $0.physicalBSD,
                    "partitionType": String($0.partitionType),
                    "filesystem": $0.filesystem,
                    "mountpoint": $0.userMount ?? "",
                ]
            }
        }
    }

    func summary(deviceID: String, partitionType: UInt32) -> [String: String]? {
        lifecycleSync {
            guard let session = sessions["\(deviceID):\(partitionType)"] else { return nil }
            var filesystem = session.filesystem
            var mountpoint = session.userMount ?? ""
            if !session.exposedBSD.isEmpty,
               let resolved = try? resolveFilesystemDevice(session.exposedBSD) {
                switch resolved.magic {
                case "EXFAT": filesystem = "ExFAT"
                case "NTFS": filesystem = "NTFS"
                case "FAT":
                    filesystem = session.partitionType == EDPPartitionKind.boot.rawValue
                        ? "FAT16 (read-only)"
                        : "FAT"
                default: filesystem = "Unformatted or unsupported"
                }
                mountpoint = EDPNativeMountTable.mountPoint(forBSD: resolved.bsdName) ?? ""
                if session.partitionType != EDPPartitionKind.boot.rawValue,
                   !mountpoint.isEmpty,
                   EDPNativeMountTable.isReadOnly(mountpoint) == true {
                    filesystem += " (read-only; Finder erasable)"
                }
            }
            return [
                "filesystem": filesystem,
                "mountpoint": mountpoint,
                "exposedBSD": session.exposedBSD,
            ]
        }
    }

    func mountAsync(
        disk: PhysicalDisk,
        partitionType: UInt32,
        password: [UInt8],
        rawFD: Int32,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        let sessionKey = key(disk, partitionType)
        let operation = EDPFSKitMountOperationBox(
            sessionKey: sessionKey,
            disk: disk,
            partitionType: partitionType,
            password: password,
            rawFD: rawFD,
            journalContext: EDPLifecycleOperationContext(
                operation: "mount",
                deviceID: disk.deviceID,
                partitionType: partitionType,
                startedAtNanoseconds: scheduler.nowNanoseconds
            ),
            completion: completion
        )
        lifecycleQueue.async { [weak self, operation] in
            guard let self else {
                completion("mount manager was released")
                return
            }
            self.recordMountJournal(operation, event: "request")
            if self.sessions[sessionKey] != nil {
                self.recordMountJournal(
                    operation,
                    event: "alreadyMounted",
                    ownedResources: ["transport", "publication", "filesystem"]
                )
                completion(nil)
                return
            }
            if self.activeMountOperations.contains(sessionKey) {
                self.recordMountJournal(operation, event: "singleFlightJoined")
                self.mountWaiters[sessionKey, default: []].append(completion)
                return
            }
            self.activeMountOperations.insert(sessionKey)
            self.activeMountOperationBoxes[sessionKey] = operation
            self.cancelledMountOperations.remove(sessionKey)
            self.startMountOperationWhenQuiescent(operation)
        }
    }

    private func startMountOperationWhenQuiescent(_ operation: EDPFSKitMountOperationBox) {
        guard !operation.finished,
              activeMountOperationBoxes[operation.sessionKey] === operation else {
            return
        }
        if cancelledMountOperations.contains(operation.sessionKey) {
            executeMountAction(operation.machine.cancel(), operation: operation)
            return
        }
        if remountQuiescence.activeToken(for: operation.sessionKey) != nil {
            let remaining = remountQuiescence.remainingDelay(
                for: operation.sessionKey,
                nowNanoseconds: scheduler.nowNanoseconds
            ) ?? 0
            if !operation.quiescenceWaitRecorded {
                operation.quiescenceWaitRecorded = true
                recordMountJournal(
                    operation,
                    event: "remountQuiescenceWait"
                )
            }
            scheduler.schedule(
                on: lifecycleQueue,
                after: max(remaining, 0.05)
            ) { [weak self, operation] in
                self?.startMountOperationWhenQuiescent(operation)
            }
            return
        }
        let action = operation.machine.start()
        recordMountJournal(operation, event: "started")
        executeMountAction(action, operation: operation)
    }

    private func recordMountJournal(
        _ operation: EDPFSKitMountOperationBox,
        event: String,
        ownedResources: [String] = [],
        diagnosticCode: EDPLifecycleFailureCode? = nil
    ) {
        let state: String
        let attempt: Int?
        switch operation.machine.state {
        case .idle:
            state = "idle"
            attempt = nil
        case .preparing(let value):
            state = "preparing"
            attempt = value
        case .waitingForBridge(let value):
            state = "waitingForBridge"
            attempt = value
        case .cleaningUp(let value, _, _):
            state = "cleaningUp"
            attempt = value
        case .recoveringHost(let value, _):
            state = "recoveringHost"
            attempt = value
        case .publishing(let value):
            state = "publishing"
            attempt = value
        case .mountingFilesystem(let value):
            state = "mountingFilesystem"
            attempt = value
        case .mounted:
            state = "mounted"
            attempt = nil
        case .failed:
            state = "failed"
            attempt = nil
        }
        journal.record(
            context: operation.journalContext,
            scheduler: scheduler,
            state: state,
            event: event,
            attempt: attempt,
            recoveryBudget: operation.machine.recoveryBudget,
            ownedResources: ownedResources,
            diagnosticCode: diagnosticCode?.rawValue
        )
    }

    private func recoverFSKitHostIfSafe() -> Bool {
        metrics.increment(.fskitAgentRecovery)
        return EDPFSKitHostRecovery.restartConsoleAgentIfSafe()
    }

    private func cancelMountOperation(_ sessionKey: String) {
        cancelledMountOperations.insert(sessionKey)
        if let operation = activeMountOperationBoxes[sessionKey] {
            recordMountJournal(operation, event: "cancelRequested")
            operation.publicationOperation?.cancel()
        }
    }

    private func executeMountAction(
        _ action: EDPFSKitMountLifecycleAction,
        operation: EDPFSKitMountOperationBox
    ) {
        guard !operation.finished else { return }
        switch action {
        case .launchAttempt(let attempt):
            launchMountAttempt(operation, attempt: attempt)
        case .fail(let failure):
            recordMountJournal(
                operation,
                event: "terminalFailure",
                diagnosticCode: failure.code
            )
            finishMountOperation(operation, error: failure)
        case .complete:
            recordMountJournal(
                operation,
                event: "terminalSuccess",
                ownedResources: ["transport", "publication", "filesystem"]
            )
            finishMountOperation(operation, error: nil)
        case .waitForBridge, .cleanup, .restartHost, .publish, .mountFilesystem:
            break
        }
    }

    private func launchMountAttempt(
        _ operation: EDPFSKitMountOperationBox,
        attempt: Int
    ) {
        if attempt > 0 {
            metrics.increment(.mountRetry)
        }
        recordMountJournal(operation, event: "launchAttempt")
        if cancelledMountOperations.contains(operation.sessionKey) {
            executeMountAction(operation.machine.cancel(), operation: operation)
            return
        }

        do {
            let runtimeStatus = try EDPTransportRuntimePolicy.verifySelectedRuntime(
                requireFinderHidden: true
            )
            let disk = operation.disk
            let partitionType = operation.partitionType
            let generation = String(
                operation.journalContext.id.uuidString.lowercased().prefix(8)
            )
            let suffix = safeName(disk.deviceID) + "-\(partitionType)-\(generation)-\(attempt)"
            let bridgeMount = "/Volumes/.edp-block-\(suffix)"
            let identity = try consoleIdentity()

            if EDPNativeMountTable.isMountpoint(bridgeMount) {
                try? EDPNativeMountTable.unmountPath(bridgeMount)
                if EDPNativeMountTable.isMountpoint(bridgeMount) {
                    try EDPNativeMountTable.unmountPath(bridgeMount, force: true)
                }
            }
            try? FileManager.default.removeItem(atPath: bridgeMount)
            try FileManager.default.createDirectory(
                atPath: bridgeMount,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: mode_t(0o700))]
            )
            guard chown(bridgeMount, identity.0, identity.1) == 0 else {
                throw fail("cannot assign block-transport mountpoint to console user: errno=\(errno)")
            }

            let continueLaunch: @Sendable () -> Void = { [weak self, operation] in
                guard let self else { return }
                self.lifecycleQueue.async {
                    self.startTransportAttempt(
                        operation,
                        attempt: attempt,
                        runtimeStatus: runtimeStatus,
                        identity: identity,
                        suffix: suffix,
                        bridgeMount: bridgeMount
                    )
                }
            }

            guard EDPNativeMountTable.hasMountedBSDPrefix(disk.bsdName) else {
                continueLaunch()
                return
            }
            diskArbitration.unmountWholeAsync(
                disk.bsdName,
                expectedRegistryEntryID: disk.registryEntryID
            ) { [weak self, operation] error in
                guard let self else { return }
                self.lifecycleQueue.async {
                    guard !self.cancelledMountOperations.contains(operation.sessionKey) else {
                        self.executeMountAction(operation.machine.cancel(), operation: operation)
                        return
                    }
                    if let error {
                        self.executeMountAction(
                            operation.machine.stageFailed(EDPLifecycleFailure(
                                code: .teardownFailed,
                                detail: String(describing: error)
                            )),
                            operation: operation
                        )
                        return
                    }
                    continueLaunch()
                }
            }
        } catch {
            let failure = EDPLifecycleFailure(
                code: .bridgeLaunchFailed,
                detail: String(describing: error)
            )
            executeMountAction(operation.machine.stageFailed(failure), operation: operation)
        }
    }

    private func startTransportAttempt(
        _ operation: EDPFSKitMountOperationBox,
        attempt: Int,
        runtimeStatus: EDPTransportRuntimeStatus,
        identity: (uid_t, gid_t),
        suffix: String,
        bridgeMount: String
    ) {
        guard !cancelledMountOperations.contains(operation.sessionKey) else {
            executeMountAction(operation.machine.cancel(), operation: operation)
            return
        }
        do {
            let disk = operation.disk
            let partitionType = operation.partitionType
            let volumeName = "EDP \(partitionType == 1 ? "Boot" : (partitionType == 2 ? "Exchange" : "Secure")) Transport"
            let transportRequest = EDPTransportRequest(
                binaryRoot: binaryRoot,
                rawDevice: disk.rawPath,
                rawFD: 3,
                vid: disk.vidHex,
                pid: disk.pidHex,
                deviceSize: disk.sizeBytes,
                partitionType: partitionType,
                controlFD: 0,
                mountpoint: bridgeMount,
                volumeName: volumeName,
                readOnly: partitionType == EDPPartitionKind.boot.rawValue
            )
            let launchSpec = try EDPTransportProvider.launchSpec(
                for: runtimeStatus.backend,
                request: transportRequest,
                requireFinderHidden: true
            )
            if runtimeStatus.backend == .macFUSELocal {
                EDPMacFUSEScratchImageCleanup.captureBaselineAsync { [weak self, operation] baseline in
                    guard let self else { return }
                    self.lifecycleQueue.async {
                        guard !self.cancelledMountOperations.contains(operation.sessionKey) else {
                            self.executeMountAction(operation.machine.cancel(), operation: operation)
                            return
                        }
                        self.launchTransportProcess(
                            operation,
                            attempt: attempt,
                            runtimeStatus: runtimeStatus,
                            identity: identity,
                            suffix: suffix,
                            bridgeMount: bridgeMount,
                            launchSpec: launchSpec,
                            scratchBaseline: baseline
                        )
                    }
                }
                return
            }
            launchTransportProcess(
                operation,
                attempt: attempt,
                runtimeStatus: runtimeStatus,
                identity: identity,
                suffix: suffix,
                bridgeMount: bridgeMount,
                launchSpec: launchSpec,
                scratchBaseline: nil
            )
        } catch {
            executeMountAction(
                operation.machine.stageFailed(EDPLifecycleFailure(
                    code: .bridgeLaunchFailed,
                    detail: String(describing: error)
                )),
                operation: operation
            )
        }
    }

    private func launchTransportProcess(
        _ operation: EDPFSKitMountOperationBox,
        attempt: Int,
        runtimeStatus: EDPTransportRuntimeStatus,
        identity: (uid_t, gid_t),
        suffix: String,
        bridgeMount: String,
        launchSpec: EDPTransportLaunchSpec,
        scratchBaseline: Set<String>?
    ) {
        guard !cancelledMountOperations.contains(operation.sessionKey) else {
            executeMountAction(operation.machine.cancel(), operation: operation)
            return
        }
        recordMountJournal(operation, event: "bridgeLaunchStarted")
        do {
            let passwordPipe = Pipe()
            let logPath = sessionRoot + "/\(suffix).bridge.log"
            try FileManager.default.createDirectory(atPath: sessionRoot, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: logPath, contents: nil)
            let log = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
            var environment = ProcessInfo.processInfo.environment
            environment["DYLD_LIBRARY_PATH"] = binaryRoot
            for (key, value) in launchSpec.environment { environment[key] = value }
            let transportProcess = try spawnConsoleTransport(
                binaryRoot: binaryRoot,
                identity: identity,
                executable: launchSpec.executable,
                arguments: launchSpec.arguments,
                environment: environment,
                rawFD: operation.rawFD,
                stdinFD: passwordPipe.fileHandleForReading.fileDescriptor,
                logFD: log.fileDescriptor
            )
            try passwordPipe.fileHandleForReading.close()
            passwordPipe.fileHandleForWriting.write(Data(operation.password))
            try passwordPipe.fileHandleForWriting.close()

            let transportSession = EDPTransportSession(
                backend: runtimeStatus.backend,
                mountpoint: bridgeMount,
                capabilities: launchSpec.capabilities,
                process: transportProcess,
                scheduler: scheduler
            )
            _ = operation.machine.attemptLaunched(attempt)
            recordMountJournal(
                operation,
                event: "bridgeWaitStarted",
                ownedResources: ["transport"]
            )
            pollBridgeActivation(
                operation,
                attempt: attempt,
                runtimeStatus: runtimeStatus,
                identity: identity,
                suffix: suffix,
                bridgeMount: bridgeMount,
                log: log,
                logPath: logPath,
                scratchBaseline: scratchBaseline,
                transportSession: transportSession,
                deadline: scheduler.deadline(after: 8)
            )
        } catch {
            executeMountAction(
                operation.machine.stageFailed(EDPLifecycleFailure(
                    code: .bridgeLaunchFailed,
                    detail: String(describing: error)
                )),
                operation: operation
            )
        }
    }

    private func pollBridgeActivation(
        _ operation: EDPFSKitMountOperationBox,
        attempt: Int,
        runtimeStatus: EDPTransportRuntimeStatus,
        identity: (uid_t, gid_t),
        suffix: String,
        bridgeMount: String,
        log: FileHandle,
        logPath: String,
        scratchBaseline: Set<String>?,
        transportSession: EDPTransportSession,
        deadline: UInt64
    ) {
        if cancelledMountOperations.contains(operation.sessionKey) {
            let action = operation.machine.cancel()
            if case .cleanup(_, let allowHostRecoveryDuringStop) = action {
                cleanupMountAttempt(
                    operation,
                    attempt: attempt,
                    runtimeStatus: runtimeStatus,
                    bridgeMount: bridgeMount,
                    scratchBaseline: scratchBaseline,
                    transportSession: transportSession,
                    publishedDevice: nil,
                    allowHostRecoveryDuringStop: allowHostRecoveryDuringStop,
                    failure: .cancelled
                )
            } else {
                executeMountAction(action, operation: operation)
            }
            return
        }

        let bridgeMounted = EDPNativeMountTable.isMountpoint(bridgeMount)
        if bridgeMounted && transportSession.isRunning {
            _ = operation.machine.bridgeActivated(attempt)
            recordMountJournal(
                operation,
                event: "bridgeReady",
                ownedResources: ["transport"]
            )
            continueMountedBridge(
                operation,
                attempt: attempt,
                runtimeStatus: runtimeStatus,
                identity: identity,
                suffix: suffix,
                bridgeMount: bridgeMount,
                logPath: logPath,
                scratchBaseline: scratchBaseline,
                transportSession: transportSession
            )
            return
        }

        if !transportSession.isRunning {
            try? log.synchronize()
            let detail = bridgeLogTail(logPath)
            var failure = EDPLifecycleFailure.classifyBridgeActivation(
                timedOut: false,
                logDetail: detail
            )
            if detail?.isEmpty != false {
                failure = EDPLifecycleFailure(
                    code: failure.code,
                    detail: failure.detail + "; see \(logPath)"
                )
            }
            let recoverable = EDPFSKitMountRecoveryPolicy.shouldRecoverBridgeActivation(
                failure: failure,
                transportStillRunning: false,
                bridgeMounted: bridgeMounted
            )
            recordMountJournal(
                operation,
                event: "bridgeFailure",
                ownedResources: ["transport"],
                diagnosticCode: failure.code
            )
            failBridgeAttempt(
                operation,
                attempt: attempt,
                runtimeStatus: runtimeStatus,
                bridgeMount: bridgeMount,
                logPath: logPath,
                scratchBaseline: scratchBaseline,
                transportSession: transportSession,
                publishedDevice: nil,
                recoverable: recoverable,
                failure: failure
            )
            return
        }

        if scheduler.hasReached(deadline) {
            let failure = EDPLifecycleFailure.classifyBridgeActivation(
                timedOut: true,
                logDetail: nil
            )
            let recoverable = EDPFSKitMountRecoveryPolicy.shouldRecoverBridgeActivation(
                failure: failure,
                transportStillRunning: transportSession.isRunning,
                bridgeMounted: bridgeMounted
            )
            recordMountJournal(
                operation,
                event: "bridgeFailure",
                ownedResources: ["transport"],
                diagnosticCode: failure.code
            )
            failBridgeAttempt(
                operation,
                attempt: attempt,
                runtimeStatus: runtimeStatus,
                bridgeMount: bridgeMount,
                logPath: logPath,
                scratchBaseline: scratchBaseline,
                transportSession: transportSession,
                publishedDevice: nil,
                recoverable: recoverable,
                failure: failure
            )
            return
        }

        scheduler.schedule(on: lifecycleQueue, after: 0.1) { [weak self, operation] in
            self?.pollBridgeActivation(
                operation,
                attempt: attempt,
                runtimeStatus: runtimeStatus,
                identity: identity,
                suffix: suffix,
                bridgeMount: bridgeMount,
                log: log,
                logPath: logPath,
                scratchBaseline: scratchBaseline,
                transportSession: transportSession,
                deadline: deadline
            )
        }
    }

    private func continueMountedBridge(
        _ operation: EDPFSKitMountOperationBox,
        attempt: Int,
        runtimeStatus: EDPTransportRuntimeStatus,
        identity: (uid_t, gid_t),
        suffix: String,
        bridgeMount: String,
        logPath: String,
        scratchBaseline: Set<String>?,
        transportSession: EDPTransportSession
    ) {
        if cancelledMountOperations.contains(operation.sessionKey) {
            let action = operation.machine.cancel()
            if case .cleanup(_, let allowHostRecoveryDuringStop) = action {
                cleanupMountAttempt(
                    operation,
                    attempt: attempt,
                    runtimeStatus: runtimeStatus,
                    bridgeMount: bridgeMount,
                    scratchBaseline: scratchBaseline,
                    transportSession: transportSession,
                    publishedDevice: nil,
                    allowHostRecoveryDuringStop: allowHostRecoveryDuringStop,
                    failure: .cancelled
                )
            } else {
                executeMountAction(action, operation: operation)
            }
            return
        }

        let decryptedVolume = bridgeMount + "/volume.raw"
        recordMountJournal(
            operation,
            event: "publicationStarted",
            ownedResources: ["transport"]
        )
        operation.publicationOperation = blockPublisher.publishWritableImageAsync(
            at: decryptedVolume
        ) { [weak self, operation] published, errorMessage in
            guard let self else { return }
            self.lifecycleQueue.async {
                operation.publicationOperation = nil
                let cancelled = self.cancelledMountOperations.contains(operation.sessionKey)
                guard let published else {
                    let failure = cancelled
                        ? EDPLifecycleFailure.cancelled
                        : EDPLifecycleFailure(
                            code: .publicationFailed,
                            detail: errorMessage ?? "block publication returned no device"
                        )
                    self.recordMountJournal(
                        operation,
                        event: cancelled ? "publicationCancelled" : "publicationFailure",
                        ownedResources: ["transport"],
                        diagnosticCode: failure.code
                    )
                    self.cleanupPublishedMount(
                        operation,
                        attempt: attempt,
                        runtimeStatus: runtimeStatus,
                        bridgeMount: bridgeMount,
                        scratchBaseline: scratchBaseline,
                        transportSession: transportSession,
                        publishedDevice: nil,
                        failure: failure,
                        cancelled: cancelled
                    )
                    return
                }

                guard !cancelled else {
                    // Publication won the cancellation race. Tear down that exact
                    // backing/device tuple before transport cleanup continues.
                    self.recordMountJournal(
                        operation,
                        event: "publicationCancelled",
                        ownedResources: ["transport", "publication"],
                        diagnosticCode: .cancelled
                    )
                    self.recordMountJournal(
                        operation,
                        event: "publicationTeardownStarted",
                        ownedResources: ["transport", "publication"]
                    )
                    self.blockPublisher.unpublishAsync(published) { [weak self, operation] unpublishError in
                        guard let self else { return }
                        self.lifecycleQueue.async {
                            if let unpublishError {
                                NSLog("EDP cancelled publication teardown: %@", unpublishError)
                            }
                            self.recordMountJournal(
                                operation,
                                event: unpublishError == nil
                                    ? "publicationTeardownComplete"
                                    : "publicationTeardownFailure",
                                ownedResources: unpublishError == nil
                                    ? ["transport"]
                                    : ["transport", "publication"],
                                diagnosticCode: unpublishError == nil ? nil : .teardownFailed
                            )
                            self.cleanupPublishedMount(
                                operation,
                                attempt: attempt,
                                runtimeStatus: runtimeStatus,
                                bridgeMount: bridgeMount,
                                scratchBaseline: scratchBaseline,
                                transportSession: transportSession,
                                publishedDevice: unpublishError == nil ? nil : published,
                                failure: .cancelled,
                                cancelled: true
                            )
                        }
                    }
                    return
                }

                _ = operation.machine.publicationFinished(attempt)
                self.recordMountJournal(
                    operation,
                    event: "publicationComplete",
                    ownedResources: ["transport", "publication"]
                )
                self.recordMountJournal(
                    operation,
                    event: "filesystemMountStarted",
                    ownedResources: ["transport", "publication"]
                )
                do {
                    let resolved = try resolveFilesystemDevice(published.bsdName)
                    self.mountResolvedFilesystemAsync(
                        bsd: resolved.bsdName,
                        magic: resolved.magic,
                        isBoot: operation.partitionType == EDPPartitionKind.boot.rawValue,
                        sessionSuffix: suffix,
                        owner: identity
                    ) { [weak self, operation] filesystem, mountpoint, filesystemError in
                        guard let self else { return }
                        self.lifecycleQueue.async {
                            let cancelled = self.cancelledMountOperations.contains(operation.sessionKey)
                            if cancelled, let mountpoint {
                                try? EDPNativeMountTable.unmountPath(mountpoint, force: true)
                            }
                            if cancelled || filesystemError != nil {
                                let failure = cancelled
                                    ? EDPLifecycleFailure.cancelled
                                    : EDPLifecycleFailure(
                                        code: .filesystemMountFailed,
                                        detail: filesystemError ?? "filesystem mount failed"
                                    )
                                self.recordMountJournal(
                                    operation,
                                    event: cancelled ? "filesystemMountCancelled" : "filesystemMountFailure",
                                    ownedResources: ["transport", "publication"],
                                    diagnosticCode: failure.code
                                )
                                self.cleanupPublishedMount(
                                    operation,
                                    attempt: attempt,
                                    runtimeStatus: runtimeStatus,
                                    bridgeMount: bridgeMount,
                                    scratchBaseline: scratchBaseline,
                                    transportSession: transportSession,
                                    publishedDevice: published,
                                    failure: failure,
                                    cancelled: cancelled
                                )
                                return
                            }
                            guard let filesystem else {
                                let failure = EDPLifecycleFailure(
                                    code: .filesystemMountFailed,
                                    detail: "filesystem mount returned no result"
                                )
                                self.recordMountJournal(
                                    operation,
                                    event: "filesystemMountFailure",
                                    ownedResources: ["transport", "publication"],
                                    diagnosticCode: failure.code
                                )
                                self.cleanupPublishedMount(
                                    operation,
                                    attempt: attempt,
                                    runtimeStatus: runtimeStatus,
                                    bridgeMount: bridgeMount,
                                    scratchBaseline: scratchBaseline,
                                    transportSession: transportSession,
                                    publishedDevice: published,
                                    failure: failure,
                                    cancelled: false
                                )
                                return
                            }
                            self.sessions[operation.sessionKey] = MountSession(
                                physicalBSD: operation.disk.bsdName,
                                deviceID: operation.disk.deviceID,
                                partitionType: operation.partitionType,
                                bridgeMount: bridgeMount,
                                exposedBSD: published.bsdName,
                                filesystem: filesystem,
                                userMount: mountpoint,
                                transport: transportSession,
                                filesystemProcess: nil
                            )
                            self.persistSessions()
                            _ = operation.machine.filesystemMounted(attempt)
                            self.recordMountJournal(
                                operation,
                                event: "filesystemMountComplete",
                                ownedResources: ["transport", "publication", "filesystem"]
                            )
                            NSLog(
                                "EDP mounted %@ partition %u as %@ at %@",
                                operation.disk.deviceID,
                                operation.partitionType,
                                filesystem,
                                mountpoint ?? "(unknown)"
                            )
                            self.executeMountAction(.complete, operation: operation)
                        }
                    }
                } catch {
                    let failure = EDPLifecycleFailure(
                        code: .filesystemMountFailed,
                        detail: String(describing: error)
                    )
                    self.recordMountJournal(
                        operation,
                        event: "filesystemMountFailure",
                        ownedResources: ["transport", "publication"],
                        diagnosticCode: failure.code
                    )
                    self.cleanupPublishedMount(
                        operation,
                        attempt: attempt,
                        runtimeStatus: runtimeStatus,
                        bridgeMount: bridgeMount,
                        scratchBaseline: scratchBaseline,
                        transportSession: transportSession,
                        publishedDevice: published,
                        failure: failure,
                        cancelled: false
                    )
                }
            }
        }
    }

    private func cleanupPublishedMount(
        _ operation: EDPFSKitMountOperationBox,
        attempt: Int,
        runtimeStatus: EDPTransportRuntimeStatus,
        bridgeMount: String,
        scratchBaseline: Set<String>?,
        transportSession: EDPTransportSession,
        publishedDevice: EDPPublishedBlockDevice?,
        failure: EDPLifecycleFailure,
        cancelled: Bool
    ) {
        let action = cancelled ? operation.machine.cancel() : operation.machine.stageFailed(failure)
        if case .cleanup(_, let allowHostRecoveryDuringStop) = action {
            cleanupMountAttempt(
                operation,
                attempt: attempt,
                runtimeStatus: runtimeStatus,
                bridgeMount: bridgeMount,
                scratchBaseline: scratchBaseline,
                transportSession: transportSession,
                publishedDevice: publishedDevice,
                allowHostRecoveryDuringStop: allowHostRecoveryDuringStop,
                failure: cancelled ? .cancelled : failure
            )
        } else {
            executeMountAction(action, operation: operation)
        }
    }

    private func mountResolvedFilesystemAsync(
        bsd: String,
        magic: String,
        isBoot: Bool,
        sessionSuffix: String,
        owner: (uid_t, gid_t),
        completion: @escaping @Sendable (String?, String?, String?) -> Void
    ) {
        if isBoot, magic == "FAT" {
            mountFATReadOnlyAsync(bsd, owner: owner) { mountpoint, errorMessage in
                if let errorMessage {
                    completion(nil, nil, errorMessage)
                    return
                }
                completion("FAT16 (read-only)", mountpoint, nil)
            }
            return
        }

        guard ["EXFAT", "NTFS", "FAT"].contains(magic) else {
            completion("Unformatted or unsupported", nil, nil)
            return
        }

        prepareFinderDefaultsAsync(
            bsd: bsd,
            sessionSuffix: sessionSuffix,
            owner: owner
        ) { [weak self] stagingError in
            guard let self else {
                completion(nil, nil, "mount manager was released")
                return
            }
            self.lifecycleQueue.async {
                if let stagingError {
                    completion(nil, nil, stagingError)
                    return
                }
                self.diskArbitration.mountAsync(bsd) { [weak self] mountpoint, error in
                    guard let self else {
                        completion(nil, nil, "mount manager was released")
                        return
                    }
                    self.lifecycleQueue.async {
                        if let error {
                            completion(nil, nil, String(describing: error))
                            return
                        }
                        guard let mountpoint else {
                            completion(nil, nil, "Disk Arbitration returned no mount point")
                            return
                        }
                        switch magic {
                        case "EXFAT":
                            guard EDPNativeMountTable.isReadOnly(mountpoint) == false else {
                                completion(nil, mountpoint, "native ExFAT mounted read-only")
                                return
                            }
                            completion("ExFAT", mountpoint, nil)
                        case "NTFS":
                            completion(
                                EDPNativeMountTable.isReadOnly(mountpoint) == true
                                    ? "NTFS (read-only; Finder erasable)"
                                    : "NTFS",
                                mountpoint,
                                nil
                            )
                        case "FAT":
                            completion("FAT", mountpoint, nil)
                        default:
                            completion("Unformatted or unsupported", nil, nil)
                        }
                    }
                }
            }
        }
    }

    private func failBridgeAttempt(
        _ operation: EDPFSKitMountOperationBox,
        attempt: Int,
        runtimeStatus: EDPTransportRuntimeStatus,
        bridgeMount: String,
        logPath: String,
        scratchBaseline: Set<String>?,
        transportSession: EDPTransportSession,
        publishedDevice: EDPPublishedBlockDevice?,
        recoverable: Bool,
        failure: EDPLifecycleFailure
    ) {
        let action = operation.machine.bridgeFailed(
            attempt,
            recoverable: recoverable,
            failure: failure
        )
        guard case .cleanup(_, let allowHostRecoveryDuringStop) = action else {
            executeMountAction(action, operation: operation)
            return
        }
        cleanupMountAttempt(
            operation,
            attempt: attempt,
            runtimeStatus: runtimeStatus,
            bridgeMount: bridgeMount,
            scratchBaseline: scratchBaseline,
            transportSession: transportSession,
            publishedDevice: publishedDevice,
            allowHostRecoveryDuringStop: allowHostRecoveryDuringStop,
            failure: failure
        )
    }

    private func cleanupMountAttempt(
        _ operation: EDPFSKitMountOperationBox,
        attempt: Int,
        runtimeStatus: EDPTransportRuntimeStatus,
        bridgeMount: String,
        scratchBaseline: Set<String>?,
        transportSession: EDPTransportSession,
        publishedDevice: EDPPublishedBlockDevice?,
        allowHostRecoveryDuringStop: Bool,
        failure: EDPLifecycleFailure
    ) {
        recordMountJournal(
            operation,
            event: "cleanupStarted",
            ownedResources: publishedDevice == nil
                ? ["transport"]
                : ["transport", "publication"],
            diagnosticCode: failure.code
        )
        guard let publishedDevice else {
            stopTransportAfterMountCleanup(
                operation,
                attempt: attempt,
                runtimeStatus: runtimeStatus,
                bridgeMount: bridgeMount,
                scratchBaseline: scratchBaseline,
                transportSession: transportSession,
                allowHostRecoveryDuringStop: allowHostRecoveryDuringStop,
                failure: failure
            )
            return
        }
        recordMountJournal(
            operation,
            event: "publicationTeardownStarted",
            ownedResources: ["transport", "publication"]
        )
        blockPublisher.unpublishAsync(publishedDevice) { [weak self, operation] unpublishError in
            guard let self else { return }
            self.lifecycleQueue.async {
                if let unpublishError {
                    NSLog("EDP async publication cleanup after %@: %@", failure.description, unpublishError)
                }
                self.recordMountJournal(
                    operation,
                    event: unpublishError == nil
                        ? "publicationTeardownComplete"
                        : "publicationTeardownFailure",
                    ownedResources: unpublishError == nil
                        ? ["transport"]
                        : ["transport", "publication"],
                    diagnosticCode: unpublishError == nil ? nil : .teardownFailed
                )
                self.stopTransportAfterMountCleanup(
                    operation,
                    attempt: attempt,
                    runtimeStatus: runtimeStatus,
                    bridgeMount: bridgeMount,
                    scratchBaseline: scratchBaseline,
                    transportSession: transportSession,
                    allowHostRecoveryDuringStop: allowHostRecoveryDuringStop,
                    failure: failure
                )
            }
        }
    }

    private func stopTransportAfterMountCleanup(
        _ operation: EDPFSKitMountOperationBox,
        attempt: Int,
        runtimeStatus: EDPTransportRuntimeStatus,
        bridgeMount: String,
        scratchBaseline: Set<String>?,
        transportSession: EDPTransportSession,
        allowHostRecoveryDuringStop: Bool,
        failure: EDPLifecycleFailure
    ) {
        let recoverStuckProcess: (() -> Bool)? = allowHostRecoveryDuringStop
            ? { [weak self, operation] in
                guard let self,
                      !self.cancelledMountOperations.contains(operation.sessionKey) else {
                    return false
                }
                self.recordMountJournal(
                    operation,
                    event: "hostRecoveryStarted",
                    ownedResources: ["transport"]
                )
                let recovered = self.recoverFSKitHostIfSafe()
                self.recordMountJournal(
                    operation,
                    event: recovered ? "hostRecoveryComplete" : "hostRecoveryFailure",
                    ownedResources: ["transport"],
                    diagnosticCode: recovered ? nil : .teardownFailed
                )
                return recovered
            }
            : nil

        recordMountJournal(
            operation,
            event: "transportTeardownStarted",
            ownedResources: ["transport"]
        )
        transportSession.stopAsync(
            on: lifecycleQueue,
            unmount: { try EDPNativeMountTable.unmountPath($0, force: true) },
            isMounted: { EDPNativeMountTable.isMountpoint($0) },
            recoverStuckProcess: recoverStuckProcess
        ) { [weak self, operation] stopRecoveredHost, hostRecoveryAttempted, stopError in
            guard let self else { return }
            let finishCleanup: @Sendable () -> Void = { [weak self, operation] in
                guard let self else { return }
                self.lifecycleQueue.async {
                    self.finalizeStoppedTransportCleanup(
                        operation,
                        attempt: attempt,
                        bridgeMount: bridgeMount,
                        transportSession: transportSession,
                        stopRecoveredHost: stopRecoveredHost,
                        hostRecoveryAttempted: hostRecoveryAttempted,
                        stopError: stopError,
                        failure: failure
                    )
                }
            }
            if runtimeStatus.backend == .macFUSELocal {
                self.metrics.increment(.diskImagesAttachRecovery)
                EDPMacFUSEScratchImageCleanup.cleanupNewOrphansAsync(
                    since: scratchBaseline,
                    completion: finishCleanup
                )
            } else {
                finishCleanup()
            }
        }
    }

    private func finalizeStoppedTransportCleanup(
        _ operation: EDPFSKitMountOperationBox,
        attempt: Int,
        bridgeMount: String,
        transportSession: EDPTransportSession,
        stopRecoveredHost: Bool,
        hostRecoveryAttempted: Bool,
        stopError: String?,
        failure: EDPLifecycleFailure
    ) {
        try? FileManager.default.removeItem(atPath: bridgeMount)
        if let stopError {
            NSLog("EDP async transport cleanup after %@: %@", failure.description, stopError)
        }
        recordMountJournal(
            operation,
            event: stopError == nil ? "transportTeardownComplete" : "transportTeardownFailure",
            diagnosticCode: stopError == nil ? nil : .teardownFailed
        )
        recordMountJournal(
            operation,
            event: "cleanupComplete",
            diagnosticCode: failure.code
        )

        guard stopError == nil, !transportSession.isRunning else {
            continueStoppedTransportCleanup(
                operation,
                attempt: attempt,
                transportSession: transportSession,
                stopRecoveredHost: stopRecoveredHost,
                hostRecoveryAttempted: hostRecoveryAttempted
            )
            return
        }

        let token = remountQuiescence.begin(
            sessionKey: operation.sessionKey,
            nowNanoseconds: scheduler.nowNanoseconds,
            stabilizationSeconds: remountQuiescenceSeconds
        )
        recordMountJournal(operation, event: "remountQuiescenceStarted")
        scheduler.schedule(
            on: lifecycleQueue,
            after: remountQuiescenceSeconds
        ) { [weak self, operation] in
            guard let self,
                  self.remountQuiescence.complete(token) else {
                return
            }
            self.recordMountJournal(operation, event: "remountQuiescenceComplete")
            self.continueStoppedTransportCleanup(
                operation,
                attempt: attempt,
                transportSession: transportSession,
                stopRecoveredHost: stopRecoveredHost,
                hostRecoveryAttempted: hostRecoveryAttempted
            )
        }
    }

    private func continueStoppedTransportCleanup(
        _ operation: EDPFSKitMountOperationBox,
        attempt: Int,
        transportSession: EDPTransportSession,
        stopRecoveredHost: Bool,
        hostRecoveryAttempted: Bool
    ) {
        if cancelledMountOperations.contains(operation.sessionKey) {
            executeMountAction(operation.machine.cancel(), operation: operation)
            return
        }

        if hostRecoveryAttempted {
            let action = operation.machine.cleanupFinished(
                attempt,
                hostAlreadyRecovered: stopRecoveredHost && !transportSession.isRunning
            )
            if case .restartHost = action {
                // A recovery callback was already attempted by stopAsync. Never
                // consume a second global fskit_agent restart here.
                executeMountAction(
                    operation.machine.hostRecoveryFinished(false),
                    operation: operation
                )
            } else {
                executeMountAction(action, operation: operation)
            }
            return
        }

        let action = operation.machine.cleanupFinished(
            attempt,
            hostAlreadyRecovered: false
        )
        if case .restartHost = action {
            recordMountJournal(operation, event: "hostRecoveryStarted")
            let recovered = recoverFSKitHostIfSafe()
                && !transportSession.isRunning
            recordMountJournal(
                operation,
                event: recovered ? "hostRecoveryComplete" : "hostRecoveryFailure",
                diagnosticCode: recovered ? nil : .teardownFailed
            )
            executeMountAction(
                operation.machine.hostRecoveryFinished(recovered),
                operation: operation
            )
        } else {
            executeMountAction(action, operation: operation)
        }
    }

    private func bridgeLogTail(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).flatMap { data -> String? in
            let tail = data.suffix(4096)
            return String(data: tail, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func finishMountOperation(
        _ operation: EDPFSKitMountOperationBox,
        error: EDPLifecycleFailure?
    ) {
        guard !operation.finished else { return }
        operation.finished = true
        activeMountOperations.remove(operation.sessionKey)
        activeMountOperationBoxes.removeValue(forKey: operation.sessionKey)
        if error != nil {
            operation.publicationOperation?.cancel()
        }
        operation.publicationOperation = nil
        cancelledMountOperations.remove(operation.sessionKey)
        let waiters = mountWaiters.removeValue(forKey: operation.sessionKey) ?? []
        if let error {
            lastMountFailureCodes[operation.sessionKey] = error.code
        } else {
            lastMountFailureCodes.removeValue(forKey: operation.sessionKey)
        }
        let message = error?.description
        operation.completion(message)
        for callback in waiters { callback(message) }
    }

    private func prepareFinderDefaultsAsync(
        bsd: String,
        sessionSuffix: String,
        owner: (uid_t, gid_t),
        completion: @escaping EDPBlockDeviceCompletion
    ) {
        let safeSuffix = String(sessionSuffix.prefix(48))
        let stagingMount = "/private/tmp/.edp-finder-seed-\(safeSuffix)-\(UUID().uuidString)"
        do {
            try FileManager.default.createDirectory(
                atPath: stagingMount,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: mode_t(0o700))]
            )
        } catch {
            NSLog(
                "EDP could not create Finder staging mount for %@; continuing without defaults: %@",
                bsd,
                String(describing: error)
            )
            completion(nil)
            return
        }

        let finish: @Sendable (String?) -> Void = { errorMessage in
            try? FileManager.default.removeItem(atPath: stagingMount)
            completion(errorMessage)
        }

        diskArbitration.mountNobrowseAsync(bsd, at: stagingMount) { [weak self] _, error in
            guard let self else {
                finish("mount manager was released")
                return
            }
            self.lifecycleQueue.async {
                if let error {
                    NSLog(
                        "EDP could not stage %@ with nobrowse; continuing with normal mount: %@",
                        bsd,
                        String(describing: error)
                    )
                    finish(nil)
                    return
                }

                do {
                    if try EDPFinderVolumeDefaults.seedIfMissing(at: stagingMount, owner: owner) {
                        NSLog("EDP seeded Finder list/sidebar defaults on %@", bsd)
                    }
                } catch {
                    NSLog(
                        "EDP could not seed Finder defaults on %@; preserving existing volume contents: %@",
                        bsd,
                        String(describing: error)
                    )
                }

                self.diskArbitration.unmountAsync(bsd) { [weak self] firstError in
                    guard let self else {
                        finish("mount manager was released")
                        return
                    }
                    self.lifecycleQueue.async {
                        guard let firstError else {
                            finish(nil)
                            return
                        }
                        self.diskArbitration.unmountAsync(bsd) { secondError in
                            self.lifecycleQueue.async {
                                if EDPNativeMountTable.mountPoint(forBSD: bsd) != nil {
                                    finish(String(describing: secondError ?? firstError))
                                    return
                                }
                                NSLog("EDP Finder staging unmount for %@ recovered after retry", bsd)
                                finish(nil)
                            }
                        }
                    }
                }
            }
        }
    }

    private func mountFATReadOnlyAsync(
        _ bsd: String,
        owner: (uid_t, gid_t),
        completion: @escaping @Sendable (String?, String?) -> Void
    ) {
        let mountpoint = uniqueMountpoint("EDP Boot")
        do {
            try FileManager.default.createDirectory(
                atPath: mountpoint,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: mode_t(0o755))]
            )
            guard chown(mountpoint, owner.0, owner.1) == 0 else {
                throw fail("cannot assign FAT16 mountpoint to console user: errno=\(errno)")
            }
        } catch {
            try? FileManager.default.removeItem(atPath: mountpoint)
            completion(nil, String(describing: error))
            return
        }

        diskArbitration.mountReadOnlyAsync(bsd, at: mountpoint) { [weak self] actual, error in
            guard let self else {
                completion(nil, "mount manager was released")
                return
            }
            self.lifecycleQueue.async {
                guard error == nil,
                      actual == mountpoint,
                      EDPNativeMountTable.isMountpoint(mountpoint),
                      EDPNativeMountTable.isReadOnly(mountpoint) == true else {
                    try? EDPNativeMountTable.unmountPath(mountpoint, force: true)
                    try? FileManager.default.removeItem(atPath: mountpoint)
                    let detail = error.map(String.init(describing:))
                        ?? "Disk Arbitration did not produce the required read-only FAT16 mount"
                    completion(nil, detail)
                    return
                }
                completion(mountpoint, nil)
            }
        }
    }

    @discardableResult
    func removeMissing(availableDisks: [String: String], graceSeconds: TimeInterval = 5) -> Bool {
        lifecycleSync {
            let now = Date()
            var pending = false
            for (sessionKey, session) in Array(sessions) {
                if availableDisks[session.deviceID] == session.physicalBSD {
                    missingSince.removeValue(forKey: sessionKey)
                    continue
                }
                if let since = missingSince[sessionKey], now.timeIntervalSince(since) >= graceSeconds {
                    beginUnmount(sessionKey) { errorMessage in
                        if let errorMessage {
                            NSLog("EDP missing-device teardown failed for %@: %@", sessionKey, errorMessage)
                        }
                    }
                } else {
                    missingSince[sessionKey] = missingSince[sessionKey] ?? now
                    pending = true
                }
            }
            for operationKey in activeMountOperations {
                guard let separator = operationKey.lastIndex(of: ":") else { continue }
                let deviceID = String(operationKey[..<separator])
                if availableDisks[deviceID] == nil {
                    cancelMountOperation(operationKey)
                    pending = true
                }
            }
            return pending
        }
    }

    func unmountAsync(
        deviceID: String,
        partitionType: UInt32,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        let sessionKey = "\(deviceID):\(partitionType)"
        lifecycleQueue.async { [weak self] in
            guard let self else {
                completion("mount manager was released")
                return
            }
            let context = self.makeLifecycleContext(
                operation: "unmount",
                deviceID: deviceID,
                partitionType: partitionType
            )
            self.recordLifecycle(context, state: "requested", event: "request")
            self.requestUnmount(
                sessionKey,
                context: context,
                deadline: self.scheduler.deadline(after: 15),
                waitingRecorded: false,
                completion: completion
            )
        }
    }

    private func requestUnmount(
        _ sessionKey: String,
        context: EDPLifecycleOperationContext,
        deadline: UInt64,
        waitingRecorded: Bool,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        if activeMountOperations.contains(sessionKey) {
            if !waitingRecorded {
                recordLifecycle(
                    context,
                    state: "waitingForMountDrain",
                    event: "cancelActiveMount"
                )
            }
            cancelMountOperation(sessionKey)
            guard !scheduler.hasReached(deadline) else {
                recordLifecycle(
                    context,
                    state: "failed",
                    event: "terminalFailure",
                    diagnosticCode: .teardownFailed
                )
                completion("mount cancellation did not drain before unmount deadline")
                return
            }
            scheduler.schedule(on: lifecycleQueue, after: 0.1) { [weak self] in
                self?.requestUnmount(
                    sessionKey,
                    context: context,
                    deadline: deadline,
                    waitingRecorded: true,
                    completion: completion
                )
            }
            return
        }
        beginUnmount(sessionKey, context: context, completion: completion)
    }

    private func beginUnmount(
        _ sessionKey: String,
        context: EDPLifecycleOperationContext? = nil,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        let journalContext = context
            ?? makeLifecycleContext(operation: "unmount", sessionKey: sessionKey)
        if unmountWaiters[sessionKey] != nil {
            recordLifecycle(
                journalContext,
                state: "coalesced",
                event: "joinedExistingUnmount"
            )
            unmountWaiters[sessionKey, default: []].append(completion)
            return
        }
        guard let session = sessions[sessionKey] else {
            recordLifecycle(journalContext, state: "completed", event: "terminalSuccess")
            completion(nil)
            return
        }
        unmountWaiters[sessionKey] = [completion]
        unmountJournalContexts[sessionKey] = journalContext
        missingSince.removeValue(forKey: sessionKey)

        if let userMount = session.userMount, EDPNativeMountTable.isMountpoint(userMount) {
            guard session.transport.isRunning else {
                recordLifecycle(
                    journalContext,
                    state: "failed",
                    event: "transportUnavailableWithMountedFilesystem",
                    ownedResources: ["filesystem", "publication", "transport"],
                    diagnosticCode: .teardownFailed
                )
                finishUnmount(
                    sessionKey,
                    error: "transport exited while user filesystem remains mounted; refusing synchronous VFS unmount"
                )
                return
            }
            recordLifecycle(
                journalContext,
                state: "tearingDownFilesystem",
                event: "userFilesystemTeardownStarted",
                ownedResources: ["filesystem", "publication", "transport"]
            )
            do {
                try EDPNativeMountTable.unmountPath(userMount)
            } catch {
                finishUnmount(sessionKey, error: String(describing: error))
                return
            }
            guard !EDPNativeMountTable.isMountpoint(userMount) else {
                finishUnmount(
                    sessionKey,
                    error: "user volume remained mounted after unmount: \(userMount)"
                )
                return
            }
            recordLifecycle(
                journalContext,
                state: "quiescingFilesystem",
                event: "userFilesystemTeardownComplete",
                ownedResources: ["publication", "transport"]
            )
            recordLifecycle(
                journalContext,
                state: "quiescingFilesystem",
                event: "nativeFilesystemQuiescenceStarted",
                ownedResources: ["publication", "transport"]
            )
            if remountQuiescenceSeconds > 0 {
                scheduler.schedule(
                    on: lifecycleQueue,
                    after: remountQuiescenceSeconds
                ) { [weak self] in
                    guard let self,
                          self.unmountWaiters[sessionKey] != nil,
                          self.sessions[sessionKey] === session else {
                        return
                    }
                    self.recordLifecycle(
                        journalContext,
                        state: "tearingDownPublication",
                        event: "nativeFilesystemQuiescenceComplete",
                        ownedResources: ["publication", "transport"]
                    )
                    self.continueUnmountAfterNativeFilesystemQuiescence(
                        sessionKey,
                        session: session,
                        journalContext: journalContext
                    )
                }
                return
            }
            recordLifecycle(
                journalContext,
                state: "tearingDownPublication",
                event: "nativeFilesystemQuiescenceComplete",
                ownedResources: ["publication", "transport"]
            )
        }

        continueUnmountAfterNativeFilesystemQuiescence(
            sessionKey,
            session: session,
            journalContext: journalContext
        )
    }

    private func continueUnmountAfterNativeFilesystemQuiescence(
        _ sessionKey: String,
        session: MountSession,
        journalContext: EDPLifecycleOperationContext
    ) {
        session.filesystemProcess?.terminate()
        if !session.exposedBSD.isEmpty {
            recordLifecycle(
                journalContext,
                state: "tearingDownPublication",
                event: "publicationTeardownStarted",
                ownedResources: ["publication", "transport"]
            )
            blockPublisher.unpublishAsync(
                EDPPublishedBlockDevice(
                    bsdName: session.exposedBSD,
                    backingPath: session.bridgeMount + "/volume.raw"
                )
            ) { [weak self] errorMessage in
                guard let self else { return }
                self.lifecycleQueue.async {
                    if let errorMessage {
                        self.recordLifecycle(
                            journalContext,
                            state: "failed",
                            event: "publicationTeardownFailure",
                            ownedResources: ["publication", "transport"],
                            diagnosticCode: .teardownFailed
                        )
                        self.finishUnmount(sessionKey, error: errorMessage)
                        return
                    }
                    self.recordLifecycle(
                        journalContext,
                        state: "tearingDownTransport",
                        event: "publicationTeardownComplete",
                        ownedResources: ["transport"]
                    )
                    self.stopSessionTransport(sessionKey, session: session)
                }
            }
            return
        }

        stopSessionTransport(sessionKey, session: session)
    }

    private func stopSessionTransport(_ sessionKey: String, session: MountSession) {
        if let context = unmountJournalContexts[sessionKey] {
            recordLifecycle(
                context,
                state: "tearingDownTransport",
                event: "transportTeardownStarted",
                ownedResources: ["transport"]
            )
        }
        session.transport.stopAsync(
            on: lifecycleQueue,
            unmount: { try EDPNativeMountTable.unmountPath($0, force: true) },
            isMounted: { EDPNativeMountTable.isMountpoint($0) },
            recoverStuckProcess: { [weak self] in
                self?.recoverFSKitHostIfSafe() ?? false
            }
        ) { [weak self] _, _, errorMessage in
            guard let self else { return }
            if let errorMessage {
                if let context = self.unmountJournalContexts[sessionKey] {
                    self.recordLifecycle(
                        context,
                        state: "failed",
                        event: "transportTeardownFailure",
                        ownedResources: ["transport"],
                        diagnosticCode: .teardownFailed
                    )
                }
                self.finishUnmount(sessionKey, error: errorMessage)
                return
            }
            if let context = self.unmountJournalContexts[sessionKey] {
                self.recordLifecycle(
                    context,
                    state: "finalizing",
                    event: "transportTeardownComplete"
                )
            }
            self.sessions.removeValue(forKey: sessionKey)
            try? FileManager.default.removeItem(atPath: session.bridgeMount)
            self.persistSessions()
            self.beginUnmountQuiescence(sessionKey)
        }
    }

    private func beginUnmountQuiescence(_ sessionKey: String) {
        let token = remountQuiescence.begin(
            sessionKey: sessionKey,
            nowNanoseconds: scheduler.nowNanoseconds,
            stabilizationSeconds: remountQuiescenceSeconds
        )
        if let context = unmountJournalContexts[sessionKey] {
            recordLifecycle(
                context,
                state: "quiescing",
                event: "remountQuiescenceStarted"
            )
        }
        scheduler.schedule(
            on: lifecycleQueue,
            after: remountQuiescenceSeconds
        ) { [weak self] in
            guard let self,
                  self.remountQuiescence.complete(token) else {
                return
            }
            if let context = self.unmountJournalContexts[sessionKey] {
                self.recordLifecycle(
                    context,
                    state: "finalizing",
                    event: "remountQuiescenceComplete"
                )
            }
            self.finishUnmount(sessionKey, error: nil)
        }
    }

    private func finishUnmount(_ sessionKey: String, error: String?) {
        if error != nil { persistSessions() }
        if let context = unmountJournalContexts.removeValue(forKey: sessionKey) {
            recordLifecycle(
                context,
                state: error == nil ? "completed" : "failed",
                event: error == nil ? "terminalSuccess" : "terminalFailure",
                diagnosticCode: error == nil ? nil : .teardownFailed
            )
        }
        let callbacks = unmountWaiters.removeValue(forKey: sessionKey) ?? []
        for callback in callbacks { callback(error) }
    }

    func ejectAsync(deviceID: String, completion: @escaping EDPDaemonMountCompletion) {
        lifecycleQueue.async { [weak self] in
            guard let self else {
                completion("mount manager was released")
                return
            }
            if self.ejectWaiters[deviceID] != nil {
                if let context = self.ejectJournalContexts[deviceID] {
                    self.recordLifecycle(
                        context,
                        state: "coalesced",
                        event: "coalescedRequest"
                    )
                }
                self.ejectWaiters[deviceID, default: []].append(completion)
                return
            }
            let context = self.makeLifecycleContext(operation: "eject", deviceID: deviceID)
            self.ejectWaiters[deviceID] = [completion]
            self.ejectJournalContexts[deviceID] = context
            self.recordLifecycle(context, state: "requested", event: "request")
            let active = self.activeMountOperations.filter { $0.hasPrefix("\(deviceID):") }
            if !active.isEmpty {
                self.recordLifecycle(
                    context,
                    state: "waitingForMountDrain",
                    event: "cancelActiveMounts"
                )
            }
            for sessionKey in active { self.cancelMountOperation(sessionKey) }
            self.waitForDeviceMountsToDrain(
                deviceID: deviceID,
                deadline: self.scheduler.deadline(after: 15),
                waitingRecorded: !active.isEmpty
            )
        }
    }

    private func waitForDeviceMountsToDrain(
        deviceID: String,
        deadline: UInt64,
        waitingRecorded: Bool
    ) {
        if activeMountOperations.contains(where: { $0.hasPrefix("\(deviceID):") }) {
            if !waitingRecorded, let context = ejectJournalContexts[deviceID] {
                recordLifecycle(
                    context,
                    state: "waitingForMountDrain",
                    event: "waitingForMountDrain"
                )
            }
            guard !scheduler.hasReached(deadline) else {
                finishEject(deviceID, error: "mount operations did not drain before eject deadline")
                return
            }
            scheduler.schedule(on: lifecycleQueue, after: 0.1) { [weak self] in
                self?.waitForDeviceMountsToDrain(
                    deviceID: deviceID,
                    deadline: deadline,
                    waitingRecorded: true
                )
            }
            return
        }
        let keys = sessions.compactMap { $0.value.deviceID == deviceID ? $0.key : nil }.sorted()
        if let context = ejectJournalContexts[deviceID] {
            recordLifecycle(
                context,
                state: "tearingDownSessions",
                event: "sessionTeardownStarted",
                ownedResources: keys.isEmpty ? [] : ["filesystem", "publication", "transport"]
            )
        }
        teardownSessionKeys(keys, index: 0) { [weak self] errorMessage in
            guard let self else { return }
            if let context = self.ejectJournalContexts[deviceID] {
                self.recordLifecycle(
                    context,
                    state: errorMessage == nil ? "physicalEjectHandoff" : "failed",
                    event: errorMessage == nil
                        ? "sessionTeardownComplete"
                        : "sessionTeardownFailure",
                    diagnosticCode: errorMessage == nil ? nil : .teardownFailed
                )
            }
            self.finishEject(deviceID, error: errorMessage)
        }
    }

    private func teardownSessionKeys(
        _ keys: [String],
        index: Int,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        guard index < keys.count else {
            completion(nil)
            return
        }
        beginUnmount(keys[index]) { [weak self] errorMessage in
            guard let self else { return }
            if let errorMessage {
                completion(errorMessage)
                return
            }
            self.teardownSessionKeys(keys, index: index + 1, completion: completion)
        }
    }

    private func finishEject(_ deviceID: String, error: String?) {
        if let context = ejectJournalContexts[deviceID] {
            if error == nil {
                recordLifecycle(
                    context,
                    state: "physicalEjectHandoff",
                    event: "physicalEjectHandoff"
                )
            } else {
                ejectJournalContexts.removeValue(forKey: deviceID)
                recordLifecycle(
                    context,
                    state: "failed",
                    event: "terminalFailure",
                    diagnosticCode: .teardownFailed
                )
            }
        }
        let callbacks = ejectWaiters.removeValue(forKey: deviceID) ?? []
        for callback in callbacks { callback(error) }
    }

    func recordPhysicalEjectResult(
        deviceID: String,
        failureCode: EDPLifecycleFailureCode?
    ) {
        lifecycleQueue.async { [weak self] in
            guard let self,
                  let context = self.ejectJournalContexts.removeValue(forKey: deviceID) else {
                return
            }
            self.recordLifecycle(
                context,
                state: failureCode == nil ? "completed" : "failed",
                event: failureCode == nil ? "terminalSuccess" : "terminalFailure",
                diagnosticCode: failureCode
            )
        }
    }

    func recordShutdownCoalesced() {
        lifecycleQueue.async { [weak self] in
            guard let self, let context = self.shutdownJournalContext else { return }
            self.recordLifecycle(
                context,
                state: "coalesced",
                event: "coalescedRequest"
            )
        }
    }

    func unmountAllAsync(completion: @escaping EDPDaemonMountCompletion) {
        lifecycleQueue.async { [weak self] in
            guard let self else {
                completion("mount manager was released")
                return
            }
            if let context = self.shutdownJournalContext {
                self.shutdownWaiters.append(completion)
                self.recordLifecycle(
                    context,
                    state: "coalesced",
                    event: "coalescedRequest"
                )
                return
            }
            let context = self.makeLifecycleContext(operation: "shutdown", deviceID: "service")
            self.shutdownJournalContext = context
            self.shutdownWaiters = [completion]
            self.recordLifecycle(context, state: "requested", event: "request")
            if !self.activeMountOperations.isEmpty {
                self.recordLifecycle(
                    context,
                    state: "waitingForMountDrain",
                    event: "cancelActiveMounts"
                )
            }
            for sessionKey in self.activeMountOperations { self.cancelMountOperation(sessionKey) }
            self.waitForAllMountsToDrain(
                deadline: self.scheduler.deadline(after: 15),
                waitingRecorded: !self.activeMountOperations.isEmpty
            )
        }
    }

    private func waitForAllMountsToDrain(
        deadline: UInt64,
        waitingRecorded: Bool
    ) {
        if !activeMountOperations.isEmpty {
            if !waitingRecorded, let context = shutdownJournalContext {
                recordLifecycle(
                    context,
                    state: "waitingForMountDrain",
                    event: "waitingForMountDrain"
                )
            }
            guard !scheduler.hasReached(deadline) else {
                finishShutdown("mount operations did not drain before shutdown deadline")
                return
            }
            scheduler.schedule(on: lifecycleQueue, after: 0.1) { [weak self] in
                self?.waitForAllMountsToDrain(
                    deadline: deadline,
                    waitingRecorded: true
                )
            }
            return
        }
        let keys = Array(sessions.keys).sorted()
        if let context = shutdownJournalContext {
            recordLifecycle(
                context,
                state: "tearingDownSessions",
                event: "sessionTeardownStarted",
                ownedResources: keys.isEmpty ? [] : ["filesystem", "publication", "transport"]
            )
        }
        teardownSessionKeys(keys, index: 0) { [weak self] errorMessage in
            guard let self else { return }
            let finalError: String?
            if errorMessage == nil, !self.sessions.isEmpty {
                finalError = "one or more EDP sessions could not be safely unmounted"
            } else {
                finalError = errorMessage
            }
            if let context = self.shutdownJournalContext {
                self.recordLifecycle(
                    context,
                    state: finalError == nil ? "finalizing" : "failed",
                    event: finalError == nil
                        ? "sessionTeardownComplete"
                        : "sessionTeardownFailure",
                    diagnosticCode: finalError == nil ? nil : .teardownFailed
                )
            }
            self.finishShutdown(finalError)
        }
    }

    private func finishShutdown(_ error: String?) {
        if let context = shutdownJournalContext {
            recordLifecycle(
                context,
                state: error == nil ? "completed" : "failed",
                event: error == nil ? "terminalSuccess" : "terminalFailure",
                diagnosticCode: error == nil ? nil : .teardownFailed
            )
        }
        shutdownJournalContext = nil
        let callbacks = shutdownWaiters
        shutdownWaiters.removeAll()
        for callback in callbacks { callback(error) }
    }

    private func persistSessions() {
        let publicState = sessions.values.map {
            [
                "physicalBSD": $0.physicalBSD,
                "deviceID": $0.deviceID,
                "partitionType": String($0.partitionType),
                "bridgeMount": $0.bridgeMount,
                "exposedBSD": $0.exposedBSD,
                "filesystem": $0.filesystem,
                "mountpoint": $0.userMount ?? "",
            ]
        }
        if let data = try? JSONSerialization.data(
            withJSONObject: publicState,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? atomicWrite(data, to: dataRoot + "/sessions.json", mode: 0o644)
        }
    }
}

func recoverPersistedMountSessionsForServiceCleanup(
    completion: @escaping EDPDaemonMountCompletion
) throws {
    let manager = try EDPMountCoordinator()
    manager.recoverPersistedSessionsAsync(completion: completion)
}

typealias EDPCredentialVerifying = @Sendable (PhysicalDisk, UInt32, [UInt8], Int32) throws -> Void

private final class EDPSensitiveBytesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    func take() -> [UInt8] {
        lock.lock()
        let copy = bytes
        secureZero(&bytes)
        bytes.removeAll(keepingCapacity: false)
        lock.unlock()
        return copy
    }

    deinit {
        secureZero(&bytes)
    }
}

final class EDPServiceController: @unchecked Sendable {
    private let store: EDPCredentialStore
    private let policies: EDPDevicePolicyStore
    private let manager: any EDPDaemonMountManaging
    private let diskArbitration: any EDPDaemonDiskArbitrating
    private let mediaProvider: any EDPWholeUSBMediaProviding
    private let discovery: EDPDeviceDiscoveryController
    private let rawAccess: EDPRawAccessCoordinator
    private let eject: EDPEjectCoordinator
    private let recovery: EDPRecoveryCoordinator
    private let credentialVerifier: EDPCredentialVerifying
    private let metrics: EDPRuntimeMetrics
    private let automation = EDPAutomationState()
    private let serviceLifecycle = EDPServiceLifecycleState()
    private let queue = DispatchQueue(label: "com.edp.drive.controller")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let activityStore = EDPActivityStore()
    private var missingCleanupScheduled = false
    private var connectedDisks = [PhysicalDisk]()

    init(
        store: EDPCredentialStore? = nil,
        policies: EDPDevicePolicyStore? = nil,
        manager: (any EDPDaemonMountManaging)? = nil,
        diskArbitration: (any EDPDaemonDiskArbitrating)? = nil,
        mediaProvider: any EDPWholeUSBMediaProviding = EDPIOKitWholeUSBMediaProvider(),
        metadataReader: any EDPRawMetadataReading = EDPPrivilegedRawMetadataReader(),
        rawAccessLeaseOpener: EDPRawAccessLeaseOpening? = nil,
        credentialVerifier: EDPCredentialVerifying? = nil,
        metrics: EDPRuntimeMetrics = EDPRuntimeMetrics(),
        ejectSuppressionPath: String? = nil,
        performLegacyRuntimeMigration: Bool = true
    ) throws {
        self.mediaProvider = mediaProvider
        self.metrics = metrics
        queue.setSpecific(key: queueKey, value: 1)
        self.discovery = EDPDeviceDiscoveryController(
            mediaProvider: mediaProvider,
            metadataReader: metadataReader
        )
        let effectiveRawAccessLeaseOpener: EDPRawAccessLeaseOpening
        let rawAccessOpenerRunsOffControllerQueue: Bool
        if let rawAccessLeaseOpener {
            effectiveRawAccessLeaseOpener = rawAccessLeaseOpener
            rawAccessOpenerRunsOffControllerQueue = false
        } else {
            effectiveRawAccessLeaseOpener = { disk in
                try openPersistentRawAccess(for: disk, mediaProvider: mediaProvider)
            }
            rawAccessOpenerRunsOffControllerQueue = true
        }
        self.credentialVerifier = credentialVerifier ?? { disk, partitionType, password, rawFD in
            try verifyPartitionType(
                disk: disk,
                partitionType: partitionType,
                password: password,
                rawFD: rawFD
            )
        }
        if performLegacyRuntimeMigration {
            try migrateLegacyRuntimeState()
        }
        self.store = try store ?? makeCredentialStore()
        self.policies = try policies ?? makePolicyStore()
        self.manager = try manager ?? EDPMountCoordinator(metrics: metrics)
        let effectiveDiskArbitration = try diskArbitration ?? EDPDiskArbitrationController()
        self.diskArbitration = effectiveDiskArbitration
        self.rawAccess = EDPRawAccessCoordinator(
            ownerQueue: queue,
            diskArbitration: effectiveDiskArbitration,
            leaseOpener: effectiveRawAccessLeaseOpener,
            openerRunsOffOwnerQueue: rawAccessOpenerRunsOffControllerQueue,
            metrics: metrics
        )
        let effectiveEjectSuppressionPath = ejectSuppressionPath
            ?? (performLegacyRuntimeMigration ? logicalEjectSuppressionPath : nil)
        let effectiveEjectCoordinator = try EDPEjectCoordinator(
            ownerQueue: queue,
            diskArbitration: effectiveDiskArbitration,
            mediaProvider: mediaProvider,
            metrics: metrics,
            logicalSuppressionPath: effectiveEjectSuppressionPath
        )
        self.eject = effectiveEjectCoordinator
        self.recovery = EDPRecoveryCoordinator(
            mediaProvider: mediaProvider,
            ejectCoordinator: effectiveEjectCoordinator
        )
        _ = try self.store.load()
        _ = try self.policies.load()
        if performLegacyRuntimeMigration {
            finalizeLegacyRuntimeStateMigration()
        }
        self.manager.recoverPersistedSessionsAsync { [weak self] errorMessage in
            guard let self else { return }
            self.onControllerQueue {
                self.serviceLifecycle.completeStartupRecovery(errorMessage: errorMessage)
                if let errorMessage {
                    self.addActivity(
                        "启动时残留会话恢复失败：\(errorMessage)",
                        level: "error"
                    )
                }
                self.reconcileLocked()
            }
        }
    }

    private func key(_ deviceID: String, _ partitionType: UInt32) -> String {
        "\(deviceID):\(partitionType)"
    }

    private func onControllerQueue(_ body: @escaping @Sendable () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            body()
        } else {
            queue.async(execute: body)
        }
    }

    private func addActivity(
        _ message: String,
        level: String = "info",
        deviceID: String? = nil,
        partitionType: UInt32? = nil
    ) {
        activityStore.add(
            message,
            level: level,
            deviceID: deviceID,
            partitionType: partitionType
        )
    }

    private func observe(_ disks: [PhysicalDisk]) throws {
        for disk in disks {
            _ = try policies.observe(
                deviceID: disk.deviceID,
                mediaName: disk.mediaName,
                vidPID: "\(disk.vidHex):\(disk.pidHex)",
                sizeBytes: disk.sizeBytes
            )
        }
    }

    private func probeDefaultPasswordsLocked(
        disks: [PhysicalDisk],
        policyDocument: EDPPolicyDocument
    ) throws {
        var records = try store.load().records
        for disk in disks where !eject.isSuppressed(deviceID: disk.deviceID) {
            guard let devicePolicy = policyDocument.devices.first(
                where: { $0.deviceID == disk.deviceID }
            ) else { continue }

            for partitionType in [UInt32(2), 4] {
                let partitionKey = key(disk.deviceID, partitionType)
                guard devicePolicy.policy(for: partitionType).autoProbePassword,
                      records.first(where: { $0.deviceID == disk.deviceID })?
                        .partitionTypes.contains(partitionType) != true,
                      !automation.isDefaultProbeSuppressed(partitionKey) else {
                    continue
                }

                do {
                    var password = try store.defaultProbePassword(partitionType: partitionType)
                    defer { secureZero(&password) }
                    guard let rawLease = rawAccessLeaseLocked(for: disk) else {
                        // Raw access acquisition is single-flight and asynchronous.
                        // Its completion schedules another reconcile; never block
                        // the controller here waiting for Disk Arbitration.
                        continue
                    }
                    try credentialVerifier(disk, partitionType, password, rawLease.fd)
                    try store.put(
                        deviceID: disk.deviceID,
                        partitionType: partitionType,
                        password: password
                    )
                    records = try store.load().records
                    automation.clearFailure(for: partitionKey)
                    addActivity(
                        "默认密码探测成功并已保存",
                        deviceID: disk.deviceID,
                        partitionType: partitionType
                    )
                } catch {
                    if let rawFailure = EDPLifecycleFailure.recognizedRawAccessFailure(error) {
                        rawAccess.markFailure(
                            deviceID: disk.deviceID,
                            detail: rawFailure.description
                        )
                        continue
                    }
                    automation.suppressDefaultProbe(partitionKey)
                    addActivity(
                        "默认密码未匹配，本次插盘不再自动探测",
                        deviceID: disk.deviceID,
                        partitionType: partitionType
                    )
                }
            }
        }
    }

    private func rawAccessLeaseLocked(for disk: PhysicalDisk) -> EDPRawAccessLease? {
        rawAccess.lease(for: disk)
    }

    private func rawAccessGenerationMatchesLocked(_ disk: PhysicalDisk) -> Bool {
        guard !eject.isSuppressed(deviceID: disk.deviceID),
              let current = connectedDisks.first(where: { $0.deviceID == disk.deviceID }),
              current.registryEntryID == disk.registryEntryID,
              current.rawPath == disk.rawPath,
              mediaProvider.registryEntryExists(disk.registryEntryID) else {
            return false
        }
        return true
    }

    private func rawAccessProbeAsyncLocked(
        for disk: PhysicalDisk,
        temporarilyUnmount: Bool,
        completion: @escaping EDPRawAccessLeaseCompletion
    ) {
        rawAccess.probeAsync(
            for: disk,
            temporarilyUnmount: temporarilyUnmount,
            generationMatches: { [weak self] candidate in
                self?.rawAccessGenerationMatchesLocked(candidate) == true
            },
            onBusyRecovery: { [weak self] candidate in
                self?.addActivity(
                    "物理介质被系统占用，执行一次强制整盘卸载后重试",
                    deviceID: candidate.deviceID
                )
            },
            completion: completion
        )
    }

    private func requireRawAccessLeaseAsyncLocked(
        for disk: PhysicalDisk,
        completion: @escaping EDPRawAccessLeaseCompletion
    ) {
        rawAccess.requireLeaseAsync(
            for: disk,
            isEjecting: eject.isSuppressed(deviceID: disk.deviceID),
            generationMatches: { [weak self] candidate in
                self?.rawAccessGenerationMatchesLocked(candidate) == true
            },
            onBusyRecovery: { [weak self] candidate in
                self?.addActivity(
                    "物理介质被系统占用，执行一次强制整盘卸载后重试",
                    deviceID: candidate.deviceID
                )
            },
            completion: completion
        )
    }

    private func mountBootAsyncLocked(
        disk: PhysicalDisk,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        let partitionType = EDPPartitionKind.boot.rawValue
        requireRawAccessLeaseAsyncLocked(for: disk) { [weak self] rawLease, failure in
            guard let self else { return }
            self.onControllerQueue {
                if let failure {
                    completion(failure.description)
                    return
                }
                guard let rawLease else {
                    completion("EDP raw access lease was not retained")
                    return
                }
                self.manager.mountAsync(
                    disk: disk,
                    partitionType: partitionType,
                    password: [],
                    rawFD: rawLease.fd
                ) { [weak self] errorMessage in
                    guard let self else { return }
                    self.onControllerQueue { completion(errorMessage) }
                }
            }
        }
    }

    private func restoreBootPolicyAsyncLocked(disk: PhysicalDisk) {
        guard let document = try? policies.load(),
              document.globalAutoMountEnabled,
              let policy = document.devices.first(where: { $0.deviceID == disk.deviceID }),
              policy.policy(for: EDPPartitionKind.boot.rawValue).autoMount,
              !automation.isManualUnmountSuppressed(
                  key(disk.deviceID, EDPPartitionKind.boot.rawValue)
              ),
              !manager.contains(disk, EDPPartitionKind.boot.rawValue) else { return }
        mountBootAsyncLocked(disk: disk) { [weak self] errorMessage in
            guard let self, let errorMessage else { return }
            let partitionType = EDPPartitionKind.boot.rawValue
            let partitionKey = self.key(disk.deviceID, partitionType)
            self.automation.recordFailure(
                errorMessage,
                code: self.manager.lastFailureCode(
                    deviceID: disk.deviceID,
                    partitionType: partitionType
                ),
                for: partitionKey
            )
        }
    }

    func reconcile() {
        queue.async { [weak self] in self?.reconcileLocked() }
    }

#if EDP_REGRESSION_TESTS
    func reconcileSynchronouslyForTesting() {
        queue.sync { reconcileLocked() }
    }

    func drainForTesting() {
        queue.sync {}
    }
#endif

    private func reconcileLocked() {
        guard serviceLifecycle.startupRecoveryComplete,
              !serviceLifecycle.shutdownRequested else { return }
        autoreleasepool {
            do {
                let disks = try discovery.scan()
                connectedDisks = disks
                let connectedDeviceIDs = Set(disks.map(\.deviceID))
                try eject.reconcileSuppressedGenerations(disks: disks)
                rawAccess.prune(to: disks)
                for disk in disks where !eject.isSuppressed(deviceID: disk.deviceID)
                    && (rawAccess.readiness(deviceID: disk.deviceID) == nil
                        || rawAccessLeaseLocked(for: disk) == nil) {
                    rawAccessProbeAsyncLocked(for: disk, temporarilyUnmount: true) { [weak self] _, failure in
                        guard let self else { return }
                        self.onControllerQueue {
                            if let failure {
                                NSLog(
                                    "EDP Full Disk Access probe unavailable for %@: %@",
                                    disk.deviceID,
                                    failure.description
                                )
                            } else {
                                // Re-run policy/probe/mount decisions now that the
                                // retained raw lease exists. The raw probe itself
                                // is single-flight, so this cannot recurse into a
                                // second acquisition for the same device.
                                self.reconcileLocked()
                            }
                        }
                    }
                }
                let availableDisks = Dictionary(
                    uniqueKeysWithValues: disks.map { ($0.deviceID, $0.bsdName) }
                )
                if manager.removeMissing(availableDisks: availableDisks, graceSeconds: 5),
                   !missingCleanupScheduled {
                    missingCleanupScheduled = true
                    queue.asyncAfter(deadline: .now() + 6) { [weak self] in
                        guard let self else { return }
                        self.missingCleanupScheduled = false
                        self.reconcileLocked()
                    }
                }
                automation.prune(connectedDeviceIDs: connectedDeviceIDs)
                try observe(disks)
                let policyDocument = try policies.load()
                try probeDefaultPasswordsLocked(disks: disks, policyDocument: policyDocument)
                let records = try store.load().records
                for disk in disks {
                    if eject.isSuppressed(deviceID: disk.deviceID) {
                        if EDPNativeMountTable.hasMountedBSDPrefix(disk.bsdName) {
                            diskArbitration.unmountWholeAsync(
                                disk.bsdName,
                                expectedRegistryEntryID: disk.registryEntryID
                            ) { error in
                                if let error {
                                    NSLog(
                                        "EDP eject-pending whole unmount failed for %@: %@",
                                        disk.bsdName,
                                        String(describing: error)
                                    )
                                }
                            }
                        }
                        continue
                    }
                    guard let devicePolicy = policyDocument.devices.first(
                        where: { $0.deviceID == disk.deviceID }
                    ) else { continue }
                    let bootAutoMount = devicePolicy.policy(
                        for: EDPPartitionKind.boot.rawValue
                    ).autoMount
                    let bootKey = key(disk.deviceID, EDPPartitionKind.boot.rawValue)
                    if policyDocument.globalAutoMountEnabled,
                       bootAutoMount,
                       !automation.isManualUnmountSuppressed(bootKey),
                       !manager.contains(disk, EDPPartitionKind.boot.rawValue) {
                        mountBootAsyncLocked(disk: disk) { [weak self] errorMessage in
                            guard let self else { return }
                            if let errorMessage {
                                self.automation.recordFailure(
                                    errorMessage,
                                    code: self.manager.lastFailureCode(
                                        deviceID: disk.deviceID,
                                        partitionType: EDPPartitionKind.boot.rawValue
                                    ),
                                    for: bootKey
                                )
                                self.addActivity(
                                    "启动区自动挂载失败：\(errorMessage)",
                                    level: "error",
                                    deviceID: disk.deviceID,
                                    partitionType: EDPPartitionKind.boot.rawValue
                                )
                            } else {
                                self.automation.clearFailure(for: bootKey)
                            }
                        }
                    }
                    // `autoMount == false` means "do not mount automatically".
                    // It must never tear down a partition the user mounted
                    // explicitly. Manual unmount is handled only by the user
                    // action path below.
                    guard policyDocument.globalAutoMountEnabled,
                          let record = records.first(where: { $0.deviceID == disk.deviceID }) else {
                        continue
                    }
                    for type in [UInt32(2), UInt32(4)]
                    where devicePolicy.policy(for: type).autoMount
                        && record.partitionTypes.contains(type)
                        && !manager.contains(disk, type)
                        && !automation.isManualUnmountSuppressed(key(disk.deviceID, type)) {
                        let key = "\(disk.deviceID):\(type)"
                        if automation.failureMessage(for: key) != nil { continue }
                        mountEncryptedPartitionAsyncLocked(
                            disk: disk,
                            partitionType: type
                        ) { [weak self] errorMessage in
                            guard let self else { return }
                            self.restoreBootPolicyAsyncLocked(disk: disk)
                            if let errorMessage {
                                NSLog(
                                    "EDP auto-mount failed for %@ type %u; automatic retry paused until explicit user action or device reconnect: %@",
                                    disk.deviceID,
                                    type,
                                    errorMessage
                                )
                                self.addActivity(
                                    "自动挂载失败：\(errorMessage)",
                                    level: "error",
                                    deviceID: disk.deviceID,
                                    partitionType: type
                                )
                            } else {
                                self.addActivity(
                                    "自动挂载成功",
                                    deviceID: disk.deviceID,
                                    partitionType: type
                                )
                            }
                        }
                    }
                }
            } catch {
                NSLog("EDP event reconciliation failed: %@", String(describing: error))
            }
        }
    }

    func snapshotData() -> Data {
        queue.sync {
            do {
                // Physical discovery owns raw-device access and is driven by
                // Disk Arbitration.  The UI polls snapshots every two seconds;
                // rescanning here would fork a privileged metadata helper for
                // every poll and can create an unbounded failure loop when the
                // current service context cannot open /dev/rdiskN.
                let disks = connectedDisks
                try observe(disks)
                let records = try store.load().records
                let policyDocument = try policies.load()
                let connectedByID = Dictionary(uniqueKeysWithValues: disks
                    .filter { !eject.isSuppressed(deviceID: $0.deviceID) }
                    .map { ($0.deviceID, $0) })
                let deviceIDs = Set(policyDocument.devices.map(\.deviceID))
                    .union(records.map(\.deviceID))
                    .union(disks.map(\.deviceID))
                let devices = deviceIDs.sorted().map { deviceID in
                    let disk = connectedByID[deviceID]
                    let record = records.first { $0.deviceID == deviceID }
                    let policy = policyDocument.devices.first { $0.deviceID == deviceID }
                    let partitions = EDPPartitionKind.allCases.map { kind -> EDPXPCPartition in
                        let summary = manager.summary(
                            deviceID: deviceID,
                            partitionType: kind.rawValue
                        )
                        let mountpoint = summary?["mountpoint"]
                        let isMounted = mountpoint?.isEmpty == false || summary != nil
                        let credentialStatus: EDPCredentialStatus = kind.isEncrypted
                            ? (record?.partitionTypes.contains(kind.rawValue) == true ? .saved : .missing)
                            : .notRequired
                        return EDPXPCPartition(
                            partitionType: kind.rawValue,
                            displayName: kind.displayName,
                            encrypted: kind.isEncrypted,
                            autoMount: policy?.policy(for: kind.rawValue).autoMount ?? false,
                            credentialStatus: credentialStatus,
                            mountState: disk == nil ? .unavailable : (isMounted ? .mounted : .unmounted),
                            filesystem: summary?["filesystem"],
                            readOnly: mountpoint.flatMap { EDPNativeMountTable.isReadOnly($0) },
                            mountPoint: mountpoint,
                            lastError: automation.failureMessage(for: key(deviceID, kind.rawValue))
                        )
                    }
                    return EDPXPCDevice(
                        deviceID: deviceID,
                        metadataDeviceID: disk?.metadataDeviceID,
                        bsdName: disk?.bsdName ?? "",
                        mediaName: disk?.mediaName ?? policy?.lastMediaName ?? "EDP USB",
                        displayName: policy?.displayName ?? disk?.mediaName ?? "EDP USB",
                        vidPID: disk.map { "\($0.vidHex):\($0.pidHex)" }
                            ?? policy?.lastVIDPID ?? "-",
                        labelOnlyID: disk?.labelOnlyID,
                        sizeBytes: disk?.sizeBytes ?? policy?.lastSizeBytes ?? 0,
                        connected: disk != nil,
                        privilegedAccessReady: disk.map {
                            rawAccess.readiness(deviceID: $0.deviceID) == true
                        } ?? false,
                        partitions: partitions
                    )
                }
                let partitionDefaults = EDPPartitionKind.allCases.map { kind in
                    let policy = policyDocument.defaultPolicy(for: kind.rawValue)
                    return EDPXPCPartitionDefault(
                        partitionType: kind.rawValue,
                        displayName: kind.displayName,
                        autoMount: policy.autoMount,
                        autoProbePassword: kind.isEncrypted && policy.autoProbePassword,
                        defaultProbePasswordCustomized: kind.isEncrypted
                            && store.hasCustomizedDefaultProbePassword(partitionType: kind.rawValue)
                    )
                }
                return try JSONEncoder().encode(EDPXPCSnapshot(
                    devices: devices,
                    activities: activityStore.snapshot(),
                    serviceVersion: installedProductVersion(),
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    globalAutoMountEnabled: policyDocument.globalAutoMountEnabled,
                    partitionDefaults: partitionDefaults
                ))
            } catch {
                return Data("{\"error\":\"\(String(describing: error).replacingOccurrences(of: "\"", with: "'"))\"}".utf8)
            }
        }
    }

    func saveCredentialAsync(
        deviceID: String,
        partitionType: UInt32,
        passwordData: Data,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        let passwordBox = EDPSensitiveBytesBox([UInt8](passwordData))
        queue.async { [weak self] in
            guard let self else {
                completion("EDP service controller was released")
                return
            }
            guard self.serviceLifecycle.startupRecoveryComplete,
                  !self.serviceLifecycle.shutdownRequested else {
                completion(self.serviceLifecycle.shutdownRequested
                    ? "EDP service is shutting down"
                    : "EDP service startup recovery is still in progress")
                return
            }
            guard let disk = self.connectedDisks.first(where: { $0.deviceID == deviceID }) else {
                completion("EDP device is no longer connected")
                return
            }
            self.requireRawAccessLeaseAsyncLocked(for: disk) { [weak self] rawLease, rawError in
                guard let self else { return }
                self.onControllerQueue {
                    if let rawError {
                        completion(rawError.description)
                        return
                    }
                    guard let rawLease else {
                        completion("EDP raw access lease was not retained")
                        return
                    }
                    var password = passwordBox.take()
                    defer { secureZero(&password) }
                    do {
                        try self.credentialVerifier(
                            disk,
                            partitionType,
                            password,
                            rawLease.fd
                        )
                        try self.store.put(
                            deviceID: deviceID,
                            partitionType: partitionType,
                            password: password
                        )
                        let partitionKey = self.key(deviceID, partitionType)
                        self.automation.clearFailure(for: partitionKey)
                        self.addActivity(
                            "密码验证并保存成功",
                            deviceID: deviceID,
                            partitionType: partitionType
                        )
                        completion(nil)
                        self.reconcileLocked()
                    } catch {
                        completion(userFacingRawAccessFailure(error).description)
                    }
                }
            }
        }
    }

    func mountPartitionAsync(
        deviceID: String,
        partitionType: UInt32,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        queue.async { [weak self] in
            guard let self else {
                completion("EDP service controller was released")
                return
            }
            guard !self.serviceLifecycle.shutdownRequested else {
                completion("EDP service is shutting down")
                return
            }
            let partitionKey = self.key(deviceID, partitionType)
            self.automation.clearFailure(for: partitionKey)
            self.automation.clearManualRemountSuppression(partitionKey)
            guard let disk = self.connectedDisks.first(where: { $0.deviceID == deviceID }) else {
                completion("EDP device is no longer connected")
                return
            }

            if partitionType == EDPPartitionKind.boot.rawValue {
                self.mountBootAsyncLocked(disk: disk) { [weak self] errorMessage in
                    guard let self else { return }
                    if let errorMessage {
                        self.automation.recordFailure(
                            errorMessage,
                            code: self.manager.lastFailureCode(
                                deviceID: disk.deviceID,
                                partitionType: partitionType
                            ),
                            for: partitionKey
                        )
                        self.addActivity(
                            "手动挂载失败：\(errorMessage)",
                            level: "error",
                            deviceID: deviceID,
                            partitionType: partitionType
                        )
                    } else {
                        self.automation.clearFailure(for: partitionKey)
                        self.addActivity("手动挂载成功", deviceID: deviceID, partitionType: partitionType)
                    }
                    completion(errorMessage)
                }
                return
            }

            self.mountEncryptedPartitionAsyncLocked(
                disk: disk,
                partitionType: partitionType
            ) { [weak self] errorMessage in
                guard let self else { return }
                self.restoreBootPolicyAsyncLocked(disk: disk)
                if let errorMessage {
                    self.addActivity(
                        "手动挂载失败：\(errorMessage)",
                        level: "error",
                        deviceID: deviceID,
                        partitionType: partitionType
                    )
                } else {
                    self.addActivity("手动挂载成功", deviceID: deviceID, partitionType: partitionType)
                }
                completion(errorMessage)
            }
        }
    }

    private func mountEncryptedPartitionAsyncLocked(
        disk: PhysicalDisk,
        partitionType: UInt32,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        guard [UInt32(2), 4].contains(partitionType) else {
            completion("unsupported encrypted partition type")
            return
        }
        let passwordBox: EDPSensitiveBytesBox
        do {
            var password = try store.password(
                deviceID: disk.deviceID,
                partitionType: partitionType
            )
            passwordBox = EDPSensitiveBytesBox(password)
            secureZero(&password)
        } catch {
            completion(String(describing: error))
            return
        }

        requireRawAccessLeaseAsyncLocked(for: disk) { [weak self] rawLease, rawError in
            guard let self else { return }
            self.onControllerQueue {
                let partitionKey = self.key(disk.deviceID, partitionType)
                if let rawError {
                    self.automation.recordFailure(
                        rawError.description,
                        code: rawError.code,
                        for: partitionKey
                    )
                    completion(rawError.description)
                    return
                }
                guard let rawLease else {
                    let detail = "EDP raw access lease was not retained"
                    self.automation.recordFailure(
                        detail,
                        code: .rawAccessUnavailable,
                        for: partitionKey
                    )
                    completion(detail)
                    return
                }
                var password = passwordBox.take()
                defer { secureZero(&password) }
                self.manager.mountAsync(
                    disk: disk,
                    partitionType: partitionType,
                    password: password,
                    rawFD: rawLease.fd
                ) { [weak self] errorMessage in
                    guard let self else { return }
                    self.onControllerQueue {
                        if let errorMessage {
                            let code = self.manager.lastFailureCode(
                                deviceID: disk.deviceID,
                                partitionType: partitionType
                            ) ?? .unknown
                            if code == .rawAccessPermission || code == .rawAccessUnavailable {
                                self.rawAccess.markFailure(
                                    deviceID: disk.deviceID,
                                    detail: errorMessage
                                )
                            }
                            self.automation.recordFailure(
                                errorMessage,
                                code: code,
                                for: partitionKey
                            )
                        } else {
                            self.rawAccess.markReady(deviceID: disk.deviceID)
                            self.automation.clearFailure(for: partitionKey)
                        }
                        completion(errorMessage)
                    }
                }
            }
        }
    }

    func unmountPartitionAsync(
        deviceID: String,
        partitionType: UInt32,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        queue.async { [weak self] in
            guard let self else {
                completion("EDP service controller was released")
                return
            }
            let partitionKey = self.key(deviceID, partitionType)
            self.manager.unmountAsync(
                deviceID: deviceID,
                partitionType: partitionType
            ) { [weak self] errorMessage in
                guard let self else { return }
                self.onControllerQueue {
                    if let errorMessage {
                        self.automation.recordFailure(
                            errorMessage,
                            code: .teardownFailed,
                            for: partitionKey
                        )
                        self.addActivity(
                            "分区卸载失败：\(errorMessage)",
                            level: "error",
                            deviceID: deviceID,
                            partitionType: partitionType
                        )
                    } else {
                        self.automation.suppressManualRemount(partitionKey)
                        self.automation.clearFailure(for: partitionKey)
                        self.addActivity("分区已卸载", deviceID: deviceID, partitionType: partitionType)
                    }
                    completion(errorMessage)
                }
            }
        }
    }

    func deleteCredentialAsync(
        deviceID: String,
        partitionType: UInt32,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        queue.async { [weak self] in
            guard let self else {
                completion("EDP service controller was released")
                return
            }
            self.manager.unmountAsync(
                deviceID: deviceID,
                partitionType: partitionType
            ) { [weak self] errorMessage in
                guard let self else { return }
                self.onControllerQueue {
                    if let errorMessage {
                        completion(errorMessage)
                        return
                    }
                    do {
                        try self.store.remove(deviceID: deviceID, partitionType: partitionType)
                        let partitionKey = self.key(deviceID, partitionType)
                        self.automation.clearFailure(for: partitionKey)
                        self.automation.clearManualRemountSuppression(partitionKey)
                        self.automation.suppressDefaultProbe(partitionKey)
                        self.addActivity(
                            "已删除保存的密码",
                            deviceID: deviceID,
                            partitionType: partitionType
                        )
                        completion(nil)
                    } catch {
                        completion(String(describing: error))
                    }
                }
            }
        }
    }

    func deleteDeviceRecord(deviceID: String) throws {
        try queue.sync {
            guard !connectedDisks.contains(where: { $0.deviceID == deviceID }) else {
                throw fail("请先安全推出并拔出该 U 盘，再删除设备记录")
            }
            guard !manager.isMounted(deviceID: deviceID) else {
                throw fail("该设备仍有挂载会话，暂时不能删除记录")
            }
            try store.remove(deviceID: deviceID)
            try policies.remove(deviceID: deviceID)
            automation.removeDevice(deviceID)
            addActivity("已删除设备记录和保存的密码", deviceID: deviceID)
        }
    }

    func setDefaultPartitionAutoMount(partitionType: UInt32, enabled: Bool) throws {
        try queue.sync {
            try policies.setDefaultAutoMount(partitionType: partitionType, enabled: enabled)
            addActivity(
                enabled ? "已开启新设备默认自动挂载" : "已关闭新设备默认自动挂载",
                partitionType: partitionType
            )
        }
    }

    func setDefaultPartitionAutoProbePassword(partitionType: UInt32, enabled: Bool) throws {
        try queue.sync {
            try policies.setDefaultAutoProbePassword(partitionType: partitionType, enabled: enabled)
            if enabled {
                for disk in connectedDisks {
                    automation.clearDefaultProbeSuppression(key(disk.deviceID, partitionType))
                }
            }
            addActivity(
                enabled ? "已开启新设备默认密码探测" : "已关闭新设备默认密码探测",
                partitionType: partitionType
            )
        }
    }

    func setDefaultProbePassword(partitionType: UInt32, passwordData: Data) throws {
        var password = [UInt8](passwordData)
        defer { secureZero(&password) }
        try queue.sync {
            try store.setDefaultProbePassword(partitionType: partitionType, password: password)
            for disk in connectedDisks {
                automation.clearDefaultProbeSuppression(key(disk.deviceID, partitionType))
            }
            addActivity("已更新默认探测密码", partitionType: partitionType)
        }
        reconcile()
    }

    func resetDefaultProbePassword(partitionType: UInt32) throws {
        try queue.sync {
            try store.resetDefaultProbePassword(partitionType: partitionType)
            for disk in connectedDisks {
                automation.clearDefaultProbeSuppression(key(disk.deviceID, partitionType))
            }
            addActivity("默认探测密码已恢复为 0000aaaa", partitionType: partitionType)
        }
        reconcile()
    }

    func setPartitionAutoMount(deviceID: String, partitionType: UInt32, enabled: Bool) throws {
        try queue.sync {
            try policies.setAutoMount(
                deviceID: deviceID,
                partitionType: partitionType,
                enabled: enabled
            )
            automation.clearManualRemountSuppression(key(deviceID, partitionType))
            addActivity(
                enabled ? "已开启自动挂载" : "已关闭自动挂载",
                deviceID: deviceID,
                partitionType: partitionType
            )
        }
        if enabled { reconcile() }
    }

    func setDeviceDisplayName(deviceID: String, displayName: String) throws {
        try queue.sync { try policies.setDisplayName(deviceID: deviceID, displayName: displayName) }
    }

    func setGlobalAutoMount(_ enabled: Bool) throws {
        try queue.sync {
            try policies.setGlobalAutoMount(enabled)
            addActivity(enabled ? "已恢复全局自动挂载" : "已暂停全局自动挂载")
        }
        if enabled { reconcile() }
    }

    func refreshRawAccessAsync(completion: @escaping EDPDaemonMountCompletion) {
        queue.async { [weak self] in
            guard let self else {
                completion("EDP service controller was released")
                return
            }
            let disks = self.connectedDisks.filter {
                !self.eject.isSuppressed(deviceID: $0.deviceID)
            }
            self.refreshRawAccessNextLocked(
                disks,
                index: 0,
                firstError: nil,
                completion: completion
            )
        }
    }

    private func refreshRawAccessNextLocked(
        _ disks: [PhysicalDisk],
        index: Int,
        firstError: String?,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        guard index < disks.count else {
            completion(firstError)
            reconcileLocked()
            return
        }
        let disk = disks[index]
        rawAccessProbeAsyncLocked(for: disk, temporarilyUnmount: true) { [weak self] _, failure in
            guard let self else { return }
            self.onControllerQueue {
                let nextError = firstError ?? failure?.description
                if let failure {
                    self.addActivity(
                        "完全磁盘访问不可用：\(failure.description)",
                        level: "error",
                        deviceID: disk.deviceID
                    )
                } else {
                    self.addActivity("完全磁盘访问已验证", deviceID: disk.deviceID)
                }
                self.refreshRawAccessNextLocked(
                    disks,
                    index: index + 1,
                    firstError: nextError,
                    completion: completion
                )
            }
        }
    }

    func retryTransientAutomaticMounts() throws {
        let shouldReconcile = try queue.sync { () -> Bool in
            let policyDocument = try policies.load()
            guard policyDocument.globalAutoMountEnabled else { return false }

            var clearedAny = false
            for disk in connectedDisks where !eject.isSuppressed(deviceID: disk.deviceID) {
                guard let devicePolicy = policyDocument.devices.first(
                    where: { $0.deviceID == disk.deviceID }
                ) else { continue }

                for type in [UInt32(2), UInt32(4)]
                where devicePolicy.policy(for: type).autoMount {
                    let partitionKey = key(disk.deviceID, type)
                    guard !automation.isManualUnmountSuppressed(partitionKey),
                          automation.failureMessage(for: partitionKey) != nil,
                          automation.failureCode(for: partitionKey) == .bridgeExtensionUnavailable else {
                        continue
                    }
                    automation.clearFailure(for: partitionKey)
                    clearedAny = true
                    addActivity(
                        "macFUSE FSKit 已恢复，重试自动挂载",
                        deviceID: disk.deviceID,
                        partitionType: type
                    )
                }
            }
            return clearedAny
        }
        if shouldReconcile { reconcile() }
    }

    func ejectAsync(deviceID: String, completion: @escaping EDPDaemonMountCompletion) {
        queue.async { [weak self] in
            guard let self else {
                completion("EDP service controller was released")
                return
            }
            guard !self.serviceLifecycle.shutdownRequested else {
                completion("EDP service is shutting down")
                return
            }
            if self.eject.joinIfActive(deviceID: deviceID, completion: completion) {
                return
            }
            guard let disk = self.connectedDisks.first(where: { $0.deviceID == deviceID }) else {
                completion("EDP device is no longer connected")
                return
            }

            guard self.eject.begin(disk: disk, completion: completion) else { return }
            let finishRequest: EDPDaemonMountCompletion = { [weak self] errorMessage in
                guard let self else { return }
                self.onControllerQueue {
                    self.finishEjectWaitersLocked(deviceID: deviceID, errorMessage: errorMessage)
                }
            }
            self.manager.ejectAsync(deviceID: deviceID) { [weak self] teardownError in
                guard let self else { return }
                self.onControllerQueue {
                    if let teardownError {
                        self.recoverFailedEjectLocked(
                            disk: disk,
                            errorMessage: teardownError,
                            completion: finishRequest
                        )
                        return
                    }

                    self.rawAccess.prepareForPhysicalEject(deviceID: deviceID)
                    do {
                        try self.eject.armLogicalSuppression(disk: disk)
                    } catch {
                        self.manager.recordPhysicalEjectResult(
                            deviceID: deviceID,
                            failureCode: .teardownFailed
                        )
                        self.recoverFailedEjectLocked(
                            disk: disk,
                            errorMessage: "无法持久化安全推出抑制状态：\(error)",
                            completion: finishRequest
                        )
                        return
                    }

                    self.eject.performPhysicalEjectAsync(disk: disk) { [weak self] errorMessage in
                        guard let self else { return }
                        self.onControllerQueue {
                            if let errorMessage {
                                self.manager.recordPhysicalEjectResult(
                                    deviceID: deviceID,
                                    failureCode: .teardownFailed
                                )
                                do {
                                    try self.eject.cancelLogicalSuppression(deviceID: deviceID)
                                } catch {
                                    self.addActivity(
                                        "安全推出失败且抑制状态回滚失败：\(error)",
                                        level: "error",
                                        deviceID: deviceID
                                    )
                                    finishRequest(
                                        "\(errorMessage)；安全推出抑制状态回滚失败：\(error)"
                                    )
                                    return
                                }
                                self.recoverFailedEjectLocked(
                                    disk: disk,
                                    errorMessage: errorMessage,
                                    completion: finishRequest
                                )
                                return
                            }
                            self.manager.recordPhysicalEjectResult(
                                deviceID: deviceID,
                                failureCode: nil
                            )
                            self.connectedDisks.removeAll { $0.deviceID == deviceID }
                            self.rawAccess.removeDevice(deviceID: deviceID)
                            if !self.mediaProvider.registryEntryExists(disk.usbRegistryEntryID) {
                                do {
                                    try self.eject.cancelLogicalSuppression(deviceID: deviceID)
                                } catch {
                                    // The USB generation is already physically
                                    // absent, so the eject itself is complete.
                                    // A stale persisted tombstone is harmless and
                                    // will be retired when a different USB
                                    // generation is observed on reinsertion.
                                    self.addActivity(
                                        "设备已拔出，但安全推出抑制状态清理失败：\(error)",
                                        level: "error",
                                        deviceID: deviceID
                                    )
                                }
                            }
                            self.addActivity("设备已安全推出", deviceID: deviceID)
                            finishRequest(nil)
                        }
                    }
                }
            }
        }
    }

    private func finishEjectWaitersLocked(deviceID: String, errorMessage: String?) {
        eject.finishWaiters(deviceID: deviceID, errorMessage: errorMessage)
        beginShutdownTeardownIfReadyLocked()
    }

    private func recoverFailedEjectLocked(
        disk: PhysicalDisk,
        errorMessage: String,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        recovery.recoverFailedEject(
            disk: disk,
            errorMessage: errorMessage,
            probeRawAccess: { [weak self] candidate, callback in
                guard let self else { return }
                self.rawAccessProbeAsyncLocked(
                    for: candidate,
                    temporarilyUnmount: true,
                    completion: callback
                )
            },
            restoreBootPolicy: { [weak self] candidate in
                self?.restoreBootPolicyAsyncLocked(disk: candidate)
            },
            recordFailure: { [weak self] candidate, message in
                self?.addActivity(
                    "设备安全推出失败：\(message)",
                    level: "error",
                    deviceID: candidate.deviceID
                )
            },
            completion: completion
        )
    }

    func diagnosticsData() -> Data {
        queue.sync {
            let payload: [String: Any] = [
                "mounts": manager.mountedSummaries(),
                "lifecycleJournal": manager.lifecycleJournalSnapshot().map(\.jsonObject),
                "failedMounts": automation.failedMountsSnapshot(),
                "manualUnmountSuppressions": automation.manualUnmountSuppressionsSnapshot(),
                "rawAccessMode": "single EDP Drive Full Disk Access identity broker + retained raw fd + inherited transport fd",
                "rawAccessDaemon": rawAccessDaemonPath(),
                "rawAccessReadyDeviceIDs": rawAccess.readyDeviceIDs(),
                "rawAccessErrors": rawAccess.errorsSnapshot(),
                "nativeMountCount": EDPNativeMountTable.entries().count,
                "legacyDiscoveryCLI": false,
                "legacyMountCLI": false,
                "eventDrivenDiscovery": true,
                "automaticMountRetry": false,
                "credentialStore": "System Keychain",
                "startupRecoveryComplete": serviceLifecycle.startupRecoveryComplete,
                "startupRecoveryError": serviceLifecycle.startupRecoveryError as Any,
                "deviceDiscoveryDiagnostics": EDPNativeDeviceDiscovery.diagnosticReport()
                    + discovery.diagnostics,
                "discoveryScanCount": discovery.scanCount,
                "lastDiscoveryTimestamp": discovery.lastScanTimestamp,
                "runtimeMetrics": metrics.snapshot().jsonObject,
            ]
            return (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        }
    }

    func shutdownGracefullyAsync(completion: @escaping EDPDaemonMountCompletion) {
        queue.async { [weak self] in
            guard let self else {
                completion("EDP service controller was released")
                return
            }
            guard self.serviceLifecycle.beginShutdown(completion: completion) else {
                self.manager.recordShutdownCoalesced()
                return
            }
            self.beginShutdownTeardownIfReadyLocked()
        }
    }

    private func beginShutdownTeardownIfReadyLocked() {
        guard serviceLifecycle.beginTeardownIfReady(
            hasActiveEjects: eject.hasActiveEjects
        ) else { return }
        manager.unmountAllAsync { [weak self] errorMessage in
            guard let self else { return }
            self.onControllerQueue {
                var finalError = errorMessage
                if finalError == nil, !self.manager.mountedSummaries().isEmpty {
                    finalError = "one or more EDP sessions could not be safely unmounted"
                }
                if finalError == nil {
                    self.rawAccess.invalidateAll()
                    self.connectedDisks.removeAll()
                    self.addActivity("后台服务已安全停止")
                } else {
                    // Failed shutdown remains quiesced. The caller can report
                    // the error without allowing new mount work to race the
                    // partially torn-down state.
                    self.addActivity(
                        "后台服务停止失败：\(finalError!)",
                        level: "error"
                    )
                }
                let completions = self.serviceLifecycle.finishShutdown()
                for callback in completions { callback(finalError) }
            }
        }
    }

#if EDP_REGRESSION_TESTS
    private func waitForRegressionOperation(
        timeout: TimeInterval = 45,
        start: (@escaping EDPDaemonMountCompletion) -> Void
    ) throws {
        guard DispatchQueue.getSpecific(key: queueKey) == nil else {
            throw fail("regression sync adapter cannot run on the controller queue")
        }
        let semaphore = DispatchSemaphore(value: 0)
        let result = EDPRegressionAsyncResultBox()
        start { errorMessage in
            result.set(errorMessage)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw fail("regression async operation timed out")
        }
        if let errorMessage = result.snapshot() {
            throw fail(errorMessage)
        }
    }

    func mountPartition(deviceID: String, partitionType: UInt32) throws {
        try waitForRegressionOperation {
            mountPartitionAsync(
                deviceID: deviceID,
                partitionType: partitionType,
                completion: $0
            )
        }
    }

    func unmountPartition(deviceID: String, partitionType: UInt32) throws {
        try waitForRegressionOperation {
            unmountPartitionAsync(
                deviceID: deviceID,
                partitionType: partitionType,
                completion: $0
            )
        }
    }

    func saveCredential(
        deviceID: String,
        partitionType: UInt32,
        passwordData: Data
    ) throws {
        try waitForRegressionOperation {
            saveCredentialAsync(
                deviceID: deviceID,
                partitionType: partitionType,
                passwordData: passwordData,
                completion: $0
            )
        }
    }

    func deleteCredential(deviceID: String, partitionType: UInt32) throws {
        try waitForRegressionOperation {
            deleteCredentialAsync(
                deviceID: deviceID,
                partitionType: partitionType,
                completion: $0
            )
        }
    }

    func eject(deviceID: String) throws {
        try waitForRegressionOperation {
            ejectAsync(deviceID: deviceID, completion: $0)
        }
    }

    func shutdownGracefully() throws {
        try waitForRegressionOperation {
            shutdownGracefullyAsync(completion: $0)
        }
    }
#endif
}
