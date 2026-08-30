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

final class EDPRawAccessLease: @unchecked Sendable {
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

private func wholeUSBMediaStillMatches(
    _ disk: PhysicalDisk,
    mediaProvider: any EDPWholeUSBMediaProviding
) throws -> Bool {
    try mediaProvider.allWholeUSBMedia().contains {
        $0.bsdName == disk.bsdName
            && $0.sizeBytes == disk.sizeBytes
            && $0.vidHex.lowercased() == disk.vidHex
            && $0.pidHex.lowercased() == disk.pidHex
            && $0.registryEntryID == disk.registryEntryID
            && $0.usbRegistryEntryID == disk.usbRegistryEntryID
    }
}

private func openPersistentRawAccess(
    for disk: PhysicalDisk,
    mediaProvider: any EDPWholeUSBMediaProviding = EDPIOKitWholeUSBMediaProvider()
) throws -> EDPRawAccessLease {
    guard geteuid() == 0, try wholeUSBMediaStillMatches(disk, mediaProvider: mediaProvider) else {
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
              try wholeUSBMediaStillMatches(disk, mediaProvider: mediaProvider) else {
            throw fail("EDP_RAW_LEASE_TYPE_REFUSED")
        }

        let metadata = try rawMetadataSnapshot(fd: fd)
        guard EDPPhysicalDeviceRevalidation.metadataStillMatches(metadata, disk: disk) else {
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

struct EDPPrivilegedRawMetadataReader: EDPRawMetadataReading {
    func snapshot(for media: EDPWholeUSBMedia) throws -> EDPRawMetadataSnapshot {
        guard FileManager.default.fileExists(atPath: media.rawPath) else {
            throw fail("raw device missing: \(media.rawPath)")
        }
        return try rawMetadataSnapshot(for: media.rawPath)
    }
}

private func discoverEDPDisks(
    mediaProvider: any EDPWholeUSBMediaProviding = EDPIOKitWholeUSBMediaProvider(),
    metadataReader: any EDPRawMetadataReading = EDPPrivilegedRawMetadataReader(),
    diagnostic: ((String) -> Void)? = nil
) throws -> [PhysicalDisk] {
    try EDPPhysicalDiskDiscovery(
        mediaProvider: mediaProvider,
        metadataReader: metadataReader
    ).discover(diagnostic: diagnostic)
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

enum EDPFSKitMountRecoveryPolicy {
    static func shouldRecoverBridgeActivation(
        timedOut: Bool,
        transportStillRunning: Bool,
        bridgeMounted: Bool,
        logDetail: String?
    ) -> Bool {
        guard !bridgeMounted else { return false }
        if timedOut && transportStillRunning { return true }

        let normalized = (logDetail ?? "").lowercased()
        return normalized.contains("mount(8) returned 69")
            || normalized.contains("file system extension not found")
    }
}

enum EDPFSKitMountLifecycleState: Equatable, Sendable {
    case idle
    case preparing(attempt: Int)
    case waitingForBridge(attempt: Int)
    case cleaningUp(attempt: Int, recoverable: Bool, failure: String)
    case recoveringHost(attempt: Int, failure: String)
    case publishing(attempt: Int)
    case mountingFilesystem(attempt: Int)
    case mounted
    case failed(String)
}

enum EDPFSKitMountLifecycleAction: Equatable, Sendable {
    case launchAttempt(attempt: Int)
    case waitForBridge(attempt: Int)
    case cleanup(attempt: Int, allowHostRecoveryDuringStop: Bool)
    case restartHost
    case publish(attempt: Int)
    case mountFilesystem(attempt: Int)
    case complete
    case fail(String)
}

struct EDPFSKitMountLifecycleMachine: Sendable {
    private(set) var state: EDPFSKitMountLifecycleState = .idle
    private(set) var recoveryBudget = 1

    mutating func start() -> EDPFSKitMountLifecycleAction {
        guard state == .idle else { return .fail("mount operation already started") }
        state = .preparing(attempt: 0)
        return .launchAttempt(attempt: 0)
    }

    mutating func attemptLaunched(_ attempt: Int) -> EDPFSKitMountLifecycleAction {
        guard state == .preparing(attempt: attempt) else {
            return invalidTransition("attemptLaunched")
        }
        state = .waitingForBridge(attempt: attempt)
        return .waitForBridge(attempt: attempt)
    }

    mutating func bridgeActivated(_ attempt: Int) -> EDPFSKitMountLifecycleAction {
        guard state == .waitingForBridge(attempt: attempt) else {
            return invalidTransition("bridgeActivated")
        }
        state = .publishing(attempt: attempt)
        return .publish(attempt: attempt)
    }

    mutating func bridgeFailed(
        _ attempt: Int,
        recoverable: Bool,
        failure: String
    ) -> EDPFSKitMountLifecycleAction {
        guard state == .waitingForBridge(attempt: attempt) else {
            return invalidTransition("bridgeFailed")
        }
        let mayRecover = recoverable && recoveryBudget > 0
        state = .cleaningUp(attempt: attempt, recoverable: mayRecover, failure: failure)
        return .cleanup(attempt: attempt, allowHostRecoveryDuringStop: mayRecover)
    }

    mutating func cleanupFinished(
        _ attempt: Int,
        hostAlreadyRecovered: Bool
    ) -> EDPFSKitMountLifecycleAction {
        guard case .cleaningUp(let currentAttempt, let recoverable, let failure) = state,
              currentAttempt == attempt else {
            return invalidTransition("cleanupFinished")
        }
        guard recoverable else {
            state = .failed(failure)
            return .fail(failure)
        }
        if hostAlreadyRecovered {
            recoveryBudget -= 1
            let next = attempt + 1
            state = .preparing(attempt: next)
            return .launchAttempt(attempt: next)
        }
        state = .recoveringHost(attempt: attempt, failure: failure)
        return .restartHost
    }

    mutating func hostRecoveryFinished(_ succeeded: Bool) -> EDPFSKitMountLifecycleAction {
        guard case .recoveringHost(let attempt, let failure) = state else {
            return invalidTransition("hostRecoveryFinished")
        }
        guard succeeded, recoveryBudget > 0 else {
            state = .failed(failure)
            return .fail(failure)
        }
        recoveryBudget -= 1
        let next = attempt + 1
        state = .preparing(attempt: next)
        return .launchAttempt(attempt: next)
    }

    mutating func publicationFinished(_ attempt: Int) -> EDPFSKitMountLifecycleAction {
        guard state == .publishing(attempt: attempt) else {
            return invalidTransition("publicationFinished")
        }
        state = .mountingFilesystem(attempt: attempt)
        return .mountFilesystem(attempt: attempt)
    }

    mutating func filesystemMounted(_ attempt: Int) -> EDPFSKitMountLifecycleAction {
        guard state == .mountingFilesystem(attempt: attempt) else {
            return invalidTransition("filesystemMounted")
        }
        state = .mounted
        return .complete
    }

    mutating func stageFailed(_ failure: String) -> EDPFSKitMountLifecycleAction {
        switch state {
        case .publishing(let attempt), .mountingFilesystem(let attempt):
            state = .cleaningUp(attempt: attempt, recoverable: false, failure: failure)
            return .cleanup(attempt: attempt, allowHostRecoveryDuringStop: false)
        default:
            state = .failed(failure)
            return .fail(failure)
        }
    }

    mutating func cancel() -> EDPFSKitMountLifecycleAction {
        let failure = "mount operation cancelled"
        switch state {
        case .idle, .preparing:
            state = .failed(failure)
            return .fail(failure)
        case .waitingForBridge(let attempt),
             .publishing(let attempt),
             .mountingFilesystem(let attempt):
            state = .cleaningUp(attempt: attempt, recoverable: false, failure: failure)
            return .cleanup(attempt: attempt, allowHostRecoveryDuringStop: false)
        case .cleaningUp, .recoveringHost:
            // Cleanup/recovery work already owns the resources. The caller uses
            // this event only after that in-flight step returns, so cancellation
            // wins over retry/recovery without launching a second cleanup.
            state = .failed(failure)
            return .fail(failure)
        case .mounted:
            return .fail("mount operation already completed")
        case .failed(let existing):
            return .fail(existing)
        }
    }

    private mutating func invalidTransition(_ event: String) -> EDPFSKitMountLifecycleAction {
        // Async callbacks may arrive after an operation has already reached a
        // terminal state. They are stale events, not a new lifecycle failure.
        switch state {
        case .failed(let existing):
            return .fail(existing)
        case .mounted:
            return .complete
        default:
            let message = "invalid FSKit mount lifecycle transition: \(event) from \(state)"
            state = .failed(message)
            return .fail(message)
        }
    }
}

private enum EDPFSKitHostRecovery {
    static func restartConsoleAgentIfSafe() -> Bool {
        guard geteuid() == 0 else { return false }

        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count >= 0, let mounts else { return false }
        for index in 0..<Int(count) {
            if (mounts[index].f_flags_ext & UInt32(MNT_EXT_FSKIT)) != 0 {
                NSLog("EDP refused FSKit agent recovery because an FSKit mount is still active")
                return false
            }
        }

        var console = stat()
        guard stat("/dev/console", &console) == 0,
              console.st_uid != 0 else {
            return false
        }

        do {
            let status = try EDPNativeBoundedProcess.run(
                executable: "/usr/bin/pkill",
                arguments: ["-9", "-U", String(console.st_uid), "-x", "fskit_agent"],
                timeout: 3,
                label: "restart console-user FSKit agent"
            )
            guard status == 0 else { return false }
            NSLog("EDP restarted console-user fskit_agent after a mount-free stuck transport")
            return true
        } catch {
            NSLog("EDP FSKit agent recovery failed: %@", String(describing: error))
            return false
        }
    }
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
        signal(SIGTERM)
    }

    func forceTerminate() {
        signal(SIGKILL)
    }

    private func signal(_ signal: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard !reaped else { return }
        _ = kill(pid, signal)
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

    var inheritedRawFD = rawFD
    if rawFD == 3 {
        inheritedRawFD = fcntl(rawFD, F_DUPFD_CLOEXEC, 64)
        guard inheritedRawFD >= 0 else {
            throw fail("cannot stage raw fd 3 for child inheritance: errno=\(errno)")
        }
    }
    defer {
        if inheritedRawFD != rawFD {
            close(inheritedRawFD)
        }
    }

    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else {
        throw fail("posix_spawn_file_actions_init failed")
    }
    defer { posix_spawn_file_actions_destroy(&actions) }
    for (source, destination) in [(stdinFD, STDIN_FILENO), (logFD, STDOUT_FILENO), (logFD, STDERR_FILENO), (inheritedRawFD, 3)] {
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

private final class MountSession: @unchecked Sendable {
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

private final class EDPFSKitMountOperationBox: @unchecked Sendable {
    var machine = EDPFSKitMountLifecycleMachine()
    let sessionKey: String
    let disk: PhysicalDisk
    let partitionType: UInt32
    var password: [UInt8]
    let rawFD: Int32
    let completion: EDPDaemonMountCompletion
    var finished = false

    init(
        sessionKey: String,
        disk: PhysicalDisk,
        partitionType: UInt32,
        password: [UInt8],
        rawFD: Int32,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        self.sessionKey = sessionKey
        self.disk = disk
        self.partitionType = partitionType
        self.password = password
        self.rawFD = rawFD
        self.completion = completion
    }

    deinit { secureZero(&password) }
}

private final class EDPSendableStringReply: @unchecked Sendable {
    private let callback: (String?) -> Void
    init(_ callback: @escaping (String?) -> Void) { self.callback = callback }
    func callAsFunction(_ value: String?) { callback(value) }
}

#if EDP_REGRESSION_TESTS
private final class EDPRegressionAsyncResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func set(_ value: String?) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func snapshot() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
#endif

typealias EDPDaemonMountCompletion = @Sendable (String?) -> Void

protocol EDPDaemonMountManaging: AnyObject {
    func recoverPersistedSessionsAsync(completion: @escaping EDPDaemonMountCompletion)
    func contains(_ disk: PhysicalDisk, _ type: UInt32) -> Bool
    func mountedPhysicalDisks() -> Set<String>
    func isMounted(deviceID: String) -> Bool
    func mountedSummaries() -> [[String: String]]
    func summary(deviceID: String, partitionType: UInt32) -> [String: String]?
    func mountAsync(
        disk: PhysicalDisk,
        partitionType: UInt32,
        password: [UInt8],
        rawFD: Int32,
        completion: @escaping EDPDaemonMountCompletion
    )
    func unmountAsync(
        deviceID: String,
        partitionType: UInt32,
        completion: @escaping EDPDaemonMountCompletion
    )
    func ejectAsync(deviceID: String, completion: @escaping EDPDaemonMountCompletion)
    @discardableResult
    func removeMissing(availableDisks: [String: String], graceSeconds: TimeInterval) -> Bool
    func unmountAllAsync(completion: @escaping EDPDaemonMountCompletion)
}

private final class MountManager: EDPDaemonMountManaging, @unchecked Sendable {
    private var sessions = [String: MountSession]()
    private var missingSince = [String: Date]()
    private let binaryRoot: String
    private let diskArbitration: EDPDiskArbitrationController
    private let blockPublisher: any EDPBlockDevicePublisher
    private let lifecycleQueue = DispatchQueue(label: "com.edp.drive.mount-lifecycle", qos: .userInitiated)
    private let filesystemOperationQueue = DispatchQueue(
        label: "com.edp.drive.filesystem-operation",
        qos: .userInitiated
    )
    private let lifecycleQueueKey = DispatchSpecificKey<UInt8>()
    private var activeMountOperations = Set<String>()
    private var cancelledMountOperations = Set<String>()
    private var mountWaiters = [String: [EDPDaemonMountCompletion]]()
    private var unmountWaiters = [String: [EDPDaemonMountCompletion]]()
    private var ejectWaiters = [String: [EDPDaemonMountCompletion]]()

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
        lifecycleQueue.setSpecific(key: lifecycleQueueKey, value: 1)
    }

    private func lifecycleSync<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: lifecycleQueueKey) != nil {
            return try body()
        }
        return try lifecycleQueue.sync(execute: body)
    }

    func recoverPersistedSessionsAsync(completion: @escaping EDPDaemonMountCompletion) {
        lifecycleQueue.async { [weak self] in
            guard let self else {
                completion("mount manager was released")
                return
            }
            let path = dataRoot + "/sessions.json"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
                completion(nil)
                return
            }
            self.recoverPersistedSessionItems(items, index: 0) { errorMessage in
                if errorMessage == nil {
                    try? FileManager.default.removeItem(atPath: path)
                }
                completion(errorMessage)
            }
        }
    }

    private func recoverPersistedSessionItems(
        _ items: [[String: String]],
        index: Int,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        guard index < items.count else {
            completion(nil)
            return
        }
        let item = items[index]
        let advance: @Sendable () -> Void = { [weak self] in
            guard let self else {
                completion("mount manager was released")
                return
            }
            self.recoverPersistedSessionItems(items, index: index + 1, completion: completion)
        }

        if let mountpoint = item["mountpoint"], !mountpoint.isEmpty {
            do {
                try EDPNativeMountTable.unmountPath(mountpoint)
            } catch {
                NSLog(
                    "EDP persisted-session recovery stopped at user mount %@: %@",
                    mountpoint,
                    String(describing: error)
                )
                advance()
                return
            }
            guard !EDPNativeMountTable.isMountpoint(mountpoint) else {
                NSLog("EDP persisted-session recovery kept active user mount %@", mountpoint)
                advance()
                return
            }
            try? FileManager.default.removeItem(atPath: mountpoint)
        }

        if let exposed = item["exposedBSD"], !exposed.isEmpty {
            let backingPath = item["bridgeMount"].map { $0 + "/volume.raw" }
            blockPublisher.unpublishAsync(
                EDPPublishedBlockDevice(bsdName: exposed, backingPath: backingPath)
            ) { [weak self] errorMessage in
                guard let self else {
                    completion("mount manager was released")
                    return
                }
                self.lifecycleQueue.async {
                    if let errorMessage {
                        NSLog(
                            "EDP persisted-session recovery kept published device %@: %@",
                            exposed,
                            errorMessage
                        )
                        advance()
                        return
                    }
                    self.recoverPersistedBridge(item, advance: advance)
                }
            }
            return
        }
        recoverPersistedBridge(item, advance: advance)
    }

    private func recoverPersistedBridge(
        _ item: [String: String],
        advance: @escaping @Sendable () -> Void
    ) {
        if let bridge = item["bridgeMount"], !bridge.isEmpty {
            if EDPNativeMountTable.isMountpoint(bridge) {
                _ = EDPMacFUSEScratchImageCleanup.cleanupOrphan(mountedAt: bridge)
            }
            do {
                try EDPNativeMountTable.unmountPath(bridge)
                if EDPNativeMountTable.isMountpoint(bridge) {
                    try EDPNativeMountTable.unmountPath(bridge, force: true)
                }
            } catch {
                NSLog(
                    "EDP persisted-session recovery kept transport mount %@: %@",
                    bridge,
                    String(describing: error)
                )
                advance()
                return
            }
            guard !EDPNativeMountTable.isMountpoint(bridge) else {
                NSLog("EDP persisted-session recovery kept active transport mount %@", bridge)
                advance()
                return
            }
            try? FileManager.default.removeItem(atPath: bridge)
        }
        advance()
    }

    private func key(_ disk: PhysicalDisk, _ type: UInt32) -> String {
        "\(disk.deviceID):\(type)"
    }

    func contains(_ disk: PhysicalDisk, _ type: UInt32) -> Bool {
        lifecycleSync { sessions[key(disk, type)] != nil || activeMountOperations.contains(key(disk, type)) }
    }

    func mountedPhysicalDisks() -> Set<String> {
        lifecycleSync { Set(sessions.values.map(\.physicalBSD)) }
    }

    func isMounted(deviceID: String) -> Bool {
        lifecycleSync {
            sessions.values.contains { $0.deviceID == deviceID }
                || activeMountOperations.contains { $0.hasPrefix("\(deviceID):") }
        }
    }

    func mountedSummaries() -> [[String: String]] {
        lifecycleSync {
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
    }

    func summary(deviceID: String, partitionType: UInt32) -> [String: String]? {
        lifecycleSync {
            guard let session = sessions["\(deviceID):\(partitionType)"] else { return nil }
            var filesystem = session.filesystem
            var mountpoint = session.userMount ?? ""
            if !session.exposedBSD.isEmpty,
               let resolved = try? resolveFilesystemDevice(session.exposedBSD) {
                switch resolved.magic {
                case "EXFAT": filesystem = "ExFAT"
                case "NTFS": filesystem = "NTFS"
                case "FAT":
                    filesystem = session.partitionType == EDPPartitionKind.boot.rawValue
                        ? "FAT16 (read-only)"
                        : "FAT"
                default: filesystem = "Unformatted or unsupported"
                }
                mountpoint = EDPNativeMountTable.mountPoint(forBSD: resolved.bsdName) ?? ""
                if session.partitionType != EDPPartitionKind.boot.rawValue,
                   !mountpoint.isEmpty,
                   EDPNativeMountTable.isReadOnly(mountpoint) == true {
                    filesystem += " (read-only; Finder erasable)"
                }
            }
            return [
                "filesystem": filesystem,
                "mountpoint": mountpoint,
                "exposedBSD": session.exposedBSD,
            ]
        }
    }

    func mountAsync(
        disk: PhysicalDisk,
        partitionType: UInt32,
        password: [UInt8],
        rawFD: Int32,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        let sessionKey = key(disk, partitionType)
        let operation = EDPFSKitMountOperationBox(
            sessionKey: sessionKey,
            disk: disk,
            partitionType: partitionType,
            password: password,
            rawFD: rawFD,
            completion: completion
        )
        lifecycleQueue.async { [weak self, operation] in
            guard let self else {
                completion("mount manager was released")
                return
            }
            if self.sessions[sessionKey] != nil {
                completion(nil)
                return
            }
            if self.activeMountOperations.contains(sessionKey) {
                self.mountWaiters[sessionKey, default: []].append(completion)
                return
            }
            self.activeMountOperations.insert(sessionKey)
            self.cancelledMountOperations.remove(sessionKey)
            self.executeMountAction(operation.machine.start(), operation: operation)
        }
    }

    private func executeMountAction(
        _ action: EDPFSKitMountLifecycleAction,
        operation: EDPFSKitMountOperationBox
    ) {
        guard !operation.finished else { return }
        switch action {
        case .launchAttempt(let attempt):
            launchMountAttempt(operation, attempt: attempt)
        case .fail(let failure):
            finishMountOperation(operation, error: failure)
        case .complete:
            finishMountOperation(operation, error: nil)
        case .waitForBridge, .cleanup, .restartHost, .publish, .mountFilesystem:
            break
        }
    }

    private func launchMountAttempt(
        _ operation: EDPFSKitMountOperationBox,
        attempt: Int
    ) {
        if cancelledMountOperations.contains(operation.sessionKey) {
            executeMountAction(operation.machine.cancel(), operation: operation)
            return
        }

        do {
            let runtimeStatus = try EDPTransportRuntimePolicy.verifySelectedRuntime(
                requireFinderHidden: true
            )
            let disk = operation.disk
            let partitionType = operation.partitionType
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

            let continueLaunch: @Sendable () -> Void = { [weak self, operation] in
                guard let self else { return }
                self.lifecycleQueue.async {
                    self.startTransportAttempt(
                        operation,
                        attempt: attempt,
                        runtimeStatus: runtimeStatus,
                        identity: identity,
                        suffix: suffix,
                        bridgeMount: bridgeMount
                    )
                }
            }

            guard EDPNativeMountTable.hasMountedBSDPrefix(disk.bsdName) else {
                continueLaunch()
                return
            }
            diskArbitration.unmountWholeAsync(disk.bsdName) { [weak self, operation] error in
                guard let self else { return }
                self.lifecycleQueue.async {
                    guard !self.cancelledMountOperations.contains(operation.sessionKey) else {
                        self.executeMountAction(operation.machine.cancel(), operation: operation)
                        return
                    }
                    if let error {
                        self.executeMountAction(
                            operation.machine.stageFailed(String(describing: error)),
                            operation: operation
                        )
                        return
                    }
                    continueLaunch()
                }
            }
        } catch {
            let failure = String(describing: error)
            executeMountAction(operation.machine.stageFailed(failure), operation: operation)
        }
    }

    private func startTransportAttempt(
        _ operation: EDPFSKitMountOperationBox,
        attempt: Int,
        runtimeStatus: EDPTransportRuntimeStatus,
        identity: (uid_t, gid_t),
        suffix: String,
        bridgeMount: String
    ) {
        guard !cancelledMountOperations.contains(operation.sessionKey) else {
            executeMountAction(operation.machine.cancel(), operation: operation)
            return
        }
        do {
            let disk = operation.disk
            let partitionType = operation.partitionType
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
                readOnly: partitionType == EDPPartitionKind.boot.rawValue
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
            for (key, value) in launchSpec.environment { environment[key] = value }
            let transportProcess = try spawnConsoleTransport(
                binaryRoot: binaryRoot,
                identity: identity,
                executable: launchSpec.executable,
                arguments: launchSpec.arguments,
                environment: environment,
                rawFD: operation.rawFD,
                stdinFD: passwordPipe.fileHandleForReading.fileDescriptor,
                logFD: log.fileDescriptor
            )
            try passwordPipe.fileHandleForReading.close()
            passwordPipe.fileHandleForWriting.write(Data(operation.password))
            try passwordPipe.fileHandleForWriting.close()

            let transportSession = EDPTransportSession(
                backend: runtimeStatus.backend,
                mountpoint: bridgeMount,
                capabilities: launchSpec.capabilities,
                process: transportProcess
            )
            _ = operation.machine.attemptLaunched(attempt)
            pollBridgeActivation(
                operation,
                attempt: attempt,
                runtimeStatus: runtimeStatus,
                identity: identity,
                suffix: suffix,
                bridgeMount: bridgeMount,
                log: log,
                logPath: logPath,
                scratchBaseline: macFUSEScratchBaseline,
                transportSession: transportSession,
                deadline: Date().addingTimeInterval(8)
            )
        } catch {
            executeMountAction(
                operation.machine.stageFailed(String(describing: error)),
                operation: operation
            )
        }
    }

    private func pollBridgeActivation(
        _ operation: EDPFSKitMountOperationBox,
        attempt: Int,
        runtimeStatus: EDPTransportRuntimeStatus,
        identity: (uid_t, gid_t),
        suffix: String,
        bridgeMount: String,
        log: FileHandle,
        logPath: String,
        scratchBaseline: Set<String>?,
        transportSession: EDPTransportSession,
        deadline: Date
    ) {
        if cancelledMountOperations.contains(operation.sessionKey) {
            let action = operation.machine.cancel()
            if case .cleanup(_, let allowHostRecoveryDuringStop) = action {
                cleanupMountAttempt(
                    operation,
                    attempt: attempt,
                    runtimeStatus: runtimeStatus,
                    bridgeMount: bridgeMount,
                    scratchBaseline: scratchBaseline,
                    transportSession: transportSession,
                    publishedDevice: nil,
                    allowHostRecoveryDuringStop: allowHostRecoveryDuringStop,
                    failure: "mount operation cancelled"
                )
            } else {
                executeMountAction(action, operation: operation)
            }
            return
        }

        let bridgeMounted = EDPNativeMountTable.isMountpoint(bridgeMount)
        if bridgeMounted && transportSession.isRunning {
            _ = operation.machine.bridgeActivated(attempt)
            continueMountedBridge(
                operation,
                attempt: attempt,
                runtimeStatus: runtimeStatus,
                identity: identity,
                suffix: suffix,
                bridgeMount: bridgeMount,
                logPath: logPath,
                scratchBaseline: scratchBaseline,
                transportSession: transportSession
            )
            return
        }

        if !transportSession.isRunning {
            try? log.synchronize()
            let detail = bridgeLogTail(logPath)
            let recoverable = EDPFSKitMountRecoveryPolicy.shouldRecoverBridgeActivation(
                timedOut: false,
                transportStillRunning: false,
                bridgeMounted: bridgeMounted,
                logDetail: detail
            )
            let failure = "encrypted block bridge failed"
                + (detail?.isEmpty == false ? ": \(detail!)" : "; see \(logPath)")
            failBridgeAttempt(
                operation,
                attempt: attempt,
                runtimeStatus: runtimeStatus,
                bridgeMount: bridgeMount,
                logPath: logPath,
                scratchBaseline: scratchBaseline,
                transportSession: transportSession,
                publishedDevice: nil,
                recoverable: recoverable,
                failure: failure
            )
            return
        }

        if Date() >= deadline {
            let recoverable = EDPFSKitMountRecoveryPolicy.shouldRecoverBridgeActivation(
                timedOut: true,
                transportStillRunning: transportSession.isRunning,
                bridgeMounted: bridgeMounted,
                logDetail: nil
            )
            failBridgeAttempt(
                operation,
                attempt: attempt,
                runtimeStatus: runtimeStatus,
                bridgeMount: bridgeMount,
                logPath: logPath,
                scratchBaseline: scratchBaseline,
                transportSession: transportSession,
                publishedDevice: nil,
                recoverable: recoverable,
                failure: "operation timed out after 8 seconds"
            )
            return
        }

        lifecycleQueue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self, operation] in
            self?.pollBridgeActivation(
                operation,
                attempt: attempt,
                runtimeStatus: runtimeStatus,
                identity: identity,
                suffix: suffix,
                bridgeMount: bridgeMount,
                log: log,
                logPath: logPath,
                scratchBaseline: scratchBaseline,
                transportSession: transportSession,
                deadline: deadline
            )
        }
    }

    private func continueMountedBridge(
        _ operation: EDPFSKitMountOperationBox,
        attempt: Int,
        runtimeStatus: EDPTransportRuntimeStatus,
        identity: (uid_t, gid_t),
        suffix: String,
        bridgeMount: String,
        logPath: String,
        scratchBaseline: Set<String>?,
        transportSession: EDPTransportSession
    ) {
        if cancelledMountOperations.contains(operation.sessionKey) {
            let action = operation.machine.cancel()
            if case .cleanup(_, let allowHostRecoveryDuringStop) = action {
                cleanupMountAttempt(
                    operation,
                    attempt: attempt,
                    runtimeStatus: runtimeStatus,
                    bridgeMount: bridgeMount,
                    scratchBaseline: scratchBaseline,
                    transportSession: transportSession,
                    publishedDevice: nil,
                    allowHostRecoveryDuringStop: allowHostRecoveryDuringStop,
                    failure: "mount operation cancelled"
                )
            } else {
                executeMountAction(action, operation: operation)
            }
            return
        }

        do {
            let decryptedVolume = bridgeMount + "/volume.raw"
            let published = try blockPublisher.publishWritableImage(at: decryptedVolume)
            _ = operation.machine.publicationFinished(attempt)
            guard !cancelledMountOperations.contains(operation.sessionKey) else {
                cleanupPublishedMount(
                    operation,
                    attempt: attempt,
                    runtimeStatus: runtimeStatus,
                    bridgeMount: bridgeMount,
                    scratchBaseline: scratchBaseline,
                    transportSession: transportSession,
                    publishedDevice: published,
                    failure: "mount operation cancelled",
                    cancelled: true
                )
                return
            }

            let resolved = try resolveFilesystemDevice(published.bsdName)
            mountResolvedFilesystemAsync(
                bsd: resolved.bsdName,
                magic: resolved.magic,
                isBoot: operation.partitionType == EDPPartitionKind.boot.rawValue,
                sessionSuffix: suffix,
                owner: identity
            ) { [weak self, operation] filesystem, mountpoint, errorMessage in
                guard let self else { return }
                self.lifecycleQueue.async {
                    let cancelled = self.cancelledMountOperations.contains(operation.sessionKey)
                    if cancelled, let mountpoint {
                        try? EDPNativeMountTable.unmountPath(mountpoint, force: true)
                    }
                    if let errorMessage = cancelled ? "mount operation cancelled" : errorMessage {
                        self.cleanupPublishedMount(
                            operation,
                            attempt: attempt,
                            runtimeStatus: runtimeStatus,
                            bridgeMount: bridgeMount,
                            scratchBaseline: scratchBaseline,
                            transportSession: transportSession,
                            publishedDevice: published,
                            failure: errorMessage,
                            cancelled: cancelled
                        )
                        return
                    }
                    guard let filesystem else {
                        self.cleanupPublishedMount(
                            operation,
                            attempt: attempt,
                            runtimeStatus: runtimeStatus,
                            bridgeMount: bridgeMount,
                            scratchBaseline: scratchBaseline,
                            transportSession: transportSession,
                            publishedDevice: published,
                            failure: "filesystem mount returned no result",
                            cancelled: false
                        )
                        return
                    }
                    self.sessions[operation.sessionKey] = MountSession(
                        physicalBSD: operation.disk.bsdName,
                        deviceID: operation.disk.deviceID,
                        partitionType: operation.partitionType,
                        bridgeMount: bridgeMount,
                        exposedBSD: published.bsdName,
                        filesystem: filesystem,
                        userMount: mountpoint,
                        transport: transportSession,
                        filesystemProcess: nil
                    )
                    self.persistSessions()
                    _ = operation.machine.filesystemMounted(attempt)
                    NSLog(
                        "EDP mounted %@ partition %u as %@ at %@",
                        operation.disk.deviceID,
                        operation.partitionType,
                        filesystem,
                        mountpoint ?? "(unknown)"
                    )
                    self.executeMountAction(.complete, operation: operation)
                }
            }
        } catch {
            cleanupPublishedMount(
                operation,
                attempt: attempt,
                runtimeStatus: runtimeStatus,
                bridgeMount: bridgeMount,
                scratchBaseline: scratchBaseline,
                transportSession: transportSession,
                publishedDevice: nil,
                failure: String(describing: error),
                cancelled: cancelledMountOperations.contains(operation.sessionKey)
            )
        }
    }

    private func cleanupPublishedMount(
        _ operation: EDPFSKitMountOperationBox,
        attempt: Int,
        runtimeStatus: EDPTransportRuntimeStatus,
        bridgeMount: String,
        scratchBaseline: Set<String>?,
        transportSession: EDPTransportSession,
        publishedDevice: EDPPublishedBlockDevice?,
        failure: String,
        cancelled: Bool
    ) {
        let action = cancelled ? operation.machine.cancel() : operation.machine.stageFailed(failure)
        if case .cleanup(_, let allowHostRecoveryDuringStop) = action {
            cleanupMountAttempt(
                operation,
                attempt: attempt,
                runtimeStatus: runtimeStatus,
                bridgeMount: bridgeMount,
                scratchBaseline: scratchBaseline,
                transportSession: transportSession,
                publishedDevice: publishedDevice,
                allowHostRecoveryDuringStop: allowHostRecoveryDuringStop,
                failure: cancelled ? "mount operation cancelled" : failure
            )
        } else {
            executeMountAction(action, operation: operation)
        }
    }

    private func mountResolvedFilesystemAsync(
        bsd: String,
        magic: String,
        isBoot: Bool,
        sessionSuffix: String,
        owner: (uid_t, gid_t),
        completion: @escaping @Sendable (String?, String?, String?) -> Void
    ) {
        if isBoot, magic == "FAT" {
            filesystemOperationQueue.async { [weak self] in
                guard let self else {
                    completion(nil, nil, "mount manager was released")
                    return
                }
                do {
                    let mountpoint = try self.mountFATReadOnly(bsd, owner: owner)
                    completion("FAT16 (read-only)", mountpoint, nil)
                } catch {
                    completion(nil, nil, String(describing: error))
                }
            }
            return
        }

        guard ["EXFAT", "NTFS", "FAT"].contains(magic) else {
            completion("Unformatted or unsupported", nil, nil)
            return
        }

        prepareFinderDefaultsAsync(
            bsd: bsd,
            sessionSuffix: sessionSuffix,
            owner: owner
        ) { [weak self] stagingError in
            guard let self else {
                completion(nil, nil, "mount manager was released")
                return
            }
            self.lifecycleQueue.async {
                if let stagingError {
                    completion(nil, nil, stagingError)
                    return
                }
                self.diskArbitration.mountAsync(bsd) { [weak self] mountpoint, error in
                    guard let self else {
                        completion(nil, nil, "mount manager was released")
                        return
                    }
                    self.lifecycleQueue.async {
                        if let error {
                            completion(nil, nil, String(describing: error))
                            return
                        }
                        guard let mountpoint else {
                            completion(nil, nil, "Disk Arbitration returned no mount point")
                            return
                        }
                        switch magic {
                        case "EXFAT":
                            guard EDPNativeMountTable.isReadOnly(mountpoint) == false else {
                                completion(nil, mountpoint, "native ExFAT mounted read-only")
                                return
                            }
                            completion("ExFAT", mountpoint, nil)
                        case "NTFS":
                            completion(
                                EDPNativeMountTable.isReadOnly(mountpoint) == true
                                    ? "NTFS (read-only; Finder erasable)"
                                    : "NTFS",
                                mountpoint,
                                nil
                            )
                        case "FAT":
                            completion("FAT", mountpoint, nil)
                        default:
                            completion("Unformatted or unsupported", nil, nil)
                        }
                    }
                }
            }
        }
    }

    private func failBridgeAttempt(
        _ operation: EDPFSKitMountOperationBox,
        attempt: Int,
        runtimeStatus: EDPTransportRuntimeStatus,
        bridgeMount: String,
        logPath: String,
        scratchBaseline: Set<String>?,
        transportSession: EDPTransportSession,
        publishedDevice: EDPPublishedBlockDevice?,
        recoverable: Bool,
        failure: String
    ) {
        let action = operation.machine.bridgeFailed(
            attempt,
            recoverable: recoverable,
            failure: failure
        )
        guard case .cleanup(_, let allowHostRecoveryDuringStop) = action else {
            executeMountAction(action, operation: operation)
            return
        }
        cleanupMountAttempt(
            operation,
            attempt: attempt,
            runtimeStatus: runtimeStatus,
            bridgeMount: bridgeMount,
            scratchBaseline: scratchBaseline,
            transportSession: transportSession,
            publishedDevice: publishedDevice,
            allowHostRecoveryDuringStop: allowHostRecoveryDuringStop,
            failure: failure
        )
    }

    private func cleanupMountAttempt(
        _ operation: EDPFSKitMountOperationBox,
        attempt: Int,
        runtimeStatus: EDPTransportRuntimeStatus,
        bridgeMount: String,
        scratchBaseline: Set<String>?,
        transportSession: EDPTransportSession,
        publishedDevice: EDPPublishedBlockDevice?,
        allowHostRecoveryDuringStop: Bool,
        failure: String
    ) {
        guard let publishedDevice else {
            stopTransportAfterMountCleanup(
                operation,
                attempt: attempt,
                runtimeStatus: runtimeStatus,
                bridgeMount: bridgeMount,
                scratchBaseline: scratchBaseline,
                transportSession: transportSession,
                allowHostRecoveryDuringStop: allowHostRecoveryDuringStop,
                failure: failure
            )
            return
        }
        blockPublisher.unpublishAsync(publishedDevice) { [weak self, operation] unpublishError in
            guard let self else { return }
            self.lifecycleQueue.async {
                if let unpublishError {
                    NSLog("EDP async publication cleanup after %@: %@", failure, unpublishError)
                }
                self.stopTransportAfterMountCleanup(
                    operation,
                    attempt: attempt,
                    runtimeStatus: runtimeStatus,
                    bridgeMount: bridgeMount,
                    scratchBaseline: scratchBaseline,
                    transportSession: transportSession,
                    allowHostRecoveryDuringStop: allowHostRecoveryDuringStop,
                    failure: failure
                )
            }
        }
    }

    private func stopTransportAfterMountCleanup(
        _ operation: EDPFSKitMountOperationBox,
        attempt: Int,
        runtimeStatus: EDPTransportRuntimeStatus,
        bridgeMount: String,
        scratchBaseline: Set<String>?,
        transportSession: EDPTransportSession,
        allowHostRecoveryDuringStop: Bool,
        failure: String
    ) {
        let recoverStuckProcess: (() -> Bool)? = allowHostRecoveryDuringStop
            ? { [weak self, operation] in
                guard let self,
                      !self.cancelledMountOperations.contains(operation.sessionKey) else {
                    return false
                }
                return EDPFSKitHostRecovery.restartConsoleAgentIfSafe()
            }
            : nil

        transportSession.stopAsync(
            on: lifecycleQueue,
            unmount: { try EDPNativeMountTable.unmountPath($0, force: true) },
            isMounted: { EDPNativeMountTable.isMountpoint($0) },
            recoverStuckProcess: recoverStuckProcess
        ) { [weak self, operation] stopRecoveredHost, hostRecoveryAttempted, stopError in
            guard let self else { return }
            if runtimeStatus.backend == .macFUSELocal {
                EDPMacFUSEScratchImageCleanup.cleanupNewOrphans(since: scratchBaseline)
            }
            try? FileManager.default.removeItem(atPath: bridgeMount)
            if let stopError {
                NSLog("EDP async transport cleanup after %@: %@", failure, stopError)
            }

            if self.cancelledMountOperations.contains(operation.sessionKey) {
                self.executeMountAction(operation.machine.cancel(), operation: operation)
                return
            }

            if hostRecoveryAttempted {
                let action = operation.machine.cleanupFinished(
                    attempt,
                    hostAlreadyRecovered: stopRecoveredHost && !transportSession.isRunning
                )
                if case .restartHost = action {
                    // A recovery callback was already attempted by stopAsync.
                    // Never consume a second global fskit_agent restart here.
                    self.executeMountAction(
                        operation.machine.hostRecoveryFinished(false),
                        operation: operation
                    )
                } else {
                    self.executeMountAction(action, operation: operation)
                }
                return
            }

            let action = operation.machine.cleanupFinished(
                attempt,
                hostAlreadyRecovered: false
            )
            if case .restartHost = action {
                let recovered = EDPFSKitHostRecovery.restartConsoleAgentIfSafe()
                    && !transportSession.isRunning
                self.executeMountAction(
                    operation.machine.hostRecoveryFinished(recovered),
                    operation: operation
                )
            } else {
                self.executeMountAction(action, operation: operation)
            }
        }
    }

    private func bridgeLogTail(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).flatMap { data -> String? in
            let tail = data.suffix(4096)
            return String(data: tail, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func finishMountOperation(
        _ operation: EDPFSKitMountOperationBox,
        error: String?
    ) {
        guard !operation.finished else { return }
        operation.finished = true
        activeMountOperations.remove(operation.sessionKey)
        cancelledMountOperations.remove(operation.sessionKey)
        let waiters = mountWaiters.removeValue(forKey: operation.sessionKey) ?? []
        operation.completion(error)
        for callback in waiters { callback(error) }
    }

    private func prepareFinderDefaultsAsync(
        bsd: String,
        sessionSuffix: String,
        owner: (uid_t, gid_t),
        completion: @escaping EDPBlockDeviceCompletion
    ) {
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
            completion(nil)
            return
        }

        let finish: @Sendable (String?) -> Void = { errorMessage in
            try? FileManager.default.removeItem(atPath: stagingMount)
            completion(errorMessage)
        }

        diskArbitration.mountNobrowseAsync(bsd, at: stagingMount) { [weak self] _, error in
            guard let self else {
                finish("mount manager was released")
                return
            }
            self.lifecycleQueue.async {
                if let error {
                    NSLog(
                        "EDP could not stage %@ with nobrowse; continuing with normal mount: %@",
                        bsd,
                        String(describing: error)
                    )
                    finish(nil)
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

                self.diskArbitration.unmountAsync(bsd) { [weak self] firstError in
                    guard let self else {
                        finish("mount manager was released")
                        return
                    }
                    self.lifecycleQueue.async {
                        guard let firstError else {
                            finish(nil)
                            return
                        }
                        self.diskArbitration.unmountAsync(bsd) { secondError in
                            self.lifecycleQueue.async {
                                if EDPNativeMountTable.mountPoint(forBSD: bsd) != nil {
                                    finish(String(describing: secondError ?? firstError))
                                    return
                                }
                                NSLog("EDP Finder staging unmount for %@ recovered after retry", bsd)
                                finish(nil)
                            }
                        }
                    }
                }
            }
        }
    }

    private func mountFATReadOnly(_ bsd: String, owner: (uid_t, gid_t)) throws -> String {
        let mountpoint = uniqueMountpoint("EDP Boot")
        try FileManager.default.createDirectory(
            atPath: mountpoint,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: mode_t(0o755))]
        )
        do {
            let status = try EDPNativeBoundedProcess.run(
                executable: "/sbin/mount_msdos",
                arguments: [
                    "-o", "rdonly",
                    "-u", String(owner.0),
                    "-g", String(owner.1),
                    "-m", "755",
                    "/dev/\(bsd)",
                    mountpoint,
                ],
                timeout: 20,
                label: "mount FAT16 read-only"
            )
            guard status == 0,
                  EDPNativeMountTable.isMountpoint(mountpoint),
                  EDPNativeMountTable.isReadOnly(mountpoint) == true else {
                throw fail("native FAT16 read-only mount failed for \(bsd): status=\(status)")
            }
            return mountpoint
        } catch {
            try? EDPNativeMountTable.unmountPath(mountpoint, force: true)
            try? FileManager.default.removeItem(atPath: mountpoint)
            throw error
        }
    }

    @discardableResult
    func removeMissing(availableDisks: [String: String], graceSeconds: TimeInterval = 5) -> Bool {
        lifecycleSync {
            let now = Date()
            var pending = false
            for (sessionKey, session) in Array(sessions) {
                if availableDisks[session.deviceID] == session.physicalBSD {
                    missingSince.removeValue(forKey: sessionKey)
                    continue
                }
                if let since = missingSince[sessionKey], now.timeIntervalSince(since) >= graceSeconds {
                    beginUnmount(sessionKey) { errorMessage in
                        if let errorMessage {
                            NSLog("EDP missing-device teardown failed for %@: %@", sessionKey, errorMessage)
                        }
                    }
                } else {
                    missingSince[sessionKey] = missingSince[sessionKey] ?? now
                    pending = true
                }
            }
            for operationKey in activeMountOperations {
                guard let separator = operationKey.lastIndex(of: ":") else { continue }
                let deviceID = String(operationKey[..<separator])
                if availableDisks[deviceID] == nil {
                    cancelledMountOperations.insert(operationKey)
                    pending = true
                }
            }
            return pending
        }
    }

    func unmountAsync(
        deviceID: String,
        partitionType: UInt32,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        let sessionKey = "\(deviceID):\(partitionType)"
        lifecycleQueue.async { [weak self] in
            guard let self else {
                completion("mount manager was released")
                return
            }
            self.requestUnmount(
                sessionKey,
                deadline: Date().addingTimeInterval(15),
                completion: completion
            )
        }
    }

    private func requestUnmount(
        _ sessionKey: String,
        deadline: Date,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        if activeMountOperations.contains(sessionKey) {
            cancelledMountOperations.insert(sessionKey)
            guard Date() < deadline else {
                completion("mount cancellation did not drain before unmount deadline")
                return
            }
            lifecycleQueue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                self?.requestUnmount(sessionKey, deadline: deadline, completion: completion)
            }
            return
        }
        beginUnmount(sessionKey, completion: completion)
    }

    private func beginUnmount(
        _ sessionKey: String,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        if unmountWaiters[sessionKey] != nil {
            unmountWaiters[sessionKey, default: []].append(completion)
            return
        }
        guard let session = sessions[sessionKey] else {
            completion(nil)
            return
        }
        unmountWaiters[sessionKey] = [completion]
        missingSince.removeValue(forKey: sessionKey)

        if let userMount = session.userMount, EDPNativeMountTable.isMountpoint(userMount) {
            do {
                try EDPNativeMountTable.unmountPath(userMount)
            } catch {
                finishUnmount(sessionKey, error: String(describing: error))
                return
            }
            guard !EDPNativeMountTable.isMountpoint(userMount) else {
                finishUnmount(
                    sessionKey,
                    error: "user volume remained mounted after unmount: \(userMount)"
                )
                return
            }
        }

        session.filesystemProcess?.terminate()
        if !session.exposedBSD.isEmpty {
            blockPublisher.unpublishAsync(
                EDPPublishedBlockDevice(
                    bsdName: session.exposedBSD,
                    backingPath: session.bridgeMount + "/volume.raw"
                )
            ) { [weak self] errorMessage in
                guard let self else { return }
                self.lifecycleQueue.async {
                    if let errorMessage {
                        self.finishUnmount(sessionKey, error: errorMessage)
                        return
                    }
                    self.stopSessionTransport(sessionKey, session: session)
                }
            }
            return
        }

        stopSessionTransport(sessionKey, session: session)
    }

    private func stopSessionTransport(_ sessionKey: String, session: MountSession) {
        session.transport.stopAsync(
            on: lifecycleQueue,
            unmount: { try EDPNativeMountTable.unmountPath($0, force: true) },
            isMounted: { EDPNativeMountTable.isMountpoint($0) },
            recoverStuckProcess: { EDPFSKitHostRecovery.restartConsoleAgentIfSafe() }
        ) { [weak self] _, _, errorMessage in
            guard let self else { return }
            if let errorMessage {
                self.finishUnmount(sessionKey, error: errorMessage)
                return
            }
            self.sessions.removeValue(forKey: sessionKey)
            try? FileManager.default.removeItem(atPath: session.bridgeMount)
            self.persistSessions()
            self.finishUnmount(sessionKey, error: nil)
        }
    }

    private func finishUnmount(_ sessionKey: String, error: String?) {
        if error != nil { persistSessions() }
        let callbacks = unmountWaiters.removeValue(forKey: sessionKey) ?? []
        for callback in callbacks { callback(error) }
    }

    func ejectAsync(deviceID: String, completion: @escaping EDPDaemonMountCompletion) {
        lifecycleQueue.async { [weak self] in
            guard let self else {
                completion("mount manager was released")
                return
            }
            if self.ejectWaiters[deviceID] != nil {
                self.ejectWaiters[deviceID, default: []].append(completion)
                return
            }
            self.ejectWaiters[deviceID] = [completion]
            let active = self.activeMountOperations.filter { $0.hasPrefix("\(deviceID):") }
            self.cancelledMountOperations.formUnion(active)
            self.waitForDeviceMountsToDrain(
                deviceID: deviceID,
                deadline: Date().addingTimeInterval(15)
            )
        }
    }

    private func waitForDeviceMountsToDrain(deviceID: String, deadline: Date) {
        if activeMountOperations.contains(where: { $0.hasPrefix("\(deviceID):") }) {
            guard Date() < deadline else {
                finishEject(deviceID, error: "mount operations did not drain before eject deadline")
                return
            }
            lifecycleQueue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                self?.waitForDeviceMountsToDrain(deviceID: deviceID, deadline: deadline)
            }
            return
        }
        let keys = sessions.compactMap { $0.value.deviceID == deviceID ? $0.key : nil }.sorted()
        teardownSessionKeys(keys, index: 0) { [weak self] errorMessage in
            self?.finishEject(deviceID, error: errorMessage)
        }
    }

    private func teardownSessionKeys(
        _ keys: [String],
        index: Int,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        guard index < keys.count else {
            completion(nil)
            return
        }
        beginUnmount(keys[index]) { [weak self] errorMessage in
            guard let self else { return }
            if let errorMessage {
                completion(errorMessage)
                return
            }
            self.teardownSessionKeys(keys, index: index + 1, completion: completion)
        }
    }

    private func finishEject(_ deviceID: String, error: String?) {
        let callbacks = ejectWaiters.removeValue(forKey: deviceID) ?? []
        for callback in callbacks { callback(error) }
    }

    func unmountAllAsync(completion: @escaping EDPDaemonMountCompletion) {
        lifecycleQueue.async { [weak self] in
            guard let self else {
                completion("mount manager was released")
                return
            }
            self.cancelledMountOperations.formUnion(self.activeMountOperations)
            self.waitForAllMountsToDrain(
                deadline: Date().addingTimeInterval(15),
                completion: completion
            )
        }
    }

    private func waitForAllMountsToDrain(
        deadline: Date,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        if !activeMountOperations.isEmpty {
            guard Date() < deadline else {
                completion("mount operations did not drain before shutdown deadline")
                return
            }
            lifecycleQueue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                self?.waitForAllMountsToDrain(deadline: deadline, completion: completion)
            }
            return
        }
        teardownSessionKeys(Array(sessions.keys).sorted(), index: 0) { [weak self] errorMessage in
            guard let self else { return }
            if errorMessage == nil, !self.sessions.isEmpty {
                completion("one or more EDP sessions could not be safely unmounted")
            } else {
                completion(errorMessage)
            }
        }
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

typealias EDPRawAccessLeaseOpening = @Sendable (PhysicalDisk) throws -> EDPRawAccessLease
typealias EDPCredentialVerifying = @Sendable (PhysicalDisk, UInt32, [UInt8], Int32) throws -> Void
typealias EDPRawAccessLeaseCompletion = @Sendable (EDPRawAccessLease?, String?) -> Void

private final class EDPSensitiveBytesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    func take() -> [UInt8] {
        lock.lock()
        let copy = bytes
        secureZero(&bytes)
        bytes.removeAll(keepingCapacity: false)
        lock.unlock()
        return copy
    }

    deinit {
        secureZero(&bytes)
    }
}

final class EDPDaemonController: @unchecked Sendable {
    private let store: EDPCredentialStore
    private let policies: EDPDevicePolicyStore
    private let manager: any EDPDaemonMountManaging
    private let diskArbitration: any EDPDaemonDiskArbitrating
    private let mediaProvider: any EDPWholeUSBMediaProviding
    private let metadataReader: any EDPRawMetadataReading
    private let rawAccessLeaseOpener: EDPRawAccessLeaseOpening
    private let credentialVerifier: EDPCredentialVerifying
    private let queue = DispatchQueue(label: "com.edp.drive.controller")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var failedMounts = [String: String]()
    private var manualUnmountSuppressions = Set<String>()
    private var defaultProbeSuppressions = Set<String>()
    private var activities = [EDPXPCActivity]()
    private var missingCleanupScheduled = false
    private var connectedDisks = [PhysicalDisk]()
    private var rawAccessLeases = [String: EDPRawAccessLease]()
    private var rawAccessProbeWaiters = [String: [EDPRawAccessLeaseCompletion]]()
    private var ejectingUSBRegistryIDs = [String: UInt64]()
    private var rawAccessReadyByDeviceID = [String: Bool]()
    private var rawAccessErrorsByDeviceID = [String: String]()
    private var lastDiscoveryDiagnostics = ["discovery_not_started"]
    private var discoveryScanCount: UInt64 = 0
    private var lastDiscoveryTimestamp = ""
    private var startupRecoveryComplete = false
    private var startupRecoveryError: String?
    private var shutdownRequested = false
    private var shutdownInProgress = false
    private var shutdownCompletions = [EDPDaemonMountCompletion]()

