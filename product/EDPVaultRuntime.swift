import CryptoKit
import Darwin
import Foundation
import Security

private let productRoot = "/Library/Application Support/EDP USB Vault"
private let dataRoot = "/var/db/com.edp.usbvault"
private let sessionRoot = dataRoot + "/sessions"
private let credentialPath = dataRoot + "/credentials.json"
private let masterKeyPath = dataRoot + "/master.key"
private let launchdLabel = "com.edp.usbvault.mountd"

private enum RuntimeError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let value): return value
        }
    }
}

private func fail(_ message: String) -> RuntimeError { .message(message) }

private func secureZero<T>(_ bytes: inout [T]) {
    bytes.withUnsafeMutableBytes { raw in
        if let base = raw.baseAddress { memset_s(base, raw.count, 0, raw.count) }
    }
}

private struct CommandResult {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

@discardableResult
private func run(
    _ executable: String,
    _ arguments: [String] = [],
    environment: [String: String]? = nil,
    accepted: Set<Int32> = [0]
) throws -> CommandResult {
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = errors
    if let environment { process.environment = environment }
    try process.run()
    // Drain output while the child is running. `ioreg -a` can exceed the pipe
    // buffer on machines with many USB devices.
    let stdout = output.fileHandleForReading.readDataToEndOfFile()
    let stderr = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let result = CommandResult(
        status: process.terminationStatus,
        stdout: stdout,
        stderr: stderr
    )
    guard accepted.contains(result.status) else {
        throw fail(
            "command failed (\(result.status)): \(executable) "
                + arguments.joined(separator: " ") + "\n" + result.stderrText
        )
    }
    return result
}

private func plist(_ data: Data) throws -> [String: Any] {
    guard let value = try PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
    ) as? [String: Any] else {
        throw fail("command did not return a property-list dictionary")
    }
    return value
}

private func atomicWrite(_ data: Data, to path: String, mode: mode_t) throws {
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
    try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: mode_t(0o700))]
    )
    let temporary = path + ".tmp.\(getpid())"
    try data.write(to: URL(fileURLWithPath: temporary), options: .withoutOverwriting)
    guard chmod(temporary, mode) == 0 else {
        let saved = errno
        try? FileManager.default.removeItem(atPath: temporary)
        throw fail("chmod failed for \(temporary): errno=\(saved)")
    }
    if rename(temporary, path) != 0 {
        let saved = errno
        try? FileManager.default.removeItem(atPath: temporary)
        throw fail("atomic rename failed for \(path): errno=\(saved)")
    }
}

private struct PhysicalDisk {
    let bsdName: String
    let rawPath: String
    let sizeBytes: UInt64
    let mediaName: String
    let vidHex: String
    let pidHex: String
    let deviceID: String
}

private func integerValue(_ value: Any?) -> UInt64? {
    if let number = value as? NSNumber { return number.uint64Value }
    if let data = value as? Data {
        var answer: UInt64 = 0
        for (index, byte) in data.prefix(8).enumerated() {
            answer |= UInt64(byte) << UInt64(index * 8)
        }
        return answer
    }
    if let text = value as? String {
        let cleaned = text.lowercased().hasPrefix("0x") ? String(text.dropFirst(2)) : text
        return UInt64(cleaned, radix: 16) ?? UInt64(text)
    }
    return nil
}

private func children(_ node: [String: Any]) -> [[String: Any]] {
    node["IORegistryEntryChildren"] as? [[String: Any]] ?? []
}

private func descendant(_ node: [String: Any], containsBSD bsd: String) -> Bool {
    for key in ["BSD Name", "BSDName", "IOBSDName"] {
        if node[key] as? String == bsd { return true }
    }
    return children(node).contains { descendant($0, containsBSD: bsd) }
}

