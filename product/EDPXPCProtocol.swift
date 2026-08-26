import Foundation

let edpVaultMachServiceName = "com.edp.usbvault.xpc"

struct EDPXPCDevice: Codable, Hashable, Sendable, Identifiable {
    var id: String { deviceID }
    let deviceID: String
    let bsdName: String
    let mediaName: String
    let vidPID: String
    let sizeBytes: UInt64
    let authorized: Bool
    let mounted: Bool
    let partitionTypes: [UInt32]
}

struct EDPXPCSnapshot: Codable, Sendable {
    let devices: [EDPXPCDevice]
    let serviceVersion: String
    let timestamp: String
}

@objc protocol EDPVaultXPCProtocol {
    func snapshot(withReply reply: @escaping (Data) -> Void)
    func authorize(deviceID: String, password: Data, withReply reply: @escaping (String?) -> Void)
    func revoke(deviceID: String, withReply reply: @escaping (String?) -> Void)
    func eject(deviceID: String, withReply reply: @escaping (String?) -> Void)
    func diagnostics(withReply reply: @escaping (Data) -> Void)
}
