import Foundation

enum RawBrokerConstants {
    static let machServiceName = "com.evolution404.edpopen.rawbroker"
    static let helperIdentifier = "com.evolution404.edpopen.rawbroker"
    static let appIdentifier = "com.evolution404.edpopen"
    static let signingCertificateLeafSHA1 = "040b5488fb2b6c02b0786e76b674cb4460658ca2"
    static let signingCertificateRootSHA1 = signingCertificateLeafSHA1
    static let appExecutablePath = "/Applications/EDPOpen.app/Contents/MacOS/EDPOpen"
    static let brokerExecutablePath = "/Library/PrivilegedHelperTools/com.evolution404.edpopen.rawbroker"

    static let appCodeSigningRequirement = "identifier \"\(appIdentifier)\" and certificate leaf = H\"\(signingCertificateLeafSHA1)\""
    static let brokerCodeSigningRequirement = "identifier \"\(helperIdentifier)\" and certificate leaf = H\"\(signingCertificateLeafSHA1)\""
}

@objc protocol EDPRawBrokerProtocol {
    func ping(withReply reply: @escaping (String) -> Void)
    func listUSBDisks(withReply reply: @escaping (String) -> Void)
    func probeReadAccess(_ diskNumber: UInt32, withReply reply: @escaping (String) -> Void)
}