private func usbIdentity(
    roots: [[String: Any]],
    bsd: String,
    deviceTreePath: String
) -> (String, String)? {
    func byDescendant(
        _ node: [String: Any],
        inheritedVID: UInt64?,
        inheritedPID: UInt64?
    ) -> (UInt64, UInt64)? {
        let vid = integerValue(node["idVendor"]) ?? inheritedVID
        let pid = integerValue(node["idProduct"]) ?? inheritedPID
        if let vid, let pid, descendant(node, containsBSD: bsd) { return (vid, pid) }
        for child in children(node) {
            if let answer = byDescendant(child, inheritedVID: vid, inheritedPID: pid) {
                return answer
            }
        }
        return nil
    }

    let location = deviceTreePath.split(separator: "@").last.map(String.init)?.lowercased()
    func byLocation(_ node: [String: Any]) -> (UInt64, UInt64)? {
        if let location,
           (node["IORegistryEntryLocation"] as? String)?.lowercased() == location,
           let vid = integerValue(node["idVendor"]),
           let pid = integerValue(node["idProduct"]) {
            return (vid, pid)
        }
        for child in children(node) {
            if let answer = byLocation(child) { return answer }
        }
        return nil
    }

    for root in roots {
        if let answer = byDescendant(root, inheritedVID: nil, inheritedPID: nil) {
            return (String(format: "%04x", answer.0), String(format: "%04x", answer.1))
        }
    }
    for root in roots {
        if let answer = byLocation(root) {
            return (String(format: "%04x", answer.0), String(format: "%04x", answer.1))
        }
    }
    return nil
}

private func discoverEDPDisks() throws -> [PhysicalDisk] {
    let diskList = try plist(run("/usr/sbin/diskutil", ["list", "-plist"]).stdout)
    let usbValue = try PropertyListSerialization.propertyList(
        from: run("/usr/sbin/ioreg", ["-p", "IOUSB", "-l", "-w0", "-a"]).stdout,
        options: [],
        format: nil
    )
    let usbRoots = usbValue as? [[String: Any]]
        ?? (usbValue as? [String: Any]).map { [$0] }
        ?? []
    let entries = diskList["AllDisksAndPartitions"] as? [[String: Any]] ?? []
    var answer = [PhysicalDisk]()

    for entry in entries {
        guard let bsd = entry["DeviceIdentifier"] as? String,
              bsd.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else {
            continue
        }
        let info = try plist(run("/usr/sbin/diskutil", ["info", "-plist", "/dev/\(bsd)"]).stdout)
        guard (info["Whole"] as? Bool) == true || (info["WholeDisk"] as? Bool) == true,
              (info["Internal"] as? Bool) != true,
              (info["VirtualOrPhysical"] as? String) != "Virtual",
              let size = integerValue(info["DiskSize"] ?? info["TotalSize"] ?? info["Size"]),
              size > 0 else {
            continue
        }
        let rawPath = "/dev/r\(bsd)"
        guard FileManager.default.fileExists(atPath: rawPath) else { continue }
        let raw: EDPFileRawDevice
        do {
            raw = try EDPFileRawDevice(path: rawPath, declaredSizeBytes: size)
        } catch {
            continue
        }
        guard let lba4 = try? raw.readExact(
            at: EDPMetadataProbe.lba4ByteOffset,
            length: Int(EDPMetadataProbe.legacySectorByteLength)
        ),
        let lba7 = try? raw.readExact(
            at: EDPMetadataProbe.lba7ByteOffset,
            length: Int(EDPMetadataProbe.legacySectorByteLength)
        ),
        EDPMetadataProbe.recognizeReservedSectors(
            lba4: [UInt8](lba4),
            lba7: [UInt8](lba7)
        ) != nil else {
            continue
        }
        let treePath = info["DeviceTreePath"] as? String ?? ""
        guard let (vid, pid) = usbIdentity(
            roots: usbRoots,
            bsd: bsd,
            deviceTreePath: treePath
        ),
        let lba11 = try? raw.readExact(
            at: EDPVolumeMetadata.lba11ByteOffset,
            length: Int(EDPMetadataProbe.legacySectorByteLength)
        ),
        let deviceID = EDPVolumeMetadata.deviceIDFromLBA11(
            [UInt8](lba11),
            vidHex: vid,
            pidHex: pid,
            sizeBytes: size
        ) else {
            continue
        }
        answer.append(PhysicalDisk(
            bsdName: bsd,
            rawPath: rawPath,
            sizeBytes: size,
            mediaName: info["MediaName"] as? String ?? "EDP USB",
            vidHex: vid,
            pidHex: pid,
            deviceID: deviceID
        ))
    }
    return answer
}

