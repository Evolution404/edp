import Darwin
import Foundation
import Security

private struct VirtualUSBLabError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class VirtualUSBSecurityContext {
    let root: URL
    let keychainURL: URL
    let policyURL: URL
    let credentialIndexURL: URL
    let ejectSuppressionURL: URL
    private let keychain: SecKeychain

    init() throws {
        let localRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edp-virtual-usb-lab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        let localKeychainURL = localRoot.appendingPathComponent("test.keychain-db")
        let password = Data("edp-virtual-usb-lab-keychain".utf8)
        var created: SecKeychain?
        let createStatus = password.withUnsafeBytes { raw in
            SecKeychainCreate(
                localKeychainURL.path,
                UInt32(raw.count),
                raw.baseAddress,
                false,
                nil,
                &created
            )
        }
        guard createStatus == errSecSuccess, let created else {
            throw VirtualUSBLabError("temporary keychain create failed: \(createStatus)")
        }
        let unlockStatus = password.withUnsafeBytes { raw in
            SecKeychainUnlock(created, UInt32(raw.count), raw.baseAddress, true)
        }
        guard unlockStatus == errSecSuccess else {
            _ = SecKeychainDelete(created)
            throw VirtualUSBLabError("temporary keychain unlock failed: \(unlockStatus)")
        }
        root = localRoot
        keychainURL = localKeychainURL
        policyURL = localRoot.appendingPathComponent("policy.json")
        credentialIndexURL = localRoot.appendingPathComponent("credential-index.json")
        ejectSuppressionURL = localRoot.appendingPathComponent("logical-eject-suppressions.json")
        keychain = created
    }

    deinit {
        _ = SecKeychainDelete(keychain)
        try? FileManager.default.removeItem(at: root)
    }

    func credentialStore() throws -> EDPCredentialStore {
        try EDPCredentialStore(
            indexPath: credentialIndexURL.path,
            keychainPath: keychainURL.path,
            restrictToRoot: false
        )
    }

    func policyStore() throws -> EDPDevicePolicyStore {
        try EDPDevicePolicyStore(path: policyURL.path)
    }
}

private final class VirtualUSBMountManager: EDPDaemonMountManaging, @unchecked Sendable {
    struct Mounted: Sendable {
        let physicalBSD: String
        let deviceID: String
        let partitionType: UInt32
    }

    private let lock = NSLock()
    private var mounted = [String: Mounted]()

    private func key(_ deviceID: String, _ partitionType: UInt32) -> String {
        "\(deviceID):\(partitionType)"
    }

    func recoverPersistedSessionsAsync(completion: @escaping EDPDaemonMountCompletion) {
        completion(nil)
    }

    func contains(_ disk: PhysicalDisk, _ type: UInt32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return mounted[key(disk.deviceID, type)] != nil
    }

    func mountedPhysicalDisks() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(mounted.values.map(\.physicalBSD))
    }

    func isMounted(deviceID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return mounted.values.contains { $0.deviceID == deviceID }
    }

    func mountedSummaries() -> [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        return mounted.values.map {
            [
                "deviceID": $0.deviceID,
                "physicalBSD": $0.physicalBSD,
                "partitionType": String($0.partitionType),
                "filesystem": "VirtualFS",
                "mountpoint": "/virtual/edp/\($0.partitionType)",
            ]
        }
    }

    func summary(deviceID: String, partitionType: UInt32) -> [String: String]? {
        lock.lock(); defer { lock.unlock() }
        guard mounted[key(deviceID, partitionType)] != nil else { return nil }
        return [
            "filesystem": "VirtualFS",
            "mountpoint": "/virtual/edp/\(partitionType)",
            "exposedBSD": "virtual\(partitionType)",
        ]
    }

    func mountAsync(
        disk: PhysicalDisk,
        partitionType: UInt32,
        password: [UInt8],
        rawFD: Int32,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        _ = password
        _ = rawFD
        lock.lock()
        mounted[key(disk.deviceID, partitionType)] = Mounted(
            physicalBSD: disk.bsdName,
            deviceID: disk.deviceID,
            partitionType: partitionType
        )
        lock.unlock()
        completion(nil)
    }

    func unmountAsync(
        deviceID: String,
        partitionType: UInt32,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        lock.lock()
        mounted.removeValue(forKey: key(deviceID, partitionType))
        lock.unlock()
        completion(nil)
    }

    func ejectAsync(deviceID: String, completion: @escaping EDPDaemonMountCompletion) {
        lock.lock()
        mounted = mounted.filter { $0.value.deviceID != deviceID }
        lock.unlock()
        completion(nil)
    }

    @discardableResult
    func removeMissing(availableDisks: [String: String], graceSeconds: TimeInterval) -> Bool {
        _ = graceSeconds
        lock.lock()
        mounted = mounted.filter { _, session in
            availableDisks[session.deviceID] == session.physicalBSD
        }
        lock.unlock()
        return false
    }

    func unmountAllAsync(completion: @escaping EDPDaemonMountCompletion) {
        lock.lock()
        mounted.removeAll()
        lock.unlock()
        completion(nil)
    }

    func mountedPartitionTypes(deviceID: String) -> Set<UInt32> {
        lock.lock(); defer { lock.unlock() }
        return Set(mounted.values.filter { $0.deviceID == deviceID }.map(\.partitionType))
    }
}

