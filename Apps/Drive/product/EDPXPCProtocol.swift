import Foundation

let edpVaultMachServiceName = "com.edp.drive.service"

enum EDPPartitionKind: UInt32, Codable, CaseIterable, Sendable {
    case boot = 1
    case exchange = 2
    case secure = 4

    var displayName: String {
        switch self {
        case .boot: return "启动区"
        case .exchange: return "交换区"
        case .secure: return "保密区"
        }
    }

    var isEncrypted: Bool { self != .boot }
}

enum EDPCredentialStatus: String, Codable, Sendable {
    case notRequired
    case missing
    case saved
    case invalid
}

enum EDPMountState: String, Codable, Sendable {
    case unavailable
    case unmounted
    case mounting
    case mounted
    case failed
}

struct EDPXPCPartitionDefault: Codable, Hashable, Sendable, Identifiable {
    var id: UInt32 { partitionType }
    let partitionType: UInt32
    let displayName: String
    let autoMount: Bool
    let autoProbePassword: Bool
    let defaultProbePasswordCustomized: Bool
}

struct EDPXPCPartition: Codable, Hashable, Sendable, Identifiable {
    var id: UInt32 { partitionType }
    let partitionType: UInt32
    let displayName: String
    let encrypted: Bool
    let autoMount: Bool
    let credentialStatus: EDPCredentialStatus
    let mountState: EDPMountState
    let filesystem: String?
    let readOnly: Bool?
    let mountPoint: String?
    let lastError: String?
}

struct EDPXPCDevice: Codable, Hashable, Sendable, Identifiable {
    var id: String { deviceID }
    let deviceID: String
    let metadataDeviceID: String?
    let bsdName: String
    let mediaName: String
    let displayName: String
    let vidPID: String
    let labelOnlyID: UInt64?
    let sizeBytes: UInt64
    let connected: Bool
    let privilegedAccessReady: Bool
    let partitions: [EDPXPCPartition]

    var mounted: Bool { partitions.contains { $0.mountState == .mounted } }
    var authorized: Bool { partitions.contains { $0.credentialStatus == .saved } }
    var partitionTypes: [UInt32] {
        partitions.filter { $0.credentialStatus == .saved }.map(\.partitionType)
    }
}

struct EDPXPCActivity: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let timestamp: String
    let level: String
    let deviceID: String?
    let partitionType: UInt32?
    let message: String
}

struct EDPXPCSnapshot: Codable, Sendable {
    let devices: [EDPXPCDevice]
    let activities: [EDPXPCActivity]
    let serviceVersion: String
    let timestamp: String
    let globalAutoMountEnabled: Bool
    let partitionDefaults: [EDPXPCPartitionDefault]

    init(
        devices: [EDPXPCDevice],
        activities: [EDPXPCActivity] = [],
        serviceVersion: String,
        timestamp: String,
        globalAutoMountEnabled: Bool = true,
        partitionDefaults: [EDPXPCPartitionDefault] = EDPPartitionKind.allCases.map {
            EDPXPCPartitionDefault(
                partitionType: $0.rawValue,
                displayName: $0.displayName,
                autoMount: false,
                autoProbePassword: false,
                defaultProbePasswordCustomized: false
            )
        }
    ) {
        self.devices = devices
        self.activities = activities
        self.serviceVersion = serviceVersion
        self.timestamp = timestamp
        self.globalAutoMountEnabled = globalAutoMountEnabled
        self.partitionDefaults = partitionDefaults
    }
}

@objc protocol EDPVaultXPCProtocol {
    func healthCheck(withReply reply: @escaping (String) -> Void)
    func requestGracefulShutdown(withReply reply: @escaping (String?) -> Void)
    func snapshot(withReply reply: @escaping (Data) -> Void)
    func refreshRawAccess(withReply reply: @escaping (String?) -> Void)
    func retryTransientAutomaticMounts(withReply reply: @escaping (String?) -> Void)
    func saveCredential(deviceID: String, partitionType: UInt32, password: Data, withReply reply: @escaping (String?) -> Void)
    func deleteCredential(deviceID: String, partitionType: UInt32, withReply reply: @escaping (String?) -> Void)
    func deleteDeviceRecord(deviceID: String, withReply reply: @escaping (String?) -> Void)
    func setPartitionAutoMount(deviceID: String, partitionType: UInt32, enabled: Bool, withReply reply: @escaping (String?) -> Void)
    func setDefaultPartitionAutoMount(partitionType: UInt32, enabled: Bool, withReply reply: @escaping (String?) -> Void)
    func setDefaultPartitionAutoProbePassword(partitionType: UInt32, enabled: Bool, withReply reply: @escaping (String?) -> Void)
    func setDefaultProbePassword(partitionType: UInt32, password: Data, withReply reply: @escaping (String?) -> Void)
    func resetDefaultProbePassword(partitionType: UInt32, withReply reply: @escaping (String?) -> Void)
    func setDeviceDisplayName(deviceID: String, displayName: String, withReply reply: @escaping (String?) -> Void)
    func setGlobalAutoMount(enabled: Bool, withReply reply: @escaping (String?) -> Void)
    func mountPartition(deviceID: String, partitionType: UInt32, withReply reply: @escaping (String?) -> Void)
    func unmountPartition(deviceID: String, partitionType: UInt32, withReply reply: @escaping (String?) -> Void)
    func eject(deviceID: String, withReply reply: @escaping (String?) -> Void)
    func diagnostics(withReply reply: @escaping (Data) -> Void)
}
