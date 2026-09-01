import Darwin
import Foundation

final class EDPSpawnedProcess: EDPManagedProcess, @unchecked Sendable {
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

func spawnConsoleTransport(
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

func safeName(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let converted = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
    let result = String(converted).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return result.isEmpty ? "EDP" : String(result.prefix(48))
}

final class MountSession: @unchecked Sendable {
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

final class EDPFSKitMountOperationBox: @unchecked Sendable {
    var machine = EDPFSKitMountLifecycleMachine()
    let sessionKey: String
    let disk: PhysicalDisk
    let partitionType: UInt32
    var password: [UInt8]
    let rawFD: Int32
    let journalContext: EDPLifecycleOperationContext
    let completion: EDPDaemonMountCompletion
    var publicationOperation: (any EDPCancellableOperation)?
    var quiescenceWaitRecorded = false
    var finished = false

    init(
        sessionKey: String,
        disk: PhysicalDisk,
        partitionType: UInt32,
        password: [UInt8],
        rawFD: Int32,
        journalContext: EDPLifecycleOperationContext,
        completion: @escaping EDPDaemonMountCompletion
    ) {
        self.sessionKey = sessionKey
        self.disk = disk
        self.partitionType = partitionType
        self.password = password
        self.rawFD = rawFD
        self.journalContext = journalContext
        self.completion = completion
    }

    deinit { secureZero(&password) }
}
