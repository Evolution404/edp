import Darwin
import Foundation
import Security

private let dataRoot = "/var/db/com.edp.drive"
private let legacyDataRoot = "/var/db/com.edp.usbvault"
private let sessionRoot = dataRoot + "/sessions"
private let credentialIndexPath = dataRoot + "/credential-index.json"
private let policyPath = dataRoot + "/device-policies.json"
private let legacyCredentialPath = legacyDataRoot + "/credentials.json"
private let legacyMasterKeyPath = legacyDataRoot + "/master.key"

private enum RuntimeError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let value): return value
        }
    }
}

private func fail(_ message: String) -> RuntimeError { .message(message) }

private func migrateLegacyRuntimeState() throws {
    try FileManager.default.createDirectory(
        atPath: dataRoot,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: mode_t(0o700))]
    )
    guard chmod(dataRoot, 0o700) == 0 else {
        throw fail("failed to secure EDP Drive state root: errno=\(errno)")
    }
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    let oldCredentialIndex = legacyDataRoot + "/credential-index.json"
    if FileManager.default.fileExists(atPath: oldCredentialIndex) {
        let legacy = try decoder.decode(
            EDPCredentialIndex.self,
            from: Data(contentsOf: URL(fileURLWithPath: oldCredentialIndex))
        )
        var merged = FileManager.default.fileExists(atPath: credentialIndexPath)
            ? try decoder.decode(
                EDPCredentialIndex.self,
                from: Data(contentsOf: URL(fileURLWithPath: credentialIndexPath))
            )
            : EDPCredentialIndex()
        for record in legacy.records {
            if let index = merged.records.firstIndex(where: { $0.deviceID == record.deviceID }) {
                let types = Set(merged.records[index].partitionTypes)
                    .union(record.partitionTypes).sorted()
                merged.records[index] = EDPCredentialRecord(
                    deviceID: record.deviceID,
                    partitionTypes: types,
                    updatedAt: merged.records[index].updatedAt
                )
            } else {
                merged.records.append(record)
            }
        }
        merged.records.sort { $0.deviceID < $1.deviceID }
        try atomicWrite(try encoder.encode(merged), to: credentialIndexPath, mode: 0o600)
    }

    let oldPolicyPath = legacyDataRoot + "/device-policies.json"
    if FileManager.default.fileExists(atPath: oldPolicyPath) {
        let legacy = try decoder.decode(
            EDPPolicyDocument.self,
            from: Data(contentsOf: URL(fileURLWithPath: oldPolicyPath))
        )
        let hasNewPolicy = FileManager.default.fileExists(atPath: policyPath)
        var merged = hasNewPolicy
            ? try decoder.decode(
                EDPPolicyDocument.self,
                from: Data(contentsOf: URL(fileURLWithPath: policyPath))
            )
            : legacy
        if hasNewPolicy {
            for device in legacy.devices
                where !merged.devices.contains(where: { $0.deviceID == device.deviceID }) {
                merged.devices.append(device)
            }
            merged.devices.sort { $0.deviceID < $1.deviceID }
        }
        try atomicWrite(try encoder.encode(merged), to: policyPath, mode: 0o600)
    }

    let oldSessionsPath = legacyDataRoot + "/sessions.json"
    let newSessionsPath = dataRoot + "/sessions.json"
    if FileManager.default.fileExists(atPath: oldSessionsPath),
       !FileManager.default.fileExists(atPath: newSessionsPath) {
        let data = try Data(contentsOf: URL(fileURLWithPath: oldSessionsPath))
        _ = try JSONSerialization.jsonObject(with: data)
        try atomicWrite(data, to: newSessionsPath, mode: 0o644)
    }
}

private func finalizeLegacyRuntimeStateMigration() {
    for name in ["credential-index.json", "device-policies.json", "sessions.json"] {
        let oldPath = legacyDataRoot + "/" + name
        let newPath = dataRoot + "/" + name
        guard FileManager.default.fileExists(atPath: newPath) else { continue }
        try? FileManager.default.removeItem(atPath: oldPath)
    }
    try? FileManager.default.removeItem(atPath: legacyDataRoot)
}

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
    input: Data? = nil,
    accepted: Set<Int32> = [0]
) throws -> CommandResult {
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = errors
    let inputPipe = input == nil ? nil : Pipe()
    if let inputPipe { process.standardInput = inputPipe }
    if let environment { process.environment = environment }
    try process.run()
    if let input, let inputPipe {
        inputPipe.fileHandleForWriting.write(input)
        try inputPipe.fileHandleForWriting.close()
    }
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
    let lba0: Data
    let lba4: Data
    let lba7: Data
    let lba11: Data
    let lba12: Data
}

private final class EDPRawAccessLease: @unchecked Sendable {
    let deviceID: String
    let registryEntryID: UInt64
    let rawPath: String
    private(set) var fd: Int32

    init(deviceID: String, registryEntryID: UInt64, rawPath: String, fd: Int32) {
        self.deviceID = deviceID
        self.registryEntryID = registryEntryID
        self.rawPath = rawPath
        self.fd = fd
    }

    func invalidate() {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
    }

    deinit {
        invalidate()
    }
}

private func preadExact(fd: Int32, offset: UInt64, length: Int) throws -> Data {
    guard offset <= UInt64(Int64.max) else { throw fail("raw read offset exceeds off_t") }
    var data = Data(count: length)
    try data.withUnsafeMutableBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        var completed = 0
        while completed < length {
            let result = Darwin.pread(
                fd,
                base.advanced(by: completed),
                length - completed,
                off_t(offset + UInt64(completed))
            )
            if result < 0 {
                if errno == EINTR { continue }
                throw fail("raw pread failed: errno=\(errno)")
            }
            guard result > 0 else { throw fail("raw pread reached EOF") }
            completed += result
        }
    }
    return data
}