    init(
        store: EDPCredentialStore? = nil,
        policies: EDPDevicePolicyStore? = nil,
        manager: (any EDPDaemonMountManaging)? = nil,
        diskArbitration: (any EDPDaemonDiskArbitrating)? = nil,
        mediaProvider: any EDPWholeUSBMediaProviding = EDPIOKitWholeUSBMediaProvider(),
        metadataReader: any EDPRawMetadataReading = EDPPrivilegedRawMetadataReader(),
        rawAccessLeaseOpener: EDPRawAccessLeaseOpening? = nil,
        credentialVerifier: EDPCredentialVerifying? = nil,
        performLegacyRuntimeMigration: Bool = true
    ) throws {
        self.mediaProvider = mediaProvider
        queue.setSpecific(key: queueKey, value: 1)
        self.metadataReader = metadataReader
        self.rawAccessLeaseOpener = rawAccessLeaseOpener ?? { disk in
            try openPersistentRawAccess(for: disk, mediaProvider: mediaProvider)
        }
        self.credentialVerifier = credentialVerifier ?? { disk, partitionType, password, rawFD in
            try verifyPartitionType(
                disk: disk,
                partitionType: partitionType,
                password: password,
                rawFD: rawFD
            )
        }
        if performLegacyRuntimeMigration {
            try migrateLegacyRuntimeState()
        }
        self.store = try store ?? makeCredentialStore()
        self.policies = try policies ?? makePolicyStore()
        self.manager = try manager ?? MountManager()
        self.diskArbitration = try diskArbitration ?? EDPDiskArbitrationController()
        _ = try self.store.load()
        _ = try self.policies.load()
        if performLegacyRuntimeMigration {
            finalizeLegacyRuntimeStateMigration()
        }
        self.manager.recoverPersistedSessionsAsync { [weak self] errorMessage in
            guard let self else { return }
            self.onControllerQueue {
                self.startupRecoveryError = errorMessage
                self.startupRecoveryComplete = true
                if let errorMessage {
                    self.addActivity(
                        "启动时残留会话恢复失败：\(errorMessage)",
                        level: "error"
                    )
                }
                self.reconcileLocked()
            }
        }
    }

