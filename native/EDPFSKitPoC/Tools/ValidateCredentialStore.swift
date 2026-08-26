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
        defer { _ = SecKeychainDelete(keychain) }

        let store = try EDPCredentialStore(
            indexPath: indexURL.path,
            keychainPath: keychainURL.path
        )
        let deviceID = "21c4-0cd1-test-device"
        let secret = Array("correct horse battery staple".utf8)
        try store.put(deviceID: deviceID, password: secret, partitionTypes: [4, 2])

        let index = try store.load()
        guard index.schemaVersion == 2,
              index.records.count == 1,
              index.records[0].deviceID == deviceID,
              index.records[0].partitionTypes == [2, 4] else {
            throw EDPCredentialStoreError("credential index round-trip mismatch")
        }
        let loaded = try store.password(for: index.records[0])
        guard loaded == secret else {
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
        do {
            _ = try store.password(for: EDPCredentialRecord(
                deviceID: deviceID,
                partitionTypes: [2, 4],
                updatedAt: "test"
            ))
            throw EDPCredentialStoreError("revoked Keychain password remained readable")
        } catch let error as EDPCredentialStoreError {
            guard error.message.contains("Keychain password unavailable") else { throw error }
        }
        print("RESULT=KEYCHAIN_REVOKE_OK")
        print("RESULT=KEYCHAIN_CREDENTIAL_STORE_E2E_OK")
    }
}
