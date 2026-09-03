import Darwin
import Foundation

let dataRoot = "/var/db/com.edp.drive"
let legacyDataRoot = "/var/db/com.edp.usbvault"
let sessionRoot = dataRoot + "/sessions"
let credentialIndexPath = dataRoot + "/credential-index.json"
let policyPath = dataRoot + "/device-policies.json"
let logicalEjectSuppressionPath = dataRoot + "/logical-eject-suppressions.json"
let legacyCredentialPath = legacyDataRoot + "/credentials.json"
let legacyMasterKeyPath = legacyDataRoot + "/master.key"

func migrateLegacyRuntimeState() throws {
    try FileManager.default.createDirectory(
        atPath: dataRoot,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: mode_t(0o700))]
    )
    guard chmod(dataRoot, 0o700) == 0 else {
        throw fail("failed to secure EDP Drive state root: errno=\(errno)")
    }
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    let oldCredentialIndex = legacyDataRoot + "/credential-index.json"
    if FileManager.default.fileExists(atPath: oldCredentialIndex) {
        let legacy = try decoder.decode(
            EDPCredentialIndex.self,
            from: Data(contentsOf: URL(fileURLWithPath: oldCredentialIndex))
        )
        var merged = FileManager.default.fileExists(atPath: credentialIndexPath)
            ? try decoder.decode(
                EDPCredentialIndex.self,
                from: Data(contentsOf: URL(fileURLWithPath: credentialIndexPath))
            )
            : EDPCredentialIndex()
        for record in legacy.records {
            if let index = merged.records.firstIndex(where: { $0.deviceID == record.deviceID }) {
                let types = Set(merged.records[index].partitionTypes)
                    .union(record.partitionTypes).sorted()
                merged.records[index] = EDPCredentialRecord(
                    deviceID: record.deviceID,
                    partitionTypes: types,
                    updatedAt: merged.records[index].updatedAt
                )
            } else {
                merged.records.append(record)
            }
        }
        merged.records.sort { $0.deviceID < $1.deviceID }
        try atomicWrite(try encoder.encode(merged), to: credentialIndexPath, mode: 0o600)
    }

    let oldPolicyPath = legacyDataRoot + "/device-policies.json"
    if FileManager.default.fileExists(atPath: oldPolicyPath) {
        let legacy = try decoder.decode(
            EDPPolicyDocument.self,
            from: Data(contentsOf: URL(fileURLWithPath: oldPolicyPath))
        )
        let hasNewPolicy = FileManager.default.fileExists(atPath: policyPath)
        var merged = hasNewPolicy
            ? try decoder.decode(
                EDPPolicyDocument.self,
                from: Data(contentsOf: URL(fileURLWithPath: policyPath))
            )
            : legacy
        if hasNewPolicy {
            for device in legacy.devices
                where !merged.devices.contains(where: { $0.deviceID == device.deviceID }) {
                merged.devices.append(device)
            }
            merged.devices.sort { $0.deviceID < $1.deviceID }
        }
        try atomicWrite(try encoder.encode(merged), to: policyPath, mode: 0o600)
    }

    let oldSessionsPath = legacyDataRoot + "/sessions.json"
    let newSessionsPath = dataRoot + "/sessions.json"
    if FileManager.default.fileExists(atPath: oldSessionsPath),
       !FileManager.default.fileExists(atPath: newSessionsPath) {
        let data = try Data(contentsOf: URL(fileURLWithPath: oldSessionsPath))
        _ = try JSONSerialization.jsonObject(with: data)
        try atomicWrite(data, to: newSessionsPath, mode: 0o644)
    }
}

func finalizeLegacyRuntimeStateMigration() {
    for name in ["credential-index.json", "device-policies.json", "sessions.json"] {
        let oldPath = legacyDataRoot + "/" + name
        let newPath = dataRoot + "/" + name
        guard FileManager.default.fileExists(atPath: newPath) else { continue }
        try? FileManager.default.removeItem(atPath: oldPath)
    }
    try? FileManager.default.removeItem(atPath: legacyDataRoot)
}

func makeCredentialStore() throws -> EDPCredentialStore {
    try EDPCredentialStore(
        indexPath: credentialIndexPath,
        legacyCredentialPath: legacyCredentialPath,
        legacyMasterKeyPath: legacyMasterKeyPath
    )
}

func makePolicyStore() throws -> EDPDevicePolicyStore {
    try EDPDevicePolicyStore(path: policyPath)
}
