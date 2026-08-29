import Foundation

enum RawBrokerConstants {
    static let machServiceName = "com.evolution404.edpopen.rawbroker"
    static let helperIdentifier = "com.evolution404.edpopen.rawbroker"
    static let appIdentifier = "com.evolution404.edpopen"
    static let teamIdentifier = "W82WPH8HY7"

    static let appCodeSigningRequirement = "identifier \"\(appIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    static let brokerCodeSigningRequirement = "identifier \"\(helperIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
}

@objc protocol EDPRawBrokerProtocol {
    func ping(withReply reply: @escaping (String) -> Void)
    func probeReadAccess(_ diskNumber: UInt32, withReply reply: @escaping (String) -> Void)
}
