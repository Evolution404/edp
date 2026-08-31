import Darwin
import Foundation
import Security

private struct LifecycleValidationError: Error, CustomStringConvertible, Sendable {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class TemporaryKeychainContext {
    let root: URL
    let keychainURL: URL
    let policyURL: URL
    let credentialIndexURL: URL
    private let keychain: SecKeychain

    init() throws {
        let localRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edp-test-e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        let localKeychainURL = localRoot.appendingPathComponent("test.keychain-db")
        let localPolicyURL = localRoot.appendingPathComponent("policy.json")
        let localCredentialIndexURL = localRoot.appendingPathComponent("credential-index.json")

        let password = Data("edp-test-e-keychain-password".utf8)
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
            throw LifecycleValidationError("temporary Keychain create failed: \(createStatus)")
        }
        let unlockStatus = password.withUnsafeBytes { raw in
            SecKeychainUnlock(
                created,
                UInt32(raw.count),
                raw.baseAddress,
                true
            )
        }
        guard unlockStatus == errSecSuccess else {
            _ = SecKeychainDelete(created)
            throw LifecycleValidationError("temporary Keychain unlock failed: \(unlockStatus)")
        }
        root = localRoot
        keychainURL = localKeychainURL
        policyURL = localPolicyURL
        credentialIndexURL = localCredentialIndexURL
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

private final class FakeMountManager: EDPDaemonMountManaging, @unchecked Sendable {
    struct Mounted: Sendable {
        let physicalBSD: String
        let deviceID: String
        let partitionType: UInt32
    }

    private final class PendingMount: @unchecked Sendable {
        let mounted: Mounted
        let primary: EDPDaemonMountCompletion
        var duplicateWaiters = [EDPDaemonMountCompletion]()
        var unmountWaiters = [EDPDaemonMountCompletion]()
        var cancelled = false

        init(mounted: Mounted, primary: @escaping EDPDaemonMountCompletion) {
            self.mounted = mounted
            self.primary = primary
        }
    }

    private let asyncLock = NSLock()
    private var heldMountKeys = Set<String>()
    private var pendingMounts = [String: PendingMount]()
    private var pendingEjectWaiters = [String: [EDPDaemonMountCompletion]]()
    private var pendingUnmountAllWaiters = [EDPDaemonMountCompletion]()
    private(set) var mounted = [String: Mounted]()
    private(set) var mountAttempts = [String: Int]()
    private(set) var recoverCount = 0
    private(set) var unmountAllCount = 0
    private var failures = [String: (remaining: Int, message: String)]()
    private var unmountFailures = [String: (remaining: Int, message: String)]()
    private var ejectFailures = [String: (remaining: Int, message: String)]()
    var staleSessionCount = 0

    private func key(_ deviceID: String, _ partitionType: UInt32) -> String {
        "\(deviceID):\(partitionType)"
    }

    func failNextMounts(deviceID: String, partitionType: UInt32, count: Int, message: String) {
        failures[key(deviceID, partitionType)] = (count, message)
    }

    func holdNextMount(deviceID: String, partitionType: UInt32) {
        asyncLock.lock()
        heldMountKeys.insert(key(deviceID, partitionType))
        asyncLock.unlock()
    }

    func hasPendingMount(deviceID: String, partitionType: UInt32) -> Bool {
        asyncLock.lock()
        defer { asyncLock.unlock() }
        return pendingMounts[key(deviceID, partitionType)] != nil
    }

    func pendingDuplicateWaiterCount(deviceID: String, partitionType: UInt32) -> Int {
        asyncLock.lock()
        defer { asyncLock.unlock() }
        return pendingMounts[key(deviceID, partitionType)]?.duplicateWaiters.count ?? 0
    }

    func pendingMountIsCancelled(deviceID: String, partitionType: UInt32) -> Bool {
        asyncLock.lock()
        defer { asyncLock.unlock() }
        return pendingMounts[key(deviceID, partitionType)]?.cancelled == true
    }

    func mountAttemptCount(deviceID: String, partitionType: UInt32) -> Int {
        asyncLock.lock()
        defer { asyncLock.unlock() }
        return mountAttempts[key(deviceID, partitionType), default: 0]
    }

    func releaseHeldMount(
        deviceID: String,
        partitionType: UInt32,
        errorMessage: String? = nil
    ) {
        let sessionKey = key(deviceID, partitionType)
        var mountCallbacks = [EDPDaemonMountCompletion]()
        var mountResult = errorMessage
        var unmountCallbacks = [EDPDaemonMountCompletion]()
        var ejectCallbacks = [EDPDaemonMountCompletion]()
        var shutdownCallbacks = [EDPDaemonMountCompletion]()

        asyncLock.lock()
        guard let pending = pendingMounts.removeValue(forKey: sessionKey) else {
            asyncLock.unlock()
            return
        }
        mountCallbacks = [pending.primary] + pending.duplicateWaiters
        unmountCallbacks = pending.unmountWaiters
        if pending.cancelled {
            mountResult = "mount operation cancelled"
        } else if mountResult == nil {
            mounted[sessionKey] = pending.mounted
        }

        if pendingMounts.values.allSatisfy({ $0.mounted.deviceID != deviceID }),
           let callbacks = pendingEjectWaiters.removeValue(forKey: deviceID) {
            mounted = mounted.filter { $0.value.deviceID != deviceID }
            ejectCallbacks = callbacks
        }
        if pendingMounts.isEmpty, !pendingUnmountAllWaiters.isEmpty {
            mounted.removeAll()
            shutdownCallbacks = pendingUnmountAllWaiters
            pendingUnmountAllWaiters.removeAll()
        }
        asyncLock.unlock()

        for callback in mountCallbacks { callback(mountResult) }
        for callback in unmountCallbacks { callback(nil) }
        for callback in ejectCallbacks { callback(nil) }
        for callback in shutdownCallbacks { callback(nil) }
    }

    func failNextUnmounts(deviceID: String, partitionType: UInt32, count: Int, message: String) {
        unmountFailures[key(deviceID, partitionType)] = (count, message)
    }

    func failNextEjects(deviceID: String, count: Int, message: String) {
        ejectFailures[deviceID] = (count, message)
    }

    func recoverPersistedSessionsAsync(completion: @escaping EDPDaemonMountCompletion) {
        recoverCount += 1
        staleSessionCount = 0
        completion(nil)
    }

    func contains(_ disk: PhysicalDisk, _ type: UInt32) -> Bool {
        asyncLock.lock()
        defer { asyncLock.unlock() }
        let sessionKey = key(disk.deviceID, type)
        return mounted[sessionKey] != nil || pendingMounts[sessionKey] != nil
    }

    func mountedPhysicalDisks() -> Set<String> {
        Set(mounted.values.map(\.physicalBSD))
    }

    func isMounted(deviceID: String) -> Bool {
        asyncLock.lock()
        defer { asyncLock.unlock() }
        return mounted.values.contains { $0.deviceID == deviceID }
            || pendingMounts.values.contains { $0.mounted.deviceID == deviceID }
    }

    func mountedSummaries() -> [[String: String]] {
        mounted.values.map {
            [
                "deviceID": $0.deviceID,
                "physicalBSD": $0.physicalBSD,
                "partitionType": String($0.partitionType),
                "filesystem": "VirtualFS",
                "mountpoint": "",
            ]
        }
    }

    func summary(deviceID: String, partitionType: UInt32) -> [String: String]? {
        guard mounted[key(deviceID, partitionType)] != nil else { return nil }
        return [
            "filesystem": "VirtualFS",
            "mountpoint": "",
            "exposedBSD": "",
        ]
    }

    func ejectAsync(deviceID: String, completion: @escaping EDPDaemonMountCompletion) {
        asyncLock.lock()
        if var failure = ejectFailures[deviceID], failure.remaining > 0 {
            failure.remaining -= 1
            ejectFailures[deviceID] = failure
            asyncLock.unlock()
            completion(failure.message)
            return
        }
        let pending = pendingMounts.values.filter { $0.mounted.deviceID == deviceID }
        if !pending.isEmpty {
            for item in pending { item.cancelled = true }
            pendingEjectWaiters[deviceID, default: []].append(completion)
            asyncLock.unlock()
            return
        }
        mounted = mounted.filter { $0.value.deviceID != deviceID }
        asyncLock.unlock()
        completion(nil)
    }

    func unmountAsync(
        deviceID: String,
        partitionType: UInt32,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        let sessionKey = key(deviceID, partitionType)
        asyncLock.lock()
        if var failure = unmountFailures[sessionKey], failure.remaining > 0 {
            failure.remaining -= 1
            unmountFailures[sessionKey] = failure
            asyncLock.unlock()
            completion(failure.message)
            return
        }
        if let pending = pendingMounts[sessionKey] {
            pending.cancelled = true
            pending.unmountWaiters.append(completion)
            asyncLock.unlock()
            return
        }
        mounted.removeValue(forKey: sessionKey)
        asyncLock.unlock()
        completion(nil)
    }