    private func key(_ deviceID: String, _ partitionType: UInt32) -> String {
        "\(deviceID):\(partitionType)"
    }

    private func onControllerQueue(_ body: @escaping @Sendable () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            body()
        } else {
            queue.async(execute: body)
        }
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

    private func probeDefaultPasswordsLocked(
        disks: [PhysicalDisk],
        policyDocument: EDPPolicyDocument
    ) throws {
        var records = try store.load().records
        for disk in disks where ejectingUSBRegistryIDs[disk.deviceID] == nil {
            guard let devicePolicy = policyDocument.devices.first(
                where: { $0.deviceID == disk.deviceID }
            ) else { continue }

            for partitionType in [UInt32(2), 4] {
                let partitionKey = key(disk.deviceID, partitionType)
                guard devicePolicy.policy(for: partitionType).autoProbePassword,
                      records.first(where: { $0.deviceID == disk.deviceID })?
                        .partitionTypes.contains(partitionType) != true,
                      !defaultProbeSuppressions.contains(partitionKey) else {
                    continue
                }

                do {
                    var password = try store.defaultProbePassword(partitionType: partitionType)
                    defer { secureZero(&password) }
                    guard let rawLease = rawAccessLeaseLocked(for: disk) else {
                        // Raw access acquisition is single-flight and asynchronous.
                        // Its completion schedules another reconcile; never block
                        // the controller here waiting for Disk Arbitration.
                        continue
                    }
                    try credentialVerifier(disk, partitionType, password, rawLease.fd)
                    try store.put(
                        deviceID: disk.deviceID,
                        partitionType: partitionType,
                        password: password
                    )
                    records = try store.load().records
                    failedMounts.removeValue(forKey: partitionKey)
                    addActivity(
                        "默认密码探测成功并已保存",
                        deviceID: disk.deviceID,
                        partitionType: partitionType
                    )
                } catch {
                    let detail = String(describing: error)
                    if detail.contains("EDP_RAW_BROKER_")
                        || detail.contains("EDP_RAW_LEASE_")
                        || isRawAccessPermissionFailure(error) {
                        rawAccessReadyByDeviceID[disk.deviceID] = false
                        rawAccessErrorsByDeviceID[disk.deviceID] = detail
                        continue
                    }
                    defaultProbeSuppressions.insert(partitionKey)
                    addActivity(
                        "默认密码未匹配，本次插盘不再自动探测",
                        deviceID: disk.deviceID,
                        partitionType: partitionType
                    )
                }
            }
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

    private func rawAccessProbeAsyncLocked(
        for disk: PhysicalDisk,
        temporarilyUnmount: Bool,
        completion: @escaping EDPRawAccessLeaseCompletion
    ) {
        if let lease = rawAccessLeaseLocked(for: disk) {
            rawAccessReadyByDeviceID[disk.deviceID] = true
            rawAccessErrorsByDeviceID.removeValue(forKey: disk.deviceID)
            completion(lease, nil)
            return
        }
        if rawAccessProbeWaiters[disk.deviceID] != nil {
            rawAccessProbeWaiters[disk.deviceID, default: []].append(completion)
            return
        }
        rawAccessProbeWaiters[disk.deviceID] = [completion]

        let openLease: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.onControllerQueue {
                guard self.ejectingUSBRegistryIDs[disk.deviceID] == nil,
                      let current = self.connectedDisks.first(where: { $0.deviceID == disk.deviceID }),
                      current.registryEntryID == disk.registryEntryID,
                      current.rawPath == disk.rawPath else {
                    self.finishRawAccessProbeLocked(
                        disk: disk,
                        lease: nil,
                        errorMessage: "EDP device changed while raw access was being prepared"
                    )
                    return
                }
                do {
                    let lease = try self.rawAccessLeaseOpener(disk)
                    self.finishRawAccessProbeLocked(disk: disk, lease: lease, errorMessage: nil)
                } catch {
                    let userError = userFacingRawAccessError(error)
                    self.finishRawAccessProbeLocked(
                        disk: disk,
                        lease: nil,
                        errorMessage: String(describing: userError)
                    )
                }
            }
        }

        guard temporarilyUnmount,
              EDPNativeMountTable.hasMountedBSDPrefix(disk.bsdName) else {
            openLease()
            return
        }
        diskArbitration.unmountWholeAsync(disk.bsdName) { [weak self] error in
            guard let self else { return }
            self.onControllerQueue {
                if let error {
                    self.finishRawAccessProbeLocked(
                        disk: disk,
                        lease: nil,
                        errorMessage: String(describing: error)
                    )
                    return
                }
                openLease()
            }
        }
    }

    private func finishRawAccessProbeLocked(
        disk: PhysicalDisk,
        lease: EDPRawAccessLease?,
        errorMessage: String?
    ) {
        if let lease {
            rawAccessLeases[disk.deviceID] = lease
            rawAccessReadyByDeviceID[disk.deviceID] = true
            rawAccessErrorsByDeviceID.removeValue(forKey: disk.deviceID)
        } else {
            rawAccessLeases.removeValue(forKey: disk.deviceID)
            rawAccessReadyByDeviceID[disk.deviceID] = false
            rawAccessErrorsByDeviceID[disk.deviceID] = errorMessage ?? "raw access probe failed"
        }
        let callbacks = rawAccessProbeWaiters.removeValue(forKey: disk.deviceID) ?? []
        for callback in callbacks { callback(lease, errorMessage) }
    }

    private func requireRawAccessLeaseAsyncLocked(
        for disk: PhysicalDisk,
        completion: @escaping EDPRawAccessLeaseCompletion
    ) {
        guard ejectingUSBRegistryIDs[disk.deviceID] == nil else {
            completion(nil, "EDP device was safely ejected; physically reinsert it before mounting")
            return
        }
        if let lease = rawAccessLeaseLocked(for: disk) {
            completion(lease, nil)
            return
        }
        rawAccessProbeAsyncLocked(for: disk, temporarilyUnmount: true, completion: completion)
    }

    private func mountBootAsyncLocked(
        disk: PhysicalDisk,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        let partitionType = EDPPartitionKind.boot.rawValue
        requireRawAccessLeaseAsyncLocked(for: disk) { [weak self] rawLease, errorMessage in
            guard let self else { return }
            self.onControllerQueue {
                if let errorMessage {
                    completion(errorMessage)
                    return
                }
                guard let rawLease else {
                    completion("EDP raw access lease was not retained")
                    return
                }
                self.manager.mountAsync(
                    disk: disk,
                    partitionType: partitionType,
                    password: [],
                    rawFD: rawLease.fd
                ) { [weak self] errorMessage in
                    guard let self else { return }
                    self.onControllerQueue { completion(errorMessage) }
                }
            }
        }
    }

    private func restoreBootPolicyAsyncLocked(disk: PhysicalDisk) {
        guard let document = try? policies.load(),
              document.globalAutoMountEnabled,
              let policy = document.devices.first(where: { $0.deviceID == disk.deviceID }),
              policy.policy(for: EDPPartitionKind.boot.rawValue).autoMount,
              !manualUnmountSuppressions.contains(
                  key(disk.deviceID, EDPPartitionKind.boot.rawValue)
              ),
              !manager.contains(disk, EDPPartitionKind.boot.rawValue) else { return }
        mountBootAsyncLocked(disk: disk) { [weak self] errorMessage in
            guard let self, let errorMessage else { return }
            self.failedMounts[self.key(disk.deviceID, EDPPartitionKind.boot.rawValue)] = errorMessage
        }
    }

    func reconcile() {
        queue.async { [weak self] in self?.reconcileLocked() }
    }

#if EDP_REGRESSION_TESTS
    func reconcileSynchronouslyForTesting() {
        queue.sync { reconcileLocked() }
    }

    func drainForTesting() {
        queue.sync {}
    }
#endif

    private func reconcileLocked() {
        guard startupRecoveryComplete, !shutdownRequested else { return }
        autoreleasepool {
            do {
                var scanDiagnostics = [String]()
                let disks = try discoverEDPDisks(
                    mediaProvider: mediaProvider,
                    metadataReader: metadataReader,
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
                where !mediaProvider.registryEntryExists(usbRegistryEntryID) {
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
                    rawAccessProbeAsyncLocked(for: disk, temporarilyUnmount: true) { [weak self] _, errorMessage in
                        guard let self else { return }
                        self.onControllerQueue {
                            if let errorMessage {
                                NSLog(
                                    "EDP Full Disk Access probe unavailable for %@: %@",
                                    disk.deviceID,
                                    errorMessage
                                )
                            } else {
                                // Re-run policy/probe/mount decisions now that the
                                // retained raw lease exists. The raw probe itself
                                // is single-flight, so this cannot recurse into a
                                // second acquisition for the same device.
                                self.reconcileLocked()
                            }
                        }
                    }
                }
                let availableDisks = Dictionary(
                    uniqueKeysWithValues: disks.map { ($0.deviceID, $0.bsdName) }
                )
                if manager.removeMissing(availableDisks: availableDisks, graceSeconds: 5),
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
                defaultProbeSuppressions = defaultProbeSuppressions.filter { item in
                    guard let separator = item.lastIndex(of: ":") else { return false }
                    return connectedDeviceIDs.contains(String(item[..<separator]))
                }
                try observe(disks)
                let policyDocument = try policies.load()
                try probeDefaultPasswordsLocked(disks: disks, policyDocument: policyDocument)
                let records = try store.load().records
                for disk in disks {
                    if ejectingUSBRegistryIDs[disk.deviceID] != nil {
                        if EDPNativeMountTable.hasMountedBSDPrefix(disk.bsdName) {
                            diskArbitration.unmountWholeAsync(disk.bsdName) { error in
                                if let error {
                                    NSLog(
                                        "EDP eject-pending whole unmount failed for %@: %@",
                                        disk.bsdName,
                                        String(describing: error)
                                    )
                                }
                            }
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
                       !manualUnmountSuppressions.contains(bootKey),
                       !manager.contains(disk, EDPPartitionKind.boot.rawValue) {
                        mountBootAsyncLocked(disk: disk) { [weak self] errorMessage in
                            guard let self else { return }
                            if let errorMessage {
                                self.failedMounts[bootKey] = errorMessage
                                self.addActivity(
                                    "启动区自动挂载失败：\(errorMessage)",
                                    level: "error",
                                    deviceID: disk.deviceID,
                                    partitionType: EDPPartitionKind.boot.rawValue
                                )
                            } else {
                                self.failedMounts.removeValue(forKey: bootKey)
                            }
                        }
                    }
                    // `autoMount == false` means "do not mount automatically".
                    // It must never tear down a partition the user mounted
                    // explicitly. Manual unmount is handled only by the user
                    // action path below.
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
                        mountEncryptedPartitionAsyncLocked(
                            disk: disk,
                            partitionType: type
                        ) { [weak self] errorMessage in
                            guard let self else { return }
                            self.restoreBootPolicyAsyncLocked(disk: disk)
                            if let errorMessage {
                                NSLog(
                                    "EDP auto-mount failed for %@ type %u; automatic retry paused until explicit user action or device reconnect: %@",
                                    disk.deviceID,
                                    type,
                                    errorMessage
                                )
                                self.addActivity(
                                    "自动挂载失败：\(errorMessage)",
                                    level: "error",
                                    deviceID: disk.deviceID,
                                    partitionType: type
                                )
                            } else {
                                self.addActivity(
                                    "自动挂载成功",
                                    deviceID: disk.deviceID,
                                    partitionType: type
                                )
                            }
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
                            autoMount: policy?.policy(for: kind.rawValue).autoMount ?? false,
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
                        metadataDeviceID: disk?.metadataDeviceID,
                        bsdName: disk?.bsdName ?? "",
                        mediaName: disk?.mediaName ?? policy?.lastMediaName ?? "EDP USB",
                        displayName: policy?.displayName ?? disk?.mediaName ?? "EDP USB",
                        vidPID: disk.map { "\($0.vidHex):\($0.pidHex)" }
                            ?? policy?.lastVIDPID ?? "-",
                        labelOnlyID: disk?.labelOnlyID,
                        sizeBytes: disk?.sizeBytes ?? policy?.lastSizeBytes ?? 0,
                        connected: disk != nil,
                        privilegedAccessReady: disk.map {
                            rawAccessReadyByDeviceID[$0.deviceID] == true
                        } ?? false,
                        partitions: partitions
                    )
                }
                let partitionDefaults = EDPPartitionKind.allCases.map { kind in
                    let policy = policyDocument.defaultPolicy(for: kind.rawValue)
                    return EDPXPCPartitionDefault(
                        partitionType: kind.rawValue,
                        displayName: kind.displayName,
                        autoMount: policy.autoMount,
                        autoProbePassword: kind.isEncrypted && policy.autoProbePassword,
                        defaultProbePasswordCustomized: kind.isEncrypted
                            && store.hasCustomizedDefaultProbePassword(partitionType: kind.rawValue)
                    )
                }
                return try JSONEncoder().encode(EDPXPCSnapshot(
                    devices: devices,
                    activities: activities,
                    serviceVersion: installedProductVersion(),
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    globalAutoMountEnabled: policyDocument.globalAutoMountEnabled,
                    partitionDefaults: partitionDefaults
                ))
            } catch {
                return Data("{\"error\":\"\(String(describing: error).replacingOccurrences(of: "\"", with: "'"))\"}".utf8)
            }
        }
    }

    func saveCredentialAsync(
        deviceID: String,
        partitionType: UInt32,
        passwordData: Data,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        let passwordBox = EDPSensitiveBytesBox([UInt8](passwordData))
        queue.async { [weak self] in
            guard let self else {
                completion("EDP service controller was released")
                return
            }
            guard self.startupRecoveryComplete, !self.shutdownRequested else {
                completion(self.shutdownRequested
                    ? "EDP service is shutting down"
                    : "EDP service startup recovery is still in progress")
                return
            }
            guard let disk = self.connectedDisks.first(where: { $0.deviceID == deviceID }) else {
                completion("EDP device is no longer connected")
                return
            }
            self.requireRawAccessLeaseAsyncLocked(for: disk) { [weak self] rawLease, rawError in
                guard let self else { return }
                self.onControllerQueue {
                    if let rawError {
                        completion(rawError)
                        return
                    }
                    guard let rawLease else {
                        completion("EDP raw access lease was not retained")
                        return
                    }
                    var password = passwordBox.take()
                    defer { secureZero(&password) }
                    do {
                        try self.credentialVerifier(
                            disk,
                            partitionType,
                            password,
                            rawLease.fd
                        )
                        try self.store.put(
                            deviceID: deviceID,
                            partitionType: partitionType,
                            password: password
                        )
                        self.failedMounts.removeValue(forKey: self.key(deviceID, partitionType))
                        self.addActivity(
                            "密码验证并保存成功",
                            deviceID: deviceID,
                            partitionType: partitionType
                        )
                        completion(nil)
                        self.reconcileLocked()
                    } catch {
                        completion(String(describing: userFacingRawAccessError(error)))
                    }
                }
            }
        }
    }

    func mountPartitionAsync(
        deviceID: String,
        partitionType: UInt32,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        queue.async { [weak self] in
            guard let self else {
                completion("EDP service controller was released")
                return
            }
            guard !self.shutdownRequested else {
                completion("EDP service is shutting down")
                return
            }
            let partitionKey = self.key(deviceID, partitionType)
            self.failedMounts.removeValue(forKey: partitionKey)
            self.manualUnmountSuppressions.remove(partitionKey)
            guard let disk = self.connectedDisks.first(where: { $0.deviceID == deviceID }) else {
                completion("EDP device is no longer connected")
                return
            }

            if partitionType == EDPPartitionKind.boot.rawValue {
                self.mountBootAsyncLocked(disk: disk) { [weak self] errorMessage in
                    guard let self else { return }
                    if let errorMessage {
                        self.failedMounts[partitionKey] = errorMessage
                        self.addActivity(
                            "手动挂载失败：\(errorMessage)",
                            level: "error",
                            deviceID: deviceID,
                            partitionType: partitionType
                        )
                    } else {
                        self.failedMounts.removeValue(forKey: partitionKey)
                        self.addActivity("手动挂载成功", deviceID: deviceID, partitionType: partitionType)
                    }
                    completion(errorMessage)
                }
                return
            }

            self.mountEncryptedPartitionAsyncLocked(
                disk: disk,
                partitionType: partitionType
            ) { [weak self] errorMessage in
                guard let self else { return }
                self.restoreBootPolicyAsyncLocked(disk: disk)
                if let errorMessage {
                    self.addActivity(
                        "手动挂载失败：\(errorMessage)",
                        level: "error",
                        deviceID: deviceID,
                        partitionType: partitionType
                    )
                } else {
                    self.addActivity("手动挂载成功", deviceID: deviceID, partitionType: partitionType)
                }
                completion(errorMessage)
            }
        }
    }

    private func mountEncryptedPartitionAsyncLocked(
        disk: PhysicalDisk,
        partitionType: UInt32,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        guard [UInt32(2), 4].contains(partitionType) else {
            completion("unsupported encrypted partition type")
            return
        }
        let passwordBox: EDPSensitiveBytesBox
        do {
            var password = try store.password(
                deviceID: disk.deviceID,
                partitionType: partitionType
            )
            passwordBox = EDPSensitiveBytesBox(password)
            secureZero(&password)
        } catch {
            completion(String(describing: error))
            return
        }

        requireRawAccessLeaseAsyncLocked(for: disk) { [weak self] rawLease, rawError in
            guard let self else { return }
            self.onControllerQueue {
                let partitionKey = self.key(disk.deviceID, partitionType)
                if let rawError {
                    self.failedMounts[partitionKey] = rawError
                    completion(rawError)
                    return
                }
                guard let rawLease else {
                    let detail = "EDP raw access lease was not retained"
                    self.failedMounts[partitionKey] = detail
                    completion(detail)
                    return
                }
                var password = passwordBox.take()
                defer { secureZero(&password) }
                self.manager.mountAsync(
                    disk: disk,
                    partitionType: partitionType,
                    password: password,
                    rawFD: rawLease.fd
                ) { [weak self] errorMessage in
                    guard let self else { return }
                    self.onControllerQueue {
                        if let errorMessage {
                            if errorMessage.contains("EDP_RAW_BROKER_")
                                || errorMessage.contains("EDP_RAW_LEASE_") {
                                self.rawAccessReadyByDeviceID[disk.deviceID] = false
                                self.rawAccessErrorsByDeviceID[disk.deviceID] = errorMessage
                            }
                            self.failedMounts[partitionKey] = errorMessage
                        } else {
                            self.rawAccessReadyByDeviceID[disk.deviceID] = true
                            self.rawAccessErrorsByDeviceID.removeValue(forKey: disk.deviceID)
                            self.failedMounts.removeValue(forKey: partitionKey)
                        }
                        completion(errorMessage)
                    }
                }
            }
        }
    }

    func unmountPartitionAsync(
        deviceID: String,
        partitionType: UInt32,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        queue.async { [weak self] in
            guard let self else {
                completion("EDP service controller was released")
                return
            }
            let partitionKey = self.key(deviceID, partitionType)
            self.manager.unmountAsync(
                deviceID: deviceID,
                partitionType: partitionType
            ) { [weak self] errorMessage in
                guard let self else { return }
                self.onControllerQueue {
                    if let errorMessage {
                        self.failedMounts[partitionKey] = errorMessage
                        self.addActivity(
                            "分区卸载失败：\(errorMessage)",
                            level: "error",
                            deviceID: deviceID,
                            partitionType: partitionType
                        )
                    } else {
                        self.manualUnmountSuppressions.insert(partitionKey)
                        self.failedMounts.removeValue(forKey: partitionKey)
                        self.addActivity("分区已卸载", deviceID: deviceID, partitionType: partitionType)
                    }
                    completion(errorMessage)
                }
            }
        }
    }

    func deleteCredentialAsync(
        deviceID: String,
        partitionType: UInt32,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        queue.async { [weak self] in
            guard let self else {
                completion("EDP service controller was released")
                return
            }
            self.manager.unmountAsync(
                deviceID: deviceID,
                partitionType: partitionType
            ) { [weak self] errorMessage in
                guard let self else { return }
                self.onControllerQueue {
                    if let errorMessage {
                        completion(errorMessage)
                        return
                    }
                    do {
                        try self.store.remove(deviceID: deviceID, partitionType: partitionType)
                        let partitionKey = self.key(deviceID, partitionType)
                        self.failedMounts.removeValue(forKey: partitionKey)
                        self.manualUnmountSuppressions.remove(partitionKey)
                        self.defaultProbeSuppressions.insert(partitionKey)
                        self.addActivity(
                            "已删除保存的密码",
                            deviceID: deviceID,
                            partitionType: partitionType
                        )
                        completion(nil)
                    } catch {
                        completion(String(describing: error))
                    }
                }
            }
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
            defaultProbeSuppressions = defaultProbeSuppressions.filter {
                !$0.hasPrefix("\(deviceID):")
            }
            addActivity("已删除设备记录和保存的密码", deviceID: deviceID)
        }
    }

    func setDefaultPartitionAutoMount(partitionType: UInt32, enabled: Bool) throws {
        try queue.sync {
            try policies.setDefaultAutoMount(partitionType: partitionType, enabled: enabled)
            addActivity(
                enabled ? "已开启新设备默认自动挂载" : "已关闭新设备默认自动挂载",
                partitionType: partitionType
            )
        }
    }

    func setDefaultPartitionAutoProbePassword(partitionType: UInt32, enabled: Bool) throws {
        try queue.sync {
            try policies.setDefaultAutoProbePassword(partitionType: partitionType, enabled: enabled)
            if enabled {
                for disk in connectedDisks {
                    defaultProbeSuppressions.remove(key(disk.deviceID, partitionType))
                }
            }
            addActivity(
                enabled ? "已开启新设备默认密码探测" : "已关闭新设备默认密码探测",
                partitionType: partitionType
            )
        }
    }

    func setDefaultProbePassword(partitionType: UInt32, passwordData: Data) throws {
        var password = [UInt8](passwordData)
        defer { secureZero(&password) }
        try queue.sync {
            try store.setDefaultProbePassword(partitionType: partitionType, password: password)
            for disk in connectedDisks {
                defaultProbeSuppressions.remove(key(disk.deviceID, partitionType))
            }
            addActivity("已更新默认探测密码", partitionType: partitionType)
        }
        reconcile()
    }

    func resetDefaultProbePassword(partitionType: UInt32) throws {
        try queue.sync {
            try store.resetDefaultProbePassword(partitionType: partitionType)
            for disk in connectedDisks {
                defaultProbeSuppressions.remove(key(disk.deviceID, partitionType))
            }
            addActivity("默认探测密码已恢复为 0000aaaa", partitionType: partitionType)
        }
        reconcile()
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

    func refreshRawAccessAsync(completion: @escaping EDPDaemonMountCompletion) {
        queue.async { [weak self] in
            guard let self else {
                completion("EDP service controller was released")
                return
            }
            let disks = self.connectedDisks.filter {
                self.ejectingUSBRegistryIDs[$0.deviceID] == nil
            }
            self.refreshRawAccessNextLocked(
                disks,
                index: 0,
                firstError: nil,
                completion: completion
            )
        }
    }

    private func refreshRawAccessNextLocked(
        _ disks: [PhysicalDisk],
        index: Int,
        firstError: String?,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        guard index < disks.count else {
            completion(firstError)
            reconcileLocked()
            return
        }
        let disk = disks[index]
        rawAccessProbeAsyncLocked(for: disk, temporarilyUnmount: true) { [weak self] _, errorMessage in
            guard let self else { return }
            self.onControllerQueue {
                let nextError = firstError ?? errorMessage
                if let errorMessage {
                    self.addActivity(
                        "完全磁盘访问不可用：\(errorMessage)",
                        level: "error",
                        deviceID: disk.deviceID
                    )
                } else {
                    self.addActivity("完全磁盘访问已验证", deviceID: disk.deviceID)
                }
                self.refreshRawAccessNextLocked(
                    disks,
                    index: index + 1,
                    firstError: nextError,
                    completion: completion
                )
            }
        }
    }

    func retryTransientAutomaticMounts() throws {
        let shouldReconcile = try queue.sync { () -> Bool in
            let policyDocument = try policies.load()
            guard policyDocument.globalAutoMountEnabled else { return false }

            var clearedAny = false
            for disk in connectedDisks where ejectingUSBRegistryIDs[disk.deviceID] == nil {
                guard let devicePolicy = policyDocument.devices.first(
                    where: { $0.deviceID == disk.deviceID }
                ) else { continue }

                for type in [UInt32(2), 4]
                where devicePolicy.policy(for: type).autoMount {
                    let partitionKey = key(disk.deviceID, type)
                    guard !manualUnmountSuppressions.contains(partitionKey),
                          let failure = failedMounts[partitionKey],
                          failure.contains("File system extension not found")
                            || failure.contains("File system extension not enabled") else {
                        continue
                    }
                    failedMounts.removeValue(forKey: partitionKey)
                    clearedAny = true
                    addActivity(
                        "macFUSE FSKit 已恢复，重试自动挂载",
                        deviceID: disk.deviceID,
                        partitionType: type
                    )
                }
            }
            return clearedAny
        }
        if shouldReconcile { reconcile() }
    }

    func ejectAsync(deviceID: String, completion: @escaping EDPDaemonMountCompletion) {
        queue.async { [weak self] in
            guard let self else {
                completion("EDP service controller was released")
                return
            }
            guard !self.shutdownRequested else {
                completion("EDP service is shutting down")
                return
            }
            guard let disk = self.connectedDisks.first(where: { $0.deviceID == deviceID }) else {
                completion("EDP device is no longer connected")
                return
            }
            if self.ejectingUSBRegistryIDs[deviceID] != nil {
                completion("EDP device eject is already in progress")
                return
            }

            self.ejectingUSBRegistryIDs[deviceID] = disk.usbRegistryEntryID
            self.diskArbitration.suppressAutomount(usbRegistryEntryID: disk.usbRegistryEntryID)
            self.manager.ejectAsync(deviceID: deviceID) { [weak self] teardownError in
                guard let self else { return }
                self.onControllerQueue {
                    if let teardownError {
                        self.recoverFailedEjectLocked(
                            disk: disk,
                            errorMessage: teardownError,
                            completion: completion
                        )
                        return
                    }

                    if let lease = self.rawAccessLeases.removeValue(forKey: deviceID) {
                        lease.invalidate()
                    }
                    self.rawAccessReadyByDeviceID[deviceID] = false
                    self.rawAccessErrorsByDeviceID.removeValue(forKey: deviceID)

                    self.performPhysicalEjectAsyncLocked(disk: disk) { [weak self] errorMessage in
                        guard let self else { return }
                        self.onControllerQueue {
                            if let errorMessage {
                                self.recoverFailedEjectLocked(
                                    disk: disk,
                                    errorMessage: errorMessage,
                                    completion: completion
                                )
                                return
                            }
                            self.connectedDisks.removeAll { $0.deviceID == deviceID }
                            self.rawAccessReadyByDeviceID.removeValue(forKey: deviceID)
                            self.rawAccessErrorsByDeviceID.removeValue(forKey: deviceID)
                            self.addActivity("设备已安全推出", deviceID: deviceID)
                            completion(nil)
                        }
                    }
                }
            }
        }
    }

    private func performPhysicalEjectAsyncLocked(
        disk: PhysicalDisk,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        let ejectNow: @Sendable () -> Void = { [weak self] in
            guard let self else {
                completion("EDP service controller was released")
                return
            }
            self.diskArbitration.ejectAsync(disk.bsdName) { [weak self] error in
                guard let self else { return }
                self.onControllerQueue {
                    completion(error.map { String(describing: $0) })
                }
            }
        }

        guard EDPNativeMountTable.hasMountedBSDPrefix(disk.bsdName) else {
            ejectNow()
            return
        }
        diskArbitration.unmountWholeAsync(disk.bsdName) { [weak self] error in
            guard let self else { return }
            self.onControllerQueue {
                if let error {
                    completion(String(describing: error))
                    return
                }
                ejectNow()
            }
        }
    }

    private func recoverFailedEjectLocked(
        disk: PhysicalDisk,
        errorMessage: String,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        ejectingUSBRegistryIDs.removeValue(forKey: disk.deviceID)
        diskArbitration.allowAutomount(usbRegistryEntryID: disk.usbRegistryEntryID)

        let finish: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.onControllerQueue {
                self.addActivity(
                    "设备安全推出失败：\(errorMessage)",
                    level: "error",
                    deviceID: disk.deviceID
                )
                completion(errorMessage)
            }
        }

        guard (try? wholeUSBMediaStillMatches(disk, mediaProvider: mediaProvider)) == true else {
            finish()
            return
        }
        rawAccessProbeAsyncLocked(for: disk, temporarilyUnmount: true) { [weak self] _, _ in
            guard let self else { return }
            self.onControllerQueue {
                self.restoreBootPolicyAsyncLocked(disk: disk)
                finish()
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
                "startupRecoveryComplete": startupRecoveryComplete,
                "startupRecoveryError": startupRecoveryError as Any,
                "deviceDiscoveryDiagnostics": EDPNativeDeviceDiscovery.diagnosticReport()
                    + lastDiscoveryDiagnostics,
                "discoveryScanCount": discoveryScanCount,
                "lastDiscoveryTimestamp": lastDiscoveryTimestamp,
            ]
            return (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        }
    }

    func shutdownGracefullyAsync(completion: @escaping EDPDaemonMountCompletion) {
        queue.async { [weak self] in
            guard let self else {
                completion("EDP service controller was released")
                return
            }
            self.shutdownCompletions.append(completion)
            guard !self.shutdownInProgress else { return }

            self.shutdownRequested = true
            self.shutdownInProgress = true
            self.manager.unmountAllAsync { [weak self] errorMessage in
                guard let self else { return }
                self.onControllerQueue {
                    var finalError = errorMessage
                    if finalError == nil, !self.manager.mountedSummaries().isEmpty {
                        finalError = "one or more EDP sessions could not be safely unmounted"
                    }
                    if finalError == nil {
                        for lease in self.rawAccessLeases.values { lease.invalidate() }
                        self.rawAccessLeases.removeAll()
                        self.rawAccessReadyByDeviceID.removeAll()
                        self.rawAccessErrorsByDeviceID.removeAll()
                        self.connectedDisks.removeAll()
                        self.addActivity("后台服务已安全停止")
                    } else {
                        // Failed shutdown remains quiesced. The caller can report
                        // the error without allowing new mount work to race the
                        // partially torn-down state.
                        self.addActivity(
                            "后台服务停止失败：\(finalError!)",
                            level: "error"
                        )
                    }
                    self.shutdownInProgress = false
                    let completions = self.shutdownCompletions
                    self.shutdownCompletions.removeAll()
                    for callback in completions { callback(finalError) }
                }
            }
        }
    }

#if EDP_REGRESSION_TESTS
    private func waitForRegressionOperation(
        timeout: TimeInterval = 45,
        start: (@escaping EDPDaemonMountCompletion) -> Void
    ) throws {
        guard DispatchQueue.getSpecific(key: queueKey) == nil else {
            throw fail("regression sync adapter cannot run on the controller queue")
        }
        let semaphore = DispatchSemaphore(value: 0)
        let result = EDPRegressionAsyncResultBox()
        start { errorMessage in
            result.set(errorMessage)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw fail("regression async operation timed out")
        }
        if let errorMessage = result.snapshot() {
            throw fail(errorMessage)
        }
    }

    func mountPartition(deviceID: String, partitionType: UInt32) throws {
        try waitForRegressionOperation {
            mountPartitionAsync(
                deviceID: deviceID,
                partitionType: partitionType,
                completion: $0
            )
        }
    }

    func unmountPartition(deviceID: String, partitionType: UInt32) throws {
        try waitForRegressionOperation {
            unmountPartitionAsync(
                deviceID: deviceID,
                partitionType: partitionType,
                completion: $0
            )
        }
    }

    func saveCredential(
        deviceID: String,
        partitionType: UInt32,
        passwordData: Data
    ) throws {
        try waitForRegressionOperation {
            saveCredentialAsync(
                deviceID: deviceID,
                partitionType: partitionType,
                passwordData: passwordData,
                completion: $0
            )
        }
    }

    func deleteCredential(deviceID: String, partitionType: UInt32) throws {
        try waitForRegressionOperation {
            deleteCredentialAsync(
                deviceID: deviceID,
                partitionType: partitionType,
                completion: $0
            )
        }
    }

    func eject(deviceID: String) throws {
        try waitForRegressionOperation {
            ejectAsync(deviceID: deviceID, completion: $0)
        }
    }

    func shutdownGracefully() throws {
        try waitForRegressionOperation {
            shutdownGracefullyAsync(completion: $0)
        }
    }
#endif
}

final class EDPXPCService: NSObject, NSXPCListenerDelegate, EDPVaultXPCProtocol, @unchecked Sendable {
    private let controller: EDPDaemonController
    private let didRequestShutdown: @Sendable () -> Void
    private let shutdownLock = NSLock()
    private var shutdownSignaled = false

    init(controller: EDPDaemonController, didRequestShutdown: @escaping @Sendable () -> Void) {
        self.controller = controller
        self.didRequestShutdown = didRequestShutdown
    }

    func healthCheck(withReply reply: @escaping (String) -> Void) {
        reply("com.edp.drive.service:running")
    }

    private func signalShutdownOnce() {
        shutdownLock.lock()
        let shouldSignal = !shutdownSignaled
        shutdownSignaled = true
        shutdownLock.unlock()
        if shouldSignal { didRequestShutdown() }
    }

    func requestGracefulShutdown(withReply reply: @escaping (String?) -> Void) {
        let replyBox = EDPSendableStringReply(reply)
        controller.shutdownGracefullyAsync { [weak self] errorMessage in
            replyBox(errorMessage)
            if errorMessage == nil {
                self?.signalShutdownOnce()
            }
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
        let replyBox = EDPSendableStringReply(reply)
        controller.refreshRawAccessAsync { errorMessage in
            replyBox(errorMessage)
        }
    }

    func retryTransientAutomaticMounts(withReply reply: @escaping (String?) -> Void) {
        do {
            try controller.retryTransientAutomaticMounts()
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
        let replyBox = EDPSendableStringReply(reply)
        controller.saveCredentialAsync(
            deviceID: deviceID,
            partitionType: partitionType,
            passwordData: password
        ) { errorMessage in
            replyBox(errorMessage)
        }
    }

    func deleteCredential(
        deviceID: String,
        partitionType: UInt32,
        withReply reply: @escaping (String?) -> Void
    ) {
        let replyBox = EDPSendableStringReply(reply)
        controller.deleteCredentialAsync(
            deviceID: deviceID,
            partitionType: partitionType
        ) { errorMessage in
            replyBox(errorMessage)
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

    func setDefaultPartitionAutoMount(
        partitionType: UInt32,
        enabled: Bool,
        withReply reply: @escaping (String?) -> Void
    ) {
        do {
            try controller.setDefaultPartitionAutoMount(
                partitionType: partitionType,
                enabled: enabled
            )
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func setDefaultPartitionAutoProbePassword(
        partitionType: UInt32,
        enabled: Bool,
        withReply reply: @escaping (String?) -> Void
    ) {
        do {
            try controller.setDefaultPartitionAutoProbePassword(
                partitionType: partitionType,
                enabled: enabled
            )
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func setDefaultProbePassword(
        partitionType: UInt32,
        password: Data,
        withReply reply: @escaping (String?) -> Void
    ) {
        do {
            try controller.setDefaultProbePassword(
                partitionType: partitionType,
                passwordData: password
            )
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func resetDefaultProbePassword(
        partitionType: UInt32,
        withReply reply: @escaping (String?) -> Void
    ) {
        do {
            try controller.resetDefaultProbePassword(partitionType: partitionType)
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
        let replyBox = EDPSendableStringReply(reply)
        controller.mountPartitionAsync(
            deviceID: deviceID,
            partitionType: partitionType
        ) { errorMessage in
            replyBox(errorMessage)
        }
    }

    func unmountPartition(
        deviceID: String,
        partitionType: UInt32,
        withReply reply: @escaping (String?) -> Void
    ) {
        let replyBox = EDPSendableStringReply(reply)
        controller.unmountPartitionAsync(
            deviceID: deviceID,
            partitionType: partitionType
        ) { errorMessage in
            replyBox(errorMessage)
        }
    }

    func eject(deviceID: String, withReply reply: @escaping (String?) -> Void) {
        let replyBox = EDPSendableStringReply(reply)
        controller.ejectAsync(deviceID: deviceID) { errorMessage in
            replyBox(errorMessage)
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
    let transportTools = [false, true].map {
        EDPTransportProvider.executableName(for: transportBackend, readOnly: $0)
    }
    for tool in transportTools + ["edp-console-exec", "edp-raw-metadata", "diskimages2-attach"] {
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

#if !EDP_REGRESSION_TESTS
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
                let manager = try MountManager()
                manager.recoverPersistedSessionsAsync { errorMessage in
                    if let errorMessage {
                        FileHandle.standardError.write(Data("ERROR=\(errorMessage)\n".utf8))
                        exit(1)
                    }
                    print("RESULT=EDP_PERSISTED_SESSION_CLEANUP_OK")
                    exit(0)
                }
                dispatchMain()
            case "daemon": try daemon()
            default: usage()
            }
        } catch {
            FileHandle.standardError.write(Data("ERROR=\(error)\n".utf8))
            exit(1)
        }
    }
}
#endif