private final class VirtualUSBDiskArbitration: EDPDaemonDiskArbitrating, @unchecked Sendable {
    private let lock = NSLock()
    private var suppressed = Set<UInt64>()
    private var claimedRegistryEntries = Set<UInt64>()
    private var systemMountedWholeBSDs = Set<String>()
    private var events = [String]()
    private var unmountWholeCount = 0
    private var forceUnmountWholeCount = 0
    private var ejectCount = 0

    func suppressAutomount(usbRegistryEntryID: UInt64) {
        lock.lock()
        suppressed.insert(usbRegistryEntryID)
        events.append("suppress:\(usbRegistryEntryID)")
        lock.unlock()
    }

    func allowAutomount(usbRegistryEntryID: UInt64) {
        lock.lock()
        suppressed.remove(usbRegistryEntryID)
        events.append("allow:\(usbRegistryEntryID)")
        lock.unlock()
    }

    func hasExclusiveClaim(_ bsdName: String, expectedRegistryEntryID: UInt64) -> Bool {
        _ = bsdName
        lock.lock(); defer { lock.unlock() }
        return claimedRegistryEntries.contains(expectedRegistryEntryID)
    }

    func unmountWholeAsync(
        _ bsdName: String,
        expectedRegistryEntryID: UInt64?,
        completion: @escaping EDPDiskArbitrationVoidCompletion
    ) {
        _ = expectedRegistryEntryID
        lock.lock()
        systemMountedWholeBSDs.remove(bsdName)
        unmountWholeCount += 1
        events.append("whole_unmount:\(bsdName)")
        lock.unlock()
        completion(nil)
    }

    func forceUnmountWholeAsync(
        _ bsdName: String,
        expectedRegistryEntryID: UInt64?,
        completion: @escaping EDPDiskArbitrationVoidCompletion
    ) {
        _ = expectedRegistryEntryID
        lock.lock()
        systemMountedWholeBSDs.remove(bsdName)
        forceUnmountWholeCount += 1
        events.append("whole_force_unmount:\(bsdName)")
        lock.unlock()
        completion(nil)
    }

    func ejectAsync(
        _ bsdName: String,
        expectedRegistryEntryID: UInt64?,
        completion: @escaping EDPDiskArbitrationVoidCompletion
    ) {
        lock.lock()
        systemMountedWholeBSDs.remove(bsdName)
        if let expectedRegistryEntryID {
            claimedRegistryEntries.remove(expectedRegistryEntryID)
        }
        ejectCount += 1
        events.append("eject:\(bsdName)")
        lock.unlock()
        completion(nil)
    }

    func simulatePhysicalInsert(
        media: EDPWholeUSBMedia,
        classifier: EDPEarlyDiskClaimClassifier,
        serviceRunning: Bool
    ) {
        lock.lock()
        events.append("insert:\(media.bsdName):\(media.registryEntryID):\(media.usbRegistryEntryID)")
        lock.unlock()

        if serviceRunning,
           classifier.claimCandidate(usbRegistryEntryID: media.usbRegistryEntryID) != nil {
            lock.lock()
            claimedRegistryEntries.insert(media.registryEntryID)
            systemMountedWholeBSDs.remove(media.bsdName)
            events.append("mount_approval_dissent:\(media.bsdName)")
            events.append("claim:\(media.bsdName):\(media.registryEntryID)")
            lock.unlock()
        } else {
            lock.lock()
            systemMountedWholeBSDs.insert(media.bsdName)
            events.append("system_automount:\(media.bsdName)")
            lock.unlock()
        }
    }

