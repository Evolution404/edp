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
        try require(initial.policy(for: 1).autoMount, "boot partition must default to auto-mount")
        try require(!initial.policy(for: 2).autoMount, "exchange must default to manual")
        try require(!initial.policy(for: 4).autoMount, "secure must default to manual")

        try store.setAutoMount(deviceID: initial.deviceID, partitionType: 2, enabled: true)
        try store.setDisplayName(deviceID: initial.deviceID, displayName: "财务安全盘")
        try store.setGlobalAutoMount(false)
        let updated = try store.load()
        try require(!updated.globalAutoMountEnabled, "global auto-mount update was not persisted")
        try require(updated.devices.count == 1, "device observation created a duplicate")
        try require(updated.devices[0].displayName == "财务安全盘", "display name was not persisted")
        try require(updated.devices[0].policy(for: 2).autoMount, "partition policy was not persisted")

        let partitions = EDPPartitionKind.allCases.map { kind in
            EDPXPCPartition(
                partitionType: kind.rawValue,
                displayName: kind.displayName,
                encrypted: kind.isEncrypted,
                autoMount: updated.devices[0].policy(for: kind.rawValue).autoMount,
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
                bsdName: "disk99",
                mediaName: "Fixture EDP",
                displayName: "财务安全盘",
                vidPID: "21c4:0cd1",
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

        let physicalID = initial.deviceID + "#0123456789abcdef"
        try store.migrateDeviceID(from: initial.deviceID, to: physicalID)
        let migrated = try store.load()
        try require(migrated.devices.count == 1, "device-ID migration created a duplicate policy")
        try require(migrated.devices[0].deviceID == physicalID, "physical device ID was not migrated")
        try require(migrated.devices[0].displayName == "财务安全盘", "device-ID migration lost display name")
        try require(migrated.devices[0].policy(for: 2).autoMount, "device-ID migration lost auto-mount policy")

        try store.remove(deviceID: physicalID)
        let removed = try store.load()
        try require(removed.devices.isEmpty, "device policy removal did not delete the record")

        print("RESULT=EDP_PRODUCT_MODELS_OK")
    }
}
