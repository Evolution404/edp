import Darwin
import Dispatch
import Foundation

final class EDPTransportReadinessSignal: EDPTransportReadinessObserving, @unchecked Sendable {
    private struct Observer {
        let queue: DispatchQueue
        let handler: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var ready = false
    private var closed = false
    private var observers = [Observer]()
    private var source: DispatchSourceRead?

    init(fileDescriptor: Int32) {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fileDescriptor,
            queue: DispatchQueue.global(qos: .utility)
        )
        self.source = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var marker: UInt8 = 0
            while true {
                let count = withUnsafeMutablePointer(to: &marker) {
                    Darwin.read(fileDescriptor, $0, 1)
                }
                if count == 1 {
                    if marker == UInt8(ascii: "R") {
                        self.finishReady()
                        return
                    }
                    continue
                }
                if count == 0 {
                    self.finishClosed()
                    return
                }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                self.finishClosed()
                return
            }
        }
        source.setCancelHandler {
            Darwin.close(fileDescriptor)
        }
        source.resume()
    }

    func observeReady(on queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if ready {
            lock.unlock()
            queue.async(execute: handler)
            return
        }
        guard !closed else {
            lock.unlock()
            return
        }
        observers.append(Observer(queue: queue, handler: handler))
        lock.unlock()
    }

    private func finishReady() {
        lock.lock()
        guard !ready, !closed else {
            lock.unlock()
            return
        }
        ready = true
        let callbacks = observers
        observers.removeAll()
        let source = self.source
        self.source = nil
        lock.unlock()
        source?.cancel()
        for callback in callbacks {
            callback.queue.async(execute: callback.handler)
        }
    }

    private func finishClosed() {
        lock.lock()
        guard !ready, !closed else {
            lock.unlock()
            return
        }
        closed = true
        observers.removeAll()
        let source = self.source
        self.source = nil
        lock.unlock()
        source?.cancel()
    }

    deinit {
        source?.cancel()
    }
}

struct EDPSpawnedTransport: Sendable {
    let process: EDPSpawnedProcess
    let readiness: EDPTransportReadinessSignal
}

final class EDPSpawnedProcess: EDPManagedProcess, @unchecked Sendable {
    private struct ExitObserver {
        let queue: DispatchQueue
        let handler: EDPProcessExitHandler
    }

    private let lock = NSLock()
    private let pid: pid_t
    private var reaped = false
    private var exitObservers = [ExitObserver]()

    init(pid: pid_t) {
        self.pid = pid
        DispatchQueue.global(qos: .utility).async { [self] in
            reapProcess()
        }
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !reaped
    }

    func observeExit(on queue: DispatchQueue, _ handler: @escaping EDPProcessExitHandler) {
        lock.lock()
        if reaped {
            lock.unlock()
            queue.async(execute: handler)
            return
        }
        exitObservers.append(ExitObserver(queue: queue, handler: handler))
        lock.unlock()
    }

    private func reapProcess() {
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(pid, &status, 0)
        } while result < 0 && errno == EINTR

        lock.lock()
        guard !reaped else {
            lock.unlock()
            return
        }
        reaped = true
        let observers = exitObservers
        exitObservers.removeAll()
        lock.unlock()

        for observer in observers {
            observer.queue.async(execute: observer.handler)
        }
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
) throws -> EDPSpawnedTransport {
    let launcher = binaryRoot + "/edp-console-exec"
    let argv = [launcher, String(identity.0), String(identity.1), "--", executable] + arguments
    var childEnvironment = environment
    childEnvironment["EDP_MFMOUNT_READY_FD"] = "4"
    let env = childEnvironment.map { "\($0.key)=\($0.value)" }

    var readyPipe = [Int32](repeating: -1, count: 2)
    guard readyPipe.withUnsafeMutableBufferPointer({ Darwin.pipe($0.baseAddress!) }) == 0 else {
        throw fail("cannot create transport readiness pipe: errno=\(errno)")
    }
    var parentOwnsReadyRead = true
    var parentOwnsReadyWrite = true
    defer {
        if parentOwnsReadyRead { Darwin.close(readyPipe[0]) }
        if parentOwnsReadyWrite { Darwin.close(readyPipe[1]) }
    }
    _ = fcntl(readyPipe[0], F_SETFD, FD_CLOEXEC)
    _ = fcntl(readyPipe[1], F_SETFD, FD_CLOEXEC)

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
    for (source, destination) in [
        (stdinFD, STDIN_FILENO),
        (logFD, STDOUT_FILENO),
        (logFD, STDERR_FILENO),
        (inheritedRawFD, 3),
        (readyPipe[1], 4),
    ] {
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
    Darwin.close(readyPipe[1])
    parentOwnsReadyWrite = false
    let readiness = EDPTransportReadinessSignal(fileDescriptor: readyPipe[0])
    parentOwnsReadyRead = false
    return EDPSpawnedTransport(
        process: EDPSpawnedProcess(pid: child),
        readiness: readiness
    )
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
    let exposedRegistryEntryID: UInt64?
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
        exposedRegistryEntryID: UInt64? = nil,
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
        self.exposedRegistryEntryID = exposedRegistryEntryID
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
    var cancellationHandler: (@Sendable () -> Void)?
    var terminalObservers = [@Sendable () -> Void]()
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