private struct StoredCredential: Codable {
    let deviceID: String
    let sealedPassword: String
    let partitionTypes: [UInt32]
    let updatedAt: String
}

private struct CredentialFile: Codable {
    var schemaVersion = 1
    var records = [StoredCredential]()
}

private final class CredentialStore {
    private let key: SymmetricKey

    init() throws {
        try FileManager.default.createDirectory(
            atPath: dataRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: mode_t(0o700))]
        )
        guard chmod(dataRoot, 0o700) == 0 else {
            throw fail("failed to secure credential directory: errno=\(errno)")
        }
        if FileManager.default.fileExists(atPath: masterKeyPath) {
            let data = try Data(contentsOf: URL(fileURLWithPath: masterKeyPath))
            guard data.count == 32 else { throw fail("invalid credential master key") }
            key = SymmetricKey(data: data)
        } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw fail("failed to create credential master key")
            }
            let data = Data(bytes)
            try atomicWrite(data, to: masterKeyPath, mode: 0o600)
            key = SymmetricKey(data: data)
            secureZero(&bytes)
        }
    }

    func load() throws -> CredentialFile {
        guard FileManager.default.fileExists(atPath: credentialPath) else {
            return CredentialFile()
        }
        return try JSONDecoder().decode(
            CredentialFile.self,
            from: Data(contentsOf: URL(fileURLWithPath: credentialPath))
        )
    }

    func save(_ file: CredentialFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try atomicWrite(try encoder.encode(file), to: credentialPath, mode: 0o600)
    }

    func password(for record: StoredCredential) throws -> [UInt8] {
        guard let combined = Data(base64Encoded: record.sealedPassword),
              let box = try? AES.GCM.SealedBox(combined: combined) else {
            throw fail("invalid encrypted credential record for \(record.deviceID)")
        }
        let clear = try AES.GCM.open(
            box,
            using: key,
            authenticating: Data(record.deviceID.utf8)
        )
        return [UInt8](clear)
    }

    func put(deviceID: String, password: [UInt8], partitionTypes: [UInt32]) throws {
        let box = try AES.GCM.seal(
            Data(password),
            using: key,
            authenticating: Data(deviceID.utf8)
        )
        guard let combined = box.combined else { throw fail("credential encryption failed") }
        var file = try load()
        file.records.removeAll { $0.deviceID == deviceID }
        file.records.append(StoredCredential(
            deviceID: deviceID,
            sealedPassword: combined.base64EncodedString(),
            partitionTypes: partitionTypes.sorted(),
            updatedAt: ISO8601DateFormatter().string(from: Date())
        ))
        try save(file)
    }

    func remove(deviceID: String) throws {
        var file = try load()
        file.records.removeAll { $0.deviceID == deviceID }
        try save(file)
    }
}

private func readPassword(prompt: String) throws -> [UInt8] {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard readpassphrase(prompt, &buffer, buffer.count, 0) != nil else {
        throw fail("password input failed")
    }
    let length = buffer.firstIndex(of: 0) ?? buffer.count
    guard length > 0 else { throw fail("password must not be empty") }
    let result = buffer[..<length].map { UInt8(bitPattern: $0) }
    secureZero(&buffer)
    return result
}

private func consoleIdentity() -> (uid_t, gid_t) {
    var status = stat()
    if stat("/dev/console", &status) == 0, status.st_uid != 0 {
        return (status.st_uid, status.st_gid)
    }
    return (501, 20)
}

private func safeName(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let converted = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
    let result = String(converted).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return result.isEmpty ? "EDP" : String(result.prefix(48))
}