    func mountAsync(
        disk: PhysicalDisk,
        partitionType: UInt32,
        password: [UInt8],
        rawFD: Int32,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        let sessionKey = key(disk.deviceID, partitionType)
        asyncLock.lock()
        if mounted[sessionKey] != nil {
            asyncLock.unlock()
            completion(nil)
            return
        }
        if let pending = pendingMounts[sessionKey] {
            pending.duplicateWaiters.append(completion)
            asyncLock.unlock()
            return
        }
        mountAttempts[sessionKey, default: 0] += 1
        if var failure = failures[sessionKey], failure.remaining > 0 {
            failure.remaining -= 1
            failures[sessionKey] = failure
            asyncLock.unlock()
            completion(failure.message)
            return
        }
        let mountedValue = Mounted(
            physicalBSD: disk.bsdName,
            deviceID: disk.deviceID,
            partitionType: partitionType
        )
        if heldMountKeys.remove(sessionKey) != nil {
            pendingMounts[sessionKey] = PendingMount(
                mounted: mountedValue,
                primary: completion
            )
            asyncLock.unlock()
            return
        }
        mounted[sessionKey] = mountedValue
        asyncLock.unlock()
        completion(nil)
    }

    @discardableResult
    func removeMissing(availableDisks: [String: String], graceSeconds: TimeInterval) -> Bool {
        mounted = mounted.filter { _, session in
            availableDisks[session.deviceID] == session.physicalBSD
        }
        return false
    }

    func unmountAllAsync(completion: @escaping EDPDaemonMountCompletion) {
        asyncLock.lock()
        unmountAllCount += 1
        if !pendingMounts.isEmpty {
            for pending in pendingMounts.values { pending.cancelled = true }
            pendingUnmountAllWaiters.append(completion)
            asyncLock.unlock()
            return
        }
        mounted.removeAll()
        asyncLock.unlock()
        completion(nil)
    }
}

private final class FakeDiskArbitration: EDPDaemonDiskArbitrating, @unchecked Sendable {
    private let callbackQueue = DispatchQueue(label: "com.edp.drive.tests.fake-da")
    private let lock = NSLock()
    private(set) var suppressed = Set<UInt64>()
    private(set) var unmountWholeCalls = [String]()
    private(set) var ejectCalls = [String]()

    func suppressAutomount(usbRegistryEntryID: UInt64) {
        lock.lock(); suppressed.insert(usbRegistryEntryID); lock.unlock()
    }

    func allowAutomount(usbRegistryEntryID: UInt64) {
        lock.lock(); suppressed.remove(usbRegistryEntryID); lock.unlock()
    }

    func unmountWholeAsync(
        _ bsdName: String,
        completion: @escaping EDPDiskArbitrationVoidCompletion
    ) {
        lock.lock(); unmountWholeCalls.append(bsdName); lock.unlock()
        callbackQueue.async { completion(nil) }
    }

    func ejectAsync(
        _ bsdName: String,
        completion: @escaping EDPDiskArbitrationVoidCompletion
    ) {
        lock.lock(); ejectCalls.append(bsdName); lock.unlock()
        callbackQueue.async { completion(nil) }
    }
}

private extension FakeDiskArbitration {
    func snapshotUnmountWholeCalls() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return unmountWholeCalls
    }

    func snapshotEjectCalls() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return ejectCalls
    }
}

private final class SendableFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class SendableOptionalStringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false
    private var value: String?

    func set(_ value: String?) {
        lock.lock()
        called = true
        self.value = value
        lock.unlock()
    }

    func snapshot() -> (Bool, String?) {
        lock.lock()
        defer { lock.unlock() }
        return (called, value)
    }
}

private final class PublisherProcessResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var status: Int32?
    private var stdout = ""
    private var errorMessage: String?

    func record(status: Int32?, stdout: String, errorMessage: String?) {
        lock.lock()
        count += 1
        self.status = status
        self.stdout = stdout
        self.errorMessage = errorMessage
        lock.unlock()
    }

    func snapshot() -> (count: Int, status: Int32?, stdout: String, errorMessage: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (count, status, stdout, errorMessage)
    }
}

private struct ControllerEnvironment {
    let security: TemporaryKeychainContext
    let state: EDPVirtualUSBState
    let credentials: EDPCredentialStore
    let policies: EDPDevicePolicyStore
    let manager: FakeMountManager
    let diskArbitration: FakeDiskArbitration
    let controller: EDPDaemonController
    let fixture: EDPVirtualMediaDevice
    let correctPassword: [UInt8]

    static func make(
        fixtureDirectory: String,
        insertDevice: Bool,
        manager: FakeMountManager = FakeMountManager(),
        security: TemporaryKeychainContext? = nil
    ) throws -> ControllerEnvironment {
        let security = try security ?? TemporaryKeychainContext()
        let state = EDPVirtualUSBState()
        let fixture = try EDPVirtualDiskFactory.capturedDisk4(fixtureDirectory: fixtureDirectory)
        if insertDevice {
            state.insert(
                fixture,
                as: "disk90",
                registryEntryID: 0x9000,
                usbRegistryEntryID: 0x9001
            )
        }
        let credentials = try security.credentialStore()
        let policies = try security.policyStore()
        let diskArbitration = FakeDiskArbitration()
        let correctPassword = Array("0000aaaa".utf8)
        let verifierMetadata = fixture.metadata
        let controller = try EDPDaemonController(
            store: credentials,
            policies: policies,
            manager: manager,
            diskArbitration: diskArbitration,
            mediaProvider: EDPVirtualWholeUSBMediaProvider(state: state),
            metadataReader: EDPVirtualRawMetadataReader(state: state),
            rawAccessLeaseOpener: { disk in
                EDPRawAccessLease(
                    deviceID: disk.deviceID,
                    registryEntryID: disk.registryEntryID,
                    rawPath: disk.rawPath,
                    fd: -1
                )
            },
            credentialVerifier: { disk, partitionType, password, _ in
                let resolved = EDPPhysicalIdentityResolver.resolve(
                    media: EDPWholeUSBMedia(
                        bsdName: disk.bsdName,
                        sizeBytes: disk.sizeBytes,
                        mediaName: disk.mediaName,
                        vidHex: disk.vidHex,
                        pidHex: disk.pidHex,
                        registryEntryID: disk.registryEntryID,
                        usbRegistryEntryID: disk.usbRegistryEntryID
                    ),
                    metadata: verifierMetadata
                )
                guard let metadataDeviceID = resolved.metadataDeviceID else {
                    throw LifecycleValidationError("fixture metadata device identity unavailable")
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
                    throw LifecycleValidationError("password did not unlock partition \(partitionType)")
                }
            },
            performLegacyRuntimeMigration: false
        )
        return ControllerEnvironment(
            security: security,
            state: state,
            credentials: credentials,
            policies: policies,
            manager: manager,
            diskArbitration: diskArbitration,
            controller: controller,
            fixture: fixture,
            correctPassword: correctPassword
        )
    }

    func insertFixture(
        registryEntryID: UInt64 = 0x9000,
        usbRegistryEntryID: UInt64 = 0x9001
    ) {
        state.insert(
            fixture,
            as: "disk90",
            registryEntryID: registryEntryID,
            usbRegistryEntryID: usbRegistryEntryID
        )
    }

    func snapshot() throws -> EDPXPCSnapshot {
        try JSONDecoder().decode(EDPXPCSnapshot.self, from: controller.snapshotData())
    }

    func connectedDevice() throws -> EDPXPCDevice {
        guard let device = try snapshot().devices.first(where: \.connected) else {
            throw LifecycleValidationError("expected one connected service device")
        }
        return device
    }
}

