import Foundation
import Security

@main
enum ValidateCredentialStore {
    static func main() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edp-keychain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let keychainURL = root.appendingPathComponent("test.keychain-db")
        let indexURL = root.appendingPathComponent("credential-index.json")
        let keychainPassword = Data("edp-ci-keychain-password".utf8)
        var keychain: SecKeychain?
        let createStatus = keychainPassword.withUnsafeBytes { raw in
            SecKeychainCreate(
                keychainURL.path,
                UInt32(raw.count),
                raw.baseAddress,
                false,
                nil,
                &keychain
            )
        }
        guard createStatus == errSecSuccess, let keychain else {
            throw EDPCredentialStoreError("test keychain create failed: status=\(createStatus)")
        }
        let unlockStatus = keychainPassword.withUnsafeBytes { raw in
            SecKeychainUnlock(
                keychain,
                UInt32(raw.count),
                raw.baseAddress,
                true
            )
        }
        guard unlockStatus == errSecSuccess else {
            throw EDPCredentialStoreError("test keychain unlock failed: status=\(unlockStatus)")
        }
        defer { _ = SecKeychainDelete(keychain) }

        let store = try EDPCredentialStore(
            indexPath: indexURL.path,
            keychainPath: keychainURL.path,
            restrictToRoot: false
        )
        let deviceID = "21c4-0cd1-test-device"
        let secret = Array("correct horse battery staple".utf8)
        try store.put(deviceID: deviceID, password: secret, partitionTypes: [4, 2])

        let index = try store.load()
        guard index.schemaVersion == 5,
              index.records.count == 1,
              index.records[0].deviceID == deviceID,
              index.records[0].partitionTypes == [2, 4] else {
            throw EDPCredentialStoreError("credential index round-trip mismatch")
        }
        let loadedExchange = try store.password(deviceID: deviceID, partitionType: 2)
        let loadedSecure = try store.password(deviceID: deviceID, partitionType: 4)
        guard loadedExchange == secret, loadedSecure == secret else {
            throw EDPCredentialStoreError("Keychain password round-trip mismatch")
        }

        let indexData = try Data(contentsOf: indexURL)
        let indexText = String(decoding: indexData, as: UTF8.self)
        guard !indexText.contains(String(decoding: secret, as: UTF8.self)),
              !indexText.contains(Data(secret).base64EncodedString()) else {
            throw EDPCredentialStoreError("credential index leaked password material")
        }
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("master.key").path) else {
            throw EDPCredentialStoreError("self-managed master.key unexpectedly created")
        }
        print("RESULT=KEYCHAIN_PASSWORD_ROUNDTRIP_OK")
        print("RESULT=CREDENTIAL_INDEX_CONTAINS_NO_SECRET_OK")
        print("RESULT=SELF_MANAGED_MASTER_KEY_ABSENT_OK")

        try store.remove(deviceID: deviceID)
        guard try store.load().records.isEmpty else {
            throw EDPCredentialStoreError("credential index revoke failed")
        }
        for partitionType in [UInt32(2), 4] {
            do {
                _ = try store.password(deviceID: deviceID, partitionType: partitionType)
                throw EDPCredentialStoreError("revoked Keychain password remained readable")
            } catch let error as EDPCredentialStoreError {
                guard error.message.contains("Keychain password unavailable") else { throw error }
            }
        }
        print("RESULT=KEYCHAIN_REVOKE_OK")

        let legacyDeviceID = "21c4-0cd1-legacy-device"
        let legacyDeviceWideID = "21c4-0cd1-legacy-device-wide"
        let legacySecret = Data("legacy namespace secret".utf8)
        let legacyIndex = """
        {"schemaVersion":4,"records":[{"deviceID":"\(legacyDeviceID)","partitionTypes":[2,4],"updatedAt":"2026-08-29T00:00:00Z"},{"deviceID":"\(legacyDeviceWideID)","partitionTypes":[2,4],"updatedAt":"2026-08-29T00:00:00Z"}]}
        """
        try Data(legacyIndex.utf8).write(to: indexURL, options: .atomic)
        for partitionType in [UInt32(2), 4] {
            let status = SecItemAdd([
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: EDPCredentialStore.legacyPartitionServiceName,
                kSecAttrAccount: "\(legacyDeviceID):\(partitionType)",
                kSecUseKeychain: keychain,
                kSecValueData: legacySecret,
            ] as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw EDPCredentialStoreError("legacy fixture add failed: status=\(status)")
            }
        }
        let legacyDeviceStatus = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: EDPCredentialStore.legacyDeviceServiceName,
            kSecAttrAccount: legacyDeviceWideID,
            kSecUseKeychain: keychain,
            kSecValueData: legacySecret,
        ] as CFDictionary, nil)
        guard legacyDeviceStatus == errSecSuccess else {
            throw EDPCredentialStoreError(
                "legacy device fixture add failed: status=\(legacyDeviceStatus)"
            )
        }

        let migratedStore = try EDPCredentialStore(
            indexPath: indexURL.path,
            keychainPath: keychainURL.path,
            restrictToRoot: false
        )
        for partitionType in [UInt32(2), 4] {
            guard try migratedStore.password(
                deviceID: legacyDeviceID,
                partitionType: partitionType
            ) == [UInt8](legacySecret) else {
                throw EDPCredentialStoreError("migrated credential mismatch")
            }
            let legacyStatus = SecItemCopyMatching([
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: EDPCredentialStore.legacyPartitionServiceName,
                kSecAttrAccount: "\(legacyDeviceID):\(partitionType)",
                kSecMatchSearchList: [keychain],
            ] as CFDictionary, nil)
            guard legacyStatus == errSecItemNotFound else {
                throw EDPCredentialStoreError("verified legacy credential was not deleted")
            }
        }
        for partitionType in [UInt32(2), 4] {
            guard try migratedStore.password(
                deviceID: legacyDeviceWideID,
                partitionType: partitionType
            ) == [UInt8](legacySecret) else {
                throw EDPCredentialStoreError("device-wide migrated credential mismatch")
            }
        }
        let legacyDeviceRemaining = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: EDPCredentialStore.legacyDeviceServiceName,
            kSecAttrAccount: legacyDeviceWideID,
            kSecMatchSearchList: [keychain],
        ] as CFDictionary, nil)
        guard legacyDeviceRemaining == errSecItemNotFound else {
            throw EDPCredentialStoreError("verified device-wide credential was not deleted")
        }
        guard try migratedStore.load().schemaVersion == 5 else {
            throw EDPCredentialStoreError("credential namespace migration schema mismatch")
        }
        print("RESULT=KEYCHAIN_NAMESPACE_MIGRATION_ATOMIC_OK")
        print("RESULT=KEYCHAIN_CREDENTIAL_STORE_E2E_OK")
    }
}