private final class MountSession {
    let physicalBSD: String
    let deviceID: String
    let partitionType: UInt32
    let bridgeMount: String
    let exposedBSD: String
    let filesystem: String
    let userMount: String?
    let fuse: Process
    let filesystemProcess: Process?

    init(
        physicalBSD: String,
        deviceID: String,
        partitionType: UInt32,
        bridgeMount: String,
        exposedBSD: String,
        filesystem: String,
        userMount: String?,
        fuse: Process,
        filesystemProcess: Process?
    ) {
        self.physicalBSD = physicalBSD
        self.deviceID = deviceID
        self.partitionType = partitionType
        self.bridgeMount = bridgeMount
        self.exposedBSD = exposedBSD
        self.filesystem = filesystem
        self.userMount = userMount
        self.fuse = fuse
        self.filesystemProcess = filesystemProcess
    }
}

private final class MountManager {
    private var sessions = [String: MountSession]()
    private let binaryRoot: String

    init() {
        binaryRoot = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent().path
    }

    func recoverPersistedSessions() {
        let path = dataRoot + "/sessions.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return
        }
        for item in items {
            if let mountpoint = item["mountpoint"], !mountpoint.isEmpty {
                _ = try? run("/sbin/umount", [mountpoint], accepted: [0, 1])
                try? FileManager.default.removeItem(atPath: mountpoint)
            }
            if let exposed = item["exposedBSD"], !exposed.isEmpty {
                _ = try? run("/usr/sbin/diskutil", ["eject", exposed], accepted: [0, 1])
            }
            if let bridge = item["bridgeMount"], !bridge.isEmpty {
                _ = try? run("/sbin/umount", [bridge], accepted: [0, 1])
                try? FileManager.default.removeItem(atPath: bridge)
            }
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func key(_ disk: PhysicalDisk, _ type: UInt32) -> String {
        "\(disk.deviceID):\(type)"
    }

    func contains(_ disk: PhysicalDisk, _ type: UInt32) -> Bool {
        sessions[key(disk, type)] != nil
    }

    func mountedPhysicalDisks() -> Set<String> {
        Set(sessions.values.map(\.physicalBSD))
    }

    func mount(disk: PhysicalDisk, partitionType: UInt32, password: [UInt8]) throws {
        let sessionKey = key(disk, partitionType)
        guard sessions[sessionKey] == nil else { return }
        let suffix = safeName(disk.deviceID) + "-\(partitionType)"
        let bridgeMount = "/Volumes/.edp-block-\(suffix)"
        try? FileManager.default.removeItem(atPath: bridgeMount)
        try FileManager.default.createDirectory(
            atPath: bridgeMount,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: mode_t(0o700))]
        )
        _ = try run("/usr/sbin/diskutil", ["unmountDisk", disk.bsdName], accepted: [0, 1])

