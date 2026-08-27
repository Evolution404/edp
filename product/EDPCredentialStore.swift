import CryptoKit
import Darwin
import Foundation
import Security

struct EDPCredentialRecord: Codable, Hashable, Sendable {
    let deviceID: String
    let partitionTypes: [UInt32]
    let updatedAt: String
}

struct EDPCredentialIndex: Codable, Sendable {
    var schemaVersion = 4
    var records = [EDPCredentialRecord]()
}

struct EDPCredentialStoreError: Error, CustomStringConvertible, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

private struct LegacyCredentialRecord: Codable {
    let deviceID: String
    let sealedPassword: String
    let partitionTypes: [UInt32]
    let updatedAt: String
}

private struct LegacyCredentialFile: Codable {
    let schemaVersion: Int
    let records: [LegacyCredentialRecord]
}

final class EDPCredentialStore {
    static let serviceName = "com.edp.usbvault.partition-password.v4"
    static let deviceServiceName = "com.edp.usbvault.device-password.v3"
    static let legacyServiceName = "com.edp.usbvault.device-password"

    private let indexPath: String
    private let keychain: SecKeychain

    init(
        indexPath: String,
        keychainPath: String = "/Library/Keychains/System.keychain",
        legacyCredentialPath: String? = nil,
        legacyMasterKeyPath: String? = nil
    ) throws {
        self.indexPath = indexPath
        let directory = URL(fileURLWithPath: indexPath).deletingLastPathComponent().path
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: mode_t(0o700))]
        )
        guard chmod(directory, 0o700) == 0 else {
            throw EDPCredentialStoreError("failed to secure credential index directory: errno=\(errno)")
        }

        var opened: SecKeychain?
        let status = SecKeychainOpen(keychainPath, &opened)
        guard status == errSecSuccess, let opened else {
            throw EDPCredentialStoreError("SecKeychainOpen failed for \(keychainPath): status=\(status)")
        }
        keychain = opened

        if !FileManager.default.fileExists(atPath: indexPath),
           let legacyCredentialPath,
           let legacyMasterKeyPath,
           FileManager.default.fileExists(atPath: legacyCredentialPath),
           FileManager.default.fileExists(atPath: legacyMasterKeyPath) {
            try migrateLegacyStore(
                credentialPath: legacyCredentialPath,
                masterKeyPath: legacyMasterKeyPath
            )
        }

        try migrateDeviceCredentialsToPartitions()
        try pruneRecordsWithoutCurrentCredentials()
    }

    func load() throws -> EDPCredentialIndex {
        guard FileManager.default.fileExists(atPath: indexPath) else {
            return EDPCredentialIndex()
        }
        return try JSONDecoder().decode(
            EDPCredentialIndex.self,
            from: Data(contentsOf: URL(fileURLWithPath: indexPath))
        )
    }

    func password(deviceID: String, partitionType: UInt32) throws -> [UInt8] {
        var query = searchQuery(deviceID: deviceID, partitionType: partitionType)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw EDPCredentialStoreError(
                "Keychain password unavailable for \(deviceID) partition \(partitionType): status=\(status)"
            )
        }
        return [UInt8](data)
    }

    func put(deviceID: String, password: [UInt8], partitionTypes: [UInt32]) throws {
        for partitionType in partitionTypes {
            try upsertPassword(
                deviceID: deviceID,
                partitionType: partitionType,
                password: password
            )
        }
        var index = try load()
        index.records.removeAll { $0.deviceID == deviceID }
        index.records.append(EDPCredentialRecord(
            deviceID: deviceID,
            partitionTypes: partitionTypes.sorted(),
            updatedAt: ISO8601DateFormatter().string(from: Date())
        ))
        index.records.sort { $0.deviceID < $1.deviceID }
        try save(index)
    }

    func put(deviceID: String, partitionType: UInt32, password: [UInt8]) throws {
        guard [UInt32(2), 4].contains(partitionType) else {
            throw EDPCredentialStoreError("credentials are only valid for partition 2 or 4")
        }
        try upsertPassword(
            deviceID: deviceID,
            partitionType: partitionType,
            password: password
        )
        var index = try load()
        var types = Set(index.records.first { $0.deviceID == deviceID }?.partitionTypes ?? [])
        types.insert(partitionType)
        index.records.removeAll { $0.deviceID == deviceID }
        index.records.append(EDPCredentialRecord(
            deviceID: deviceID,
            partitionTypes: types.sorted(),
            updatedAt: ISO8601DateFormatter().string(from: Date())
        ))
        index.records.sort { $0.deviceID < $1.deviceID }
        try save(index)
    }

    func remove(deviceID: String, partitionType: UInt32) throws {
        let status = SecItemDelete(
            searchQuery(deviceID: deviceID, partitionType: partitionType) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw EDPCredentialStoreError("Keychain delete failed: status=\(status)")
        }
        var index = try load()
        guard let record = index.records.first(where: { $0.deviceID == deviceID }) else { return }
        let remaining = record.partitionTypes.filter { $0 != partitionType }
        index.records.removeAll { $0.deviceID == deviceID }
        if !remaining.isEmpty {
            index.records.append(EDPCredentialRecord(
                deviceID: deviceID,
                partitionTypes: remaining,
                updatedAt: ISO8601DateFormatter().string(from: Date())
            ))
        }
        index.records.sort { $0.deviceID < $1.deviceID }
        try save(index)
    }

    func remove(deviceID: String) throws {
        let index = try load()
        for partitionType in index.records.first(where: { $0.deviceID == deviceID })?.partitionTypes ?? [] {
            let status = SecItemDelete(
                searchQuery(deviceID: deviceID, partitionType: partitionType) as CFDictionary
            )
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw EDPCredentialStoreError("Keychain delete failed: status=\(status)")
            }
        }
        _ = SecItemDelete(deviceSearchQuery(deviceID: deviceID) as CFDictionary)
        var updated = index
        updated.records.removeAll { $0.deviceID == deviceID }
        try save(updated)
    }

    private func account(deviceID: String, partitionType: UInt32) -> String {
        "\(deviceID):\(partitionType)"
    }

    private func itemIdentity(deviceID: String, partitionType: UInt32) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: EDPCredentialStore.serviceName,
            kSecAttrAccount: account(deviceID: deviceID, partitionType: partitionType),
        ]
    }

    private func searchQuery(deviceID: String, partitionType: UInt32) -> [CFString: Any] {
        var query = itemIdentity(deviceID: deviceID, partitionType: partitionType)
        query[kSecMatchSearchList] = [keychain]
        return query
    }

    private func deviceSearchQuery(deviceID: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: EDPCredentialStore.deviceServiceName,
            kSecAttrAccount: deviceID,
            kSecMatchSearchList: [keychain],
        ]
    }

    private func upsertPassword(
        deviceID: String,
        partitionType: UInt32,
        password: [UInt8]
    ) throws {
        let query = searchQuery(deviceID: deviceID, partitionType: partitionType)
        let secret = Data(password)
        let access = try rootOnlyAccess()
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [
                kSecValueData: secret,
                kSecAttrAccess: access,
            ] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw EDPCredentialStoreError("Keychain update failed: status=\(updateStatus)")
        }

        var attributes = itemIdentity(deviceID: deviceID, partitionType: partitionType)
        attributes[kSecUseKeychain] = keychain
        attributes[kSecValueData] = secret
        attributes[kSecAttrAccess] = access
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw EDPCredentialStoreError("Keychain add failed: status=\(addStatus)")
        }
    }

    private func rootOnlyAccess() throws -> SecAccess {
        let ownerType = SecAccessOwnerType(kSecUseOnlyUID | kSecHonorRoot)
        guard let access = SecAccessCreateWithOwnerAndACL(0, 0, ownerType, nil, nil) else {
            throw EDPCredentialStoreError("failed to create root-only Keychain access policy")
        }
        return access
    }

    private func currentCredentialExists(deviceID: String, partitionType: UInt32) -> Bool {
        var query = searchQuery(deviceID: deviceID, partitionType: partitionType)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private func pruneRecordsWithoutCurrentCredentials() throws {
        var index = try load()
        let original = index.records
        index.records = index.records.compactMap { record in
            let available = record.partitionTypes.filter {
                currentCredentialExists(deviceID: record.deviceID, partitionType: $0)
            }
            guard !available.isEmpty else { return nil }
            return EDPCredentialRecord(
                deviceID: record.deviceID,
                partitionTypes: available,
                updatedAt: record.updatedAt
            )
        }
        if index.records != original || index.schemaVersion != 4 {
            index.schemaVersion = 4
            try save(index)
        }
    }

    private func migrateDeviceCredentialsToPartitions() throws {
        guard FileManager.default.fileExists(atPath: indexPath) else { return }
        var index = try load()
        guard index.schemaVersion < 4 else { return }
        for record in index.records {
            var legacyQuery = deviceSearchQuery(deviceID: record.deviceID)
            legacyQuery[kSecReturnData] = true
            legacyQuery[kSecMatchLimit] = kSecMatchLimitOne
            var result: CFTypeRef?
            guard SecItemCopyMatching(legacyQuery as CFDictionary, &result) == errSecSuccess,
                  let secret = result as? Data else {
                continue
            }
            var password = [UInt8](secret)
            defer { credentialSecureZero(&password) }
            for partitionType in record.partitionTypes where [UInt32(2), 4].contains(partitionType) {
                try upsertPassword(
                    deviceID: record.deviceID,
                    partitionType: partitionType,
                    password: password
                )
            }
            _ = SecItemDelete(deviceSearchQuery(deviceID: record.deviceID) as CFDictionary)
        }
        index.schemaVersion = 4
        try save(index)
    }

    private func save(_ index: EDPCredentialIndex) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try credentialAtomicWrite(try encoder.encode(index), to: indexPath, mode: 0o600)
    }

    private func migrateLegacyStore(credentialPath: String, masterKeyPath: String) throws {
        let keyData = try Data(contentsOf: URL(fileURLWithPath: masterKeyPath))
        guard keyData.count == 32 else {
            throw EDPCredentialStoreError("legacy credential master key has invalid length")
        }
        let legacy = try JSONDecoder().decode(
            LegacyCredentialFile.self,
            from: Data(contentsOf: URL(fileURLWithPath: credentialPath))
        )
        let key = SymmetricKey(data: keyData)
        var migrated = EDPCredentialIndex()

        for record in legacy.records {
            guard let combined = Data(base64Encoded: record.sealedPassword),
                  let box = try? AES.GCM.SealedBox(combined: combined) else {
                throw EDPCredentialStoreError("invalid legacy credential for \(record.deviceID)")
            }
            let clear = try AES.GCM.open(
                box,
                using: key,
                authenticating: Data(record.deviceID.utf8)
            )
            var password = [UInt8](clear)
            defer { credentialSecureZero(&password) }
            for partitionType in record.partitionTypes where [UInt32(2), 4].contains(partitionType) {
                try upsertPassword(
                    deviceID: record.deviceID,
                    partitionType: partitionType,
                    password: password
                )
            }
            migrated.records.append(EDPCredentialRecord(
                deviceID: record.deviceID,
                partitionTypes: record.partitionTypes.sorted(),
                updatedAt: record.updatedAt
            ))
        }
        migrated.schemaVersion = 4
        migrated.records.sort { $0.deviceID < $1.deviceID }
        try save(migrated)
        try FileManager.default.removeItem(atPath: credentialPath)
        try FileManager.default.removeItem(atPath: masterKeyPath)
    }
}

private func credentialSecureZero<T>(_ bytes: inout [T]) {
    bytes.withUnsafeMutableBytes { raw in
        if let base = raw.baseAddress { memset_s(base, raw.count, 0, raw.count) }
    }
}

private func credentialAtomicWrite(_ data: Data, to path: String, mode: mode_t) throws {
    let temporary = path + ".tmp.\(getpid())"
    try data.write(to: URL(fileURLWithPath: temporary), options: .withoutOverwriting)
    guard chmod(temporary, mode) == 0 else {
        let saved = errno
        try? FileManager.default.removeItem(atPath: temporary)
        throw EDPCredentialStoreError("chmod failed for credential index: errno=\(saved)")
    }
    if rename(temporary, path) != 0 {
        let saved = errno
        try? FileManager.default.removeItem(atPath: temporary)
        throw EDPCredentialStoreError("credential index atomic rename failed: errno=\(saved)")
    }
}