    func simulateServiceClaim(media: EDPWholeUSBMedia, classifier: EDPEarlyDiskClaimClassifier) {
        guard classifier.claimCandidate(usbRegistryEntryID: media.usbRegistryEntryID) != nil else { return }
        lock.lock()
        claimedRegistryEntries.insert(media.registryEntryID)
        events.append("claim_existing:\(media.bsdName):\(media.registryEntryID)")
        lock.unlock()
    }

    func simulatePhysicalRemove(media: EDPWholeUSBMedia) {
        lock.lock()
        claimedRegistryEntries.remove(media.registryEntryID)
        systemMountedWholeBSDs.remove(media.bsdName)
        suppressed.remove(media.usbRegistryEntryID)
        events.append("remove:\(media.bsdName):\(media.registryEntryID):\(media.usbRegistryEntryID)")
        lock.unlock()
    }

    func isSystemMounted(_ bsdName: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return systemMountedWholeBSDs.contains(bsdName)
    }

    func mountedBSDPrefix(_ bsdName: String) -> Bool {
        isSystemMounted(bsdName)
    }

    func hasClaim(registryEntryID: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return claimedRegistryEntries.contains(registryEntryID)
    }

    func eventSnapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    func counters() -> (unmount: Int, forceUnmount: Int, eject: Int) {
        lock.lock(); defer { lock.unlock() }
        return (unmountWholeCount, forceUnmountWholeCount, ejectCount)
    }
}

private final class VirtualUSBIntegrationLab {
    let state = EDPVirtualUSBState()
    let diskArbitration = VirtualUSBDiskArbitration()
    let mountManager = VirtualUSBMountManager()
    let metrics = EDPRuntimeMetrics()
    let security: VirtualUSBSecurityContext
    let credentials: EDPCredentialStore
    let policies: EDPDevicePolicyStore
    let fixture: EDPVirtualMediaDevice
    let classifier: EDPEarlyDiskClaimClassifier
    let controller: EDPServiceController
    private let verifierMetadata: EDPRawMetadataSnapshot

