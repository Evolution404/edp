import Foundation
import Security

private let edpTrustedAppIdentifier = "com.edp.usbvault.app"
private let edpTrustedAppExecutable = "/Applications/EDP USB Vault.app/Contents/MacOS/EDP USB Vault"

enum EDPXPCPeerValidator {
    private static func ownTeamIdentifier() -> String? {
        var ownCode: SecCode?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode else { return nil }
        var ownStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(ownCode, [], &ownStaticCode) == errSecSuccess,
              let ownStaticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            ownStaticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let values = information as? [CFString: Any] else {
            return nil
        }
        return values[kSecCodeInfoTeamIdentifier] as? String
    }

    static func isTrusted(_ connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier
        guard pid > 0 else { return false }

        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else {
            return false
        }
        guard SecCodeCheckValidity(code, [], nil) == errSecSuccess else {
            return false
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return false
        }
        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo) == errSecSuccess,
              let info = signingInfo as? [CFString: Any],
              info[kSecCodeInfoIdentifier] as? String == edpTrustedAppIdentifier,
              let peerTeam = info[kSecCodeInfoTeamIdentifier] as? String,
              let ownTeam = ownTeamIdentifier(),
              peerTeam == ownTeam,
              let executableURL = info[kSecCodeInfoMainExecutable] as? URL else {
            return false
        }

        let actualPath = executableURL.resolvingSymlinksInPath().standardizedFileURL.path
        let expectedPath = URL(fileURLWithPath: edpTrustedAppExecutable)
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard actualPath == expectedPath else { return false }

        var status = stat()
        guard stat(edpTrustedAppExecutable, &status) == 0 else { return false }
        guard status.st_uid == 0, (status.st_mode & mode_t(S_IWGRP | S_IWOTH)) == 0 else {
            return false
        }
        return true
    }
}
