import Foundation
import Darwin

private struct BrokerReply: Codable {
    let ok: Bool
    let message: String
    let diskNumber: UInt32?
    let euid: UInt32
    let helperIdentifier: String
}

final class RawBrokerService: NSObject, EDPRawBrokerProtocol {
    func ping(withReply reply: @escaping (String) -> Void) {
        reply(encode(BrokerReply(
            ok: true,
            message: "raw-broker-ready",
            diskNumber: nil,
            euid: geteuid(),
            helperIdentifier: RawBrokerConstants.helperIdentifier
        )))
    }

    func probeReadAccess(_ diskNumber: UInt32, withReply reply: @escaping (String) -> Void) {
        do {
            let disk = try RawDiskValidator.validate(diskNumber)
            let fd = Darwin.open(disk.rawPath, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else {
                let code = errno
                throw RawDiskValidationError.rejected(
                    "open(\(disk.rawPath), O_RDONLY) 失败 errno=\(code) \(String(cString: strerror(code)))"
                )
            }
            defer { Darwin.close(fd) }

            var st = stat()
            guard fstat(fd, &st) == 0 else {
                let code = errno
                throw RawDiskValidationError.rejected(
                    "fstat 失败 errno=\(code) \(String(cString: strerror(code)))"
                )
            }
            guard (st.st_mode & S_IFMT) == S_IFCHR else {
                throw RawDiskValidationError.rejected("raw fd 不是字符设备")
            }

            reply(encode(BrokerReply(
                ok: true,
                message: "FDA raw read probe OK · whole/external/USB/IOKit verified · open/fstat/close only",
                diskNumber: diskNumber,
                euid: geteuid(),
                helperIdentifier: RawBrokerConstants.helperIdentifier
            )))
        } catch {
            reply(encode(BrokerReply(
                ok: false,
                message: error.localizedDescription,
                diskNumber: diskNumber,
                euid: geteuid(),
                helperIdentifier: RawBrokerConstants.helperIdentifier
            )))
        }
    }

    private func encode(_ value: BrokerReply) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"message":"JSON encode failed"}"#
        }
        return text
    }
}

final class RawBrokerListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The privileged daemon never trusts caller-supplied paths. It additionally binds
        // every XPC message to the signed EDPOpen GUI identity from the same Apple team.
        connection.setCodeSigningRequirement(RawBrokerConstants.appCodeSigningRequirement)
        connection.exportedInterface = NSXPCInterface(with: EDPRawBrokerProtocol.self)
        connection.exportedObject = RawBrokerService()
        connection.resume()
        return true
    }
}
