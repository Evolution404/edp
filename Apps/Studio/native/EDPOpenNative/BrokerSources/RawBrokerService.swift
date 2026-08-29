import Foundation
import Darwin

private struct BrokerReply: Codable {
    let ok: Bool
    let message: String
    let diskNumber: UInt32?
    let euid: UInt32
    let helperIdentifier: String
}

private struct BrokerDiskRecord: Codable {
    let diskNumber: UInt32
    let sizeBytes: UInt64
    let vendor: String
    let model: String
}

private struct BrokerDiskListReply: Codable {
    let ok: Bool
    let message: String
    let disks: [BrokerDiskRecord]
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

    func listUSBDisks(withReply reply: @escaping (String) -> Void) {
        let disks = RawDiskValidator.enumerateExternalUSBWholeDisks().map {
            BrokerDiskRecord(
                diskNumber: $0.diskNumber,
                sizeBytes: $0.sizeBytes,
                vendor: $0.vendor,
                model: $0.model
            )
        }
        reply(encode(BrokerDiskListReply(
            ok: true,
            message: "\(disks.count) external physical USB whole disk(s)",
            disks: disks,
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

    private func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"message":"JSON encode failed"}"#
        }
        return text
    }
}

enum RawBrokerProcessSecurity {
    static func validateBrokerStartup() -> String? {
        guard geteuid() == 0 else {
            return "raw broker must run as root"
        }
        guard executablePath(pid: getpid()) == RawBrokerConstants.brokerExecutablePath else {
            return "raw broker is not running from its fixed privileged helper path"
        }
        guard secureRegularFile(at: RawBrokerConstants.brokerExecutablePath, requireRootOwner: true) else {
            return "raw broker executable must be root-owned and not group/world writable"
        }
        return nil
    }

    static func validateAppConnection(_ connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier
        guard pid > 1 else { return false }
        guard executablePath(pid: pid) == RawBrokerConstants.appExecutablePath else { return false }
        guard secureRegularFile(at: RawBrokerConstants.appExecutablePath, requireRootOwner: false) else { return false }
        return true
    }

    private static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let pathBytes = buffer.prefix(Int(length)).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: pathBytes, as: UTF8.self)
    }

    private static func secureRegularFile(at path: String, requireRootOwner: Bool) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return false }
        if requireRootOwner && st.st_uid != 0 { return false }
        return (st.st_mode & (S_IWGRP | S_IWOTH)) == 0
    }
}

final class RawBrokerListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // First bind the peer to the one installed EDPOpen executable path, then require
        // the fixed GUI identifier and the exact leaf certificate shared by both EDP apps.
        guard RawBrokerProcessSecurity.validateAppConnection(connection) else { return false }
        connection.setCodeSigningRequirement(RawBrokerConstants.appCodeSigningRequirement)
        connection.exportedInterface = NSXPCInterface(with: EDPRawBrokerProtocol.self)
        connection.exportedObject = RawBrokerService()
        connection.resume()
        return true
    }
}
