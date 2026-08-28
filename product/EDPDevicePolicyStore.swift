import Darwin
import Foundation

struct EDPPartitionPolicy: Codable, Hashable, Sendable {
    let partitionType: UInt32
    var autoMount: Bool
}

struct EDPDevicePolicy: Codable, Hashable, Sendable {
    let deviceID: String
    var displayName: String
    var lastMediaName: String
    var lastVIDPID: String
    var lastSizeBytes: UInt64
    var partitions: [EDPPartitionPolicy]

    func policy(for partitionType: UInt32) -> EDPPartitionPolicy {
        partitions.first { $0.partitionType == partitionType }
            ?? EDPPartitionPolicy(partitionType: partitionType, autoMount: false)
    }
}

struct EDPPolicyDocument: Codable, Sendable {
    var schemaVersion = 1
    var globalAutoMountEnabled = true
    var devices = [EDPDevicePolicy]()
}

struct EDPDevicePolicyStoreError: Error, CustomStringConvertible, Sendable {
    let description: String
}

final class EDPDevicePolicyStore {
    private let path: String

    init(path: String) throws {
        self.path = path
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: mode_t(0o700))]
        )
        guard chmod(directory, 0o700) == 0 else {
            throw EDPDevicePolicyStoreError(
                description: "failed to secure policy directory: errno=\(errno)"
            )
        }
    }

    func load() throws -> EDPPolicyDocument {
        guard FileManager.default.fileExists(atPath: path) else {
            return EDPPolicyDocument()
        }
        return try JSONDecoder().decode(
            EDPPolicyDocument.self,
            from: Data(contentsOf: URL(fileURLWithPath: path))
        )
    }

    @discardableResult
    func observe(
        deviceID: String,
        mediaName: String,
        vidPID: String,
        sizeBytes: UInt64
    ) throws -> EDPDevicePolicy {
        var document = try load()
        if let index = document.devices.firstIndex(where: { $0.deviceID == deviceID }) {
            let existing = document.devices[index]
            guard existing.lastMediaName != mediaName
                    || existing.lastVIDPID != vidPID
                    || existing.lastSizeBytes != sizeBytes else {
                return existing
            }
            document.devices[index].lastMediaName = mediaName
            document.devices[index].lastVIDPID = vidPID
            document.devices[index].lastSizeBytes = sizeBytes
            try save(document)
            return document.devices[index]
        }
        let policy = EDPDevicePolicy(
            deviceID: deviceID,
            displayName: mediaName,
            lastMediaName: mediaName,
            lastVIDPID: vidPID,
            lastSizeBytes: sizeBytes,
            partitions: EDPPartitionKind.allCases.map {
                EDPPartitionPolicy(partitionType: $0.rawValue, autoMount: $0 == .boot)
            }
        )
        document.devices.append(policy)
        document.devices.sort { $0.deviceID < $1.deviceID }
        try save(document)
        return policy
    }

    func setAutoMount(deviceID: String, partitionType: UInt32, enabled: Bool) throws {
        guard EDPPartitionKind(rawValue: partitionType) != nil else {
            throw EDPDevicePolicyStoreError(description: "unsupported partition type \(partitionType)")
        }
        var document = try load()
        guard let deviceIndex = document.devices.firstIndex(where: { $0.deviceID == deviceID }) else {
            throw EDPDevicePolicyStoreError(description: "device policy not found")
        }
        if let partitionIndex = document.devices[deviceIndex].partitions.firstIndex(
            where: { $0.partitionType == partitionType }
        ) {
            document.devices[deviceIndex].partitions[partitionIndex].autoMount = enabled
        } else {
            document.devices[deviceIndex].partitions.append(
                EDPPartitionPolicy(partitionType: partitionType, autoMount: enabled)
            )
        }
        document.devices[deviceIndex].partitions.sort { $0.partitionType < $1.partitionType }
        try save(document)
    }

    func setDisplayName(deviceID: String, displayName: String) throws {
        let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 64 else {
            throw EDPDevicePolicyStoreError(description: "device name must contain 1...64 characters")
        }
        var document = try load()
        guard let index = document.devices.firstIndex(where: { $0.deviceID == deviceID }) else {
            throw EDPDevicePolicyStoreError(description: "device policy not found")
        }
        document.devices[index].displayName = normalized
        try save(document)
    }

    func setGlobalAutoMount(_ enabled: Bool) throws {
        var document = try load()
        document.globalAutoMountEnabled = enabled
        try save(document)
    }

    func migrateDeviceID(from legacyDeviceID: String, to deviceID: String) throws {
        guard legacyDeviceID != deviceID else { return }
        var document = try load()
        guard !document.devices.contains(where: { $0.deviceID == deviceID }),
              let index = document.devices.firstIndex(where: { $0.deviceID == legacyDeviceID }) else {
            return
        }
        let legacy = document.devices.remove(at: index)
        document.devices.append(EDPDevicePolicy(
            deviceID: deviceID,
            displayName: legacy.displayName,
            lastMediaName: legacy.lastMediaName,
            lastVIDPID: legacy.lastVIDPID,
            lastSizeBytes: legacy.lastSizeBytes,
            partitions: legacy.partitions
        ))
        document.devices.sort { $0.deviceID < $1.deviceID }
        try save(document)
    }

    private func save(_ document: EDPPolicyDocument) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        let temporary = path + ".tmp.\(getpid())"
        try data.write(to: URL(fileURLWithPath: temporary), options: .withoutOverwriting)
        guard chmod(temporary, 0o600) == 0 else {
            let saved = errno
            try? FileManager.default.removeItem(atPath: temporary)
            throw EDPDevicePolicyStoreError(description: "chmod policy failed: errno=\(saved)")
        }
        if rename(temporary, path) != 0 {
            let saved = errno
            try? FileManager.default.removeItem(atPath: temporary)
            throw EDPDevicePolicyStoreError(description: "atomic policy write failed: errno=\(saved)")
        }
    }
}
