import Foundation

private struct ValidationFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ValidationFailure(description: message) }
}

@main
private enum ValidateProductModels {
    static func main() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edp-policy-test-\(UUID().uuidString)", isDirectory: true)
        let store = try EDPDevicePolicyStore(
            path: root.appendingPathComponent("policy.json").path
        )

        let initial = try store.observe(
            deviceID: "fixture-device",
            mediaName: "Fixture EDP",
            vidPID: "21c4:0cd1",
            sizeBytes: 128 * 1024 * 1024
        )
        for kind in EDPPartitionKind.allCases {
            let policy = initial.policy(for: kind.rawValue)
            try require(!policy.autoMount, "\(kind.displayName) must default to manual mount")
            try require(!policy.autoProbePassword, "\(kind.displayName) must default to no password probing")
        }

        try store.setDefaultAutoMount(partitionType: 1, enabled: true)
        try store.setDefaultAutoMount(partitionType: 2, enabled: true)
        try store.setDefaultAutoProbePassword(partitionType: 2, enabled: true)
        try store.setDefaultAutoProbePassword(partitionType: 4, enabled: true)
        try expectThrows("boot default password probing was accepted") {
            try store.setDefaultAutoProbePassword(partitionType: 1, enabled: true)
        }

        let afterDefaultChange = try store.load()
        guard let existingAfterDefaultChange = afterDefaultChange.devices.first(
            where: { $0.deviceID == initial.deviceID }
        ) else {
            throw ValidationFailure(description: "existing device disappeared after default change")
        }
        for kind in EDPPartitionKind.allCases {
            try require(
                !existingAfterDefaultChange.policy(for: kind.rawValue).autoMount,
                "changing defaults mutated an existing device's auto-mount policy"
            )
            try require(
                !existingAfterDefaultChange.policy(for: kind.rawValue).autoProbePassword,
                "changing defaults mutated an existing device's password-probe policy"
            )
        }

        let inheritedDefaultsID = initial.deviceID + "#inherits-new-defaults"
        let inheritedDefaults = try store.observe(
            deviceID: inheritedDefaultsID,
            mediaName: "New Fixture EDP",
            vidPID: "21c4:0cd1",
            sizeBytes: 128 * 1024 * 1024
        )
        try require(inheritedDefaults.policy(for: 1).autoMount, "new boot policy did not inherit default auto-mount")
        try require(inheritedDefaults.policy(for: 2).autoMount, "new exchange policy did not inherit default auto-mount")
        try require(inheritedDefaults.policy(for: 2).autoProbePassword, "new exchange policy did not inherit password probing")
        try require(!inheritedDefaults.policy(for: 4).autoMount, "new secure policy inherited an unintended auto-mount")
        try require(inheritedDefaults.policy(for: 4).autoProbePassword, "new secure policy did not inherit password probing")

        try store.setAutoMount(deviceID: initial.deviceID, partitionType: 2, enabled: true)
        try store.setDisplayName(deviceID: initial.deviceID, displayName: "财务安全盘")
        try store.setGlobalAutoMount(false)
        let updated = try store.load()
        try require(!updated.globalAutoMountEnabled, "global auto-mount update was not persisted")
        guard let updatedInitial = updated.devices.first(where: { $0.deviceID == initial.deviceID }) else {
            throw ValidationFailure(description: "updated device record disappeared")
        }
        try require(updatedInitial.displayName == "财务安全盘", "display name was not persisted")
        try require(updatedInitial.policy(for: 2).autoMount, "partition policy was not persisted")

        let partitions = EDPPartitionKind.allCases.map { kind in
            EDPXPCPartition(
                partitionType: kind.rawValue,
                displayName: kind.displayName,
                encrypted: kind.isEncrypted,
                autoMount: updatedInitial.policy(for: kind.rawValue).autoMount,
                credentialStatus: kind.isEncrypted ? .missing : .notRequired,
                mountState: .unmounted,
                filesystem: nil,
                readOnly: nil,
                mountPoint: nil,
                lastError: nil
            )
        }
        let snapshot = EDPXPCSnapshot(
            devices: [EDPXPCDevice(
                deviceID: initial.deviceID,
                metadataDeviceID: "disk&ven_fixture&prod_usb",
                bsdName: "disk99",
                mediaName: "Fixture EDP",
                displayName: "财务安全盘",
                vidPID: "21c4:0cd1",
                labelOnlyID: 1_625_940_067,
                sizeBytes: 128 * 1024 * 1024,
                connected: true,
                privilegedAccessReady: false,
                partitions: partitions
            )],
            serviceVersion: "test",
            timestamp: "2026-08-27T00:00:00Z",
            globalAutoMountEnabled: false
        )
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(EDPXPCSnapshot.self, from: encoded)
        try require(decoded.devices[0].partitions.map(\.partitionType) == [1, 2, 4],
                    "partition snapshot round-trip changed partition ordering")
        try require(!decoded.globalAutoMountEnabled, "snapshot round-trip changed global policy")

        let differentPhysicalID = initial.deviceID + "#different-five-factor-identity"
        _ = try store.observe(
            deviceID: differentPhysicalID,
            mediaName: "Fixture EDP",
            vidPID: "21c4:0cd1",
            sizeBytes: 128 * 1024 * 1024
        )
        let distinct = try store.load()
        try require(distinct.devices.count == 3, "different physical identities must create separate device records")
        try require(
            distinct.devices.first(where: { $0.deviceID == differentPhysicalID })?.displayName == "Fixture EDP",
            "a new physical identity must not inherit the old display name"
        )
        try require(
            distinct.devices.first(where: { $0.deviceID == differentPhysicalID })?.policy(for: 2).autoMount == true,
            "a new physical identity did not inherit the current default auto-mount policy"
        )
        try require(
            distinct.devices.first(where: { $0.deviceID == differentPhysicalID })?.policy(for: 2).autoProbePassword == true,
            "a new physical identity did not inherit the current default password-probe policy"
        )

        try store.remove(deviceID: differentPhysicalID)
        try store.remove(deviceID: inheritedDefaultsID)
        try store.remove(deviceID: initial.deviceID)
        let removed = try store.load()
        try require(removed.devices.isEmpty, "device policy removal did not delete the records")

        print("RESULT=EDP_PRODUCT_MODELS_OK")
    }

    private static func expectThrows(_ message: String, _ operation: () throws -> Void) throws {
        do {
            try operation()
        } catch {
            return
        }
        throw ValidationFailure(description: message)
    }
}
