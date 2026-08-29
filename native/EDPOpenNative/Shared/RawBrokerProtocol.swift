import Foundation

enum RawBrokerConstants {
    static let machServiceName = "com.evolution404.edpopen.rawbroker"
    static let helperIdentifier = "com.evolution404.edpopen.rawbroker"
    static let appIdentifier = "com.evolution404.edpopen"
    static let signingCertificateRootSHA1 = "fda987d4d26950461a1f1810b3a66eb8bf8724c3"

    static let appCodeSigningRequirement = "identifier \"\(appIdentifier)\" and certificate root = H\"\(signingCertificateRootSHA1)\""
    static let brokerCodeSigningRequirement = "identifier \"\(helperIdentifier)\" and certificate root = H\"\(signingCertificateRootSHA1)\""
}

@objc protocol EDPRawBrokerProtocol {
    func ping(withReply reply: @escaping (String) -> Void)
    func listUSBDisks(withReply reply: @escaping (String) -> Void)
    func probeReadAccess(_ diskNumber: UInt32, withReply reply: @escaping (String) -> Void)
}