private func rawMetadataSnapshot(fd: Int32) throws -> EDPRawMetadataSnapshot {
    guard fd >= 0 else { throw fail("EDP raw access lease is closed") }
    let sector = Int(EDPMetadataProbe.legacySectorByteLength)
    return EDPRawMetadataSnapshot(
        lba0: try preadExact(fd: fd, offset: 0, length: sector),
        lba4: try preadExact(fd: fd, offset: EDPMetadataProbe.lba4ByteOffset, length: sector),
        lba7: try preadExact(fd: fd, offset: EDPMetadataProbe.lba7ByteOffset, length: sector),
        lba11: try preadExact(fd: fd, offset: EDPVolumeMetadata.lba11ByteOffset, length: sector),
        lba12: try preadExact(fd: fd, offset: EDPVolumeMetadata.lba12ByteOffset, length: sector)
    )
}

private func wholeUSBMediaStillMatches(_ disk: PhysicalDisk) throws -> Bool {
    try EDPNativeDeviceDiscovery.allWholeUSBMedia().contains {
        $0.bsdName == disk.bsdName
            && $0.size == disk.sizeBytes
            && $0.vid == disk.vidHex
            && $0.pid == disk.pidHex
            && $0.registryEntryID == disk.registryEntryID
            && $0.usbRegistryEntryID == disk.usbRegistryEntryID
    }
}

