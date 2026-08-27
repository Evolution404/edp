import Foundation
import Security

private let edpTrustedAppIdentifier = "com.edp.usbvault.app"
private let edpTrustedAppExecutable = "/Applications/EDP USB Vault.app/Contents/MacOS/EDP USB Vault"

enum EDPXPCPeerValidator {
    private struct SigningAuthority {
        let teamIdentifier: String?
        let leafCertificate: Data?
    }

    private static func signingAuthority(
        from information: [CFString: Any]
    ) -> SigningAuthority {
        let certificates = information[kSecCodeInfoCertificates] as? [SecCertificate]
        let leafCertificate = certificates?.first.map {
            SecCertificateCopyData($0) as Data
        }
        return SigningAuthority(
            teamIdentifier: information[kSecCodeInfoTeamIdentifier] as? String,
            leafCertificate: leafCertificate
        )
    }

    private static func ownSigningAuthority() -> SigningAuthority? {
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
        return signingAuthority(from: values)
    }

    private static func matchesSigningAuthority(
        peer: SigningAuthority,
        own: SigningAuthority
    ) -> Bool {
        switch (peer.teamIdentifier, own.teamIdentifier) {
        case let (peerTeam?, ownTeam?):
            return peerTeam == ownTeam
        case (nil, nil):
            guard let peerCertificate = peer.leafCertificate,
                  let ownCertificate = own.leafCertificate else {
                // Ad-hoc signatures have neither a TeamIdentifier nor a leaf
                // signing certificate. They are intentionally insufficient for
                // privileged XPC authentication.
                return false
            }
            // Non-Apple development/CI identities do not receive an Apple Team
            // ID. Requiring the exact same leaf certificate retains a concrete
            // signer boundary instead of weakening this path to arbitrary code.
            return peerCertificate == ownCertificate
        default:
            return false
        }
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
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInfo
        ) == errSecSuccess,
        let info = signingInfo as? [CFString: Any],
        info[kSecCodeInfoIdentifier] as? String == edpTrustedAppIdentifier,
        let executableURL = info[kSecCodeInfoMainExecutable] as? URL,
        let ownAuthority = ownSigningAuthority(),
        matchesSigningAuthority(
            peer: signingAuthority(from: info),
            own: ownAuthority
        ) else {
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
