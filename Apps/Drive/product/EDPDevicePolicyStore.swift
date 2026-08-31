import Darwin
import Foundation

struct EDPPartitionPolicy: Codable, Hashable, Sendable {
    let partitionType: UInt32
    var autoMount: Bool
    var autoProbePassword: Bool

    init(partitionType: UInt32, autoMount: Bool, autoProbePassword: Bool = false) {
        self.partitionType = partitionType
        self.autoMount = autoMount
        self.autoProbePassword = autoProbePassword
    }

    private enum CodingKeys: String, CodingKey {
        case partitionType
        case autoMount
        case autoProbePassword
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        partitionType = try container.decode(UInt32.self, forKey: .partitionType)
        autoMount = try container.decode(Bool.self, forKey: .autoMount)
        autoProbePassword = try container.decodeIfPresent(Bool.self, forKey: .autoProbePassword) ?? false
    }
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
    static let currentSchemaVersion = 2

    var schemaVersion = currentSchemaVersion
    var globalAutoMountEnabled = true
    var partitionDefaults = EDPPolicyDocument.safePartitionDefaults()
    var devices = [EDPDevicePolicy]()

    static func safePartitionDefaults() -> [EDPPartitionPolicy] {
        EDPPartitionKind.allCases.map {
            EDPPartitionPolicy(
                partitionType: $0.rawValue,
                autoMount: false,
                autoProbePassword: false
            )
        }
    }

    func defaultPolicy(for partitionType: UInt32) -> EDPPartitionPolicy {
        partitionDefaults.first { $0.partitionType == partitionType }
            ?? EDPPartitionPolicy(
                partitionType: partitionType,
                autoMount: false,
                autoProbePassword: false
            )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case globalAutoMountEnabled
        case partitionDefaults
        case devices
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sourceSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        schemaVersion = EDPPolicyDocument.currentSchemaVersion
        globalAutoMountEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .globalAutoMountEnabled
        ) ?? true
        partitionDefaults = try container.decodeIfPresent(
            [EDPPartitionPolicy].self,
            forKey: .partitionDefaults
        ) ?? EDPPolicyDocument.safePartitionDefaults()
        devices = try container.decodeIfPresent([EDPDevicePolicy].self, forKey: .devices) ?? []

        let existingDefaultTypes = Set(partitionDefaults.map(\.partitionType))
        for kind in EDPPartitionKind.allCases where !existingDefaultTypes.contains(kind.rawValue) {
            partitionDefaults.append(EDPPartitionPolicy(
                partitionType: kind.rawValue,
                autoMount: false,
                autoProbePassword: false
            ))
        }
        partitionDefaults = partitionDefaults
            .filter { EDPPartitionKind(rawValue: $0.partitionType) != nil }
            .map { policy in
                var normalized = policy
                if normalized.partitionType == EDPPartitionKind.boot.rawValue {
                    normalized.autoProbePassword = false
                }
                return normalized
            }
            .sorted { $0.partitionType < $1.partitionType }

        if sourceSchemaVersion < EDPPolicyDocument.currentSchemaVersion {
            // Schema v1 treated the boot partition as auto-mount by default,
            // so a stored `true` cannot be distinguished from an explicit user
            // choice.  The v2 safety contract requires every automatic action
            // to be opt-in, therefore migration resets all per-device automatic
            // actions once. Users can explicitly enable them again afterward.
            devices = devices.map { device in
                var migrated = device
                migrated.partitions = EDPPartitionKind.allCases.map { kind in
                    EDPPartitionPolicy(
                        partitionType: kind.rawValue,
                        autoMount: false,
                        autoProbePassword: false
                    )
                }
                return migrated
            }
        }
    }
}

struct EDPDevicePolicyStoreError: Error, CustomStringConvertible, Sendable {
    let description: String
}