private func openPersistentRawAccess(for disk: PhysicalDisk) throws -> EDPRawAccessLease {
    guard geteuid() == 0, try wholeUSBMediaStillMatches(disk) else {
        throw fail("EDP_RAW_LEASE_TARGET_REFUSED")
    }
    var before = stat()
    guard lstat(disk.rawPath, &before) == 0, (before.st_mode & S_IFMT) == S_IFCHR else {
        throw fail("EDP_RAW_LEASE_PATH_REFUSED")
    }

    let fd = Darwin.open(disk.rawPath, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else {
        throw fail("EDP_RAW_LEASE_OPEN_FAILED:\(errno)")
    }
    do {
        var opened = stat()
        var after = stat()
        guard fstat(fd, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFCHR,
              lstat(disk.rawPath, &after) == 0,
              (after.st_mode & S_IFMT) == S_IFCHR,
              opened.st_rdev == before.st_rdev,
              opened.st_rdev == after.st_rdev,
              try wholeUSBMediaStillMatches(disk) else {
            throw fail("EDP_RAW_LEASE_TYPE_REFUSED")
        }

        let metadata = try rawMetadataSnapshot(fd: fd)
        guard let metadataDeviceID = EDPVolumeMetadata.deviceIDFromLBA11(
                  [UInt8](metadata.lba11),
                  vidHex: disk.vidHex,
                  pidHex: disk.pidHex,
                  sizeBytes: disk.sizeBytes
              ),
              let lba12Plain = try? EDPVolumeMetadata.decodeLBA12(
                  [UInt8](metadata.lba12),
                  deviceID: metadataDeviceID
              ),
              EDPMetadataProbe.classifyMedia(
                  lba0: [UInt8](metadata.lba0),
                  lba4: [UInt8](metadata.lba4),
                  lba7: [UInt8](metadata.lba7),
                  lba12Plain: lba12Plain,
                  hasLBA11Identity: true
              ) == .standardEncrypted,
              EDPVolumeMetadata.stablePhysicalDeviceID(
                  metadataDeviceID: metadataDeviceID,
                  vidHex: disk.vidHex,
                  pidHex: disk.pidHex,
                  sizeBytes: disk.sizeBytes
              ) == disk.deviceID else {
            throw fail("EDP_RAW_LEASE_METADATA_REFUSED")
        }
        return EDPRawAccessLease(
            deviceID: disk.deviceID,
            registryEntryID: disk.registryEntryID,
            rawPath: disk.rawPath,
            fd: fd
        )
    } catch {
        close(fd)
        throw error
    }
}

private func runtimeBinaryRoot() -> String {
    if let configuredRoot = ProcessInfo.processInfo.environment["EDP_RUNTIME_BIN_ROOT"], !configuredRoot.isEmpty {
        return configuredRoot
    }
    return URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath().deletingLastPathComponent().path
}

private let defaultRawAccessDaemonPath =
    "/Applications/EDP Drive.app/Contents/Library/LaunchServices/edp-drive-service"

private func rawAccessDaemonPath() -> String {
    if let override = ProcessInfo.processInfo.environment["EDP_RAW_ACCESS_DAEMON"],
       !override.isEmpty {
        return override
    }
    return defaultRawAccessDaemonPath
}

private func installedProductVersion() -> String {
    if let override = ProcessInfo.processInfo.environment["EDP_SERVICE_VERSION"],
       !override.isEmpty {
        return override
    }
    if let bundle = Bundle(path: "/Applications/EDP Drive.app"),
       let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
       !version.isEmpty {
        return version
    }
    return "development"
}

private func isRawAccessPermissionFailure(_ error: Error) -> Bool {
    let detail = String(describing: error)
    return detail.contains("EDP_RAW_BROKER_OPEN_FAILED:1")
        || detail.contains("EDP_RAW_LEASE_OPEN_FAILED:1")
        || detail.contains("Operation not permitted")
        || detail.contains("操作不被允许")
}

private func userFacingRawAccessError(_ error: Error) -> Error {
    guard isRawAccessPermissionFailure(error) else { return error }
    return fail(
        "需要为“EDP Drive 磁盘访问”开启完全磁盘访问："
            + "系统设置 → 隐私与安全性 → 完全磁盘访问"
    )
}

private func rawMetadataSnapshot(for rawPath: String) throws -> EDPRawMetadataSnapshot {
    let uid = try consoleIdentity().0
    let result = try run(
        runtimeBinaryRoot() + "/edp-raw-metadata",
        [rawPath, String(uid)]
    )
    return try decodeRawMetadataOutput(result.stdout)
}

private func decodeRawMetadataOutput(_ output: Data) throws -> EDPRawMetadataSnapshot {
    let sector = Int(EDPMetadataProbe.legacySectorByteLength)
    guard output.count == sector * 5 else {
        throw fail("raw metadata helper returned \(output.count) bytes; expected \(sector * 5)")
    }
    func slice(_ index: Int) -> Data {
        let start = index * sector
        return output.subdata(in: start..<(start + sector))
    }
    return EDPRawMetadataSnapshot(
        lba0: slice(0),
        lba4: slice(1),
        lba7: slice(2),
        lba11: slice(3),
        lba12: slice(4)
    )
}

private func discoverEDPDisks(
    cachedDisks: [PhysicalDisk] = [],
    diagnostic: ((String) -> Void)? = nil
) throws -> [PhysicalDisk] {
    var answer: [PhysicalDisk] = []
    for media in try EDPNativeDeviceDiscovery.allWholeUSBMedia() {
        let rawPath = "/dev/r\(media.bsdName)"
        guard FileManager.default.fileExists(atPath: rawPath) else {
            diagnostic?("bsd=\(media.bsdName);result=raw_device_missing;path=\(rawPath)")
            continue
        }
        if let cached = cachedDisks.first(where: {
            $0.rawPath == rawPath
                && $0.sizeBytes == media.size
                && $0.vidHex == media.vid
                && $0.pidHex == media.pid
                && $0.registryEntryID == media.registryEntryID
                && $0.usbRegistryEntryID == media.usbRegistryEntryID
        }) {
            diagnostic?("bsd=\(media.bsdName);result=recognized_cached;deviceID=\(cached.deviceID)")
            answer.append(cached)
            continue
        }
        let metadata: EDPRawMetadataSnapshot
        do {
            metadata = try rawMetadataSnapshot(for: rawPath)
        } catch {
            let detail = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
            diagnostic?("bsd=\(media.bsdName);result=raw_metadata_failed;error=\(detail)")
            NSLog("EDP discovery skipped %@ because raw metadata read failed: %@", media.bsdName, detail)
            continue
        }
        let metadataDeviceID = EDPVolumeMetadata.deviceIDFromLBA11(
            [UInt8](metadata.lba11),
            vidHex: media.vid,
            pidHex: media.pid,
            sizeBytes: media.size
        )
        let lba12Plain = metadataDeviceID.flatMap { deviceID in
            try? EDPVolumeMetadata.decodeLBA12(
                [UInt8](metadata.lba12),
                deviceID: deviceID
            )
        }
        let mediaKind = EDPMetadataProbe.classifyMedia(
            lba0: [UInt8](metadata.lba0),
            lba4: [UInt8](metadata.lba4),
            lba7: [UInt8](metadata.lba7),
            lba12Plain: lba12Plain,
            hasLBA11Identity: metadataDeviceID != nil
        )
        diagnostic?("bsd=\(media.bsdName);classification=\(mediaKind.rawValue)")
        guard mediaKind == .standardEncrypted else {
            // No-password conversions, malformed EDP media and ordinary USB
            // storage remain entirely under macOS/Disk Arbitration ownership.
            continue
        }
        guard let metadataDeviceID else {
            diagnostic?("bsd=\(media.bsdName);result=device_id_invalid")
            continue
        }
        let deviceID = EDPVolumeMetadata.stablePhysicalDeviceID(
            metadataDeviceID: metadataDeviceID,
            vidHex: media.vid,
            pidHex: media.pid,
            sizeBytes: media.size
        )
        diagnostic?("bsd=\(media.bsdName);result=recognized;deviceID=\(deviceID)")
        answer.append(PhysicalDisk(
            bsdName: media.bsdName,
            rawPath: rawPath,
            sizeBytes: media.size,
            mediaName: media.mediaName,
            vidHex: media.vid,
            pidHex: media.pid,
            registryEntryID: media.registryEntryID,
            usbRegistryEntryID: media.usbRegistryEntryID,
            metadataDeviceID: metadataDeviceID,
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

private func consoleIdentity() throws -> (uid_t, gid_t) {
    var status = stat()
    guard stat("/dev/console", &status) == 0,
          status.st_uid != 0,
          getpwuid(status.st_uid) != nil else {
        throw fail("no authenticated console user is available")
    }
    return (status.st_uid, status.st_gid)
}

private final class EDPSpawnedProcess: EDPManagedProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t
    private var reaped = false

    init(pid: pid_t) {
        self.pid = pid
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        if reaped { return false }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == 0 { return true }
        if result == pid || (result < 0 && errno == ECHILD) {
            reaped = true
            return false
        }
        return true
    }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        guard !reaped else { return }
        _ = kill(pid, SIGTERM)
    }
}

private func withMutableCStringArray<R>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> R
) rethrows -> R {
    let pointers = strings.map { strdup($0) }
    defer { pointers.forEach { free($0) } }
    var values = pointers + [nil]
    return try values.withUnsafeMutableBufferPointer { buffer in
        try body(buffer.baseAddress!)
    }
}

private func spawnConsoleTransport(
    binaryRoot: String,
    identity: (uid_t, gid_t),
    executable: String,
    arguments: [String],
    environment: [String: String],
    rawFD: Int32,
    stdinFD: Int32,
    logFD: Int32
) throws -> EDPSpawnedProcess {
    let launcher = binaryRoot + "/edp-console-exec"
    let argv = [launcher, String(identity.0), String(identity.1), "--", executable] + arguments
    let env = environment.map { "\($0.key)=\($0.value)" }

    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else {
        throw fail("posix_spawn_file_actions_init failed")
    }
    defer { posix_spawn_file_actions_destroy(&actions) }
    for (source, destination) in [(stdinFD, STDIN_FILENO), (logFD, STDOUT_FILENO), (logFD, STDERR_FILENO), (rawFD, 3)] {
        let rc = posix_spawn_file_actions_adddup2(&actions, source, destination)
        guard rc == 0 else { throw fail("posix_spawn dup2 failed: \(rc)") }
    }

    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else {
        throw fail("posix_spawnattr_init failed")
    }
    defer { posix_spawnattr_destroy(&attributes) }
    let flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
    guard posix_spawnattr_setflags(&attributes, flags) == 0 else {
        throw fail("posix_spawnattr_setflags failed")
    }

    var child: pid_t = 0
    let status = launcher.withCString { executablePath in
        withMutableCStringArray(argv) { argvPointer in
            withMutableCStringArray(env) { envPointer in
                posix_spawn(&child, executablePath, &actions, &attributes, argvPointer, envPointer)
            }
        }
    }
    guard status == 0 else {
        throw fail("posix_spawn transport failed: \(status) \(String(cString: strerror(status)))")
    }
    return EDPSpawnedProcess(pid: child)
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

    func mount(
        disk: PhysicalDisk,
        partitionType: UInt32,
        password: [UInt8],
        rawFD: Int32
    ) throws {
        let runtimeStatus = try EDPTransportRuntimePolicy.verifySelectedRuntime(
            requireFinderHidden: true
        )
        let sessionKey = key(disk, partitionType)
        guard sessions[sessionKey] == nil else { return }
        let suffix = safeName(disk.deviceID) + "-\(partitionType)"
        let bridgeMount = "/Volumes/.edp-block-\(suffix)"
        let identity = try consoleIdentity()
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
            throw fail("cannot assign block-transport mountpoint to console user: errno=\(errno)")
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
        let macFUSEScratchBaseline = runtimeStatus.backend == .macFUSELocal
            ? EDPMacFUSEScratchImageCleanup.captureBaseline()
            : nil
        let passwordPipe = Pipe()
        let logPath = sessionRoot + "/\(suffix).bridge.log"
        try FileManager.default.createDirectory(atPath: sessionRoot, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let log = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_LIBRARY_PATH"] = binaryRoot
        for (key, value) in launchSpec.environment {
            environment[key] = value
        }
        let transportProcess = try spawnConsoleTransport(
            binaryRoot: binaryRoot,
            identity: identity,
            executable: launchSpec.executable,
            arguments: launchSpec.arguments,
            environment: environment,
            rawFD: rawFD,
            stdinFD: passwordPipe.fileHandleForReading.fileDescriptor,
            logFD: log.fileDescriptor
        )
        try passwordPipe.fileHandleForReading.close()
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
                try? log.synchronize()
                let detail = FileManager.default.contents(atPath: logPath).flatMap { data -> String? in
                    let tail = data.suffix(4096)
                    return String(data: tail, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                throw fail(
                    "encrypted block bridge failed"
                        + (detail?.isEmpty == false ? ": \(detail!)" : "; see \(logPath)")
                )
            }

            let decryptedVolume = bridgeMount + "/volume.raw"
            let published = try blockPublisher.publishWritableImage(at: decryptedVolume)
            publishedDevice = published
            let resolved = try resolveFilesystemDevice(published.bsdName)
            if ["EXFAT", "NTFS", "FAT"].contains(resolved.magic) {
                try prepareFinderDefaults(
                    bsd: resolved.bsdName,
                    sessionSuffix: suffix,
                    owner: identity
                )
            }
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
            if runtimeStatus.backend == .macFUSELocal {
                EDPMacFUSEScratchImageCleanup.cleanupNewOrphans(since: macFUSEScratchBaseline)
            }
            try? FileManager.default.removeItem(atPath: bridgeMount)
            throw error
        }
    }

    private func prepareFinderDefaults(
        bsd: String,
        sessionSuffix: String,
        owner: (uid_t, gid_t)
    ) throws {
        let safeSuffix = String(sessionSuffix.prefix(48))
        let stagingMount = "/private/tmp/.edp-finder-seed-\(safeSuffix)-\(UUID().uuidString)"
        do {
            try FileManager.default.createDirectory(
                atPath: stagingMount,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: mode_t(0o700))]
            )
        } catch {
            NSLog(
                "EDP could not create Finder staging mount for %@; continuing without defaults: %@",
                bsd,
                String(describing: error)
            )
            return
        }
        defer { try? FileManager.default.removeItem(atPath: stagingMount) }

        do {
            _ = try diskArbitration.mountNobrowse(bsd, at: stagingMount)
        } catch {
            NSLog(
                "EDP could not stage %@ with nobrowse; continuing with normal mount: %@",
                bsd,
                String(describing: error)
            )
            return
        }

        do {
            if try EDPFinderVolumeDefaults.seedIfMissing(at: stagingMount, owner: owner) {
                NSLog("EDP seeded Finder list/sidebar defaults on %@", bsd)
            }
        } catch {
            NSLog(
                "EDP could not seed Finder defaults on %@; preserving existing volume contents: %@",
                bsd,
                String(describing: error)
            )
        }

        do {
            try diskArbitration.unmount(bsd)
        } catch {
            try? diskArbitration.unmount(bsd)
            if EDPNativeMountTable.mountPoint(forBSD: bsd) != nil {
                throw error
            }
            NSLog("EDP Finder staging unmount for %@ recovered after retry", bsd)
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

private func verifiedPartitionTypes(
    disk: PhysicalDisk,
    password: [UInt8],
    rawFD: Int32? = nil
) throws -> [UInt32] {
    let metadata: EDPRawMetadataSnapshot
    if let rawFD {
        metadata = try rawMetadataSnapshot(fd: rawFD)
    } else {
        metadata = try rawMetadataSnapshot(for: disk.rawPath)
    }
    guard let metadataDeviceID = EDPVolumeMetadata.deviceIDFromLBA11(
        [UInt8](metadata.lba11),
        vidHex: disk.vidHex,
        pidHex: disk.pidHex,
        sizeBytes: disk.sizeBytes
    ), metadataDeviceID == disk.metadataDeviceID else {
        throw fail("EDP device identity changed during authorization")
    }
    let plain = try EDPVolumeMetadata.decodeLBA12(
        [UInt8](metadata.lba12),
        deviceID: metadataDeviceID
    )
    let volumes = try EDPVolumeMetadata.parseLBA12Entries(plain, password: password)
    let verified = volumes.map(\.partitionType).filter { $0 == 2 || $0 == 4 }
    guard !verified.isEmpty else { throw fail("password did not unlock EDP partition 2 or 4") }
    return Array(Set(verified)).sorted()
}

private func verifyPartitionType(
    disk: PhysicalDisk,
    partitionType: UInt32,
    password: [UInt8],
    rawFD: Int32? = nil
) throws {
    guard [UInt32(2), 4].contains(partitionType) else {
        throw fail("password validation is only valid for partition 2 or 4")
    }
    guard try verifiedPartitionTypes(
        disk: disk,
        password: password,
        rawFD: rawFD
    ).contains(partitionType) else {
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
    private let queue = DispatchQueue(label: "com.edp.drive.controller")
    private var failedMounts = [String: String]()
    private var manualUnmountSuppressions = Set<String>()
    private var activities = [EDPXPCActivity]()
    private var missingCleanupScheduled = false
    private var connectedDisks = [PhysicalDisk]()
    private var rawAccessLeases = [String: EDPRawAccessLease]()
    private var ejectingUSBRegistryIDs = [String: UInt64]()
    private var rawAccessReadyByDeviceID = [String: Bool]()
    private var rawAccessErrorsByDeviceID = [String: String]()
    private var lastDiscoveryDiagnostics = ["discovery_not_started"]
    private var discoveryScanCount: UInt64 = 0
    private var lastDiscoveryTimestamp = ""

    init() throws {
        try migrateLegacyRuntimeState()
        store = try makeCredentialStore()
        policies = try makePolicyStore()
        manager = try MountManager()
        diskArbitration = try EDPDiskArbitrationController()
        manager.recoverPersistedSessions()
        _ = try store.load()
        _ = try policies.load()
        finalizeLegacyRuntimeStateMigration()
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
            let document = try policies.load()
            if !document.devices.contains(where: { $0.deviceID == disk.deviceID }),
               let legacy = document.devices.first(where: {
                   $0.deviceID == disk.metadataDeviceID
                       && $0.lastVIDPID == "\(disk.vidHex):\(disk.pidHex)"
                       && $0.lastSizeBytes == disk.sizeBytes
               }) {
                do {
                    try store.migrateDeviceID(from: legacy.deviceID, to: disk.deviceID)
                } catch {
                    NSLog(
                        "EDP legacy credential could not be migrated from %@ to %@: %@",
                        legacy.deviceID,
                        disk.deviceID,
                        String(describing: error)
                    )
                }
                try policies.migrateDeviceID(from: legacy.deviceID, to: disk.deviceID)
            }
            _ = try policies.observe(
                deviceID: disk.deviceID,
                mediaName: disk.mediaName,
                vidPID: "\(disk.vidHex):\(disk.pidHex)",
                sizeBytes: disk.sizeBytes
            )
        }
    }

    private func rawAccessLeaseLocked(for disk: PhysicalDisk) -> EDPRawAccessLease? {
        guard let lease = rawAccessLeases[disk.deviceID],
              lease.registryEntryID == disk.registryEntryID,
              lease.rawPath == disk.rawPath else {
            return nil
        }
        return lease
    }

    private func rawAccessProbeLocked(for disk: PhysicalDisk, temporarilyUnmount: Bool) throws {
        if rawAccessLeaseLocked(for: disk) != nil {
            rawAccessReadyByDeviceID[disk.deviceID] = true
            rawAccessErrorsByDeviceID.removeValue(forKey: disk.deviceID)
            return
        }
        if temporarilyUnmount, EDPNativeMountTable.hasMountedBSDPrefix(disk.bsdName) {
            try diskArbitration.unmountWhole(disk.bsdName)
        }
        do {
            let lease = try openPersistentRawAccess(for: disk)
            rawAccessLeases[disk.deviceID] = lease
            rawAccessReadyByDeviceID[disk.deviceID] = true
            rawAccessErrorsByDeviceID.removeValue(forKey: disk.deviceID)
        } catch {
            rawAccessLeases.removeValue(forKey: disk.deviceID)
            rawAccessReadyByDeviceID[disk.deviceID] = false
            rawAccessErrorsByDeviceID[disk.deviceID] = String(describing: error)
            throw userFacingRawAccessError(error)
        }
    }

    private func requireRawAccessLeaseLocked(for disk: PhysicalDisk) throws -> EDPRawAccessLease {
        guard ejectingUSBRegistryIDs[disk.deviceID] == nil else {
            throw fail("EDP device was safely ejected; physically reinsert it before mounting")
        }
        if let lease = rawAccessLeaseLocked(for: disk) { return lease }
        try rawAccessProbeLocked(for: disk, temporarilyUnmount: true)
        guard let lease = rawAccessLeaseLocked(for: disk) else {
            throw fail("EDP raw access lease was not retained")
        }
        return lease
    }

    private func setBootMounted(_ mounted: Bool, disk: PhysicalDisk) throws {
        let partitionType = EDPPartitionKind.boot.rawValue
        if mounted {
            guard !manager.contains(disk, partitionType) else { return }
            let rawLease = try requireRawAccessLeaseLocked(for: disk)
            try manager.mount(
                disk: disk,
                partitionType: partitionType,
                password: [],
                rawFD: rawLease.fd
            )
        } else {
            manager.unmount(deviceID: disk.deviceID, partitionType: partitionType)
        }
    }

    private func restoreBootPolicy(disk: PhysicalDisk) {
        guard let document = try? policies.load(),
              document.globalAutoMountEnabled,
              let policy = document.devices.first(where: { $0.deviceID == disk.deviceID }),
              policy.policy(for: EDPPartitionKind.boot.rawValue).autoMount,
              !manualUnmountSuppressions.contains(
                  key(disk.deviceID, EDPPartitionKind.boot.rawValue)
              ) else { return }
        try? setBootMounted(true, disk: disk)
    }

    func reconcile() {
        queue.async { [weak self] in self?.reconcileLocked() }
    }

    private func reconcileLocked() {
        autoreleasepool {
            do {
                var scanDiagnostics = [String]()
                let disks = try discoverEDPDisks(
                    cachedDisks: connectedDisks,
                    diagnostic: { scanDiagnostics.append($0) }
                )
                discoveryScanCount &+= 1
                lastDiscoveryTimestamp = ISO8601DateFormatter().string(from: Date())
                lastDiscoveryDiagnostics = scanDiagnostics.isEmpty
                    ? ["no whole USB media scanned"]
                    : scanDiagnostics
                connectedDisks = disks
                let connectedDeviceIDs = Set(disks.map(\.deviceID))
                for (deviceID, usbRegistryEntryID) in ejectingUSBRegistryIDs
                where !EDPNativeDeviceDiscovery.registryEntryExists(usbRegistryEntryID) {
                    ejectingUSBRegistryIDs.removeValue(forKey: deviceID)
                    diskArbitration.allowAutomount(usbRegistryEntryID: usbRegistryEntryID)
                }
                let currentByDeviceID = Dictionary(uniqueKeysWithValues: disks.map { ($0.deviceID, $0) })
                rawAccessLeases = rawAccessLeases.filter { deviceID, lease in
                    guard let disk = currentByDeviceID[deviceID] else { return false }
                    return lease.registryEntryID == disk.registryEntryID && lease.rawPath == disk.rawPath
                }
                for disk in disks where ejectingUSBRegistryIDs[disk.deviceID] == nil
                    && (rawAccessReadyByDeviceID[disk.deviceID] == nil
                        || rawAccessLeaseLocked(for: disk) == nil) {
                    do {
                        try rawAccessProbeLocked(for: disk, temporarilyUnmount: true)
                    } catch {
                        NSLog(
                            "EDP Full Disk Access probe unavailable for %@: %@",
                            disk.deviceID,
                            String(describing: error)
                        )
                    }
                }
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
                rawAccessReadyByDeviceID = rawAccessReadyByDeviceID.filter {
                    connectedDeviceIDs.contains($0.key)
                }
                rawAccessErrorsByDeviceID = rawAccessErrorsByDeviceID.filter {
                    connectedDeviceIDs.contains($0.key)
                }
                failedMounts = failedMounts.filter { item in
                    guard let separator = item.key.lastIndex(of: ":") else { return false }
                    return connectedDeviceIDs.contains(String(item.key[..<separator]))
                }
                manualUnmountSuppressions = manualUnmountSuppressions.filter { item in
                    guard let separator = item.lastIndex(of: ":") else { return false }
                    return connectedDeviceIDs.contains(String(item[..<separator]))
                }
                try observe(disks)
                let policyDocument = try policies.load()
                let records = try store.load().records
                for disk in disks {
                    if ejectingUSBRegistryIDs[disk.deviceID] != nil {
                        if EDPNativeMountTable.hasMountedBSDPrefix(disk.bsdName) {
                            _ = try? diskArbitration.unmountWhole(disk.bsdName)
                        }
                        continue
                    }
                    guard let devicePolicy = policyDocument.devices.first(
                        where: { $0.deviceID == disk.deviceID }
                    ) else { continue }
                    let bootAutoMount = devicePolicy.policy(
                        for: EDPPartitionKind.boot.rawValue
                    ).autoMount
                    let bootKey = key(disk.deviceID, EDPPartitionKind.boot.rawValue)
                    if policyDocument.globalAutoMountEnabled,
                       bootAutoMount,
                       !manualUnmountSuppressions.contains(bootKey) {
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
                        && !manager.contains(disk, type)
                        && !manualUnmountSuppressions.contains(key(disk.deviceID, type)) {
                        let key = "\(disk.deviceID):\(type)"
                        if failedMounts[key] != nil { continue }
                        do {
                            var password = try store.password(
                                deviceID: disk.deviceID,
                                partitionType: type
                            )
                            defer { secureZero(&password) }
                            let rawLease = try requireRawAccessLeaseLocked(for: disk)
                            try manager.mount(
                                disk: disk,
                                partitionType: type,
                                password: password,
                                rawFD: rawLease.fd
                            )
                            rawAccessReadyByDeviceID[disk.deviceID] = true
                            rawAccessErrorsByDeviceID.removeValue(forKey: disk.deviceID)
                            failedMounts.removeValue(forKey: key)
                            restoreBootPolicy(disk: disk)
                            addActivity(
                                "自动挂载成功",
                                deviceID: disk.deviceID,
                                partitionType: type
                            )
                        } catch {
                            restoreBootPolicy(disk: disk)
                            NSLog("EDP auto-mount failed for %@ type %u; automatic retry paused until explicit user action or device reconnect: %@", disk.deviceID, type, String(describing: error))
                            let detail = String(describing: error)
                            if detail.contains("EDP_RAW_BROKER_")
                                || detail.contains("EDP_RAW_LEASE_")
                                || isRawAccessPermissionFailure(error) {
                                rawAccessReadyByDeviceID[disk.deviceID] = false
                                rawAccessErrorsByDeviceID[disk.deviceID] = detail
                            }
                            failedMounts[key] = String(describing: userFacingRawAccessError(error))
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
                discoveryScanCount &+= 1
                lastDiscoveryTimestamp = ISO8601DateFormatter().string(from: Date())
                lastDiscoveryDiagnostics = ["discovery_error:\(error)"]
                NSLog("EDP event reconciliation failed: %@", String(describing: error))
            }
        }
    }

    func snapshotData() -> Data {
        queue.sync {
            do {
                // Physical discovery owns raw-device access and is driven by
                // Disk Arbitration.  The UI polls snapshots every two seconds;
                // rescanning here would fork a privileged metadata helper for
                // every poll and can create an unbounded failure loop when the
                // current service context cannot open /dev/rdiskN.
                let disks = connectedDisks
                try observe(disks)
                let records = try store.load().records
                let policyDocument = try policies.load()
                let connectedByID = Dictionary(uniqueKeysWithValues: disks
                    .filter { ejectingUSBRegistryIDs[$0.deviceID] == nil }
                    .map { ($0.deviceID, $0) })
                let deviceIDs = Set(policyDocument.devices.map(\.deviceID))
                    .union(records.map(\.deviceID))
                    .union(disks.map(\.deviceID))
                let devices = deviceIDs.sorted().map { deviceID in
                    let disk = connectedByID[deviceID]
                    let record = records.first { $0.deviceID == deviceID }
                    let policy = policyDocument.devices.first { $0.deviceID == deviceID }
                    let partitions = EDPPartitionKind.allCases.map { kind -> EDPXPCPartition in
                        let summary = manager.summary(
                            deviceID: deviceID,
                            partitionType: kind.rawValue
                        )
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
                        privilegedAccessReady: disk.map {
                            rawAccessReadyByDeviceID[$0.deviceID] == true
                        } ?? false,
                        partitions: partitions
                    )
                }
                return try JSONEncoder().encode(EDPXPCSnapshot(
                    devices: devices,
                    activities: activities,
                    serviceVersion: installedProductVersion(),
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
            guard let disk = connectedDisks.first(where: { $0.deviceID == deviceID }) else {
                throw fail("EDP device is no longer connected")
            }
            let rawLease = try requireRawAccessLeaseLocked(for: disk)
            try verifyPartitionType(
                disk: disk,
                partitionType: partitionType,
                password: password,
                rawFD: rawLease.fd
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
            let partitionKey = key(deviceID, partitionType)
            failedMounts.removeValue(forKey: partitionKey)
            manualUnmountSuppressions.remove(partitionKey)
            guard let disk = connectedDisks.first(where: { $0.deviceID == deviceID }) else {
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
            let rawLease = try requireRawAccessLeaseLocked(for: disk)
            try manager.mount(
                disk: disk,
                partitionType: partitionType,
                password: password,
                rawFD: rawLease.fd
            )
            rawAccessReadyByDeviceID[disk.deviceID] = true
            rawAccessErrorsByDeviceID.removeValue(forKey: disk.deviceID)
        } catch {
            restoreBootPolicy(disk: disk)
            let detail = String(describing: error)
            if detail.contains("EDP_RAW_BROKER_")
                || detail.contains("EDP_RAW_LEASE_")
                || isRawAccessPermissionFailure(error) {
                rawAccessReadyByDeviceID[disk.deviceID] = false
                rawAccessErrorsByDeviceID[disk.deviceID] = detail
            }
            let userError = userFacingRawAccessError(error)
            failedMounts[key(disk.deviceID, partitionType)] = String(describing: userError)
            throw userError
        }
    }

    func unmountPartition(deviceID: String, partitionType: UInt32) throws {
        try queue.sync {
            if partitionType == EDPPartitionKind.boot.rawValue {
                guard let disk = connectedDisks.first(where: { $0.deviceID == deviceID }) else {
                    throw fail("EDP device is no longer connected")
                }
                try setBootMounted(false, disk: disk)
            } else {
                manager.unmount(deviceID: deviceID, partitionType: partitionType)
            }
            manualUnmountSuppressions.insert(key(deviceID, partitionType))
            addActivity("分区已卸载", deviceID: deviceID, partitionType: partitionType)
        }
    }

    func deleteCredential(deviceID: String, partitionType: UInt32) throws {
        try queue.sync {
            manager.unmount(deviceID: deviceID, partitionType: partitionType)
            try store.remove(deviceID: deviceID, partitionType: partitionType)
            failedMounts.removeValue(forKey: key(deviceID, partitionType))
            manualUnmountSuppressions.remove(key(deviceID, partitionType))
            addActivity("已删除保存的密码", deviceID: deviceID, partitionType: partitionType)
        }
    }

    func deleteDeviceRecord(deviceID: String) throws {
        try queue.sync {
            guard !connectedDisks.contains(where: { $0.deviceID == deviceID }) else {
                throw fail("请先安全推出并拔出该 U 盘，再删除设备记录")
            }
            guard !manager.isMounted(deviceID: deviceID) else {
                throw fail("该设备仍有挂载会话，暂时不能删除记录")
            }
            try store.remove(deviceID: deviceID)
            try policies.remove(deviceID: deviceID)
            failedMounts = failedMounts.filter { !$0.key.hasPrefix("\(deviceID):") }
            manualUnmountSuppressions = manualUnmountSuppressions.filter {
                !$0.hasPrefix("\(deviceID):")
            }
            addActivity("已删除设备记录和保存的密码", deviceID: deviceID)
        }
    }

    func setPartitionAutoMount(deviceID: String, partitionType: UInt32, enabled: Bool) throws {
        try queue.sync {
            try policies.setAutoMount(
                deviceID: deviceID,
                partitionType: partitionType,
                enabled: enabled
            )
            manualUnmountSuppressions.remove(key(deviceID, partitionType))
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

    func refreshRawAccess() throws {
        try queue.sync {
            guard !connectedDisks.isEmpty else { return }
            var firstError: Error?
            for disk in connectedDisks where ejectingUSBRegistryIDs[disk.deviceID] == nil {
                do {
                    try rawAccessProbeLocked(for: disk, temporarilyUnmount: true)
                    addActivity("完全磁盘访问已验证", deviceID: disk.deviceID)
                } catch {
                    if firstError == nil { firstError = error }
                    addActivity(
                        "完全磁盘访问不可用：\(error)",
                        level: "error",
                        deviceID: disk.deviceID
                    )
                }
            }
            if let firstError { throw firstError }
        }
        reconcile()
    }

    func eject(deviceID: String) throws {
        try queue.sync {
            guard let disk = connectedDisks.first(where: { $0.deviceID == deviceID }) else {
                throw fail("EDP device is no longer connected")
            }
            ejectingUSBRegistryIDs[deviceID] = disk.usbRegistryEntryID
            diskArbitration.suppressAutomount(usbRegistryEntryID: disk.usbRegistryEntryID)
            do {
                // Tear down every encrypted transport before releasing the
                // daemon-owned whole-disk descriptor.  Keeping that retained
                // O_RDWR fd open makes Disk Arbitration reject whole-device
                // eject as busy.
                manager.eject(deviceID: deviceID)
                if let lease = rawAccessLeases.removeValue(forKey: deviceID) {
                    lease.invalidate()
                }
                rawAccessReadyByDeviceID[deviceID] = false
                rawAccessErrorsByDeviceID.removeValue(forKey: deviceID)

                // DADiskEject requires all filesystems on the media family to
                // be unmounted first, including the ordinary boot partition.
                if EDPNativeMountTable.hasMountedBSDPrefix(disk.bsdName) {
                    try diskArbitration.unmountWhole(disk.bsdName)
                }
                try diskArbitration.eject(disk.bsdName)

                // Do not let a queued reconciliation reacquire the raw lease
                // while the successful physical eject is still propagating.
                connectedDisks.removeAll { $0.deviceID == deviceID }
                rawAccessReadyByDeviceID.removeValue(forKey: deviceID)
                rawAccessErrorsByDeviceID.removeValue(forKey: deviceID)
                addActivity("设备已安全推出", deviceID: deviceID)
            } catch {
                ejectingUSBRegistryIDs.removeValue(forKey: deviceID)
                diskArbitration.allowAutomount(usbRegistryEntryID: disk.usbRegistryEntryID)
                // If eject failed for an unrelated reason, return the device
                // to an operational state without asking for interactive administrator authorization.
                if (try? wholeUSBMediaStillMatches(disk)) == true {
                    try? rawAccessProbeLocked(for: disk, temporarilyUnmount: true)
                    restoreBootPolicy(disk: disk)
                }
                throw error
            }
        }
    }

    func diagnosticsData() -> Data {
        queue.sync {
            let payload: [String: Any] = [
                "mounts": manager.mountedSummaries(),
                "failedMounts": failedMounts,
                "manualUnmountSuppressions": manualUnmountSuppressions.sorted(),
                "rawAccessMode": "persistent Full Disk Access daemon + retained raw fd + inherited transport fd",
                "rawAccessDaemon": rawAccessDaemonPath(),
                "rawAccessReadyDeviceIDs": rawAccessReadyByDeviceID
                    .filter { $0.value }.map(\.key).sorted(),
                "rawAccessErrors": rawAccessErrorsByDeviceID,
                "nativeMountCount": EDPNativeMountTable.entries().count,
                "legacyDiscoveryCLI": false,
                "legacyMountCLI": false,
                "eventDrivenDiscovery": true,
                "automaticMountRetry": false,
                "credentialStore": "System Keychain",
                "deviceDiscoveryDiagnostics": EDPNativeDeviceDiscovery.diagnosticReport()
                    + lastDiscoveryDiagnostics,
                "discoveryScanCount": discoveryScanCount,
                "lastDiscoveryTimestamp": lastDiscoveryTimestamp,
            ]
            return (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        }
    }

    func shutdownGracefully() throws {
        try queue.sync {
            manager.unmountAll()
            guard manager.mountedSummaries().isEmpty else {
                throw fail("one or more EDP sessions could not be safely unmounted")
            }
            for lease in rawAccessLeases.values { lease.invalidate() }
            rawAccessLeases.removeAll()
            rawAccessReadyByDeviceID.removeAll()
            rawAccessErrorsByDeviceID.removeAll()
            connectedDisks.removeAll()
            addActivity("后台服务已安全停止")
        }
    }
}

private final class EDPXPCService: NSObject, NSXPCListenerDelegate, EDPVaultXPCProtocol {
    private let controller: EDPDaemonController
    private let didRequestShutdown: @Sendable () -> Void

    init(controller: EDPDaemonController, didRequestShutdown: @escaping @Sendable () -> Void) {
        self.controller = controller
        self.didRequestShutdown = didRequestShutdown
    }

    func healthCheck(withReply reply: @escaping (String) -> Void) {
        reply("com.edp.drive.service:running")
    }

    func requestGracefulShutdown(withReply reply: @escaping (String?) -> Void) {
        do {
            try controller.shutdownGracefully()
            reply(nil)
            didRequestShutdown()
        } catch {
            reply(String(describing: error))
        }
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

    func refreshRawAccess(withReply reply: @escaping (String?) -> Void) {
        do {
            try controller.refreshRawAccess()
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
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

    func deleteDeviceRecord(
        deviceID: String,
        withReply reply: @escaping (String?) -> Void
    ) {
        do {
            try controller.deleteDeviceRecord(deviceID: deviceID)
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

private final class EDPXPCListenerBox: @unchecked Sendable {
    let listener: NSXPCListener
    init(_ listener: NSXPCListener) { self.listener = listener }
}

private func daemon() throws -> Never {
    try requireRoot()
    let controller = try EDPDaemonController()
    let monitor = try EDPDiskEventMonitor()
    let stopped = DispatchSemaphore(value: 0)
    let listener = NSXPCListener(machServiceName: edpVaultMachServiceName)
    let listenerBox = EDPXPCListenerBox(listener)
    let xpcService = EDPXPCService(controller: controller) {
        monitor.stop()
        // Let the shutdown reply drain before invalidating the connection.
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
            listenerBox.listener.invalidate()
            stopped.signal()
        }
    }
    listener.delegate = xpcService
    listener.resume()
    Darwin.signal(SIGTERM, runtimeSignalHandler)
    Darwin.signal(SIGINT, runtimeSignalHandler)
    monitor.start { controller.reconcile() }
    withExtendedLifetime((monitor, listenerBox, xpcService)) {
        stopped.wait()
    }
    Darwin.exit(EXIT_SUCCESS)
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
    let rawDaemon = rawAccessDaemonPath()
    let rawDaemonPresent = FileManager.default.isExecutableFile(atPath: rawDaemon)
    print("RAW_ACCESS_DAEMON=\(rawDaemonPresent ? rawDaemon : "MISSING")")
    print("RAW_ACCESS_MODEL=FULL_DISK_ACCESS_RETAINED_FD")
    ok = ok && rawDaemonPresent
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
      edp-drive-service doctor
      edp-drive-service status
      sudo edp-drive-service list
      sudo edp-drive-service authorize [diskN]
      sudo edp-drive-service revoke <device-id>
      sudo edp-drive-service cleanup
      sudo edp-drive-service daemon

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
