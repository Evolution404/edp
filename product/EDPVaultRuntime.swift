import Darwin
import Foundation
import Security

private let dataRoot = "/var/db/com.edp.usbvault"
private let sessionRoot = dataRoot + "/sessions"
private let credentialIndexPath = dataRoot + "/credential-index.json"
private let policyPath = dataRoot + "/device-policies.json"
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
        guard FileManager.default.fileExists(atPath: rawPath) else { continue }
        let metadata: EDPRawMetadataSnapshot
        do {
            metadata = try rawMetadataSnapshot(for: rawPath)
        } catch {
            NSLog("EDP discovery skipped %@ because raw metadata read failed: %@", media.bsdName, String(describing: error))
            continue
        }
        guard EDPMetadataProbe.recognizeReservedSectors(
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

private func makePolicyStore() throws -> EDPDevicePolicyStore {
    try EDPDevicePolicyStore(path: policyPath)
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
    arguments: [String],
    rawDevice: String? = nil
) {
    process.executableURL = URL(fileURLWithPath: binaryRoot + "/edp-console-exec")
    var launcherArguments = [String(identity.0), String(identity.1)]
    if let rawDevice {
        launcherArguments += ["--raw-device", rawDevice]
    }
    process.arguments = launcherArguments + ["--", executable] + arguments
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
    let transport: EDPTransportSession
    let filesystemProcess: Process?

    init(
        physicalBSD: String,
        deviceID: String,
        partitionType: UInt32,
        bridgeMount: String,
        exposedBSD: String,
        filesystem: String,
        userMount: String?,
        transport: EDPTransportSession,
        filesystemProcess: Process?
    ) {
        self.physicalBSD = physicalBSD
        self.deviceID = deviceID
        self.partitionType = partitionType
        self.bridgeMount = bridgeMount
        self.exposedBSD = exposedBSD
        self.filesystem = filesystem
        self.userMount = userMount
        self.transport = transport
        self.filesystemProcess = filesystemProcess
    }
}

private final class MountManager {
    private var sessions = [String: MountSession]()
    private var missingSince = [String: Date]()
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
                if EDPNativeMountTable.isMountpoint(bridge) {
                    try? EDPNativeMountTable.unmountPath(bridge, force: true)
                }
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

    func summary(deviceID: String, partitionType: UInt32) -> [String: String]? {
        guard let session = sessions["\(deviceID):\(partitionType)"] else { return nil }
        var filesystem = session.filesystem
        var mountpoint = session.userMount ?? ""
        if !session.exposedBSD.isEmpty,
           let resolved = try? resolveFilesystemDevice(session.exposedBSD) {
            switch resolved.magic {
            case "EXFAT": filesystem = "ExFAT"
            case "NTFS": filesystem = "NTFS"
            case "FAT": filesystem = "FAT"
            default: filesystem = "Unformatted or unsupported"
            }
            mountpoint = EDPNativeMountTable.mountPoint(forBSD: resolved.bsdName) ?? ""
            if !mountpoint.isEmpty, EDPNativeMountTable.isReadOnly(mountpoint) == true {
                filesystem += " (read-only; Finder erasable)"
            }
        }
        return [
            "filesystem": filesystem,
            "mountpoint": mountpoint,
            "exposedBSD": session.exposedBSD,
        ]
    }

    func eject(deviceID: String) {
        let keys = sessions.compactMap { $0.value.deviceID == deviceID ? $0.key : nil }
        for key in keys { unmount(key: key) }
    }

    func unmount(deviceID: String, partitionType: UInt32) {
        unmount(key: "\(deviceID):\(partitionType)")
    }

    func mount(disk: PhysicalDisk, partitionType: UInt32, password: [UInt8]) throws {
        let runtimeStatus = try EDPTransportRuntimePolicy.verifySelectedRuntime(
            requireFinderHidden: true
        )
        let sessionKey = key(disk, partitionType)
        guard sessions[sessionKey] == nil else { return }
        let suffix = safeName(disk.deviceID) + "-\(partitionType)"
        let bridgeMount = "/Volumes/.edp-block-\(suffix)"
        let identity = consoleIdentity()
        if EDPNativeMountTable.isMountpoint(bridgeMount) {
            try? EDPNativeMountTable.unmountPath(bridgeMount)
            if EDPNativeMountTable.isMountpoint(bridgeMount) {
                try EDPNativeMountTable.unmountPath(bridgeMount, force: true)
            }
        }
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

        let volumeName = "EDP \(partitionType == 1 ? "Boot" : (partitionType == 2 ? "Exchange" : "Secure")) Transport"
        let transportRequest = EDPTransportRequest(
            binaryRoot: binaryRoot,
            rawDevice: disk.rawPath,
            rawFD: 3,
            vid: disk.vidHex,
            pid: disk.pidHex,
            deviceSize: disk.sizeBytes,
            partitionType: partitionType,
            controlFD: 0,
            mountpoint: bridgeMount,
            volumeName: volumeName,
            readOnly: false
        )
        let launchSpec = try EDPTransportProvider.launchSpec(
            for: runtimeStatus.backend,
            request: transportRequest,
            requireFinderHidden: true
        )
        let passwordPipe = Pipe()
        let transportProcess = Process()
        configureConsoleProcess(
            transportProcess,
            binaryRoot: binaryRoot,
            identity: identity,
            executable: launchSpec.executable,
            arguments: launchSpec.arguments,
            rawDevice: disk.rawPath
        )
        transportProcess.standardInput = passwordPipe
        let logPath = sessionRoot + "/\(suffix).bridge.log"
        try FileManager.default.createDirectory(atPath: sessionRoot, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let log = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        transportProcess.standardOutput = log
        transportProcess.standardError = log
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_LIBRARY_PATH"] = binaryRoot
        for (key, value) in launchSpec.environment {
            environment[key] = value
        }
        transportProcess.environment = environment
        try transportProcess.run()
        passwordPipe.fileHandleForWriting.write(Data(password))
        try passwordPipe.fileHandleForWriting.close()

        let transportSession = EDPTransportSession(
            backend: runtimeStatus.backend,
            mountpoint: bridgeMount,
            capabilities: launchSpec.capabilities,
            process: transportProcess
        )

        var publishedDevice: EDPPublishedBlockDevice?
        do {
            try waitUntil(seconds: 20) {
                EDPNativeMountTable.isMountpoint(bridgeMount) || !transportSession.isRunning
            }
            guard transportSession.isRunning, EDPNativeMountTable.isMountpoint(bridgeMount) else {
                throw fail("encrypted block bridge failed; see \(logPath)")
            }

            let decryptedVolume = bridgeMount + "/volume.raw"
            let published = try blockPublisher.publishWritableImage(at: decryptedVolume)
            publishedDevice = published
            let resolved = try resolveFilesystemDevice(published.bsdName)
            let mounted: (String, String?, Process?)
            switch resolved.magic {
            case "EXFAT":
                mounted = try mountExFAT(resolved.bsdName)
            case "NTFS":
                let mountpoint = try diskArbitration.mount(resolved.bsdName)
                mounted = (
                    EDPNativeMountTable.isReadOnly(mountpoint) == true
                        ? "NTFS (read-only; Finder erasable)"
                        : "NTFS",
                    mountpoint,
                    nil
                )
            case "FAT":
                mounted = ("FAT", try diskArbitration.mount(resolved.bsdName), nil)
            default:
                mounted = ("Unformatted or unsupported", nil, nil)
            }
            sessions[sessionKey] = MountSession(
                physicalBSD: disk.bsdName,
                deviceID: disk.deviceID,
                partitionType: partitionType,
                bridgeMount: bridgeMount,
                exposedBSD: published.bsdName,
                filesystem: mounted.0,
                userMount: mounted.1,
                transport: transportSession,
                filesystemProcess: mounted.2
            )
            persistSessions()
            NSLog("EDP mounted %@ partition %u as %@ at %@", disk.deviceID, partitionType, mounted.0, mounted.1 ?? "(unknown)")
        } catch {
            if let publishedDevice { try? blockPublisher.unpublish(publishedDevice) }
            try? transportSession.stop(
                unmount: { try EDPNativeMountTable.unmountPath($0, force: true) },
                isMounted: { EDPNativeMountTable.isMountpoint($0) }
            )
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

    @discardableResult
    func removeMissing(availableDisks: [String: String], graceSeconds: TimeInterval = 5) -> Bool {
        let now = Date()
        var pending = false
        for (key, session) in Array(sessions) {
            if availableDisks[session.deviceID] == session.physicalBSD {
                missingSince.removeValue(forKey: key)
                continue
            }
            if let since = missingSince[key], now.timeIntervalSince(since) >= graceSeconds {
                unmount(key: key)
            } else {
                missingSince[key] = missingSince[key] ?? now
                pending = true
            }
        }
        return pending
    }

    func unmountAll() {
        for key in Array(sessions.keys) { unmount(key: key) }
    }

    private func unmount(key: String) {
        guard let session = sessions[key] else { return }
        missingSince.removeValue(forKey: key)
        if let userMount = session.userMount {
            try? EDPNativeMountTable.unmountPath(userMount)
        }
        session.filesystemProcess?.terminate()
        if !session.exposedBSD.isEmpty {
            try? blockPublisher.unpublish(EDPPublishedBlockDevice(bsdName: session.exposedBSD))
        }
        do {
            try session.transport.stop(
                unmount: { try EDPNativeMountTable.unmountPath($0, force: true) },
                isMounted: { EDPNativeMountTable.isMountpoint($0) }
            )
        } catch {
            NSLog("EDP transport teardown failed for %@: %@", key, String(describing: error))
            persistSessions()
            return
        }
        sessions.removeValue(forKey: key)
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
    if String(bytes: bytes[54..<62], encoding: .ascii)?.hasPrefix("FAT") == true
        || String(bytes: bytes[82..<90], encoding: .ascii)?.hasPrefix("FAT") == true {
        return "FAT"
    }
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

private func verifyPartitionType(
    disk: PhysicalDisk,
    partitionType: UInt32,
    password: [UInt8]
) throws {
    guard [UInt32(2), 4].contains(partitionType) else {
        throw fail("password validation is only valid for partition 2 or 4")
    }
    guard try verifiedPartitionTypes(disk: disk, password: password).contains(partitionType) else {
        throw fail("password did not unlock partition \(partitionType)")
    }
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
    private let policies: EDPDevicePolicyStore
    private let manager: MountManager
    private let diskArbitration: EDPDiskArbitrationController
    private let queue = DispatchQueue(label: "com.edp.usbvault.controller")
    private var failedMounts = [String: String]()
    private var activities = [EDPXPCActivity]()
    private var missingCleanupScheduled = false

    init() throws {
        store = try makeCredentialStore()
        policies = try makePolicyStore()
        manager = try MountManager()
        diskArbitration = try EDPDiskArbitrationController()
        manager.recoverPersistedSessions()
    }

    private func key(_ deviceID: String, _ partitionType: UInt32) -> String {
        "\(deviceID):\(partitionType)"
    }

    private func addActivity(
        _ message: String,
        level: String = "info",
        deviceID: String? = nil,
        partitionType: UInt32? = nil
    ) {
        activities.insert(EDPXPCActivity(
            id: UUID(),
            timestamp: ISO8601DateFormatter().string(from: Date()),
            level: level,
            deviceID: deviceID,
            partitionType: partitionType,
            message: message
        ), at: 0)
        if activities.count > 200 { activities.removeLast(activities.count - 200) }
    }

    private func observe(_ disks: [PhysicalDisk]) throws {
        for disk in disks {
            _ = try policies.observe(
                deviceID: disk.deviceID,
                mediaName: disk.mediaName,
                vidPID: "\(disk.vidHex):\(disk.pidHex)",
                sizeBytes: disk.sizeBytes
            )
        }
    }

    private func setBootMounted(_ mounted: Bool, disk: PhysicalDisk) throws {
        if mounted {
            if !manager.contains(disk, EDPPartitionKind.boot.rawValue) {
                try manager.mount(
                    disk: disk,
                    partitionType: EDPPartitionKind.boot.rawValue,
                    password: []
                )
            }
        } else {
            manager.unmount(
                deviceID: disk.deviceID,
                partitionType: EDPPartitionKind.boot.rawValue
            )
        }
    }

    private func restoreBootPolicy(disk: PhysicalDisk) {
        guard let document = try? policies.load(),
              document.globalAutoMountEnabled,
              let policy = document.devices.first(where: { $0.deviceID == disk.deviceID }),
              policy.policy(for: EDPPartitionKind.boot.rawValue).autoMount else { return }
        try? setBootMounted(true, disk: disk)
    }

    func reconcile() {
        queue.async { [weak self] in self?.reconcileLocked() }
    }

    private func reconcileLocked() {
        autoreleasepool {
            do {
                let disks = try discoverEDPDisks()
                let availableDisks = Dictionary(
                    uniqueKeysWithValues: disks.map { ($0.deviceID, $0.bsdName) }
                )
                if manager.removeMissing(availableDisks: availableDisks),
                   !missingCleanupScheduled {
                    missingCleanupScheduled = true
                    queue.asyncAfter(deadline: .now() + 6) { [weak self] in
                        guard let self else { return }
                        self.missingCleanupScheduled = false
                        self.reconcileLocked()
                    }
                }
                let connectedDeviceIDs = Set(disks.map(\.deviceID))
                failedMounts = failedMounts.filter { item in
                    guard let separator = item.key.lastIndex(of: ":") else { return false }
                    return connectedDeviceIDs.contains(String(item.key[..<separator]))
                }
                try observe(disks)
                let policyDocument = try policies.load()
                let records = try store.load().records
                for disk in disks {
                    guard let devicePolicy = policyDocument.devices.first(
                        where: { $0.deviceID == disk.deviceID }
                    ) else { continue }
                    let bootAutoMount = devicePolicy.policy(
                        for: EDPPartitionKind.boot.rawValue
                    ).autoMount
                    if policyDocument.globalAutoMountEnabled, bootAutoMount {
                        try? setBootMounted(true, disk: disk)
                    } else if !bootAutoMount {
                        try? setBootMounted(false, disk: disk)
                    }
                    guard policyDocument.globalAutoMountEnabled,
                          let record = records.first(where: { $0.deviceID == disk.deviceID }) else {
                        continue
                    }
                    for type in [UInt32(2), 4]
                    where devicePolicy.policy(for: type).autoMount
                        && record.partitionTypes.contains(type)
                        && !manager.contains(disk, type) {
                        let key = "\(disk.deviceID):\(type)"
                        if failedMounts[key] != nil { continue }
                        do {
                            var password = try store.password(
                                deviceID: disk.deviceID,
                                partitionType: type
                            )
                            defer { secureZero(&password) }
                            try manager.mount(
                                disk: disk,
                                partitionType: type,
                                password: password
                            )
                            failedMounts.removeValue(forKey: key)
                            restoreBootPolicy(disk: disk)
                            addActivity(
                                "自动挂载成功",
                                deviceID: disk.deviceID,
                                partitionType: type
                            )
                        } catch {
                            NSLog("EDP auto-mount failed for %@ type %u; automatic retry paused until explicit user action or device reconnect: %@", disk.deviceID, type, String(describing: error))
                            failedMounts[key] = String(describing: error)
                            addActivity(
                                "自动挂载失败：\(error)",
                                level: "error",
                                deviceID: disk.deviceID,
                                partitionType: type
                            )
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
                try observe(disks)
                let records = try store.load().records
                let policyDocument = try policies.load()
                let connectedByID = Dictionary(uniqueKeysWithValues: disks.map { ($0.deviceID, $0) })
                let deviceIDs = Set(policyDocument.devices.map(\.deviceID))
                    .union(records.map(\.deviceID))
                    .union(disks.map(\.deviceID))
                let devices = deviceIDs.sorted().map { deviceID in
                    let disk = connectedByID[deviceID]
                    let record = records.first { $0.deviceID == deviceID }
                    let policy = policyDocument.devices.first { $0.deviceID == deviceID }
                    let partitions = EDPPartitionKind.allCases.map { kind -> EDPXPCPartition in
                        let summary = manager.summary(deviceID: deviceID, partitionType: kind.rawValue)
                        let mountpoint = summary?["mountpoint"]
                        let isMounted = mountpoint?.isEmpty == false || summary != nil
                        let credentialStatus: EDPCredentialStatus = kind.isEncrypted
                            ? (record?.partitionTypes.contains(kind.rawValue) == true ? .saved : .missing)
                            : .notRequired
                        return EDPXPCPartition(
                            partitionType: kind.rawValue,
                            displayName: kind.displayName,
                            encrypted: kind.isEncrypted,
                            autoMount: policy?.policy(for: kind.rawValue).autoMount ?? (kind == .boot),
                            credentialStatus: credentialStatus,
                            mountState: disk == nil ? .unavailable : (isMounted ? .mounted : .unmounted),
                            filesystem: summary?["filesystem"],
                            readOnly: mountpoint.flatMap { EDPNativeMountTable.isReadOnly($0) },
                            mountPoint: mountpoint,
                            lastError: failedMounts[key(deviceID, kind.rawValue)]
                        )
                    }
                    return EDPXPCDevice(
                        deviceID: deviceID,
                        bsdName: disk?.bsdName ?? "",
                        mediaName: disk?.mediaName ?? policy?.lastMediaName ?? "EDP USB",
                        displayName: policy?.displayName ?? disk?.mediaName ?? "EDP USB",
                        vidPID: disk.map { "\($0.vidHex):\($0.pidHex)" }
                            ?? policy?.lastVIDPID ?? "-",
                        sizeBytes: disk?.sizeBytes ?? policy?.lastSizeBytes ?? 0,
                        connected: disk != nil,
                        privilegedAccessReady: disk != nil,
                        partitions: partitions
                    )
                }
                return try JSONEncoder().encode(EDPXPCSnapshot(
                    devices: devices,
                    activities: activities,
                    serviceVersion: "0.6.0",
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    globalAutoMountEnabled: policyDocument.globalAutoMountEnabled
                ))
            } catch {
                return Data("{\"error\":\"\(String(describing: error).replacingOccurrences(of: "\"", with: "'"))\"}".utf8)
            }
        }
    }

    func saveCredential(
        deviceID: String,
        partitionType: UInt32,
        passwordData: Data
    ) throws {
        var password = [UInt8](passwordData)
        defer { secureZero(&password) }
        try queue.sync {
            guard let disk = try discoverEDPDisks().first(where: { $0.deviceID == deviceID }) else {
                throw fail("EDP device is no longer connected")
            }
            try verifyPartitionType(
                disk: disk,
                partitionType: partitionType,
                password: password
            )
            try store.put(
                deviceID: deviceID,
                partitionType: partitionType,
                password: password
            )
            failedMounts.removeValue(forKey: key(deviceID, partitionType))
            addActivity("密码验证并保存成功", deviceID: deviceID, partitionType: partitionType)
        }
        reconcile()
    }

    func mountPartition(deviceID: String, partitionType: UInt32) throws {
        try queue.sync {
            failedMounts.removeValue(forKey: key(deviceID, partitionType))
            guard let disk = try discoverEDPDisks().first(where: { $0.deviceID == deviceID }) else {
                throw fail("EDP device is no longer connected")
            }
            if partitionType == EDPPartitionKind.boot.rawValue {
                try setBootMounted(true, disk: disk)
            } else {
                try mountEncryptedPartitionLocked(disk: disk, partitionType: partitionType)
                restoreBootPolicy(disk: disk)
            }
            addActivity("手动挂载成功", deviceID: deviceID, partitionType: partitionType)
        }
    }

    private func mountEncryptedPartitionLocked(disk: PhysicalDisk, partitionType: UInt32) throws {
        guard [UInt32(2), 4].contains(partitionType) else {
            throw fail("unsupported encrypted partition type")
        }
        guard !manager.contains(disk, partitionType) else { return }
        var password = try store.password(
            deviceID: disk.deviceID,
            partitionType: partitionType
        )
        defer { secureZero(&password) }
        do {
            try manager.mount(
                disk: disk,
                partitionType: partitionType,
                password: password
            )
        } catch {
            failedMounts[key(disk.deviceID, partitionType)] = String(describing: error)
            throw error
        }
    }

    func unmountPartition(deviceID: String, partitionType: UInt32) throws {
        try queue.sync {
            if partitionType == EDPPartitionKind.boot.rawValue {
                guard let disk = try discoverEDPDisks().first(where: { $0.deviceID == deviceID }) else {
                    throw fail("EDP device is no longer connected")
                }
                try setBootMounted(false, disk: disk)
            } else {
                manager.unmount(deviceID: deviceID, partitionType: partitionType)
            }
            addActivity("分区已卸载", deviceID: deviceID, partitionType: partitionType)
        }
    }

    func deleteCredential(deviceID: String, partitionType: UInt32) throws {
        try queue.sync {
            manager.unmount(deviceID: deviceID, partitionType: partitionType)
            try store.remove(deviceID: deviceID, partitionType: partitionType)
            failedMounts.removeValue(forKey: key(deviceID, partitionType))
            addActivity("已删除保存的密码", deviceID: deviceID, partitionType: partitionType)
        }
    }

    func setPartitionAutoMount(deviceID: String, partitionType: UInt32, enabled: Bool) throws {
        try queue.sync {
            try policies.setAutoMount(
                deviceID: deviceID,
                partitionType: partitionType,
                enabled: enabled
            )
            addActivity(
                enabled ? "已开启自动挂载" : "已关闭自动挂载",
                deviceID: deviceID,
                partitionType: partitionType
            )
        }
        if enabled { reconcile() }
    }

    func setDeviceDisplayName(deviceID: String, displayName: String) throws {
        try queue.sync { try policies.setDisplayName(deviceID: deviceID, displayName: displayName) }
    }

    func setGlobalAutoMount(_ enabled: Bool) throws {
        try queue.sync {
            try policies.setGlobalAutoMount(enabled)
            addActivity(enabled ? "已恢复全局自动挂载" : "已暂停全局自动挂载")
        }
        if enabled { reconcile() }
    }

    func eject(deviceID: String) throws {
        try queue.sync {
            guard let disk = try discoverEDPDisks().first(where: { $0.deviceID == deviceID }) else {
                throw fail("EDP device is no longer connected")
            }
            manager.eject(deviceID: deviceID)
            try diskArbitration.eject(disk.bsdName)
            addActivity("设备已安全推出", deviceID: deviceID)
        }
    }

    func diagnosticsData() -> Data {
        queue.sync {
            let payload: [String: Any] = [
                "mounts": manager.mountedSummaries(),
                "failedMounts": failedMounts,
                "rawAccessMode": "privileged inherited file descriptor",
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

    func saveCredential(
        deviceID: String,
        partitionType: UInt32,
        password: Data,
        withReply reply: @escaping (String?) -> Void
    ) {
        do {
            try controller.saveCredential(
                deviceID: deviceID,
                partitionType: partitionType,
                passwordData: password
            )
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func deleteCredential(
        deviceID: String,
        partitionType: UInt32,
        withReply reply: @escaping (String?) -> Void
    ) {
        do {
            try controller.deleteCredential(deviceID: deviceID, partitionType: partitionType)
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func setPartitionAutoMount(
        deviceID: String,
        partitionType: UInt32,
        enabled: Bool,
        withReply reply: @escaping (String?) -> Void
    ) {
        do {
            try controller.setPartitionAutoMount(
                deviceID: deviceID,
                partitionType: partitionType,
                enabled: enabled
            )
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func setDeviceDisplayName(
        deviceID: String,
        displayName: String,
        withReply reply: @escaping (String?) -> Void
    ) {
        do {
            try controller.setDeviceDisplayName(deviceID: deviceID, displayName: displayName)
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func setGlobalAutoMount(enabled: Bool, withReply reply: @escaping (String?) -> Void) {
        do {
            try controller.setGlobalAutoMount(enabled)
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func mountPartition(
        deviceID: String,
        partitionType: UInt32,
        withReply reply: @escaping (String?) -> Void
    ) {
        do {
            try controller.mountPartition(deviceID: deviceID, partitionType: partitionType)
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func unmountPartition(
        deviceID: String,
        partitionType: UInt32,
        withReply reply: @escaping (String?) -> Void
    ) {
        do {
            try controller.unmountPartition(deviceID: deviceID, partitionType: partitionType)
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func eject(deviceID: String, withReply reply: @escaping (String?) -> Void) {
        do {
            try controller.eject(deviceID: deviceID)
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
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
    let runtimeStatus = try? EDPTransportRuntimePolicy.verifySelectedRuntime(
        requireFinderHidden: true
    )
    print("TRANSPORT_RUNTIME=\(runtimeStatus?.runtimeDescription ?? "MISSING_OR_UNSUPPORTED")")
    print("TRANSPORT_BACKEND=\(runtimeStatus?.backend.rawValue ?? "unavailable")")
    ok = ok && runtimeStatus != nil
    let binaryRoot = runtimeBinaryRoot()
    let transportBackend = runtimeStatus?.backend ?? .macFUSELocal
    let transportTool = EDPTransportProvider.executableName(
        for: transportBackend,
        readOnly: false
    )
    for tool in [transportTool, "edp-console-exec", "edp-raw-metadata", "diskimages2-attach"] {
        let path = binaryRoot + "/" + tool
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

    After passwords are verified and saved, the privileged launch daemon
    automatically mounts configured EDP partitions when the USB disk appears.
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