        let passwordPipe = Pipe()
        let fuse = Process()
        fuse.executableURL = URL(fileURLWithPath: binaryRoot + "/edp-readwrite-fuse")
        fuse.arguments = [
            "--device", disk.rawPath, disk.vidHex, disk.pidHex,
            String(disk.sizeBytes), String(partitionType), "0", bridgeMount,
        ]
        fuse.standardInput = passwordPipe
        let logPath = sessionRoot + "/\(suffix).bridge.log"
        try FileManager.default.createDirectory(atPath: sessionRoot, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let log = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        fuse.standardOutput = log
        fuse.standardError = log
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_LIBRARY_PATH"] = binaryRoot
        fuse.environment = environment
        try fuse.run()
        passwordPipe.fileHandleForWriting.write(Data(password))
        try passwordPipe.fileHandleForWriting.close()

        var attachedBSD: String?
        do {
            try waitUntil(seconds: 20) {
                FileManager.default.isWritableFile(atPath: bridgeMount + "/volume.raw")
                    || !fuse.isRunning
            }
            guard fuse.isRunning,
                  FileManager.default.isWritableFile(atPath: bridgeMount + "/volume.raw") else {
                throw fail("encrypted block bridge failed; see \(logPath)")
            }

            let attach = try run(
                binaryRoot + "/diskimages2-attach",
                ["--writable-noautomount", bridgeMount + "/volume.raw"]
            ).stdoutText
            guard let exposed = attach.split(separator: "\n")
                .first(where: { $0.hasPrefix("DI_BSD_NAME=") })?
                .split(separator: "=", maxSplits: 1).last.map(String.init),
                FileManager.default.fileExists(atPath: "/dev/\(exposed)") else {
                throw fail("DiskImages2 did not publish a writable BSD device")
            }
            attachedBSD = exposed
            let filesystemDevice = try resolveFilesystemDevice(exposed)
            let mounted: (String, String?, Process?)
            switch filesystemDevice.magic {
            case "EXFAT": mounted = try mountExFAT(filesystemDevice.bsdName)
            case "NTFS": mounted = try mountNTFS(filesystemDevice.bsdName, suffix: suffix)
            default: throw fail("unsupported decrypted filesystem: \(filesystemDevice.magic)")
            }
            sessions[sessionKey] = MountSession(
                physicalBSD: disk.bsdName,
                deviceID: disk.deviceID,
                partitionType: partitionType,
                bridgeMount: bridgeMount,
                exposedBSD: exposed,
                filesystem: mounted.0,
                userMount: mounted.1,
                fuse: fuse,
                filesystemProcess: mounted.2
            )
            persistSessions()
            NSLog("EDP mounted %@ partition %u as %@ at %@", disk.deviceID, partitionType, mounted.0, mounted.1 ?? "(unknown)")
        } catch {
            if let attachedBSD {
                _ = try? run("/usr/sbin/diskutil", ["eject", attachedBSD], accepted: [0, 1])
            }
            fuse.terminate()
            _ = try? run("/sbin/umount", [bridgeMount], accepted: [0, 1])
            try? FileManager.default.removeItem(atPath: bridgeMount)
            throw error
        }
    }

    private func mountExFAT(_ bsd: String) throws -> (String, String?, Process?) {
        _ = try run("/usr/sbin/diskutil", ["mount", bsd])
        let info = try plist(run("/usr/sbin/diskutil", ["info", "-plist", bsd]).stdout)
        let readOnlyKeys = ["ReadOnly", "ReadOnlyMedia", "ReadOnlyVolume", "VolumeReadOnly"]
        guard !readOnlyKeys.contains(where: { (info[$0] as? Bool) == true }) else {
            throw fail("native ExFAT mounted read-only")
        }
        guard let mountpoint = info["MountPoint"] as? String, !mountpoint.isEmpty else {
            throw fail("native ExFAT did not publish a mount point")
        }
        return ("ExFAT", mountpoint, nil)
    }

    private func mountNTFS(_ bsd: String, suffix: String) throws -> (String, String?, Process?) {
        let device = "/dev/\(bsd)"
        let probe = try run(
            binaryRoot + "/ntfs-3g.probe",
            ["--readwrite", device],
            accepted: Set(0...21)
        )
        guard probe.status == 0 else {
            let reasons: [Int32: String] = [
                12: "not a valid NTFS volume", 13: "inconsistent NTFS volume",
                14: "Windows hibernation/fast startup is active",
                15: "NTFS was not cleanly unmounted", 16: "volume is already in use",
                19: "insufficient privilege",
            ]
            throw fail("NTFS write probe refused the volume: \(reasons[probe.status] ?? "exit \(probe.status)")")
        }
        var label = "EDP-NTFS"
        if let result = try? run(binaryRoot + "/ntfslabel", [device]),
           !result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            label = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let mountpoint = uniqueMountpoint(safeName(label))
        try FileManager.default.createDirectory(atPath: mountpoint, withIntermediateDirectories: false)
        let identity = consoleIdentity()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryRoot + "/ntfs-3g")
        process.arguments = [
            "-o", "backend=fskit",
            "-o", "no_detach",
            "-o", "local",
            "-o", "norecover",
            "-o", "windows_names",
            "-o", "streams_interface=openxattr",
            "-o", "noatime",
            "-o", "big_writes",
            "-o", "allow_other",
            "-o", "uid=\(identity.0)",
            "-o", "gid=\(identity.1)",
            "-o", "volname=\(safeName(label))",
            device, mountpoint,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_LIBRARY_PATH"] = binaryRoot
        process.environment = environment
        let logPath = sessionRoot + "/\(suffix).ntfs.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let log = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        process.standardOutput = log
        process.standardError = log
        try process.run()
        try waitUntil(seconds: 20) { isMountpoint(mountpoint) || !process.isRunning }
        guard process.isRunning, isMountpoint(mountpoint) else {
            process.terminate()
            throw fail("NTFS-3G FSKit mount failed; see \(logPath)")
        }
        return ("NTFS", mountpoint, process)
    }

