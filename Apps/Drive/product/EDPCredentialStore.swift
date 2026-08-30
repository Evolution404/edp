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
    var schemaVersion = 5
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
    static let serviceName = "com.edp.drive.partition-password.v1"
    static let legacyPartitionServiceName = "com.edp.usbvault.partition-password.v4"
    static let legacyDeviceServiceName = "com.edp.usbvault.device-password.v3"
    static let legacyServiceName = "com.edp.usbvault.device-password"

    private let indexPath: String
    private let keychain: SecKeychain
    private let restrictToRoot: Bool

    init(
        indexPath: String,
        keychainPath: String = "/Library/Keychains/System.keychain",
        restrictToRoot: Bool = true,
        legacyCredentialPath: String? = nil,
        legacyMasterKeyPath: String? = nil
    ) throws {
        self.indexPath = indexPath
        self.restrictToRoot = restrictToRoot
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

        try migrateLegacyKeychainNamespace()
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
        try deleteItem(
            service: EDPCredentialStore.legacyDeviceServiceName,
            account: deviceID
        )
        try deleteItem(
            service: EDPCredentialStore.legacyServiceName,
            account: deviceID
        )
        var updated = index
        updated.records.removeAll { $0.deviceID == deviceID }
        try save(updated)
    }

    private func account(deviceID: String, partitionType: UInt32) -> String {
        "\(deviceID):\(partitionType)"
    }

    private func itemIdentity(
        service: String = EDPCredentialStore.serviceName,
        account: String
    ) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }

    private func searchQuery(
        service: String = EDPCredentialStore.serviceName,
        account: String
    ) -> [CFString: Any] {
        var query = itemIdentity(service: service, account: account)
        query[kSecMatchSearchList] = [keychain]
        return query
    }

    private func searchQuery(deviceID: String, partitionType: UInt32) -> [CFString: Any] {
        searchQuery(account: account(deviceID: deviceID, partitionType: partitionType))
    }

    private func passwordIfPresent(service: String, account: String) throws -> [UInt8]? {
        var query = searchQuery(service: service, account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw EDPCredentialStoreError("Keychain read failed: status=\(status)")
        }
        return [UInt8](data)
    }

    private func deleteItem(service: String, account: String) throws {
        let status = SecItemDelete(
            searchQuery(service: service, account: account) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw EDPCredentialStoreError("Keychain delete failed: status=\(status)")
        }
    }

    private func upsertPassword(
        deviceID: String,
        partitionType: UInt32,
        password: [UInt8]
    ) throws {
        let query = searchQuery(deviceID: deviceID, partitionType: partitionType)
        let secret = Data(password)
        let access = try restrictToRoot ? rootOnlyAccess() : nil
        var updates: [CFString: Any] = [kSecValueData: secret]
        if let access { updates[kSecAttrAccess] = access }
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            updates as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw EDPCredentialStoreError("Keychain update failed: status=\(updateStatus)")
        }

        var attributes = itemIdentity(
            account: account(deviceID: deviceID, partitionType: partitionType)
        )
        attributes[kSecUseKeychain] = keychain
        attributes[kSecValueData] = secret
        if let access { attributes[kSecAttrAccess] = access }
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
        if index.records != original || index.schemaVersion != 5 {
            index.schemaVersion = 5
            try save(index)
        }
    }

    private func migrateLegacyKeychainNamespace() throws {
        guard FileManager.default.fileExists(atPath: indexPath) else { return }
        var index = try load()
        for record in index.records {
            let partitionTypes = record.partitionTypes.filter {
                [UInt32(2), 4].contains($0)
            }

            // Migrate the two historical device-wide services oldest to newest.
            // Each source is verified across every indexed partition before the
            // source item is deleted.  The newer partition service is applied
            // afterward and may intentionally override these values.
            for legacyService in [
                EDPCredentialStore.legacyServiceName,
                EDPCredentialStore.legacyDeviceServiceName,
            ] {
                guard var secret = try passwordIfPresent(
                    service: legacyService,
                    account: record.deviceID
                ) else { continue }
                defer { credentialSecureZero(&secret) }
                for partitionType in partitionTypes {
                    try upsertPassword(
                        deviceID: record.deviceID,
                        partitionType: partitionType,
                        password: secret
                    )
                    var verified = try password(
                        deviceID: record.deviceID,
                        partitionType: partitionType
                    )
                    defer { credentialSecureZero(&verified) }
                    guard verified == secret else {
                        throw EDPCredentialStoreError(
                            "Keychain migration verification failed for \(record.deviceID) partition \(partitionType)"
                        )
                    }
                }
                try deleteItem(service: legacyService, account: record.deviceID)
            }

            for partitionType in partitionTypes {
                let partitionAccount = account(
                    deviceID: record.deviceID,
                    partitionType: partitionType
                )
                guard var secret = try passwordIfPresent(
                    service: EDPCredentialStore.legacyPartitionServiceName,
                    account: partitionAccount
                ) else { continue }
                defer { credentialSecureZero(&secret) }
                try upsertPassword(
                    deviceID: record.deviceID,
                    partitionType: partitionType,
                    password: secret
                )
                var verified = try password(
                    deviceID: record.deviceID,
                    partitionType: partitionType
                )
                defer { credentialSecureZero(&verified) }
                guard verified == secret else {
                    throw EDPCredentialStoreError(
                        "Keychain migration verification failed for \(record.deviceID) partition \(partitionType)"
                    )
                }
                try deleteItem(
                    service: EDPCredentialStore.legacyPartitionServiceName,
                    account: partitionAccount
                )
            }
        }
        index.schemaVersion = 5
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
        migrated.schemaVersion = 5
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