@main
struct ValidateCredentialPolicyServiceLifecycle {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw LifecycleValidationError(
                "usage: validate-credential-policy-service-lifecycle <real_disks/disk4>"
            )
        }
        let fixtureDirectory = CommandLine.arguments[1]
        try validateCredentialAndPolicyScenarios(fixtureDirectory: fixtureDirectory)
        try validateDefaultPolicyScenarios(fixtureDirectory: fixtureDirectory)
        try validateServiceScenarios(fixtureDirectory: fixtureDirectory)
        print("RESULT=DRIVE_CREDENTIAL_POLICY_SERVICE_OK")
    }

    private static func validateCredentialAndPolicyScenarios(fixtureDirectory: String) throws {
        let env = try ControllerEnvironment.make(
            fixtureDirectory: fixtureDirectory,
            insertDevice: true
        )
        env.controller.reconcileSynchronouslyForTesting()
        let device = try env.connectedDevice()
        let deviceID = device.deviceID

        guard device.partitions.first(where: { $0.partitionType == 1 })?.credentialStatus == .notRequired,
              try env.credentials.load().records.allSatisfy({ !$0.partitionTypes.contains(1) }) else {
            throw LifecycleValidationError("C01 boot partition unexpectedly required a credential")
        }
        print("SCENARIO=C01_OK boot_credential_not_required")

        try expectThrows("C02 exchange mounted without credential") {
            try env.controller.mountPartition(deviceID: deviceID, partitionType: 2)
        }
        guard !env.manager.containsPhysical(deviceID: deviceID, partitionType: 2) else {
            throw LifecycleValidationError("C02 exchange session appeared without a credential")
        }
        print("SCENARIO=C02_OK exchange_missing_credential_refused")

        try expectThrows("C03 secure mounted without credential") {
            try env.controller.mountPartition(deviceID: deviceID, partitionType: 4)
        }
        guard !env.manager.containsPhysical(deviceID: deviceID, partitionType: 4) else {
            throw LifecycleValidationError("C03 secure session appeared without a credential")
        }
        print("SCENARIO=C03_OK secure_missing_credential_refused")

        try expectThrows("C04 wrong password was accepted") {
            try env.controller.saveCredential(
                deviceID: deviceID,
                partitionType: 2,
                passwordData: Data("definitely-wrong".utf8)
            )
        }
        guard try env.credentials.load().records.first(where: { $0.deviceID == deviceID }) == nil else {
            throw LifecycleValidationError("C04 wrong password polluted the Keychain index")
        }
        print("SCENARIO=C04_OK wrong_password_not_saved")

        try env.controller.saveCredential(
            deviceID: deviceID,
            partitionType: 2,
            passwordData: Data(env.correctPassword)
        )
        guard try env.credentials.password(deviceID: deviceID, partitionType: 2) == env.correctPassword else {
            throw LifecycleValidationError("C05 verified password did not round-trip through the Keychain")
        }
        print("SCENARIO=C05_OK correct_password_saved")

        try env.controller.saveCredential(
            deviceID: deviceID,
            partitionType: 4,
            passwordData: Data(env.correctPassword)
        )
        try env.controller.deleteCredential(deviceID: deviceID, partitionType: 2)
        try expectThrows("C06 deleted exchange credential remained readable") {
            _ = try env.credentials.password(deviceID: deviceID, partitionType: 2)
        }
        guard try env.credentials.password(deviceID: deviceID, partitionType: 4) == env.correctPassword else {
            throw LifecycleValidationError("C06 deleting exchange credential damaged secure credential")
        }
        print("SCENARIO=C06_OK partition_credential_delete_isolated")

        try env.policies.setDisplayName(deviceID: deviceID, displayName: "Configured A")
        try env.policies.setAutoMount(deviceID: deviceID, partitionType: 2, enabled: true)
        try env.credentials.put(deviceID: deviceID, partitionType: 2, password: env.correctPassword)
        let fixtureB = try EDPVirtualDiskFactory.changingOnlyID(env.fixture, to: 3_164_177_654)
        env.state.replace(
            "disk90",
            with: fixtureB,
            registryEntryID: 0x9010,
            usbRegistryEntryID: 0x9011
        )
        env.controller.reconcileSynchronouslyForTesting()
        let snapshotAfterReplacement = try env.snapshot()
        guard let deviceB = snapshotAfterReplacement.devices.first(where: \.connected),
              deviceB.deviceID != deviceID,
              deviceB.displayName == fixtureB.media.mediaName,
              deviceB.partitions.first(where: { $0.partitionType == 2 })?.autoMount == false,
              deviceB.partitions.first(where: { $0.partitionType == 2 })?.credentialStatus == .missing else {
            throw LifecycleValidationError("C07 new five-factor identity inherited device A state")
        }
        print("SCENARIO=C07_OK new_identity_does_not_inherit_state")

        env.state.replace(
            "disk90",
            with: env.fixture,
            registryEntryID: 0x9020,
            usbRegistryEntryID: 0x9021
        )
        try env.policies.setDisplayName(deviceID: deviceID, displayName: "Persistent A")
        try env.policies.setAutoMount(deviceID: deviceID, partitionType: 2, enabled: true)
        try env.policies.setGlobalAutoMount(false)
        try env.credentials.put(deviceID: deviceID, partitionType: 2, password: env.correctPassword)
        env.controller.reconcileSynchronouslyForTesting()
        try env.controller.shutdownGracefully()

        let reopenedCredentials = try env.security.credentialStore()
        let reopenedPolicies = try env.security.policyStore()
        let manager2 = FakeMountManager()
        let controller2 = try makeController(
            state: env.state,
            credentials: reopenedCredentials,
            policies: reopenedPolicies,
            manager: manager2,
            correctPassword: env.correctPassword,
            verifierMetadata: env.fixture.metadata
        )
        controller2.reconcileSynchronouslyForTesting()
        let restarted = try JSONDecoder().decode(EDPXPCSnapshot.self, from: controller2.snapshotData())
        guard restarted.globalAutoMountEnabled == false,
              let persistent = restarted.devices.first(where: { $0.deviceID == deviceID }),
              persistent.displayName == "Persistent A",
              persistent.partitions.first(where: { $0.partitionType == 2 })?.autoMount == true,
              persistent.partitions.first(where: { $0.partitionType == 2 })?.credentialStatus == .saved else {
            throw LifecycleValidationError("C08 policy/credential state did not survive service reconstruction")
        }
        print("SCENARIO=C08_OK policy_and_credential_persistence")
    }

    private static func validateDefaultPolicyScenarios(fixtureDirectory: String) throws {
        do {
            let env = try ControllerEnvironment.make(
                fixtureDirectory: fixtureDirectory,
                insertDevice: true
            )
            env.controller.reconcileSynchronouslyForTesting()
            let snapshot = try env.snapshot()
            guard snapshot.partitionDefaults.allSatisfy({ !$0.autoMount && !$0.autoProbePassword }),
                  env.manager.mounted.isEmpty,
                  try env.credentials.load().records.isEmpty else {
                throw LifecycleValidationError("D01 safe defaults performed an automatic action")
            }
            print("SCENARIO=D01_OK safe_defaults_no_automatic_actions")
        }

        do {
            let env = try ControllerEnvironment.make(
                fixtureDirectory: fixtureDirectory,
                insertDevice: true
            )
            env.controller.reconcileSynchronouslyForTesting()
            let device = try env.connectedDevice()
            try env.policies.setDefaultAutoMount(partitionType: 1, enabled: true)
            try env.policies.setDefaultAutoMount(partitionType: 2, enabled: true)
            try env.policies.setDefaultAutoProbePassword(partitionType: 2, enabled: true)
            env.controller.reconcileSynchronouslyForTesting()
            let unchanged = try env.snapshot().devices.first { $0.deviceID == device.deviceID }
            guard unchanged?.partitions.allSatisfy({ !$0.autoMount }) == true,
                  try env.policies.load().devices.first(where: { $0.deviceID == device.deviceID })?
                    .policy(for: 2).autoProbePassword == false else {
                throw LifecycleValidationError("D02 changing defaults mutated an existing device")
            }
            print("SCENARIO=D02_OK defaults_do_not_mutate_existing_device")
        }

        do {
            let env = try ControllerEnvironment.make(
                fixtureDirectory: fixtureDirectory,
                insertDevice: false
            )
            try env.policies.setDefaultAutoMount(partitionType: 1, enabled: true)
            try env.policies.setDefaultAutoMount(partitionType: 2, enabled: true)
            try env.policies.setDefaultAutoProbePassword(partitionType: 2, enabled: true)
            try env.policies.setDefaultAutoProbePassword(partitionType: 4, enabled: true)
            env.insertFixture()
            env.controller.reconcileSynchronouslyForTesting()
            let device = try env.connectedDevice()
            let record = try env.credentials.load().records.first { $0.deviceID == device.deviceID }
            guard device.partitions.first(where: { $0.partitionType == 1 })?.autoMount == true,
                  device.partitions.first(where: { $0.partitionType == 2 })?.autoMount == true,
                  device.partitions.first(where: { $0.partitionType == 4 })?.autoMount == false,
                  record?.partitionTypes.sorted() == [2, 4],
                  env.manager.containsPhysical(deviceID: device.deviceID, partitionType: 1),
                  env.manager.containsPhysical(deviceID: device.deviceID, partitionType: 2),
                  !env.manager.containsPhysical(deviceID: device.deviceID, partitionType: 4) else {
                throw LifecycleValidationError("D03/D04 inherited defaults did not preserve probe/mount independence")
            }
            print("SCENARIO=D03_OK new_device_inherits_partition_defaults")
            print("SCENARIO=D04_OK password_probe_does_not_imply_auto_mount")
        }

        do {
            let env = try ControllerEnvironment.make(
                fixtureDirectory: fixtureDirectory,
                insertDevice: false
            )
            try env.policies.setDefaultAutoMount(partitionType: 2, enabled: true)
            env.insertFixture()
            env.controller.reconcileSynchronouslyForTesting()
            let device = try env.connectedDevice()
            guard !env.manager.containsPhysical(deviceID: device.deviceID, partitionType: 2),
                  try env.credentials.load().records.first(where: { $0.deviceID == device.deviceID }) == nil else {
                throw LifecycleValidationError("D05 auto-mount bypassed the missing credential")
            }
            print("SCENARIO=D05_OK auto_mount_without_probe_or_credential_stays_unmounted")
        }

        do {
            let env = try ControllerEnvironment.make(
                fixtureDirectory: fixtureDirectory,
                insertDevice: false
            )
            try env.policies.setDefaultAutoProbePassword(partitionType: 2, enabled: true)
            try env.credentials.setDefaultProbePassword(
                partitionType: 2,
                password: Array("wrong-default".utf8)
            )
            env.insertFixture()
            env.controller.reconcileSynchronouslyForTesting()
            let deviceID = try env.connectedDevice().deviceID
            func mismatchCount() throws -> Int {
                try env.snapshot().activities.filter {
                    $0.deviceID == deviceID
                        && $0.partitionType == 2
                        && $0.message.contains("默认密码未匹配")
                }.count
            }
            guard try mismatchCount() == 1 else {
                throw LifecycleValidationError("D06 first wrong default password was not recorded once")
            }
            env.controller.reconcileSynchronouslyForTesting()
            guard try mismatchCount() == 1 else {
                throw LifecycleValidationError("D06 wrong default password retried during the same insertion")
            }
            env.state.remove("disk90")
            env.controller.reconcileSynchronouslyForTesting()
            env.state.insert(
                env.fixture,
                as: "disk90",
                registryEntryID: 0x9A00,
                usbRegistryEntryID: 0x9A01
            )
            env.controller.reconcileSynchronouslyForTesting()
            guard try mismatchCount() == 2 else {
                throw LifecycleValidationError("D06 reconnect did not allow one new password probe")
            }
            print("SCENARIO=D06_OK wrong_password_once_per_insertion")

            try env.controller.setDefaultProbePassword(
                partitionType: 2,
                passwordData: Data(env.correctPassword)
            )
            env.controller.drainForTesting()
            guard try env.credentials.password(deviceID: deviceID, partitionType: 2) == env.correctPassword else {
                throw LifecycleValidationError("D07 changing the default password did not clear probe suppression")
            }
            print("SCENARIO=D07_OK password_change_retries_suppressed_probe")
        }

        do {
            let env = try ControllerEnvironment.make(
                fixtureDirectory: fixtureDirectory,
                insertDevice: false
            )
            try env.policies.setDefaultAutoProbePassword(partitionType: 2, enabled: true)
            try env.policies.setDefaultAutoProbePassword(partitionType: 4, enabled: true)
            try env.credentials.setDefaultProbePassword(
                partitionType: 2,
                password: Array("wrong-exchange-only".utf8)
            )
            env.insertFixture()
            env.controller.reconcileSynchronouslyForTesting()
            let deviceID = try env.connectedDevice().deviceID
            try expectThrows("D08 wrong exchange default unexpectedly saved") {
                _ = try env.credentials.password(deviceID: deviceID, partitionType: 2)
            }
            guard try env.credentials.password(deviceID: deviceID, partitionType: 4) == env.correctPassword else {
                throw LifecycleValidationError("D08 exchange password failure contaminated secure probing")
            }
            print("SCENARIO=D08_OK partition_probe_passwords_are_isolated")
        }

        do {
            let env = try ControllerEnvironment.make(
                fixtureDirectory: fixtureDirectory,
                insertDevice: false
            )
            try env.policies.setDefaultAutoMount(partitionType: 2, enabled: true)
            try env.policies.setDefaultAutoProbePassword(partitionType: 2, enabled: true)
            try env.policies.setGlobalAutoMount(false)
            env.insertFixture()
            env.controller.reconcileSynchronouslyForTesting()
            let deviceID = try env.connectedDevice().deviceID
            guard try env.credentials.password(deviceID: deviceID, partitionType: 2) == env.correctPassword,
                  !env.manager.containsPhysical(deviceID: deviceID, partitionType: 2) else {
                throw LifecycleValidationError("D09 global mount pause incorrectly suppressed probing or allowed mounting")
            }
            print("SCENARIO=D09_OK global_mount_pause_does_not_disable_password_probe")
        }

        do {
            let env = try ControllerEnvironment.make(
                fixtureDirectory: fixtureDirectory,
                insertDevice: true
            )
            env.controller.reconcileSynchronouslyForTesting()
            let device = try env.connectedDevice()
            try env.controller.saveCredential(
                deviceID: device.deviceID,
                partitionType: 2,
                passwordData: Data(env.correctPassword)
            )
            try env.controller.mountPartition(deviceID: device.deviceID, partitionType: 2)
            env.controller.reconcileSynchronouslyForTesting()
            guard env.manager.containsPhysical(deviceID: device.deviceID, partitionType: 2),
                  device.partitions.first(where: { $0.partitionType == 2 })?.autoMount == false else {
                throw LifecycleValidationError("D10 reconcile tore down a manually mounted partition")
            }
            print("SCENARIO=D10_OK manual_mount_survives_reconcile_when_auto_mount_off")
        }

        do {
            let env = try ControllerEnvironment.make(
                fixtureDirectory: fixtureDirectory,
                insertDevice: false
            )
            let custom = Array("custom-default-secret".utf8)
            try env.credentials.setDefaultProbePassword(partitionType: 2, password: custom)
            guard env.credentials.hasCustomizedDefaultProbePassword(partitionType: 2),
                  try env.credentials.defaultProbePassword(partitionType: 2) == custom else {
                throw LifecycleValidationError("D11 customized default probe password did not round-trip")
            }
            let policyText = (try? String(contentsOf: env.security.policyURL, encoding: .utf8)) ?? ""
            let indexText = (try? String(contentsOf: env.security.credentialIndexURL, encoding: .utf8)) ?? ""
            guard !policyText.contains("custom-default-secret"),
                  !indexText.contains("custom-default-secret") else {
                throw LifecycleValidationError("D11 default password leaked outside Keychain storage")
            }
            try env.credentials.resetDefaultProbePassword(partitionType: 2)
            guard !env.credentials.hasCustomizedDefaultProbePassword(partitionType: 2),
                  try env.credentials.defaultProbePassword(partitionType: 2)
                    == EDPCredentialStore.builtInDefaultProbePassword else {
                throw LifecycleValidationError("D11 reset did not restore built-in 0000aaaa")
            }
            print("SCENARIO=D11_OK default_password_keychain_only_and_resettable")
        }

        do {
            let env = try ControllerEnvironment.make(
                fixtureDirectory: fixtureDirectory,
                insertDevice: false
            )
            let service = EDPXPCService(controller: env.controller, didRequestShutdown: {})
            var reply: String?
            service.setDefaultPartitionAutoMount(partitionType: 1, enabled: true) { reply = $0 }
            guard reply == nil else { throw LifecycleValidationError("D12 XPC boot default auto-mount failed: \(reply!)") }
            service.setDefaultPartitionAutoMount(partitionType: 2, enabled: true) { reply = $0 }
            guard reply == nil else { throw LifecycleValidationError("D12 XPC exchange default auto-mount failed: \(reply!)") }
            service.setDefaultPartitionAutoProbePassword(partitionType: 2, enabled: true) { reply = $0 }
            guard reply == nil else { throw LifecycleValidationError("D12 XPC exchange probe toggle failed: \(reply!)") }
            service.setDefaultProbePassword(
                partitionType: 2,
                password: Data("xpc-custom-default".utf8)
            ) { reply = $0 }
            guard reply == nil else { throw LifecycleValidationError("D12 XPC default password save failed: \(reply!)") }

            var snapshotData = Data()
            service.snapshot { snapshotData = $0 }
            let snapshot = try JSONDecoder().decode(EDPXPCSnapshot.self, from: snapshotData)
            guard snapshot.partitionDefaults.first(where: { $0.partitionType == 1 })?.autoMount == true,
                  snapshot.partitionDefaults.first(where: { $0.partitionType == 2 })?.autoMount == true,
                  snapshot.partitionDefaults.first(where: { $0.partitionType == 2 })?.autoProbePassword == true,
                  snapshot.partitionDefaults.first(where: { $0.partitionType == 2 })?.defaultProbePasswordCustomized == true else {
                throw LifecycleValidationError("D12 XPC default-policy snapshot did not round-trip")
            }

            reply = nil
            service.setDefaultPartitionAutoProbePassword(partitionType: 1, enabled: true) { reply = $0 }
            guard reply?.contains("partition 2 or 4") == true else {
                throw LifecycleValidationError("D12 XPC accepted boot password probing")
            }
            reply = nil
            service.resetDefaultProbePassword(partitionType: 2) { reply = $0 }
            guard reply == nil else { throw LifecycleValidationError("D12 XPC default password reset failed: \(reply!)") }
            service.snapshot { snapshotData = $0 }
            let resetSnapshot = try JSONDecoder().decode(EDPXPCSnapshot.self, from: snapshotData)
            guard resetSnapshot.partitionDefaults.first(where: { $0.partitionType == 2 })?
                .defaultProbePasswordCustomized == false else {
                throw LifecycleValidationError("D12 XPC reset did not clear customized default state")
            }
            print("SCENARIO=D12_OK xpc_default_policy_round_trip_and_validation")
        }

        do {
            let fakeDA = FakeDiskArbitration()
            let publisher = EDPDiskImages2Publisher(
                binaryRoot: "/nonexistent-edp-runtime",
                diskArbitration: fakeDA
            )
            let unpublishDone = DispatchSemaphore(value: 0)
            let unpublishResult = SendableOptionalStringBox()
            publisher.unpublishAsync(EDPPublishedBlockDevice(
                bsdName: "disk31",
                backingPath: "/Volumes/.edp-block-stale-disk31/volume.raw"
            )) { errorMessage in
                unpublishResult.set(errorMessage)
                unpublishDone.signal()
            }
            guard unpublishDone.wait(timeout: .now() + 12) == .success,
                  unpublishResult.snapshot().1 == nil else {
                throw LifecycleValidationError("D13 stale publication async teardown did not complete")
            }
            guard fakeDA.snapshotEjectCalls().isEmpty else {
                throw LifecycleValidationError("D13 stale synthetic BSD name triggered a physical eject")
            }
            print("SCENARIO=D13_OK stale_diskn_reuse_never_ejects_without_backing_identity")
        }
    }

    private static func validateServiceScenarios(fixtureDirectory: String) throws {
        do {
            let env = try ControllerEnvironment.make(
                fixtureDirectory: fixtureDirectory,
                insertDevice: false
            )
            env.controller.reconcileSynchronouslyForTesting()
            guard try env.snapshot().devices.isEmpty else {
                throw LifecycleValidationError("S01 no-device startup produced a device")
            }
            print("SCENARIO=S01_OK startup_no_device")
        }

        do {
            let env = try ControllerEnvironment.make(
                fixtureDirectory: fixtureDirectory,
                insertDevice: true
            )
            env.controller.reconcileSynchronouslyForTesting()
            let device = try env.connectedDevice()
            guard env.manager.mounted.isEmpty,
                  device.partitions.allSatisfy({ !$0.autoMount }) else {
                throw LifecycleValidationError("S02 startup performed an automatic mount under safe defaults")
            }
            print("SCENARIO=S02_OK startup_device_present_safe_defaults_stay_manual")
        }

        do {
            let env = try ControllerEnvironment.make(
                fixtureDirectory: fixtureDirectory,
                insertDevice: false
            )
            try env.controller.shutdownGracefully()
            guard env.manager.unmountAllCount == 1, env.manager.mounted.isEmpty else {
                throw LifecycleValidationError("S03 clean service stop did not run bounded teardown")
            }
            print("SCENARIO=S03_OK stop_service_without_mounts")
        }

        do {
            let env = try ControllerEnvironment.make(
                fixtureDirectory: fixtureDirectory,
                insertDevice: true
            )
            env.controller.reconcileSynchronouslyForTesting()
            let device = try env.connectedDevice()
            try env.controller.mountPartition(deviceID: device.deviceID, partitionType: 1)
            guard !env.manager.mounted.isEmpty else {
                throw LifecycleValidationError("S04 fixture did not establish a manual mounted session")
            }
            try env.controller.shutdownGracefully()
            guard env.manager.mounted.isEmpty, env.manager.unmountAllCount == 1 else {
                throw LifecycleValidationError("S04 service stop left mounted sessions")
            }
            print("SCENARIO=S04_OK stop_service_tears_down_mounts")
        }

        do {
            let security = try TemporaryKeychainContext()
            let env1 = try ControllerEnvironment.make(
                fixtureDirectory: fixtureDirectory,
                insertDevice: true,
                security: security
            )
            env1.controller.reconcileSynchronouslyForTesting()
            let firstID = try env1.connectedDevice().deviceID
            try env1.controller.shutdownGracefully()
            let manager2 = FakeMountManager()
            let controller2 = try makeController(
                state: env1.state,
                credentials: try security.credentialStore(),
                policies: try security.policyStore(),
                manager: manager2,
                correctPassword: env1.correctPassword,
                verifierMetadata: env1.fixture.metadata
            )
            controller2.reconcileSynchronouslyForTesting()
            let second = try JSONDecoder().decode(EDPXPCSnapshot.self, from: controller2.snapshotData())
            guard second.devices.first(where: \.connected)?.deviceID == firstID else {
                throw LifecycleValidationError("S05 service restart changed stable device identity")
            }
            print("SCENARIO=S05_OK restart_service_same_identity")
        }

        do {
            let env = try ControllerEnvironment.make(
                fixtureDirectory: fixtureDirectory,
                insertDevice: true
            )
            env.controller.reconcileSynchronouslyForTesting()
            let beforeMounts = env.manager.mounted.count
            let service1 = EDPXPCService(controller: env.controller, didRequestShutdown: {})
            let service2 = EDPXPCService(controller: env.controller, didRequestShutdown: {})
            var firstSnapshot = Data()
            var secondSnapshot = Data()
            service1.snapshot { firstSnapshot = $0 }
            service2.snapshot { secondSnapshot = $0 }
            guard !firstSnapshot.isEmpty,
                  !secondSnapshot.isEmpty,
                  env.manager.mounted.count == beforeMounts else {
                throw LifecycleValidationError("S06 foreground/XPC client reconstruction changed service mounts")
            }
            print("SCENARIO=S06_OK app_restart_service_keeps_running")
        }

        do {
            let security = try TemporaryKeychainContext()
            let state = EDPVirtualUSBState()
            let fixture = try EDPVirtualDiskFactory.capturedDisk4(fixtureDirectory: fixtureDirectory)
            state.insert(fixture, as: "disk91", registryEntryID: 0x9100, usbRegistryEntryID: 0x9101)
            let credentials = try security.credentialStore()
            let policies = try security.policyStore()
            let discovered = try EDPPhysicalDiskDiscovery(
                mediaProvider: EDPVirtualWholeUSBMediaProvider(state: state),
                metadataReader: EDPVirtualRawMetadataReader(state: state)
            ).discover()
            guard let disk = discovered.first else {
                throw LifecycleValidationError("S07 could not discover fixture")
            }
            _ = try policies.observe(
                deviceID: disk.deviceID,
                mediaName: disk.mediaName,
                vidPID: "\(disk.vidHex):\(disk.pidHex)",
                sizeBytes: disk.sizeBytes
            )
            try policies.setAutoMount(deviceID: disk.deviceID, partitionType: 2, enabled: true)
            let secret = Array("0000aaaa".utf8)
            try credentials.put(deviceID: disk.deviceID, partitionType: 2, password: secret)
            let manager = FakeMountManager()
            manager.failNextMounts(
                deviceID: disk.deviceID,
                partitionType: 2,
                count: 1,
                message: "File system extension not found"
            )
            let controller = try makeController(
                state: state,
                credentials: credentials,
                policies: policies,
                manager: manager,
                correctPassword: secret,
                verifierMetadata: fixture.metadata
            )
            controller.reconcileSynchronouslyForTesting()
            let failedSnapshot = try JSONDecoder().decode(EDPXPCSnapshot.self, from: controller.snapshotData())
            guard failedSnapshot.devices.first(where: { $0.deviceID == disk.deviceID })?
                .partitions.first(where: { $0.partitionType == 2 })?.lastError?.contains("File system extension not found") == true else {
                throw LifecycleValidationError("S07 transient mount failure was not retained")
            }
            try controller.retryTransientAutomaticMounts()
            controller.drainForTesting()
            guard manager.containsPhysical(deviceID: disk.deviceID, partitionType: 2),
                  manager.mountAttempts["\(disk.deviceID):2"] == 2 else {
                throw LifecycleValidationError("S07 explicit transient retry did not recover")
            }
            print("SCENARIO=S07_OK transient_mount_retry_recovers")
        }

        do {
            let env = try ControllerEnvironment.make(
                fixtureDirectory: fixtureDirectory,
                insertDevice: true
            )
            let fixtureB = try EDPVirtualDiskFactory.changingOnlyID(env.fixture, to: 3_164_177_654)
            env.state.insert(
                fixtureB,
                as: "disk92",
                registryEntryID: 0x9200,
                usbRegistryEntryID: 0x9201
            )
            env.state.setMetadataFault(
                .readFailure("EIO: isolated device failure"),
                for: "disk92"
            )
            env.controller.reconcileSynchronouslyForTesting()
            let snapshot = try env.snapshot()
            guard snapshot.devices.filter(\.connected).count == 1,
                  snapshot.devices.first(where: \.connected)?.bsdName == "disk90" else {
                throw LifecycleValidationError("S08 broken device made daemon state globally unavailable")
            }
            print("SCENARIO=S08_OK one_device_failure_isolated")
        }

        do {
            let manager = FakeMountManager()
            manager.staleSessionCount = 3
            let env = try ControllerEnvironment.make(
                fixtureDirectory: fixtureDirectory,
                insertDevice: false,
                manager: manager
            )
            guard env.manager.recoverCount == 1, env.manager.staleSessionCount == 0 else {
                throw LifecycleValidationError("S09 controller initialization did not recover stale sessions")
            }
            print("SCENARIO=S09_OK stale_session_recovery")
        }

        do {
            let env = try ControllerEnvironment.make(
                fixtureDirectory: fixtureDirectory,
                insertDevice: true
            )
            env.controller.reconcileSynchronouslyForTesting()
            let device = try env.connectedDevice()
            try env.controller.mountPartition(deviceID: device.deviceID, partitionType: 1)
            let requested = SendableFlag()
            let service = EDPXPCService(
                controller: env.controller,
                didRequestShutdown: { requested.set() }
            )
            var replyError: String?
            let shutdownReply = DispatchSemaphore(value: 0)
            service.requestGracefulShutdown {
                replyError = $0
                shutdownReply.signal()
            }
            guard shutdownReply.wait(timeout: .now() + 2) == .success,
                  replyError == nil,
                  requested.get(),
                  env.manager.mounted.isEmpty,
                  env.manager.unmountAllCount == 1 else {
                throw LifecycleValidationError("S10 async XPC graceful full exit did not teardown service state")
            }
            print("SCENARIO=S10_OK graceful_full_exit")
        }

        do {
            guard EDPFSKitMountRecoveryPolicy.shouldRecoverBridgeActivation(
                timedOut: true,
                transportStillRunning: true,
                bridgeMounted: false,
                logDetail: nil
            ) else {
                throw LifecycleValidationError("S11 timed-out live transport was not classified recoverable")
            }
            guard EDPFSKitMountRecoveryPolicy.shouldRecoverBridgeActivation(
                timedOut: false,
                transportStillRunning: false,
                bridgeMounted: false,
                logDetail: "MFMount: Failed to mount volume: mount(8) returned 69"
            ) else {
                throw LifecycleValidationError("S11 mount(8)=69 was not classified recoverable")
            }
            guard EDPFSKitMountRecoveryPolicy.shouldRecoverBridgeActivation(
                timedOut: false,
                transportStillRunning: false,
                bridgeMounted: false,
                logDetail: "File system extension not found"
            ) else {
                throw LifecycleValidationError("S11 missing FSKit extension was not classified recoverable")
            }
            guard !EDPFSKitMountRecoveryPolicy.shouldRecoverBridgeActivation(
                timedOut: false,
                transportStillRunning: false,
                bridgeMounted: false,
                logDetail: "password validation failed"
            ) else {
                throw LifecycleValidationError("S11 password failure incorrectly triggered FSKit recovery")
            }
            guard !EDPFSKitMountRecoveryPolicy.shouldRecoverBridgeActivation(
                timedOut: false,
                transportStillRunning: false,
                bridgeMounted: false,
                logDetail: "DiskImages2 attach failed"
            ) else {
                throw LifecycleValidationError("S11 DiskImages2 failure incorrectly triggered FSKit recovery")
            }
            guard !EDPFSKitMountRecoveryPolicy.shouldRecoverBridgeActivation(
                timedOut: true,
                transportStillRunning: true,
                bridgeMounted: true,
                logDetail: "mount(8) returned 69"
            ) else {
                throw LifecycleValidationError("S11 active bridge incorrectly triggered FSKit recovery")
            }
            print("SCENARIO=S11_OK fskit_bridge_recovery_classifier_is_narrow")
        }

        do {
            let security = try TemporaryKeychainContext()
            let state = EDPVirtualUSBState()
            let fixture = try EDPVirtualDiskFactory.capturedDisk4(fixtureDirectory: fixtureDirectory)
            state.insert(fixture, as: "disk93", registryEntryID: 0x9300, usbRegistryEntryID: 0x9301)
            let credentials = try security.credentialStore()
            let policies = try security.policyStore()
            var stableDeviceID: String?
            for iteration in 1...20 {
                let manager = FakeMountManager()
                let controller = try makeController(
                    state: state,
                    credentials: credentials,
                    policies: policies,
                    manager: manager,
                    correctPassword: Array("0000aaaa".utf8),
                    verifierMetadata: fixture.metadata
                )
                controller.reconcileSynchronouslyForTesting()
                let snapshot = try JSONDecoder().decode(EDPXPCSnapshot.self, from: controller.snapshotData())
                guard let device = snapshot.devices.first(where: \.connected) else {
                    throw LifecycleValidationError("S12 cycle \(iteration) lost the connected device")
                }
                if let stableDeviceID {
                    guard device.deviceID == stableDeviceID else {
                        throw LifecycleValidationError("S12 cycle \(iteration) changed stable device identity")
                    }
                } else {
                    stableDeviceID = device.deviceID
                }
                guard manager.mounted.isEmpty else {
                    throw LifecycleValidationError("S12 cycle \(iteration) accumulated an unexpected mount")
                }
                try controller.shutdownGracefully()
                guard manager.unmountAllCount == 1, manager.mounted.isEmpty else {
                    throw LifecycleValidationError("S12 cycle \(iteration) did not fully teardown")
                }
            }
            print("SCENARIO=S12_OK repeated_service_start_stop_no_state_growth")
        }

        do {
            var success = EDPFSKitMountLifecycleMachine()
            guard success.start() == .launchAttempt(attempt: 0),
                  success.attemptLaunched(0) == .waitForBridge(attempt: 0),
                  success.bridgeActivated(0) == .publish(attempt: 0),
                  success.publicationFinished(0) == .mountFilesystem(attempt: 0),
                  success.filesystemMounted(0) == .complete,
                  success.state == .mounted,
                  success.recoveryBudget == 1 else {
                throw LifecycleValidationError("S13 normal mount lifecycle did not reach mounted state")
            }

            var retry = EDPFSKitMountLifecycleMachine()
            _ = retry.start()
            _ = retry.attemptLaunched(0)
            guard retry.bridgeFailed(0, recoverable: true, failure: "timeout")
                    == .cleanup(attempt: 0, allowHostRecoveryDuringStop: true),
                  retry.cleanupFinished(0, hostAlreadyRecovered: false) == .restartHost,
                  retry.hostRecoveryFinished(true) == .launchAttempt(attempt: 1),
                  retry.recoveryBudget == 0,
                  retry.attemptLaunched(1) == .waitForBridge(attempt: 1),
                  retry.bridgeFailed(1, recoverable: true, failure: "timeout-again")
                    == .cleanup(attempt: 1, allowHostRecoveryDuringStop: false),
                  retry.cleanupFinished(1, hostAlreadyRecovered: false) == .fail("timeout-again"),
                  retry.state == .failed("timeout-again") else {
                throw LifecycleValidationError("S13 recovery budget did not enforce one recovery and one retry")
            }

            var alreadyRecovered = EDPFSKitMountLifecycleMachine()
            _ = alreadyRecovered.start()
            _ = alreadyRecovered.attemptLaunched(0)
            _ = alreadyRecovered.bridgeFailed(0, recoverable: true, failure: "mount69")
            guard alreadyRecovered.cleanupFinished(0, hostAlreadyRecovered: true)
                    == .launchAttempt(attempt: 1),
                  alreadyRecovered.recoveryBudget == 0 else {
                throw LifecycleValidationError("S13 teardown-owned host recovery consumed the wrong budget")
            }

            var nonRecoverable = EDPFSKitMountLifecycleMachine()
            _ = nonRecoverable.start()
            _ = nonRecoverable.attemptLaunched(0)
            guard nonRecoverable.bridgeFailed(0, recoverable: false, failure: "DiskImages2")
                    == .cleanup(attempt: 0, allowHostRecoveryDuringStop: false),
                  nonRecoverable.cleanupFinished(0, hostAlreadyRecovered: false)
                    == .fail("DiskImages2"),
                  nonRecoverable.recoveryBudget == 1 else {
                throw LifecycleValidationError("S13 non-FSKit failure incorrectly consumed recovery budget")
            }

            var invalid = EDPFSKitMountLifecycleMachine()
            guard invalid.bridgeActivated(0) == .fail(
                "invalid FSKit mount lifecycle transition: bridgeActivated from idle"
            ),
            case .failed = invalid.state else {
                throw LifecycleValidationError("S13 out-of-order lifecycle event did not fail closed")
            }
            print("SCENARIO=S13_OK async_fskit_mount_state_machine_transitions")
        }

        do {
            var waiting = EDPFSKitMountLifecycleMachine()
            _ = waiting.start()
            _ = waiting.attemptLaunched(0)
            guard waiting.cancel() == .cleanup(attempt: 0, allowHostRecoveryDuringStop: false),
                  waiting.recoveryBudget == 1,
                  waiting.cleanupFinished(0, hostAlreadyRecovered: false)
                    == .fail("mount operation cancelled"),
                  waiting.state == .failed("mount operation cancelled") else {
                throw LifecycleValidationError("S14 waiting-bridge cancellation did not bypass recovery")
            }

            var cleanupRace = EDPFSKitMountLifecycleMachine()
            _ = cleanupRace.start()
            _ = cleanupRace.attemptLaunched(0)
            _ = cleanupRace.bridgeFailed(0, recoverable: true, failure: "timeout")
            guard cleanupRace.cancel() == .fail("mount operation cancelled"),
                  cleanupRace.recoveryBudget == 1,
                  cleanupRace.hostRecoveryFinished(true) == .fail("mount operation cancelled"),
                  cleanupRace.state == .failed("mount operation cancelled") else {
                throw LifecycleValidationError("S14 cancellation during recoverable cleanup allowed late recovery")
            }

            var publishing = EDPFSKitMountLifecycleMachine()
            _ = publishing.start()
            _ = publishing.attemptLaunched(0)
            _ = publishing.bridgeActivated(0)
            guard publishing.cancel() == .cleanup(attempt: 0, allowHostRecoveryDuringStop: false),
                  publishing.cleanupFinished(0, hostAlreadyRecovered: false)
                    == .fail("mount operation cancelled") else {
                throw LifecycleValidationError("S14 publication cancellation did not require cleanup")
            }

            var filesystem = EDPFSKitMountLifecycleMachine()
            _ = filesystem.start()
            _ = filesystem.attemptLaunched(0)
            _ = filesystem.bridgeActivated(0)
            _ = filesystem.publicationFinished(0)
            guard filesystem.cancel() == .cleanup(attempt: 0, allowHostRecoveryDuringStop: false),
                  filesystem.cleanupFinished(0, hostAlreadyRecovered: false)
                    == .fail("mount operation cancelled") else {
                throw LifecycleValidationError("S14 filesystem-mount cancellation did not require cleanup")
            }

            var terminal = EDPFSKitMountLifecycleMachine()
            _ = terminal.start()
            _ = terminal.attemptLaunched(0)
            _ = terminal.bridgeActivated(0)
            _ = terminal.publicationFinished(0)
            _ = terminal.filesystemMounted(0)
            guard terminal.bridgeFailed(0, recoverable: true, failure: "late") == .complete,
                  terminal.state == .mounted else {
                throw LifecycleValidationError("S14 late callback corrupted mounted terminal state")
            }

            print("SCENARIO=S14_OK cancellation_priority_and_late_callback_idempotence")
        }

        do {
            let env = try ControllerEnvironment.make(
                fixtureDirectory: fixtureDirectory,
                insertDevice: true
            )
            env.controller.reconcileSynchronouslyForTesting()
            let device = try env.connectedDevice()
            env.manager.holdNextMount(deviceID: device.deviceID, partitionType: 1)

            let first = SendableOptionalStringBox()
            let second = SendableOptionalStringBox()
            let firstDone = DispatchSemaphore(value: 0)
            let secondDone = DispatchSemaphore(value: 0)
            env.controller.mountPartitionAsync(deviceID: device.deviceID, partitionType: 1) { error in
                first.set(error)
                firstDone.signal()
            }
            env.controller.mountPartitionAsync(deviceID: device.deviceID, partitionType: 1) { error in
                second.set(error)
                secondDone.signal()
            }
            try waitForCondition("S15 duplicate mount did not join pending single-flight") {
                env.manager.pendingDuplicateWaiterCount(deviceID: device.deviceID, partitionType: 1) == 1
            }
            guard env.manager.mountAttemptCount(deviceID: device.deviceID, partitionType: 1) == 1,
                  !first.snapshot().0,
                  !second.snapshot().0 else {
                throw LifecycleValidationError("S15 duplicate mount completed early or launched twice")
            }
            env.manager.releaseHeldMount(deviceID: device.deviceID, partitionType: 1)
            guard firstDone.wait(timeout: .now() + 5) == .success,
                  secondDone.wait(timeout: .now() + 5) == .success,
                  first.snapshot().1 == nil,
                  second.snapshot().1 == nil,
                  env.manager.containsPhysical(deviceID: device.deviceID, partitionType: 1) else {
                throw LifecycleValidationError("S15 single-flight completion fanout failed")
            }
            try env.controller.unmountPartition(deviceID: device.deviceID, partitionType: 1)
            print("SCENARIO=S15_OK duplicate_mount_single_flight_fanout")
        }

        do {
            let env = try ControllerEnvironment.make(
                fixtureDirectory: fixtureDirectory,
                insertDevice: true
            )
            env.controller.reconcileSynchronouslyForTesting()
            let device = try env.connectedDevice()
            env.manager.holdNextMount(deviceID: device.deviceID, partitionType: 1)

            let mountResult = SendableOptionalStringBox()
            let unmountResult = SendableOptionalStringBox()
            let mountDone = DispatchSemaphore(value: 0)
            let unmountDone = DispatchSemaphore(value: 0)
            env.controller.mountPartitionAsync(deviceID: device.deviceID, partitionType: 1) { error in
                mountResult.set(error)
                mountDone.signal()
            }
            try waitForCondition("S16 mount did not reach deferred state") {
                env.manager.hasPendingMount(deviceID: device.deviceID, partitionType: 1)
            }
            env.controller.unmountPartitionAsync(deviceID: device.deviceID, partitionType: 1) { error in
                unmountResult.set(error)
                unmountDone.signal()
            }
            try waitForCondition("S16 unmount did not mark pending mount cancelled") {
                env.manager.pendingMountIsCancelled(deviceID: device.deviceID, partitionType: 1)
            }
            env.manager.releaseHeldMount(deviceID: device.deviceID, partitionType: 1)
            guard mountDone.wait(timeout: .now() + 5) == .success,
                  unmountDone.wait(timeout: .now() + 5) == .success,
                  mountResult.snapshot().1?.contains("cancelled") == true,
                  unmountResult.snapshot().1 == nil,
                  !env.manager.containsPhysical(deviceID: device.deviceID, partitionType: 1) else {
                throw LifecycleValidationError("S16 mount→unmount cancellation ordering failed")
            }
            print("SCENARIO=S16_OK mount_then_unmount_cancels_without_residue")
        }

        do {
            let env = try ControllerEnvironment.make(
                fixtureDirectory: fixtureDirectory,
                insertDevice: true
            )
            env.controller.reconcileSynchronouslyForTesting()
            let device = try env.connectedDevice()
            env.manager.holdNextMount(deviceID: device.deviceID, partitionType: 1)

            let mountResult = SendableOptionalStringBox()
            let ejectResult = SendableOptionalStringBox()
            let mountDone = DispatchSemaphore(value: 0)
            let ejectDone = DispatchSemaphore(value: 0)
            env.controller.mountPartitionAsync(deviceID: device.deviceID, partitionType: 1) { error in
                mountResult.set(error)
                mountDone.signal()
            }
            try waitForCondition("S17 mount did not reach deferred state") {
                env.manager.hasPendingMount(deviceID: device.deviceID, partitionType: 1)
            }
            env.controller.ejectAsync(deviceID: device.deviceID) { error in
                ejectResult.set(error)
                ejectDone.signal()
            }
            try waitForCondition("S17 eject did not cancel pending mount") {
                env.manager.pendingMountIsCancelled(deviceID: device.deviceID, partitionType: 1)
            }
            env.manager.releaseHeldMount(deviceID: device.deviceID, partitionType: 1)
            guard mountDone.wait(timeout: .now() + 5) == .success,
                  ejectDone.wait(timeout: .now() + 5) == .success,
                  mountResult.snapshot().1?.contains("cancelled") == true,
                  ejectResult.snapshot().1 == nil,
                  env.diskArbitration.ejectCalls == [device.bsdName],
                  !env.manager.containsPhysical(deviceID: device.deviceID, partitionType: 1) else {
                throw LifecycleValidationError("S17 mount→eject did not serialize cancellation before physical eject")
            }
            print("SCENARIO=S17_OK mount_then_eject_serializes_before_physical_release")
        }

        do {
            let env = try ControllerEnvironment.make(
                fixtureDirectory: fixtureDirectory,
                insertDevice: true
            )
            env.controller.reconcileSynchronouslyForTesting()
            let device = try env.connectedDevice()
            env.manager.holdNextMount(deviceID: device.deviceID, partitionType: 1)

            let mountResult = SendableOptionalStringBox()
            let firstShutdown = SendableOptionalStringBox()
            let secondShutdown = SendableOptionalStringBox()
            let rejectedMount = SendableOptionalStringBox()
            let mountDone = DispatchSemaphore(value: 0)
            let firstShutdownDone = DispatchSemaphore(value: 0)
            let secondShutdownDone = DispatchSemaphore(value: 0)
            let rejectedDone = DispatchSemaphore(value: 0)
            env.controller.mountPartitionAsync(deviceID: device.deviceID, partitionType: 1) { error in
                mountResult.set(error)
                mountDone.signal()
            }
            try waitForCondition("S18 mount did not reach deferred state") {
                env.manager.hasPendingMount(deviceID: device.deviceID, partitionType: 1)
            }
            env.controller.shutdownGracefullyAsync { error in
                firstShutdown.set(error)
                firstShutdownDone.signal()
            }
            env.controller.shutdownGracefullyAsync { error in
                secondShutdown.set(error)
                secondShutdownDone.signal()
            }
            env.controller.mountPartitionAsync(deviceID: device.deviceID, partitionType: 1) { error in
                rejectedMount.set(error)
                rejectedDone.signal()
            }
            guard rejectedDone.wait(timeout: .now() + 5) == .success,
                  rejectedMount.snapshot().1?.contains("shutting down") == true else {
                throw LifecycleValidationError("S18 shutdown did not reject new mount work")
            }
            try waitForCondition("S18 shutdown did not cancel pending mount") {
                env.manager.pendingMountIsCancelled(deviceID: device.deviceID, partitionType: 1)
            }
            env.manager.releaseHeldMount(deviceID: device.deviceID, partitionType: 1)
            guard mountDone.wait(timeout: .now() + 5) == .success,
                  firstShutdownDone.wait(timeout: .now() + 5) == .success,
                  secondShutdownDone.wait(timeout: .now() + 5) == .success,
                  mountResult.snapshot().1?.contains("cancelled") == true,
                  firstShutdown.snapshot().1 == nil,
                  secondShutdown.snapshot().1 == nil,
                  env.manager.unmountAllCount == 1,
                  env.manager.mounted.isEmpty else {
                throw LifecycleValidationError("S18 duplicate shutdown did not coalesce around in-flight mount")
            }
            print("SCENARIO=S18_OK shutdown_coalesces_and_cancels_inflight_mount")
        }

        do {
            var callbackFirst = EDPDiskArbitrationCompletionGate()
            guard callbackFirst.accept(.callback),
                  !callbackFirst.accept(.timeout),
                  callbackFirst.terminalEvent == .callback else {
                throw LifecycleValidationError(
                    "S19 callback-first DA completion gate was not once-only"
                )
            }

            var timeoutFirst = EDPDiskArbitrationCompletionGate()
            guard timeoutFirst.accept(.timeout),
                  !timeoutFirst.accept(.callback),
                  timeoutFirst.terminalEvent == .timeout else {
                throw LifecycleValidationError(
                    "S19 timeout-first late callback was not ignored"
                )
            }

            var duplicateCallback = EDPDiskArbitrationCompletionGate()
            guard duplicateCallback.accept(.callback),
                  !duplicateCallback.accept(.callback),
                  duplicateCallback.terminalEvent == .callback else {
                throw LifecycleValidationError(
                    "S19 duplicate DA callback completed more than once"
                )
            }
            print("SCENARIO=S19_OK disk_arbitration_completion_once_timeout_late_callback")
        }

        do {
            let normalBox = PublisherProcessResultBox()
            let normalDone = DispatchSemaphore(value: 0)
            _ = EDPAsyncPublisherProcessRegressionHarness.run(
                executable: "/bin/echo",
                arguments: ["publisher-ok"],
                timeout: 2
            ) { status, stdout, errorMessage in
                normalBox.record(status: status, stdout: stdout, errorMessage: errorMessage)
                normalDone.signal()
            }
            guard normalDone.wait(timeout: .now() + 5) == .success else {
                throw LifecycleValidationError("S20 normal async publisher process did not complete")
            }
            let normal = normalBox.snapshot()
            guard normal.count == 1,
                  normal.status == 0,
                  normal.stdout.contains("publisher-ok"),
                  normal.errorMessage == nil else {
                throw LifecycleValidationError("S20 normal async publisher process result changed")
            }

            let timeoutBox = PublisherProcessResultBox()
            let timeoutDone = DispatchSemaphore(value: 0)
            _ = EDPAsyncPublisherProcessRegressionHarness.run(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; while :; do :; done"],
                timeout: 0.1
            ) { status, stdout, errorMessage in
                timeoutBox.record(status: status, stdout: stdout, errorMessage: errorMessage)
                timeoutDone.signal()
            }
            guard timeoutDone.wait(timeout: .now() + 5) == .success else {
                throw LifecycleValidationError("S20 timed-out publisher process did not terminate")
            }
            let timedOut = timeoutBox.snapshot()
            guard timedOut.count == 1,
                  timedOut.errorMessage?.contains("timed out") == true else {
                throw LifecycleValidationError("S20 publisher timeout did not fail exactly once")
            }

            let cancelBox = PublisherProcessResultBox()
            let cancelDone = DispatchSemaphore(value: 0)
            let cancellable = EDPAsyncPublisherProcessRegressionHarness.run(
                executable: "/bin/sleep",
                arguments: ["5"],
                timeout: 2
            ) { status, stdout, errorMessage in
                cancelBox.record(status: status, stdout: stdout, errorMessage: errorMessage)
                cancelDone.signal()
            }
            cancellable.cancel()
            guard cancelDone.wait(timeout: .now() + 5) == .success else {
                throw LifecycleValidationError("S20 cancelled publisher process did not terminate")
            }
            Thread.sleep(forTimeInterval: 0.25)
            let cancelled = cancelBox.snapshot()
            guard cancelled.count == 1,
                  cancelled.errorMessage?.contains("cancelled") == true else {
                throw LifecycleValidationError("S20 publisher cancellation completed more than once or lost cancellation")
            }
            print("SCENARIO=S20_OK async_publisher_process_timeout_cancel_once")
        }

        do {
            let env = try ControllerEnvironment.make(
                fixtureDirectory: fixtureDirectory,
                insertDevice: true
            )
            env.controller.reconcileSynchronouslyForTesting()
            let device = try env.connectedDevice()
            try env.controller.mountPartition(deviceID: device.deviceID, partitionType: 1)
            let service = EDPXPCService(controller: env.controller, didRequestShutdown: {})

            env.manager.failNextUnmounts(
                deviceID: device.deviceID,
                partitionType: 1,
                count: 1,
                message: "EBUSY: injected user-volume unmount failure"
            )
            let unmountReply = SendableOptionalStringBox()
            let unmountReplySemaphore = DispatchSemaphore(value: 0)
            service.unmountPartition(deviceID: device.deviceID, partitionType: 1) { error in
                unmountReply.set(error)
                unmountReplySemaphore.signal()
            }
            guard unmountReplySemaphore.wait(timeout: .now() + 5) == .success else {
                throw LifecycleValidationError("M11 XPC unmount reply timed out")
            }
            let unmountSnapshot = unmountReply.snapshot()
            guard unmountSnapshot.0,
                  unmountSnapshot.1?.contains("EBUSY") == true,
                  env.manager.containsPhysical(deviceID: device.deviceID, partitionType: 1) else {
                throw LifecycleValidationError(
                    "M11 XPC unmount failure was hidden or session state was discarded"
                )
            }

            env.manager.failNextEjects(
                deviceID: device.deviceID,
                count: 1,
                message: "EBUSY: injected published-device eject failure"
            )
            try expectThrows("M11 controller eject unexpectedly succeeded") {
                try env.controller.eject(deviceID: device.deviceID)
            }
            guard env.manager.containsPhysical(deviceID: device.deviceID, partitionType: 1),
                  env.diskArbitration.ejectCalls.isEmpty else {
                throw LifecycleValidationError(
                    "M11 eject did not fail closed before physical device release"
                )
            }

            try env.controller.unmountPartition(deviceID: device.deviceID, partitionType: 1)
            guard !env.manager.containsPhysical(deviceID: device.deviceID, partitionType: 1) else {
                throw LifecycleValidationError("M11 retained session could not be cleaned up")
            }
            print("SCENARIO=M11_OK unmount_error_xpc_state_retained_eject_fail_closed")
        }
    }

    private static func makeController(
        state: EDPVirtualUSBState,
        credentials: EDPCredentialStore,
        policies: EDPDevicePolicyStore,
        manager: FakeMountManager,
        correctPassword: [UInt8],
        verifierMetadata: EDPRawMetadataSnapshot
    ) throws -> EDPDaemonController {
        try EDPDaemonController(
            store: credentials,
            policies: policies,
            manager: manager,
            diskArbitration: FakeDiskArbitration(),
            mediaProvider: EDPVirtualWholeUSBMediaProvider(state: state),
            metadataReader: EDPVirtualRawMetadataReader(state: state),
            rawAccessLeaseOpener: { disk in
                EDPRawAccessLease(
                    deviceID: disk.deviceID,
                    registryEntryID: disk.registryEntryID,
                    rawPath: disk.rawPath,
                    fd: -1
                )
            },
            credentialVerifier: { disk, partitionType, password, _ in
                guard password == correctPassword else {
                    throw LifecycleValidationError("password did not unlock partition \(partitionType)")
                }
                let resolved = EDPPhysicalIdentityResolver.resolve(
                    media: EDPWholeUSBMedia(
                        bsdName: disk.bsdName,
                        sizeBytes: disk.sizeBytes,
                        mediaName: disk.mediaName,
                        vidHex: disk.vidHex,
                        pidHex: disk.pidHex,
                        registryEntryID: disk.registryEntryID,
                        usbRegistryEntryID: disk.usbRegistryEntryID
                    ),
                    metadata: verifierMetadata
                )
                guard resolved.identity != nil, [UInt32(2), 4].contains(partitionType) else {
                    throw LifecycleValidationError("fixture identity/partition validation failed")
                }
            },
            performLegacyRuntimeMigration: false
        )
    }

    private static func waitForCondition(
        _ message: String,
        timeout: TimeInterval = 5,
        condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw LifecycleValidationError(message)
    }

    private static func expectThrows(_ message: String, _ operation: () throws -> Void) throws {
        do {
            try operation()
        } catch {
            return
        }
        throw LifecycleValidationError(message)
    }
}

private extension FakeMountManager {
    func containsPhysical(deviceID: String, partitionType: UInt32) -> Bool {
        mounted["\(deviceID):\(partitionType)"] != nil
    }
}