    func removeMissing(availableBSD: Set<String>) {
        let keys = sessions.compactMap { availableBSD.contains($0.value.physicalBSD) ? nil : $0.key }
        for key in keys { unmount(key: key) }
    }

    func unmountAll() {
        for key in Array(sessions.keys) { unmount(key: key) }
    }

    private func unmount(key: String) {
        guard let session = sessions.removeValue(forKey: key) else { return }
        if let userMount = session.userMount {
            _ = try? run("/sbin/umount", [userMount], accepted: [0, 1])
        }
        session.filesystemProcess?.terminate()
        _ = try? run("/usr/sbin/diskutil", ["eject", session.exposedBSD], accepted: [0, 1])
        session.fuse.terminate()
        _ = try? run("/sbin/umount", [session.bridgeMount], accepted: [0, 1])
        try? FileManager.default.removeItem(atPath: session.bridgeMount)
        persistSessions()
    }

    private func persistSessions() {
        let publicState = sessions.values.map {
            [
                "physicalBSD": $0.physicalBSD,
                "deviceID": $0.deviceID,
                "partitionType": String($0.partitionType),
                "bridgeMount": $0.bridgeMount,
                "exposedBSD": $0.exposedBSD,
                "filesystem": $0.filesystem,
                "mountpoint": $0.userMount ?? "",
            ]
        }
        if let data = try? JSONSerialization.data(
            withJSONObject: publicState,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? atomicWrite(data, to: dataRoot + "/sessions.json", mode: 0o644)
        }
    }
}

private func filesystemMagic(_ rawPath: String) throws -> String {
    let fd = open(rawPath, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { throw fail("cannot open published device \(rawPath): errno=\(errno)") }
    defer { close(fd) }
    var bytes = [UInt8](repeating: 0, count: 512)
    let count = bytes.withUnsafeMutableBytes { raw in
        pread(fd, raw.baseAddress, raw.count, 0)
    }
    guard count == bytes.count else {
        throw fail("cannot read decrypted filesystem boot sector")
    }
    if String(bytes: bytes[3..<11], encoding: .ascii) == "NTFS    " { return "NTFS" }
    if String(bytes: bytes[3..<11], encoding: .ascii) == "EXFAT   " { return "EXFAT" }
    return "UNKNOWN"
}

private func resolveFilesystemDevice(_ rootBSD: String) throws -> (bsdName: String, magic: String) {
    let rootMagic = try filesystemMagic("/dev/r\(rootBSD)")
    if rootMagic != "UNKNOWN" { return (rootBSD, rootMagic) }

    let tree = try plist(run("/usr/sbin/diskutil", ["list", "-plist", rootBSD]).stdout)
    let disks = tree["AllDisksAndPartitions"] as? [[String: Any]] ?? []
    for disk in disks {
        let partitions = disk["Partitions"] as? [[String: Any]] ?? []
        for partition in partitions {
            guard let bsd = partition["DeviceIdentifier"] as? String,
                  FileManager.default.fileExists(atPath: "/dev/r\(bsd)"),
                  let magic = try? filesystemMagic("/dev/r\(bsd)"),
                  magic != "UNKNOWN" else {
                continue
            }
            return (bsd, magic)
        }
    }
    return (rootBSD, "UNKNOWN")
}

private func uniqueMountpoint(_ name: String) -> String {
    let base = "/Volumes/\(name)"
    if !FileManager.default.fileExists(atPath: base) { return base }
    for index in 2...999 {
        let candidate = base + " \(index)"
        if !FileManager.default.fileExists(atPath: candidate) { return candidate }
    }
    return base + "-\(UUID().uuidString.prefix(8))"
}

private func isMountpoint(_ path: String) -> Bool {
    guard let output = try? run("/sbin/mount").stdoutText else { return false }
    return output.split(separator: "\n").contains { $0.contains(" on \(path) ") }
}

private func waitUntil(seconds: TimeInterval, condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return }
        usleep(200_000)
    }
    throw fail("operation timed out after \(Int(seconds)) seconds")
}