final class EDPDevicePolicyStore {
    private let path: String
    private let lock = NSRecursiveLock()

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

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
        try synchronized {
            guard FileManager.default.fileExists(atPath: path) else {
                return EDPPolicyDocument()
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let sourceSchemaVersion = (
                (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            )?["schemaVersion"] as? Int ?? 1
            let document = try JSONDecoder().decode(EDPPolicyDocument.self, from: data)
            if sourceSchemaVersion < EDPPolicyDocument.currentSchemaVersion {
                try save(document)
            }
            return document
        }
    }

    @discardableResult
    func observe(
        deviceID: String,
        mediaName: String,
        vidPID: String,
        sizeBytes: UInt64
    ) throws -> EDPDevicePolicy {
        try synchronized {
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
                    let defaultPolicy = document.defaultPolicy(for: $0.rawValue)
                    return EDPPartitionPolicy(
                        partitionType: $0.rawValue,
                        autoMount: defaultPolicy.autoMount,
                        autoProbePassword: $0.isEncrypted && defaultPolicy.autoProbePassword
                    )
                }
            )
            document.devices.append(policy)
            document.devices.sort { $0.deviceID < $1.deviceID }
            try save(document)
            return policy
        }
    }

    func setDefaultAutoMount(partitionType: UInt32, enabled: Bool) throws {
        try synchronized {
            guard EDPPartitionKind(rawValue: partitionType) != nil else {
                throw EDPDevicePolicyStoreError(description: "unsupported partition type \(partitionType)")
            }
            var document = try load()
            if let index = document.partitionDefaults.firstIndex(where: { $0.partitionType == partitionType }) {
                document.partitionDefaults[index].autoMount = enabled
            } else {
                document.partitionDefaults.append(EDPPartitionPolicy(
                    partitionType: partitionType,
                    autoMount: enabled,
                    autoProbePassword: false
                ))
            }
            document.partitionDefaults.sort { $0.partitionType < $1.partitionType }
            try save(document)
        }
    }

    func setDefaultAutoProbePassword(partitionType: UInt32, enabled: Bool) throws {
        try synchronized {
            guard let kind = EDPPartitionKind(rawValue: partitionType), kind.isEncrypted else {
                throw EDPDevicePolicyStoreError(
                    description: "automatic password probing is only valid for partition 2 or 4"
                )
            }
            var document = try load()
            if let index = document.partitionDefaults.firstIndex(where: { $0.partitionType == partitionType }) {
                document.partitionDefaults[index].autoProbePassword = enabled
            } else {
                document.partitionDefaults.append(EDPPartitionPolicy(
                    partitionType: partitionType,
                    autoMount: false,
                    autoProbePassword: enabled
                ))
            }
            document.partitionDefaults.sort { $0.partitionType < $1.partitionType }
            try save(document)
        }
    }

    func setAutoMount(deviceID: String, partitionType: UInt32, enabled: Bool) throws {
        try synchronized {
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
                    EDPPartitionPolicy(
                        partitionType: partitionType,
                        autoMount: enabled,
                        autoProbePassword: false
                    )
                )
            }
            document.devices[deviceIndex].partitions.sort { $0.partitionType < $1.partitionType }
            try save(document)
        }
    }

    func setAutoProbePassword(deviceID: String, partitionType: UInt32, enabled: Bool) throws {
        try synchronized {
            guard let kind = EDPPartitionKind(rawValue: partitionType), kind.isEncrypted else {
                throw EDPDevicePolicyStoreError(
                    description: "automatic password probing is only valid for partition 2 or 4"
                )
            }
            var document = try load()
            guard let deviceIndex = document.devices.firstIndex(where: { $0.deviceID == deviceID }) else {
                throw EDPDevicePolicyStoreError(description: "device policy not found")
            }
            if let partitionIndex = document.devices[deviceIndex].partitions.firstIndex(
                where: { $0.partitionType == partitionType }
            ) {
                document.devices[deviceIndex].partitions[partitionIndex].autoProbePassword = enabled
            } else {
                document.devices[deviceIndex].partitions.append(EDPPartitionPolicy(
                    partitionType: partitionType,
                    autoMount: false,
                    autoProbePassword: enabled
                ))
            }
            document.devices[deviceIndex].partitions.sort { $0.partitionType < $1.partitionType }
            try save(document)
        }
    }

    func setDisplayName(deviceID: String, displayName: String) throws {
        try synchronized {
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
    }

    func setGlobalAutoMount(_ enabled: Bool) throws {
        try synchronized {
            var document = try load()
            document.globalAutoMountEnabled = enabled
            try save(document)
        }
    }

    func remove(deviceID: String) throws {
        try synchronized {
            var document = try load()
            document.devices.removeAll { $0.deviceID == deviceID }
            try save(document)
        }
    }

    private func save(_ document: EDPPolicyDocument) throws {
        try synchronized {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            let temporary = path + ".tmp.\(getpid()).\(UUID().uuidString)"
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
}
