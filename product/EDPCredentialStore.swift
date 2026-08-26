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
    var schemaVersion = 2
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
    static let serviceName = "com.edp.usbvault.device-password"

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

    func password(for record: EDPCredentialRecord) throws -> [UInt8] {
        var query = searchQuery(deviceID: record.deviceID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw EDPCredentialStoreError(
                "Keychain password unavailable for \(record.deviceID): status=\(status)"
            )
        }
        return [UInt8](data)
    }

    func put(deviceID: String, password: [UInt8], partitionTypes: [UInt32]) throws {
        try upsertPassword(deviceID: deviceID, password: password)
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

    func remove(deviceID: String) throws {
        let query = searchQuery(deviceID: deviceID)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw EDPCredentialStoreError("Keychain delete failed: status=\(status)")
        }
        var index = try load()
        index.records.removeAll { $0.deviceID == deviceID }
        try save(index)
    }

    private func itemIdentity(deviceID: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.serviceName,
            kSecAttrAccount: deviceID,
        ]
    }

    private func searchQuery(deviceID: String) -> [CFString: Any] {
        var query = itemIdentity(deviceID: deviceID)
        query[kSecMatchSearchList] = [keychain]
        return query
    }

    private func upsertPassword(deviceID: String, password: [UInt8]) throws {
        let query = searchQuery(deviceID: deviceID)
        let secret = Data(password)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData: secret] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw EDPCredentialStoreError("Keychain update failed: status=\(updateStatus)")
        }

        var attributes = itemIdentity(deviceID: deviceID)
        attributes[kSecUseKeychain] = keychain
        attributes[kSecValueData] = secret
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw EDPCredentialStoreError("Keychain add failed: status=\(addStatus)")
        }
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
            try upsertPassword(deviceID: record.deviceID, password: password)
            migrated.records.append(EDPCredentialRecord(
                deviceID: record.deviceID,
                partitionTypes: record.partitionTypes.sorted(),
                updatedAt: record.updatedAt
            ))
        }
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