private func requireRoot() throws {
    guard geteuid() == 0 else { throw fail("this command must run as root (use sudo)") }
}

private func selectDisk(_ argument: String?, from disks: [PhysicalDisk]) throws -> PhysicalDisk {
    if let argument {
        let normalized = argument.replacingOccurrences(of: "/dev/r", with: "")
            .replacingOccurrences(of: "/dev/", with: "")
        guard let disk = disks.first(where: { $0.bsdName == normalized }) else {
            throw fail("EDP disk not found: \(argument)")
        }
        return disk
    }
    guard disks.count == 1, let disk = disks.first else {
        throw fail(disks.isEmpty ? "no EDP disk found" : "multiple EDP disks found; specify diskN")
    }
    return disk
}

private func authorize(_ diskArgument: String?) throws {
    try requireRoot()
    let disk = try selectDisk(diskArgument, from: discoverEDPDisks())
    var password = try readPassword(prompt: "EDP password for \(disk.mediaName): ")
    defer { secureZero(&password) }
    let raw = try EDPFileRawDevice(
        path: disk.rawPath,
        declaredSizeBytes: disk.sizeBytes,
        writable: false
    )
    var verified = [UInt32]()
    for type: UInt32 in [2, 4] {
        let request = EDPReadOnlyUnlockRequest(
            vidHex: disk.vidHex,
            pidHex: disk.pidHex,
            deviceSizeBytes: disk.sizeBytes,
            passwordBytes: password,
            partitionType: type
        )
        if (try? EDPReadOnlyUnlock.unlock(raw: raw, request: request)) != nil {
            verified.append(type)
        }
    }
    guard !verified.isEmpty else { throw fail("password did not unlock EDP partition 2 or 4") }
    try CredentialStore().put(
        deviceID: disk.deviceID,
        password: password,
        partitionTypes: verified
    )
    print("AUTHORIZED_DEVICE=\(disk.deviceID)")
    print("AUTHORIZED_PARTITIONS=\(verified.map(String.init).joined(separator: ","))")
    _ = try? run("/bin/launchctl", ["kickstart", "-k", "system/\(launchdLabel)"])
}

private func daemon() throws -> Never {
    try requireRoot()
    let store = try CredentialStore()
    let manager = MountManager()
    manager.recoverPersistedSessions()
    Darwin.signal(SIGTERM, runtimeSignalHandler)
    Darwin.signal(SIGINT, runtimeSignalHandler)
    var failureDeadline = [String: Date]()
    while true {
        autoreleasepool {
            do {
                let disks = try discoverEDPDisks()
                manager.removeMissing(availableBSD: Set(disks.map(\.bsdName)))
                let records = try store.load().records
                for disk in disks {
                    guard let record = records.first(where: { $0.deviceID == disk.deviceID }) else {
                        continue
                    }
                    for type in record.partitionTypes where !manager.contains(disk, type) {
                        let key = "\(disk.deviceID):\(type)"
                        if let deadline = failureDeadline[key], deadline > Date() { continue }
                        do {
                            var password = try store.password(for: record)
                            defer { secureZero(&password) }
                            try manager.mount(disk: disk, partitionType: type, password: password)
                            failureDeadline.removeValue(forKey: key)
                        } catch {
                            NSLog("EDP auto-mount failed for %@ type %u: %@", disk.deviceID, type, String(describing: error))
                            failureDeadline[key] = Date().addingTimeInterval(30)
                        }
                    }
                }
            } catch {
                NSLog("EDP discovery loop failed: %@", String(describing: error))
            }
        }
        sleep(2)
    }
}

