import Foundation

enum RawBrokerConstants {
    static let machServiceName = "com.edp.studio.rawbroker"
    static let helperIdentifier = "com.edp.studio.rawbroker"
    static let appIdentifier = "com.edp.studio"
    static let signingCertificateLeafSHA1 = "040b5488fb2b6c02b0786e76b674cb4460658ca2"
    static let signingCertificateRootSHA1 = signingCertificateLeafSHA1
    static let appExecutablePath = "/Applications/EDP Studio.app/Contents/MacOS/EDP Studio"
    static let brokerExecutablePath = "/Library/PrivilegedHelperTools/com.edp.studio.rawbroker"

    static let appCodeSigningRequirement = "identifier \"\(appIdentifier)\" and certificate leaf = H\"\(signingCertificateLeafSHA1)\""
    static let brokerCodeSigningRequirement = "identifier \"\(helperIdentifier)\" and certificate leaf = H\"\(signingCertificateLeafSHA1)\""
}

@objc protocol EDPRawBrokerProtocol {
    func ping(withReply reply: @escaping (String) -> Void)
    func listUSBDisks(withReply reply: @escaping (String) -> Void)
    func probeReadAccess(_ diskNumber: UInt32, withReply reply: @escaping (String) -> Void)
}