    init(fixtureDirectory: String, bootWithSystemMountedDevice: Bool) throws {
        security = try VirtualUSBSecurityContext()
        credentials = try security.credentialStore()
        policies = try security.policyStore()
        fixture = try EDPVirtualDiskFactory.capturedDisk4(fixtureDirectory: fixtureDirectory)
        verifierMetadata = fixture.metadata
        classifier = EDPEarlyDiskClaimClassifier(
            mediaProvider: EDPVirtualWholeUSBMediaProvider(state: state),
            metadataReader: EDPVirtualRawMetadataReader(state: state)
        )

        if bootWithSystemMountedDevice {
            state.insert(
                fixture,
                as: "disk40",
                registryEntryID: 0x4000,
                usbRegistryEntryID: 0x4001
            )
            guard let media = state.device(for: "disk40")?.media else {
                throw VirtualUSBLabError("boot fixture insert failed")
            }
            diskArbitration.simulatePhysicalInsert(
                media: media,
                classifier: classifier,
                serviceRunning: false
            )
            diskArbitration.simulateServiceClaim(media: media, classifier: classifier)
        }

        controller = try EDPServiceController(
            store: credentials,
            policies: policies,
            manager: mountManager,
            diskArbitration: diskArbitration,
            mediaProvider: EDPVirtualWholeUSBMediaProvider(state: state),
            metadataReader: EDPVirtualRawMetadataReader(state: state),
            rawAccessLeaseOpener: { [diskArbitration] disk in
                if diskArbitration.isSystemMounted(disk.bsdName) {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))
                }
                return EDPRawAccessLease(
                    deviceID: disk.deviceID,
                    registryEntryID: disk.registryEntryID,
                    rawPath: disk.rawPath,
                    fd: -1
                )
            },
            credentialVerifier: { [verifierMetadata] disk, partitionType, password, _ in
                let media = EDPWholeUSBMedia(
                    bsdName: disk.bsdName,
                    sizeBytes: disk.sizeBytes,
                    mediaName: disk.mediaName,
                    vidHex: disk.vidHex,
                    pidHex: disk.pidHex,
                    registryEntryID: disk.registryEntryID,
                    usbRegistryEntryID: disk.usbRegistryEntryID
                )
                let resolved = EDPPhysicalIdentityResolver.resolve(media: media, metadata: verifierMetadata)
                guard let metadataDeviceID = resolved.metadataDeviceID else {
                    throw VirtualUSBLabError("virtual metadata device identity unavailable")
                }
                let plain = try EDPVolumeMetadata.decodeLBA12(
                    [UInt8](verifierMetadata.lba12),
                    deviceID: metadataDeviceID
                )
                let unlocked = try EDPVolumeMetadata.parseLBA12Entries(
                    plain,
                    password: password
                ).map(\.partitionType)
                guard unlocked.contains(partitionType) else {
                    throw VirtualUSBLabError("virtual password did not unlock partition \(partitionType)")
                }
            },
            metrics: metrics,
            mountedBSDPrefixChecker: { [diskArbitration] bsdName in
                diskArbitration.mountedBSDPrefix(bsdName)
            },
            ejectSuppressionPath: security.ejectSuppressionURL.path,
            performLegacyRuntimeMigration: false
        )
        controller.drainForTesting()
        controller.reconcileSynchronouslyForTesting()
        controller.drainForTesting()
    }

    func snapshot() throws -> EDPXPCSnapshot {
        try JSONDecoder().decode(EDPXPCSnapshot.self, from: controller.snapshotData())
    }

    func connectedDevice() throws -> EDPXPCDevice {
        guard let device = try snapshot().devices.first(where: \.connected) else {
            throw VirtualUSBLabError("expected one connected virtual EDP device")
        }
        return device
    }

    func waitFor(
        _ label: String,
        attempts: Int = 100,
        condition: () throws -> Bool
    ) throws {
        for _ in 0..<attempts {
            controller.drainForTesting()
            if try condition() { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw VirtualUSBLabError("timed out: \(label)")
    }

    @discardableResult
    func insertStandard(
        bsdName: String,
        registryEntryID: UInt64,
        usbRegistryEntryID: UInt64,
        serviceRunning: Bool = true
    ) throws -> EDPXPCDevice {
        state.insert(
            fixture,
            as: bsdName,
            registryEntryID: registryEntryID,
            usbRegistryEntryID: usbRegistryEntryID
        )
        guard let media = state.device(for: bsdName)?.media else {
            throw VirtualUSBLabError("virtual insert failed for \(bsdName)")
        }
        diskArbitration.simulatePhysicalInsert(
            media: media,
            classifier: classifier,
            serviceRunning: serviceRunning
        )
        controller.reconcileSynchronouslyForTesting()
        try waitFor("raw access ready after insert \(bsdName)") {
            (try? connectedDevice().privilegedAccessReady) == true
        }
        return try connectedDevice()
    }

    func remove(bsdName: String) throws {
        guard let media = state.device(for: bsdName)?.media else {
            throw VirtualUSBLabError("cannot remove missing virtual device \(bsdName)")
        }
        state.remove(bsdName)
        diskArbitration.simulatePhysicalRemove(media: media)
        controller.reconcileSynchronouslyForTesting()
        controller.drainForTesting()
    }

    func metricsMustRemainRecoveryFree(_ label: String) throws {
        let snapshot = metrics.snapshot()
        guard snapshot.rawBusyRecoveryCount == 0,
              snapshot.forcedWholeUnmountCount == 0,
              snapshot.mountRetryCount == 0 else {
            throw VirtualUSBLabError(
                "\(label): unexpected recovery metrics rawBusy=\(snapshot.rawBusyRecoveryCount) force=\(snapshot.forcedWholeUnmountCount) mountRetry=\(snapshot.mountRetryCount)"
            )
        }
    }
}

@main
struct ValidateVirtualUSBIntegrationLab {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw VirtualUSBLabError("usage: validate-virtual-usb-integration-lab <real_disks/disk4>")
        }

        let lab = try VirtualUSBIntegrationLab(
            fixtureDirectory: CommandLine.arguments[1],
            bootWithSystemMountedDevice: true
        )

        try validateBootTakeover(lab)
        let identity = try validateFreshInsertion(lab)
        try validateMountLifecycle(lab, deviceID: identity)
        try validateRuntimeLifecycle(lab, deviceID: identity)
        try validateSafeEjectAndReinsert(lab, deviceID: identity)
        try validateAbruptUnplugWhileMounted(lab, deviceID: identity)
        try validateNonEDPFailOpen(lab)
        try lab.metricsMustRemainRecoveryFree("final")

        print("RESULT=DRIVE_VIRTUAL_USB_INTEGRATION_LAB_OK")
    }

    private static func validateBootTakeover(_ lab: VirtualUSBIntegrationLab) throws {
        let device = try lab.connectedDevice()
        guard device.bsdName == "disk40",
              device.privilegedAccessReady,
              !lab.diskArbitration.isSystemMounted("disk40"),
              lab.diskArbitration.hasClaim(registryEntryID: 0x4000),
              lab.diskArbitration.counters().unmount >= 1 else {
            throw VirtualUSBLabError("V01 boot takeover did not unmount the virtual system-owned child and retain raw access")
        }
        try lab.metricsMustRemainRecoveryFree("V01")
        print("SCENARIO=V01_OK boot_system_automount_then_edp_takeover_without_physical_usb")
    }

    private static func validateFreshInsertion(_ lab: VirtualUSBIntegrationLab) throws -> String {
        let first = try lab.connectedDevice()
        let stableID = first.deviceID
        try lab.remove(bsdName: "disk40")
        let second = try lab.insertStandard(
            bsdName: "disk77",
            registryEntryID: 0x7700,
            usbRegistryEntryID: 0x7701
        )
        let events = lab.diskArbitration.eventSnapshot()
        guard second.deviceID == stableID,
              second.bsdName == "disk77",
              second.privilegedAccessReady,
              lab.diskArbitration.hasClaim(registryEntryID: 0x7700),
              !lab.diskArbitration.isSystemMounted("disk77"),
              events.contains("mount_approval_dissent:disk77") else {
            throw VirtualUSBLabError("V02 fresh virtual insertion did not model mount-approval denial + claim")
        }
        try lab.metricsMustRemainRecoveryFree("V02")
        print("SCENARIO=V02_OK fresh_insert_mount_approval_dissent_claim_raw_ready")
        return stableID
    }

    private static func validateMountLifecycle(
        _ lab: VirtualUSBIntegrationLab,
        deviceID: String
    ) throws {
        let password = Data("0000aaaa".utf8)
        try lab.controller.saveCredential(deviceID: deviceID, partitionType: 2, passwordData: password)
        try lab.controller.saveCredential(deviceID: deviceID, partitionType: 4, passwordData: password)

        for partitionType in [UInt32(1), 2, 4] {
            try lab.controller.mountPartition(deviceID: deviceID, partitionType: partitionType)
            guard lab.mountManager.mountedPartitionTypes(deviceID: deviceID).contains(partitionType) else {
                throw VirtualUSBLabError("V03 partition \(partitionType) did not mount in virtual manager")
            }
            try lab.controller.unmountPartition(deviceID: deviceID, partitionType: partitionType)
            guard !lab.mountManager.mountedPartitionTypes(deviceID: deviceID).contains(partitionType) else {
                throw VirtualUSBLabError("V03 partition \(partitionType) did not unmount in virtual manager")
            }
        }
        print("SCENARIO=V03_OK virtual_partition_1_2_4_mount_unmount")
    }

    private static func validateRuntimeLifecycle(
        _ lab: VirtualUSBIntegrationLab,
        deviceID: String
    ) throws {
        try lab.controller.pauseRuntime()
        guard (try lab.snapshot().devices.first { $0.deviceID == deviceID })?.privilegedAccessReady == false else {
            throw VirtualUSBLabError("V04 pause did not release virtual raw access")
        }
        try lab.controller.resumeRuntime()
        try lab.waitFor("V04 resume raw ready") {
            (try? lab.snapshot().devices.first { $0.deviceID == deviceID }?.privilegedAccessReady) == true
        }
        try lab.controller.restartRuntime()
        try lab.waitFor("V04 restart raw ready") {
            (try? lab.snapshot().devices.first { $0.deviceID == deviceID }?.privilegedAccessReady) == true
        }
        try lab.metricsMustRemainRecoveryFree("V04")
        print("SCENARIO=V04_OK virtual_pause_resume_restart_same_generation")
    }

    private static func validateSafeEjectAndReinsert(
        _ lab: VirtualUSBIntegrationLab,
        deviceID: String
    ) throws {
        try lab.controller.eject(deviceID: deviceID)
        guard let ejected = try lab.snapshot().devices.first(where: { $0.deviceID == deviceID }),
              !ejected.connected,
              !ejected.privilegedAccessReady,
              ejected.rawAccessState == .logicallyEjected else {
            throw VirtualUSBLabError("V05 safe eject did not suppress the still-present virtual generation")
        }
        try lab.controller.restartRuntime()
        guard let stillEjected = try lab.snapshot().devices.first(where: { $0.deviceID == deviceID }),
              !stillEjected.connected,
              !stillEjected.privilegedAccessReady else {
            throw VirtualUSBLabError("V05 runtime restart reacquired logically-ejected virtual generation")
        }

        try lab.remove(bsdName: "disk77")
        let reinserted = try lab.insertStandard(
            bsdName: "disk103",
            registryEntryID: 0x10300,
            usbRegistryEntryID: 0x10301
        )
        guard reinserted.deviceID == deviceID,
              reinserted.bsdName == "disk103",
              reinserted.privilegedAccessReady,
              lab.diskArbitration.hasClaim(registryEntryID: 0x10300) else {
            throw VirtualUSBLabError("V05 new virtual generation was not admitted after exact removal")
        }
        try lab.metricsMustRemainRecoveryFree("V05")
        print("SCENARIO=V05_OK virtual_safe_eject_remove_reinsert_new_generation")
    }

    private static func validateAbruptUnplugWhileMounted(
        _ lab: VirtualUSBIntegrationLab,
        deviceID: String
    ) throws {
        try lab.controller.mountPartition(deviceID: deviceID, partitionType: 2)
        guard lab.mountManager.mountedPartitionTypes(deviceID: deviceID) == [2] else {
            throw VirtualUSBLabError("V06 precondition mount failed")
        }
        try lab.remove(bsdName: "disk103")
        guard lab.mountManager.mountedPartitionTypes(deviceID: deviceID).isEmpty,
              try lab.snapshot().devices.first(where: { $0.deviceID == deviceID })?.connected == false else {
            throw VirtualUSBLabError("V06 abrupt virtual unplug left a mounted session or connected device")
        }
        let recovered = try lab.insertStandard(
            bsdName: "disk204",
            registryEntryID: 0x20400,
            usbRegistryEntryID: 0x20401
        )
        guard recovered.deviceID == deviceID, recovered.privilegedAccessReady else {
            throw VirtualUSBLabError("V06 reinsert after abrupt virtual unplug did not recover")
        }
        print("SCENARIO=V06_OK abrupt_virtual_unplug_while_mounted_cleans_session_and_recovers")
    }

    private static func validateNonEDPFailOpen(_ lab: VirtualUSBIntegrationLab) throws {
        try lab.remove(bsdName: "disk204")
        let ordinary = EDPVirtualDiskFactory.withCapacity(lab.fixture, sizeBytes: 4096)
        lab.state.insert(
            ordinary,
            as: "disk300",
            registryEntryID: 0x30000,
            usbRegistryEntryID: 0x30001
        )
        guard let media = lab.state.device(for: "disk300")?.media else {
            throw VirtualUSBLabError("V07 ordinary virtual media insert failed")
        }
        lab.diskArbitration.simulatePhysicalInsert(
            media: media,
            classifier: lab.classifier,
            serviceRunning: true
        )
        lab.controller.reconcileSynchronouslyForTesting()
        let connected = try lab.snapshot().devices.filter(\.connected)
        guard connected.isEmpty,
              lab.diskArbitration.isSystemMounted("disk300"),
              !lab.diskArbitration.hasClaim(registryEntryID: 0x30000) else {
            throw VirtualUSBLabError("V07 non-EDP virtual media did not fail open to the simulated OS")
        }
        print("SCENARIO=V07_OK non_edp_virtual_usb_fail_open_to_system")
    }
}
