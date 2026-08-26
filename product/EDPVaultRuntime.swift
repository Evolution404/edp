import Darwin
import Foundation
import Security

private let productRoot = "/Library/Application Support/EDP USB Vault"
private let dataRoot = "/var/db/com.edp.usbvault"
private let sessionRoot = dataRoot + "/sessions"
private let credentialIndexPath = dataRoot + "/credential-index.json"
private let legacyCredentialPath = dataRoot + "/credentials.json"
private let legacyMasterKeyPath = dataRoot + "/master.key"

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

private struct EDPRawMetadataSnapshot {
    let lba4: Data
    let lba7: Data
    let lba11: Data
    let lba12: Data
}

private func runtimeBinaryRoot() -> String {
    if let configuredRoot = ProcessInfo.processInfo.environment["EDP_RUNTIME_BIN_ROOT"], !configuredRoot.isEmpty {
        return configuredRoot
    }
    return URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath().deletingLastPathComponent().path
}

private func rawMetadataSnapshot(for rawPath: String) throws -> EDPRawMetadataSnapshot {
    let uid = consoleIdentity().0
    let result = try run(
        runtimeBinaryRoot() + "/edp-raw-metadata",
        [rawPath, String(uid)]
    )
    let sector = Int(EDPMetadataProbe.legacySectorByteLength)
    guard result.stdout.count == sector * 4 else {
        throw fail("raw metadata helper returned \(result.stdout.count) bytes; expected \(sector * 4)")
    }
    func slice(_ index: Int) -> Data {
        let start = index * sector
        return result.stdout.subdata(in: start..<(start + sector))
    }
    return EDPRawMetadataSnapshot(lba4: slice(0), lba7: slice(1), lba11: slice(2), lba12: slice(3))
}

private func discoverEDPDisks() throws -> [PhysicalDisk] {
    var answer: [PhysicalDisk] = []
    for media in try EDPNativeDeviceDiscovery.allWholeUSBMedia() {
        let rawPath = "/dev/r\(media.bsdName)"
        guard FileManager.default.fileExists(atPath: rawPath),
              let metadata = try? rawMetadataSnapshot(for: rawPath),
              EDPMetadataProbe.recognizeReservedSectors(
                  lba4: [UInt8](metadata.lba4),
                  lba7: [UInt8](metadata.lba7)
              ) != nil,
              let deviceID = EDPVolumeMetadata.deviceIDFromLBA11(
                  [UInt8](metadata.lba11),
                  vidHex: media.vid,
                  pidHex: media.pid,
                  sizeBytes: media.size
              ) else {
            continue
        }
        answer.append(PhysicalDisk(
            bsdName: media.bsdName,
            rawPath: rawPath,
            sizeBytes: media.size,
            mediaName: media.mediaName,
            vidHex: media.vid,
            pidHex: media.pid,
            deviceID: deviceID
        ))
    }
    return answer.sorted { $0.bsdName < $1.bsdName }
}