private func runtimeSignalHandler(_ signalNumber: Int32) {
    // Only async-signal-safe work is allowed here. The next daemon instance
    // recovers the persisted session state before scanning physical disks.
    _exit(128 + signalNumber)
}

private func doctor() -> Int32 {
    var ok = true
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let macOSOK = version.majorVersion >= 26
    print("MACOS_26_OR_NEWER=\(macOSOK ? "YES" : "NO")")
    ok = ok && macOSOK
    let macFUSE = "/Library/Filesystems/macfuse.fs/Contents/Frameworks/MFMount.framework"
    let macFUSEOK = FileManager.default.fileExists(atPath: macFUSE)
    print("MACFUSE_RUNTIME=\(macFUSEOK ? "OK" : "MISSING")")
    ok = ok && macFUSEOK
    for tool in ["edp-readwrite-fuse", "diskimages2-attach", "ntfs-3g", "ntfs-3g.probe", "ntfslabel"] {
        let path = productRoot + "/bin/" + tool
        let present = FileManager.default.isExecutableFile(atPath: path)
        print("TOOL_\(tool.uppercased().replacingOccurrences(of: ".", with: "_"))=\(present ? "OK" : "MISSING")")
        ok = ok && present
    }
    if geteuid() == 0 {
        let count = (try? discoverEDPDisks().count) ?? 0
        print("EDP_DISKS=\(count)")
    } else {
        print("EDP_DISKS=REQUIRES_ROOT")
    }
    print("RESULT=\(ok ? "EDP_RUNTIME_READY" : "EDP_RUNTIME_NOT_READY")")
    return ok ? 0 : 1
}

private func usage() {
    print("""
    Usage:
      edp-vaultctl doctor
      edp-vaultctl status
      sudo edp-vaultctl list
      sudo edp-vaultctl authorize [diskN]
      sudo edp-vaultctl revoke <device-id>
      sudo edp-vaultctl cleanup
      sudo edp-vaultctl daemon

    After one-time authorization, the launch daemon automatically mounts
    clean ExFAT and NTFS partitions read/write when the EDP USB disk appears.
    """)
}

@main
private enum EDPVaultMain {
    static func main() {
        do {
            let command = CommandLine.arguments.dropFirst().first ?? "help"
            switch command {
            case "doctor": exit(doctor())
            case "status":
                let path = dataRoot + "/sessions.json"
                if let data = FileManager.default.contents(atPath: path) {
                    FileHandle.standardOutput.write(data)
                    print()
                } else {
                    print("[]")
                }
            case "list":
                try requireRoot()
                for disk in try discoverEDPDisks() {
                    print("\(disk.bsdName)\t\(disk.deviceID)\t\(disk.vidHex):\(disk.pidHex)\t\(disk.sizeBytes)\t\(disk.mediaName)")
                }
            case "authorize":
                try authorize(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil)
            case "revoke":
                try requireRoot()
                guard CommandLine.arguments.count == 3 else {
                    throw fail("revoke requires a device id")
                }
                try CredentialStore().remove(deviceID: CommandLine.arguments[2])
            case "cleanup":
                try requireRoot()
                MountManager().recoverPersistedSessions()
            case "daemon": try daemon()
            default: usage()
            }
        } catch {
            FileHandle.standardError.write(Data("ERROR=\(error)\n".utf8))
            exit(1)
        }
    }
}
