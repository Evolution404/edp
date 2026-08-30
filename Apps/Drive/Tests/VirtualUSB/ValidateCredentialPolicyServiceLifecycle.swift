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

private final class FakeMountManager: EDPDaemonMountManaging {
    struct Mounted: Sendable {
        let physicalBSD: String
        let deviceID: String
        let partitionType: UInt32
    }

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

    func failNextUnmounts(deviceID: String, partitionType: UInt32, count: Int, message: String) {
        unmountFailures[key(deviceID, partitionType)] = (count, message)
    }

    func failNextEjects(deviceID: String, count: Int, message: String) {
        ejectFailures[deviceID] = (count, message)
    }

    func recoverPersistedSessions() {
        recoverCount += 1
        staleSessionCount = 0
    }

    func contains(_ disk: PhysicalDisk, _ type: UInt32) -> Bool {
        mounted[key(disk.deviceID, type)] != nil
    }

    func mountedPhysicalDisks() -> Set<String> {
        Set(mounted.values.map(\.physicalBSD))
    }

    func isMounted(deviceID: String) -> Bool {
        mounted.values.contains { $0.deviceID == deviceID }
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

    func eject(deviceID: String) throws {
        if var failure = ejectFailures[deviceID], failure.remaining > 0 {
            failure.remaining -= 1
            ejectFailures[deviceID] = failure
            throw LifecycleValidationError(failure.message)
        }
        mounted = mounted.filter { $0.value.deviceID != deviceID }
    }

    func unmount(deviceID: String, partitionType: UInt32) throws {
        let sessionKey = key(deviceID, partitionType)
        if var failure = unmountFailures[sessionKey], failure.remaining > 0 {
            failure.remaining -= 1
            unmountFailures[sessionKey] = failure
            throw LifecycleValidationError(failure.message)
        }
        mounted.removeValue(forKey: sessionKey)
    }

    func mount(
        disk: PhysicalDisk,
        partitionType: UInt32,
        password: [UInt8],
        rawFD: Int32
    ) throws {
        let sessionKey = key(disk.deviceID, partitionType)
        mountAttempts[sessionKey, default: 0] += 1
        if var failure = failures[sessionKey], failure.remaining > 0 {
            failure.remaining -= 1
            failures[sessionKey] = failure
            throw LifecycleValidationError(failure.message)
        }
        mounted[sessionKey] = Mounted(
            physicalBSD: disk.bsdName,
            deviceID: disk.deviceID,
            partitionType: partitionType
        )
    }

    @discardableResult
    func removeMissing(availableDisks: [String: String], graceSeconds: TimeInterval) -> Bool {
        mounted = mounted.filter { _, session in
            availableDisks[session.deviceID] == session.physicalBSD
        }
        return false
    }

    func unmountAll() {
        unmountAllCount += 1
        mounted.removeAll()
    }
}

private final class FakeDiskArbitration: EDPDaemonDiskArbitrating, @unchecked Sendable {
    private(set) var suppressed = Set<UInt64>()
    private(set) var unmountWholeCalls = [String]()
    private(set) var ejectCalls = [String]()

    func suppressAutomount(usbRegistryEntryID: UInt64) {
        suppressed.insert(usbRegistryEntryID)
    }

    func allowAutomount(usbRegistryEntryID: UInt64) {
        suppressed.remove(usbRegistryEntryID)
    }

    func unmountWhole(_ bsdName: String) throws {
        unmountWholeCalls.append(bsdName)
    }

    func eject(_ bsdName: String) throws {
        ejectCalls.append(bsdName)
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
                insertDevice: true
            )
            try env.policies.setDefaultAutoMount(partitionType: 1, enabled: true)
            try env.policies.setDefaultAutoMount(partitionType: 2, enabled: true)
            try env.policies.setDefaultAutoProbePassword(partitionType: 2, enabled: true)
            try env.policies.setDefaultAutoProbePassword(partitionType: 4, enabled: true)
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
                insertDevice: true
            )
            try env.policies.setDefaultAutoMount(partitionType: 2, enabled: true)
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
                insertDevice: true
            )
            try env.policies.setDefaultAutoProbePassword(partitionType: 2, enabled: true)
            try env.credentials.setDefaultProbePassword(
                partitionType: 2,
                password: Array("wrong-default".utf8)
            )
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
                insertDevice: true
            )
            try env.policies.setDefaultAutoProbePassword(partitionType: 2, enabled: true)
            try env.policies.setDefaultAutoProbePassword(partitionType: 4, enabled: true)
            try env.credentials.setDefaultProbePassword(
                partitionType: 2,
                password: Array("wrong-exchange-only".utf8)
            )
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
                insertDevice: true
            )
            try env.policies.setDefaultAutoMount(partitionType: 2, enabled: true)
            try env.policies.setDefaultAutoProbePassword(partitionType: 2, enabled: true)
            try env.policies.setGlobalAutoMount(false)
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
            try publisher.unpublish(EDPPublishedBlockDevice(
                bsdName: "disk31",
                backingPath: "/Volumes/.edp-block-stale-disk31/volume.raw"
            ))
            guard fakeDA.ejectCalls.isEmpty else {
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
            service.requestGracefulShutdown { replyError = $0 }
            guard replyError == nil,
                  requested.get(),
                  env.manager.mounted.isEmpty,
                  env.manager.unmountAllCount == 1 else {
                throw LifecycleValidationError("S10 XPC graceful full exit did not teardown service state")
            }
            print("SCENARIO=S10_OK graceful_full_exit")
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
            var unmountReplyCalled = false
            var unmountReplyError: String?
            service.unmountPartition(deviceID: device.deviceID, partitionType: 1) { error in
                unmountReplyCalled = true
                unmountReplyError = error
            }
            guard unmountReplyCalled,
                  unmountReplyError?.contains("EBUSY") == true,
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