private func makeCredentialStore() throws -> EDPCredentialStore {
    try EDPCredentialStore(
        indexPath: credentialIndexPath,
        legacyCredentialPath: legacyCredentialPath,
        legacyMasterKeyPath: legacyMasterKeyPath
    )
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

private func configureConsoleProcess(
    _ process: Process,
    binaryRoot: String,
    identity: (uid_t, gid_t),
    executable: String,
    arguments: [String]
) {
    process.executableURL = URL(fileURLWithPath: binaryRoot + "/edp-console-exec")
    process.arguments = [
        String(identity.0), String(identity.1), "--", executable,
    ] + arguments
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
    private let diskArbitration: EDPDiskArbitrationController
    private let blockPublisher: EDPBlockDevicePublisher

    init() throws {
        if let configuredRoot = ProcessInfo.processInfo.environment["EDP_RUNTIME_BIN_ROOT"], !configuredRoot.isEmpty {
            binaryRoot = configuredRoot
        } else {
            binaryRoot = URL(fileURLWithPath: CommandLine.arguments[0])
                .resolvingSymlinksInPath().deletingLastPathComponent().path
        }
        diskArbitration = try EDPDiskArbitrationController()
        blockPublisher = EDPDiskImages2Publisher(
            binaryRoot: binaryRoot,
            diskArbitration: diskArbitration
        )
    }

    func recoverPersistedSessions() {
        let path = dataRoot + "/sessions.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            return
        }
        for item in items {
            if let mountpoint = item["mountpoint"], !mountpoint.isEmpty {
                try? EDPNativeMountTable.unmountPath(mountpoint)
                try? FileManager.default.removeItem(atPath: mountpoint)
            }
            if let exposed = item["exposedBSD"], !exposed.isEmpty {
                try? blockPublisher.unpublish(EDPPublishedBlockDevice(bsdName: exposed))
            }
            if let bridge = item["bridgeMount"], !bridge.isEmpty {
                try? EDPNativeMountTable.unmountPath(bridge)
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

    func isMounted(deviceID: String) -> Bool {
        sessions.values.contains { $0.deviceID == deviceID }
    }

    func mountedSummaries() -> [[String: String]] {
        sessions.values.map {
            [
                "deviceID": $0.deviceID,
                "physicalBSD": $0.physicalBSD,
                "partitionType": String($0.partitionType),
                "filesystem": $0.filesystem,
                "mountpoint": $0.userMount ?? "",
            ]
        }
    }

    func eject(deviceID: String) {
        let keys = sessions.compactMap { $0.value.deviceID == deviceID ? $0.key : nil }
        for key in keys { unmount(key: key) }
    }

    func mount(disk: PhysicalDisk, partitionType: UInt32, password: [UInt8], rawAuthorization: Data) throws {
        let sessionKey = key(disk, partitionType)
        guard sessions[sessionKey] == nil else { return }
        let suffix = safeName(disk.deviceID) + "-\(partitionType)"
        let bridgeMount = "/Volumes/.edp-block-\(suffix)"
        let identity = consoleIdentity()
        try? FileManager.default.removeItem(atPath: bridgeMount)
        try FileManager.default.createDirectory(
            atPath: bridgeMount,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: mode_t(0o700))]
        )
        guard chown(bridgeMount, identity.0, identity.1) == 0 else {
            throw fail("cannot assign encrypted bridge mountpoint to console user: errno=\(errno)")
        }
        if EDPNativeMountTable.hasMountedBSDPrefix(disk.bsdName) {
            try diskArbitration.unmountWhole(disk.bsdName)
        }

        let passwordPipe = Pipe()
        let fuse = Process()
        configureConsoleProcess(
            fuse,
            binaryRoot: binaryRoot,
            identity: identity,
            executable: binaryRoot + "/edp-readwrite-fuse",
            arguments: [
                "--device-auth-readonly", disk.rawPath, disk.vidHex, disk.pidHex,
                String(disk.sizeBytes), String(partitionType), "0", bridgeMount,
            ]
        )
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
        passwordPipe.fileHandleForWriting.write(rawAuthorization)
        passwordPipe.fileHandleForWriting.write(Data(password))
        try passwordPipe.fileHandleForWriting.close()

        do {
            try waitUntil(seconds: 20) {
                FileManager.default.isReadableFile(atPath: bridgeMount + "/volume.raw")
                    || !fuse.isRunning
            }
            guard fuse.isRunning,
                  FileManager.default.isReadableFile(atPath: bridgeMount + "/volume.raw") else {
                throw fail("encrypted block bridge failed; see \(logPath)")
            }

            let decryptedVolume = bridgeMount + "/volume.raw"
            let directMagic = try filesystemMagic(decryptedVolume)
            guard directMagic == "NTFS" else {
                throw fail("Finder read-only mode currently supports NTFS exchange volumes only")
            }
            let mounted: (String, String?, Process?)
            mounted = try mountNTFSReadOnly(
                decryptedVolume,
                suffix: suffix,
                identity: identity
            )
            sessions[sessionKey] = MountSession(
                physicalBSD: disk.bsdName,
                deviceID: disk.deviceID,
                partitionType: partitionType,
                bridgeMount: bridgeMount,
                exposedBSD: "",
                filesystem: mounted.0,
                userMount: mounted.1,
                fuse: fuse,
                filesystemProcess: mounted.2
            )
            persistSessions()
            NSLog("EDP mounted %@ partition %u as %@ at %@", disk.deviceID, partitionType, mounted.0, mounted.1 ?? "(unknown)")
        } catch {
            fuse.terminate()
            try? EDPNativeMountTable.unmountPath(bridgeMount)
            try? FileManager.default.removeItem(atPath: bridgeMount)
            throw error
        }
    }

    private func mountExFAT(_ bsd: String) throws -> (String, String?, Process?) {
        let mountpoint = try diskArbitration.mount(bsd)
        guard EDPNativeMountTable.isReadOnly(mountpoint) == false else {
            throw fail("native ExFAT mounted read-only")
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
            throw fail(EDPNTFSWriteSafety.refusalMessage(for: probe.status)
                ?? "NTFS write probe refused the volume")
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
        process.arguments = EDPNTFSMountPolicy.commandArguments(
            uid: identity.0,
            gid: identity.1,
            volumeName: safeName(label)
        ) + [device, mountpoint]
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_LIBRARY_PATH"] = binaryRoot
        process.environment = environment
        let logPath = sessionRoot + "/\(suffix).ntfs.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let log = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        process.standardOutput = log
        process.standardError = log
        try process.run()
        try waitUntil(seconds: 20) { EDPNativeMountTable.isMountpoint(mountpoint) || !process.isRunning }
        guard process.isRunning, EDPNativeMountTable.isMountpoint(mountpoint) else {
            process.terminate()
            throw fail("NTFS-3G FSKit mount failed; see \(logPath)")
        }
        return ("NTFS", mountpoint, process)
    }

    private func mountNTFSReadOnly(
        _ device: String,
        suffix: String,
        identity: (uid_t, gid_t)
    ) throws -> (String, String?, Process?) {
        let probe = try run(
            binaryRoot + "/ntfs-3g.probe",
            ["--readonly", device],
            accepted: Set(0...21)
        )
        guard probe.status == 0 else {
            throw fail("NTFS read-only probe refused the volume (\(probe.status))")
        }
        let label = "EDP-NTFS"
        let mountpoint = uniqueMountpoint(label)
        try FileManager.default.createDirectory(atPath: mountpoint, withIntermediateDirectories: false)
        guard chown(mountpoint, identity.0, identity.1) == 0 else {
            throw fail("cannot assign NTFS mountpoint to console user: errno=\(errno)")
        }
        let process = Process()
        configureConsoleProcess(
            process,
            binaryRoot: binaryRoot,
            identity: identity,
            executable: binaryRoot + "/ntfs-3g",
            arguments: EDPNTFSMountPolicy.readOnlyCommandArguments(
                uid: identity.0,
                gid: identity.1,
                volumeName: label
            ) + [device, mountpoint]
        )
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_LIBRARY_PATH"] = binaryRoot
        process.environment = environment
        let logPath = sessionRoot + "/\(suffix).ntfs.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let log = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        process.standardOutput = log
        process.standardError = log
        try process.run()
        try waitUntil(seconds: 20) { EDPNativeMountTable.isMountpoint(mountpoint) || !process.isRunning }
        guard process.isRunning,
              EDPNativeMountTable.isMountpoint(mountpoint),
              EDPNativeMountTable.isReadOnly(mountpoint) == true else {
            process.terminate()
            throw fail("NTFS-3G Finder read-only mount failed; see \(logPath)")
        }
        return ("NTFS (read-only)", mountpoint, process)
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
            try? EDPNativeMountTable.unmountPath(userMount)
        }
        session.filesystemProcess?.terminate()
        if !session.exposedBSD.isEmpty {
            try? blockPublisher.unpublish(EDPPublishedBlockDevice(bsdName: session.exposedBSD))
        }
        session.fuse.terminate()
        try? EDPNativeMountTable.unmountPath(session.bridgeMount)
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

    for bsd in try EDPNativeDeviceDiscovery.descendantBSDNames(of: rootBSD) {
        guard FileManager.default.fileExists(atPath: "/dev/r\(bsd)"),
              let magic = try? filesystemMagic("/dev/r\(bsd)"),
              magic != "UNKNOWN" else {
            continue
        }
        return (bsd, magic)
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

private func verifiedPartitionTypes(disk: PhysicalDisk, password: [UInt8]) throws -> [UInt32] {
    let metadata = try rawMetadataSnapshot(for: disk.rawPath)
    guard let deviceID = EDPVolumeMetadata.deviceIDFromLBA11(
        [UInt8](metadata.lba11),
        vidHex: disk.vidHex,
        pidHex: disk.pidHex,
        sizeBytes: disk.sizeBytes
    ), deviceID == disk.deviceID else {
        throw fail("EDP device identity changed during authorization")
    }
    let plain = try EDPVolumeMetadata.decodeLBA12(
        [UInt8](metadata.lba12),
        deviceID: deviceID
    )
    let volumes = try EDPVolumeMetadata.parseLBA12Entries(plain, password: password)
    let verified = volumes.map(\.partitionType).filter { $0 == 2 || $0 == 4 }
    guard !verified.isEmpty else { throw fail("password did not unlock EDP partition 2 or 4") }
    return Array(Set(verified)).sorted()
}

private func authorize(_ diskArgument: String?) throws {
    try requireRoot()
    let disk = try selectDisk(diskArgument, from: discoverEDPDisks())
    var password = try readPassword(prompt: "EDP password for \(disk.mediaName): ")
    defer { secureZero(&password) }
    let verified = try verifiedPartitionTypes(disk: disk, password: password)
    try makeCredentialStore().put(
        deviceID: disk.deviceID,
        password: password,
        partitionTypes: verified
    )
    print("AUTHORIZED_DEVICE=\(disk.deviceID)")
    print("AUTHORIZED_PARTITIONS=\(verified.map(String.init).joined(separator: ","))")
}

private final class EDPDaemonController: @unchecked Sendable {
    private let store: EDPCredentialStore
    private let manager: MountManager
    private let queue = DispatchQueue(label: "com.edp.usbvault.controller")
    private var failedMounts = Set<String>()
    private var rawAuthorization: Data?

    init() throws {
        store = try makeCredentialStore()
        manager = try MountManager()
        manager.recoverPersistedSessions()
    }

    func reconcile() {
        queue.async { [weak self] in self?.reconcileLocked() }
    }

    private func reconcileLocked() {
        autoreleasepool {
            do {
                let disks = try discoverEDPDisks()
                manager.removeMissing(availableBSD: Set(disks.map(\.bsdName)))
                let connectedDeviceIDs = Set(disks.map(\.deviceID))
                failedMounts = failedMounts.filter { key in
                    guard let separator = key.lastIndex(of: ":") else { return false }
                    return connectedDeviceIDs.contains(String(key[..<separator]))
                }
                let records = try store.load().records
                guard let rawAuthorization else { return }
                for disk in disks {
                    guard let record = records.first(where: { $0.deviceID == disk.deviceID }) else {
                        continue
                    }
                    for type in record.partitionTypes where !manager.contains(disk, type) {
                        let key = "\(disk.deviceID):\(type)"
                        if failedMounts.contains(key) { continue }
                        do {
                            var password = try store.password(for: record)
                            defer { secureZero(&password) }
                            try manager.mount(
                                disk: disk,
                                partitionType: type,
                                password: password,
                                rawAuthorization: rawAuthorization
                            )
                            failedMounts.remove(key)
                        } catch {
                            NSLog("EDP auto-mount failed for %@ type %u; automatic retry paused until explicit user action or device reconnect: %@", disk.deviceID, type, String(describing: error))
                            failedMounts.insert(key)
                        }
                    }
                }
            } catch {
                NSLog("EDP event reconciliation failed: %@", String(describing: error))
            }
        }
    }

    func snapshotData() -> Data {
        queue.sync {
            do {
                let disks = try discoverEDPDisks()
                let records = try store.load().records
                let devices = disks.map { disk in
                    let record = records.first { $0.deviceID == disk.deviceID }
                    return EDPXPCDevice(
                        deviceID: disk.deviceID,
                        bsdName: disk.bsdName,
                        mediaName: disk.mediaName,
                        vidPID: "\(disk.vidHex):\(disk.pidHex)",
                        sizeBytes: disk.sizeBytes,
                        authorized: record != nil,
                        mounted: manager.isMounted(deviceID: disk.deviceID),
                        rawAccessReady: rawAuthorization != nil,
                        partitionTypes: record?.partitionTypes ?? []
                    )
                }
                return try JSONEncoder().encode(EDPXPCSnapshot(
                    devices: devices,
                    serviceVersion: "0.5.0",
                    timestamp: ISO8601DateFormatter().string(from: Date())
                ))
            } catch {
                return Data("{\"error\":\"\(String(describing: error).replacingOccurrences(of: "\"", with: "'"))\"}".utf8)
            }
        }
    }

    func authorize(deviceID: String, passwordData: Data, rawAuthorization: Data) throws {
        var password = [UInt8](passwordData)
        defer { secureZero(&password) }
        guard rawAuthorization.count == MemoryLayout<AuthorizationExternalForm>.size else {
            throw fail("invalid raw-device authorization payload")
        }
        try queue.sync {
            guard let disk = try discoverEDPDisks().first(where: { $0.deviceID == deviceID }) else {
                throw fail("EDP device is no longer connected")
            }
            let verified = try verifiedPartitionTypes(disk: disk, password: password)
            try store.put(deviceID: deviceID, password: password, partitionTypes: verified)
            self.rawAuthorization = rawAuthorization
            for type in verified { failedMounts.remove("\(deviceID):\(type)") }
        }
        reconcile()
    }

    func grantRawAccess(_ authorization: Data) throws {
        guard authorization.count == MemoryLayout<AuthorizationExternalForm>.size else {
            throw fail("invalid raw-device authorization payload")
        }
        queue.sync {
            rawAuthorization = authorization
            failedMounts.removeAll()
        }
        reconcile()
    }

    func retryMount(deviceID: String) throws {
        try queue.sync {
            guard rawAuthorization != nil else {
                throw fail("raw-device access is not authorized")
            }
            guard try discoverEDPDisks().contains(where: { $0.deviceID == deviceID }) else {
                throw fail("EDP device is no longer connected")
            }
            guard try store.load().records.contains(where: { $0.deviceID == deviceID }) else {
                throw fail("EDP device is not authorized")
            }
            failedMounts = failedMounts.filter { !$0.hasPrefix("\(deviceID):") }
        }
        reconcile()
    }

    func revoke(deviceID: String) throws {
        try queue.sync {
            manager.eject(deviceID: deviceID)
            failedMounts = failedMounts.filter { !$0.hasPrefix("\(deviceID):") }
            try store.remove(deviceID: deviceID)
        }
    }

    func eject(deviceID: String) {
        queue.sync { manager.eject(deviceID: deviceID) }
    }

    func diagnosticsData() -> Data {
        queue.sync {
            let payload: [String: Any] = [
                "mounts": manager.mountedSummaries(),
                "failedMounts": failedMounts.sorted(),
                "rawAccessReady": rawAuthorization != nil,
                "nativeMountCount": EDPNativeMountTable.entries().count,
                "legacyDiscoveryCLI": false,
                "legacyMountCLI": false,
                "eventDrivenDiscovery": true,
                "automaticMountRetry": false,
                "credentialStore": "System Keychain",
                "deviceDiscoveryDiagnostics": EDPNativeDeviceDiscovery.diagnosticReport(),
            ]
            return (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        }
    }
}

private final class EDPXPCService: NSObject, NSXPCListenerDelegate, EDPVaultXPCProtocol {
    private let controller: EDPDaemonController

    init(controller: EDPDaemonController) {
        self.controller = controller
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard EDPXPCPeerValidator.isTrusted(newConnection) else {
            NSLog("Rejected untrusted EDP XPC peer pid=%d uid=%u", newConnection.processIdentifier, newConnection.effectiveUserIdentifier)
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func snapshot(withReply reply: @escaping (Data) -> Void) {
        reply(controller.snapshotData())
    }

    func authorize(deviceID: String, password: Data, rawAuthorization: Data, withReply reply: @escaping (String?) -> Void) {
        do {
            try controller.authorize(
                deviceID: deviceID,
                passwordData: password,
                rawAuthorization: rawAuthorization
            )
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func grantRawAccess(authorization: Data, withReply reply: @escaping (String?) -> Void) {
        do {
            try controller.grantRawAccess(authorization)
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func retryMount(deviceID: String, withReply reply: @escaping (String?) -> Void) {
        do {
            try controller.retryMount(deviceID: deviceID)
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func revoke(deviceID: String, withReply reply: @escaping (String?) -> Void) {
        do {
            try controller.revoke(deviceID: deviceID)
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func eject(deviceID: String, withReply reply: @escaping (String?) -> Void) {
        controller.eject(deviceID: deviceID)
        reply(nil)
    }

    func diagnostics(withReply reply: @escaping (Data) -> Void) {
        reply(controller.diagnosticsData())
    }
}

private func daemon() throws -> Never {
    try requireRoot()
    let controller = try EDPDaemonController()
    let monitor = try EDPDiskEventMonitor()
    let xpcService = EDPXPCService(controller: controller)
    let listener = NSXPCListener(machServiceName: edpVaultMachServiceName)
    listener.delegate = xpcService
    listener.resume()
    Darwin.signal(SIGTERM, runtimeSignalHandler)
    Darwin.signal(SIGINT, runtimeSignalHandler)
    monitor.start { controller.reconcile() }
    withExtendedLifetime((monitor, listener, xpcService)) {
        DispatchSemaphore(value: 0).wait()
    }
    fatalError("EDP daemon event loop unexpectedly returned")
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
    for tool in ["edp-readwrite-fuse", "edp-console-exec", "edp-raw-metadata", "diskimages2-attach", "ntfs-3g", "ntfs-3g.probe", "ntfslabel"] {
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
                try makeCredentialStore().remove(deviceID: CommandLine.arguments[2])
            case "cleanup":
                try requireRoot()
                try MountManager().recoverPersistedSessions()
            case "daemon": try daemon()
            default: usage()
            }
        } catch {
            FileHandle.standardError.write(Data("ERROR=\(error)\n".utf8))
            exit(1)
        }
    }
}
