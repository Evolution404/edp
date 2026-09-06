import Darwin
import Dispatch
import Foundation

struct EDPPublishedBlockDevice: Sendable {
    let bsdName: String
    let backingPath: String?
    let registryEntryID: UInt64?

    init(
        bsdName: String,
        backingPath: String? = nil,
        registryEntryID: UInt64? = nil
    ) {
        self.bsdName = bsdName
        self.backingPath = backingPath
        self.registryEntryID = registryEntryID
    }
}

typealias EDPBlockDeviceCompletion = @Sendable (String?) -> Void
typealias EDPBlockDevicePublishCompletion = @Sendable (EDPPublishedBlockDevice?, String?) -> Void
typealias EDPScratchBaselineCompletion = @Sendable (Set<String>?) -> Void
typealias EDPBooleanCompletion = @Sendable (Bool) -> Void

protocol EDPCancellableOperation: AnyObject, Sendable {
    func cancel()
}

/// Explicitly writable publication boundary used by the existing read/write
/// product path. Both publication and teardown are callback-based so the mount
/// lifecycle queue never waits for hdiutil, IOMedia teardown, or Disk Arbitration.
protocol EDPBlockDevicePublisher: AnyObject, Sendable {
    @discardableResult
    func publishWritableImageAsync(
        at path: String,
        completion: @escaping EDPBlockDevicePublishCompletion
    ) -> (any EDPCancellableOperation)?
    func unpublishAsync(_ device: EDPPublishedBlockDevice, completion: @escaping EDPBlockDeviceCompletion)
}

enum EDPBlockPublicationBackend: String, Sendable {
    case hdiutilCompatibility = "hdiutil-compatibility"
    case diskImageKitHostAttachment = "diskimagekit-host-attachment"
}

/// Central policy seam for host block-device publication.
///
/// `hdiutil` is the macOS 26 compatibility provider. macOS 27 introduces
/// DiskImageKit, but the currently documented API does not expose host IOMedia
/// attachment. Keep that future backend explicit without pretending an API
/// exists: it may be selected only after a public host-attachment capability is
/// implemented and positively probed.
enum EDPBlockDevicePublisherFactory {
    static func selectedBackend(
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        diskImageKitHostAttachmentAvailable: Bool = false
    ) -> EDPBlockPublicationBackend {
        if operatingSystemVersion.majorVersion >= 27,
           diskImageKitHostAttachmentAvailable {
            return .diskImageKitHostAttachment
        }
        return .hdiutilCompatibility
    }

    static func make(
        binaryRoot: String,
        diskArbitration: any EDPDaemonDiskArbitrating,
        metrics: EDPRuntimeMetrics = EDPRuntimeMetrics()
    ) throws -> any EDPBlockDevicePublisher {
        switch selectedBackend() {
        case .hdiutilCompatibility:
            return EDPHdiutilBlockDevicePublisher(
                binaryRoot: binaryRoot,
                diskArbitration: diskArbitration,
                metrics: metrics
            )
        case .diskImageKitHostAttachment:
            throw EDPBlockDevicePublisherError(
                "DiskImageKit host attachment was selected without a public host-IOMedia provider implementation"
            )
        }
    }
}

struct EDPBlockDevicePublisherError: Error, CustomStringConvertible, Sendable {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private struct EDPBoundedProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

private func publisherConsoleIdentity() throws -> (uid_t, gid_t) {
    var status = stat()
    guard stat("/dev/console", &status) == 0,
          status.st_uid != 0,
          getpwuid(status.st_uid) != nil else {
        throw EDPBlockDevicePublisherError("no authenticated console user is available for disk-image publication")
    }
    return (status.st_uid, status.st_gid)
}

private func processExecutablePath(_ pid: pid_t) -> String? {
    guard pid > 1 else { return nil }
    var buffer = [CChar](repeating: 0, count: 4096)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
    return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
}

private final class EDPExactResourceTerminationWaiter: @unchecked Sendable {
    private let queue: DispatchQueue
    private let media: [EDPIOMediaGeneration]
    private let timeout: TimeInterval
    private let completion: EDPBooleanCompletion
    private var mediaMonitors = [UInt64: EDPIOMediaTerminationMonitor]()
    private var remainingMedia = Set<UInt64>()
    private var finished = false
    private var keepAlive: EDPExactResourceTerminationWaiter?

    init(
        queue: DispatchQueue,
        media: [EDPIOMediaGeneration],
        timeout: TimeInterval,
        completion: @escaping EDPBooleanCompletion
    ) {
        self.queue = queue
        self.media = media
        self.timeout = timeout
        self.completion = completion
    }

    func start(afterArming action: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            guard !finished else { return }
            keepAlive = self
            remainingMedia = Set(media.map(\.registryEntryID))

            do {
                for generation in media {
                    let registryEntryID = generation.registryEntryID
                    mediaMonitors[registryEntryID] = try EDPIOMediaTerminationMonitor(
                        generation: generation,
                        queue: queue
                    ) { [weak self] in
                        guard let self else { return }
                        self.remainingMedia.remove(registryEntryID)
                        self.mediaMonitors.removeValue(forKey: registryEntryID)
                        self.completeIfTerminal()
                    }
                }
            } catch {
                finish(false)
                return
            }

            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, !self.finished else { return }
                self.finish(false)
            }

            action?()
            completeIfTerminal()
        }
    }

    private func completeIfTerminal() {
        guard remainingMedia.isEmpty else { return }
        finish(true)
    }

    private func finish(_ success: Bool) {
        guard !finished else { return }
        finished = true
        mediaMonitors.removeAll()
        completion(success)
        keepAlive = nil
    }
}

private final class EDPAsyncProcessOperation: EDPCancellableOperation, @unchecked Sendable {
    private enum TerminalReason {
        case normal
        case timeout
        case cancelled
    }

    private let queue: DispatchQueue
    private let executable: String
    private let arguments: [String]
    private let timeout: TimeInterval
    private let label: String
    private let completion: @Sendable (EDPBoundedProcessResult?, String?) -> Void
    private let stdoutURL: URL
    private let stderrURL: URL
    private let cancellationLock = NSLock()
    private var cancellationRequested = false
    private var process: Process?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var keepAlive: EDPAsyncProcessOperation?
    private var terminalReason: TerminalReason = .normal
    private var finished = false
    private var started = false

    init(
        queue: DispatchQueue,
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        label: String,
        completion: @escaping @Sendable (EDPBoundedProcessResult?, String?) -> Void
    ) {
        self.queue = queue
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.label = label
        self.completion = completion
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let token = UUID().uuidString
        stdoutURL = temporaryRoot.appendingPathComponent("edp-\(token).stdout")
        stderrURL = temporaryRoot.appendingPathComponent("edp-\(token).stderr")
    }

    func start() {
        queue.async { [self] in
            guard !finished else { return }
            keepAlive = self
            cancellationLock.lock()
            let wasCancelled = cancellationRequested
            cancellationLock.unlock()
            if wasCancelled { terminalReason = .cancelled }
            if case .cancelled = terminalReason {
                finish(result: nil, error: "\(label) cancelled before launch")
                return
            }
            do {
                _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
                _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
                let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
                let stderrHandle = try FileHandle(forWritingTo: stderrURL)
                self.stdoutHandle = stdoutHandle
                self.stderrHandle = stderrHandle

                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = stdoutHandle
                process.standardError = stderrHandle
                process.terminationHandler = { [weak self] _ in
                    guard let self else { return }
                    self.queue.async { [weak self] in self?.processDidExit() }
                }
                self.process = process
                try process.run()
                started = true
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.timeoutExpired()
                }
            } catch {
                finish(result: nil, error: "\(label) launch failed: \(error)")
            }
        }
    }

    func cancel() {
        cancellationLock.lock()
        cancellationRequested = true
        cancellationLock.unlock()
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.terminalReason = .cancelled
            guard self.started, self.process?.isRunning == true else {
                self.finish(result: nil, error: "\(self.label) cancelled")
                return
            }
            self.process?.terminate()
            self.scheduleForceTermination()
        }
    }

    private func timeoutExpired() {
        guard !finished, process?.isRunning == true else { return }
        guard case .normal = terminalReason else { return }
        terminalReason = .timeout
        process?.terminate()
        scheduleForceTermination()
    }

    private func scheduleForceTermination() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.finished, self.process?.isRunning == true else { return }
            if let pid = self.process?.processIdentifier, pid > 1 {
                _ = Darwin.kill(pid, SIGKILL)
            }
            self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.finished else { return }
                if self.process?.isRunning == true {
                    self.finish(
                        result: nil,
                        error: "\(self.label) remained alive after SIGKILL"
                    )
                }
            }
        }
    }

    private func processDidExit() {
        guard !finished, let process else { return }
        try? stdoutHandle?.synchronize()
        try? stderrHandle?.synchronize()
        let result = EDPBoundedProcessResult(
            status: process.terminationStatus,
            stdout: (try? Data(contentsOf: stdoutURL)) ?? Data(),
            stderr: (try? Data(contentsOf: stderrURL)) ?? Data()
        )
        switch terminalReason {
        case .normal:
            finish(result: result, error: nil)
        case .timeout:
            finish(result: result, error: "\(label) timed out after \(Int(timeout)) seconds")
        case .cancelled:
            finish(result: result, error: "\(label) cancelled")
        }
    }

    private func finish(result: EDPBoundedProcessResult?, error: String?) {
        guard !finished else { return }
        finished = true
        process?.terminationHandler = nil
        try? stdoutHandle?.close()
        try? stderrHandle?.close()
        stdoutHandle = nil
        stderrHandle = nil
        try? FileManager.default.removeItem(at: stdoutURL)
        try? FileManager.default.removeItem(at: stderrURL)
        completion(result, error)
        keepAlive = nil
    }
}

@discardableResult
private func runBoundedProcessAsync(
    on queue: DispatchQueue,
    executable: String,
    arguments: [String],
    timeout: TimeInterval,
    label: String,
    completion: @escaping @Sendable (EDPBoundedProcessResult?, String?) -> Void
) -> any EDPCancellableOperation {
    let operation = EDPAsyncProcessOperation(
        queue: queue,
        executable: executable,
        arguments: arguments,
        timeout: timeout,
        label: label,
        completion: completion
    )
    operation.start()
    return operation
}

/// macFUSE Local briefly creates a root-owned 4 KiB DiskImages scratch device
/// while asking FSKit to activate the Local filesystem module. A failed mount
/// can leave that helper-owned device behind even after MFMount has returned.
///
/// The cleanup below is intentionally fail-closed and narrow: it only touches
/// *new* root-owned, writable, removable, non-DiskImages2 4 KiB images whose
/// backing file is a UUID-named .dmg in root's /var/folders/zz temporary tree.
/// It must never be used as a generic disk-image cleanup mechanism.
struct EDPMacFUSEScratchImage: Sendable, Equatable {
    let imagePath: String
    let helperPID: pid_t
    let ownerUID: uid_t
    let blockCount: Int64
    let blockSize: Int64
    let autoDiskMount: Bool
    let diskImages2: Bool
    let writable: Bool
    let removable: Bool
    let devices: [String]

    var identity: String { imagePath }

    var isOrphanCleanupCandidate: Bool {
        guard ownerUID == 0,
              helperPID > 1,
              blockCount == 8,
              blockSize == 512,
              !autoDiskMount,
              !diskImages2,
              writable,
              removable,
              devices.count == 1,
              isWholeDisk(devices[0]) else {
            return false
        }

        let url = URL(fileURLWithPath: imagePath).standardizedFileURL
        guard url.pathExtension.lowercased() == "dmg",
              UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else {
            return false
        }
        let path = url.path
        return path.hasPrefix("/var/folders/zz/") || path.hasPrefix("/private/var/folders/zz/")
    }

    private func isWholeDisk(_ path: String) -> Bool {
        let prefix = "/dev/disk"
        guard path.hasPrefix(prefix) else { return false }
        let suffix = path.dropFirst(prefix.count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }
}

private final class EDPIOMediaGoneWaitOperation: @unchecked Sendable {
    private let queue: DispatchQueue
    private let generation: EDPIOMediaGeneration
    private let timeout: TimeInterval
    private let completion: EDPBooleanCompletion
    private var monitor: EDPIOMediaTerminationMonitor?
    private var finished = false
    private var keepAlive: EDPIOMediaGoneWaitOperation?

    init(
        queue: DispatchQueue,
        generation: EDPIOMediaGeneration,
        timeout: TimeInterval,
        completion: @escaping EDPBooleanCompletion
    ) {
        self.queue = queue
        self.generation = generation
        self.timeout = timeout
        self.completion = completion
    }

    func start() {
        queue.async { [self] in
            guard !finished else { return }
            keepAlive = self
            guard EDPIOKitMediaLifecycle.registryEntryExists(generation.registryEntryID) else {
                finish(true)
                return
            }
            do {
                monitor = try EDPIOMediaTerminationMonitor(
                    generation: generation,
                    queue: queue
                ) { [weak self] in
                    self?.finish(true)
                }
            } catch {
                finish(false)
                return
            }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, !self.finished else { return }
                self.finish(!EDPIOKitMediaLifecycle.registryEntryExists(self.generation.registryEntryID))
            }
        }
    }

    private func finish(_ gone: Bool) {
        guard !finished else { return }
        finished = true
        monitor = nil
        completion(gone)
        keepAlive = nil
    }
}

enum EDPMacFUSEScratchImageCleanup {
    private static let operationQueue = DispatchQueue(
        label: "com.edp.drive.macfuse-scratch-cleanup",
        qos: .utility
    )

    /// Returns nil when the baseline cannot be captured. Callers must skip
    /// cleanup in that case rather than treating an unknown baseline as empty.
    static func captureBaselineAsync(completion: @escaping EDPScratchBaselineCompletion) {
        currentImagesAsync { images, errorMessage in
            if let errorMessage {
                NSLog("EDP macFUSE scratch baseline unavailable: %@", errorMessage)
                completion(nil)
                return
            }
            completion(images.map { Set($0.map(\.identity)) })
        }
    }

    static func cleanupNewOrphansAsync(
        since baseline: Set<String>?,
        completion: @escaping @Sendable () -> Void
    ) {
        guard geteuid() == 0, let baseline else {
            operationQueue.async(execute: completion)
            return
        }
        // Transport teardown now completes only after the exact hidden source
        // IOMedia generation terminates. At that point any newly retained 4 KiB
        // scratch image is already orphaned; do not add a fixed grace delay.
        currentImagesAsync { images, errorMessage in
            if let errorMessage {
                NSLog("EDP macFUSE scratch cleanup skipped: %@", errorMessage)
                completion()
                return
            }
            let candidates = (images ?? []).filter {
                !baseline.contains($0.identity) && $0.isOrphanCleanupCandidate
            }
            cleanupCandidatesAsync(candidates, index: 0, completion: completion)
        }
    }

    /// Recovers one persisted macFUSE Local bridge after its transport process
    /// crashed before the normal signal-driven teardown could close MFChannel.
    /// The mountpoint and its exact /dev/diskN source must still match a narrow
    /// 4 KiB macFUSE scratch image candidate before public hdiutil detach is attempted.
    static func cleanupOrphanAsync(
        mountedAt mountpoint: String,
        completion: @escaping EDPBooleanCompletion
    ) {
        operationQueue.async {
            guard let source = mountSource(mountedAt: mountpoint),
                  source.hasPrefix("/dev/disk") else {
                completion(false)
                return
            }
            currentImagesAsync { images, errorMessage in
                if let errorMessage {
                    NSLog("EDP exact macFUSE orphan lookup failed: %@", errorMessage)
                    completion(false)
                    return
                }
                guard let image = orphanCandidate(forSource: source, in: images ?? []) else {
                    completion(false)
                    return
                }
                cleanupAsync(image) {
                    waitUntilGoneAsync(source, timeout: 2.0) { gone in
                        completion(gone && mountSource(mountedAt: mountpoint) == nil)
                    }
                }
            }
        }
    }

    static func orphanCandidate(
        forSource source: String,
        in images: [EDPMacFUSEScratchImage]
    ) -> EDPMacFUSEScratchImage? {
        guard source.hasPrefix("/dev/disk") else { return nil }
        return images.first {
            $0.devices == [source] && $0.isOrphanCleanupCandidate
        }
    }

    static func parseInfoPlist(_ data: Data) throws -> [EDPMacFUSEScratchImage] {
        guard let root = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
        let images = root["images"] as? [[String: Any]] else {
            throw EDPBlockDevicePublisherError("hdiutil info returned an invalid property list")
        }

        return images.compactMap { item in
            guard let imagePath = item["image-path"] as? String,
                  let helperPID = integer(item["hdid-pid"]),
                  let ownerUID = integer(item["owner-uid"]),
                  let blockCount = integer64(item["blockcount"]),
                  let blockSize = integer64(item["blocksize"]),
                  let autoDiskMount = item["autodiskmount"] as? Bool,
                  let diskImages2 = item["diskimages2"] as? Bool,
                  let writable = item["writeable"] as? Bool,
                  let removable = item["removable"] as? Bool,
                  let entities = item["system-entities"] as? [[String: Any]] else {
                return nil
            }
            let devices = entities.compactMap { $0["dev-entry"] as? String }
            return EDPMacFUSEScratchImage(
                imagePath: imagePath,
                helperPID: pid_t(helperPID),
                ownerUID: uid_t(ownerUID),
                blockCount: blockCount,
                blockSize: blockSize,
                autoDiskMount: autoDiskMount,
                diskImages2: diskImages2,
                writable: writable,
                removable: removable,
                devices: devices
            )
        }
    }

    private static func currentImagesAsync(
        completion: @escaping @Sendable ([EDPMacFUSEScratchImage]?, String?) -> Void
    ) {
        _ = runHdiutilAsync(["info", "-plist"]) { result, errorMessage in
            if let errorMessage {
                completion(nil, errorMessage)
                return
            }
            guard let result, result.status == 0 else {
                let status = result?.status ?? -1
                let detail = result.map { String(decoding: $0.stderr, as: UTF8.self) } ?? ""
                completion(nil, "hdiutil info failed (\(status)): \(detail)")
                return
            }
            do {
                completion(try parseInfoPlist(result.stdout), nil)
            } catch {
                completion(nil, String(describing: error))
            }
        }
    }

    private static func cleanupCandidatesAsync(
        _ images: [EDPMacFUSEScratchImage],
        index: Int,
        completion: @escaping @Sendable () -> Void
    ) {
        guard index < images.count else {
            completion()
            return
        }
        cleanupAsync(images[index]) {
            cleanupCandidatesAsync(images, index: index + 1, completion: completion)
        }
    }

    private static func cleanupAsync(
        _ image: EDPMacFUSEScratchImage,
        completion: @escaping @Sendable () -> Void
    ) {
        guard let device = image.devices.first else {
            completion()
            return
        }
        _ = runHdiutilAsync(["detach", device, "-force"]) { detach, _ in
            if detach?.status == 0 {
                waitUntilGoneAsync(device, timeout: 1.0) { gone in
                    if gone {
                        NSLog("EDP cleaned orphan macFUSE scratch device %@", device)
                    } else {
                        NSLog("EDP scratch detach returned success but exact IOMedia remained: %@", device)
                    }
                    completion()
                }
                return
            }

            // The helper belongs to macOS, not EDP. A failed public detach is
            // therefore a fail-closed cleanup result; never signal or kill the
            // Apple disk-image helper as a recovery mechanism.
            NSLog("EDP macFUSE scratch detach failed for %@; leaving system-owned helper untouched", device)
            completion()
        }
    }

    private static func waitUntilGoneAsync(
        _ device: String,
        timeout: TimeInterval,
        completion: @escaping EDPBooleanCompletion
    ) {
        let prefix = "/dev/"
        guard device.hasPrefix(prefix) else {
            completion(false)
            return
        }
        let bsdName = String(device.dropFirst(prefix.count))
        guard let generation = EDPIOKitMediaLifecycle.mediaGeneration(forBSDName: bsdName) else {
            // IOKit is the generation authority. No matching IOMedia means the
            // exact BSD generation is already gone; never stat /dev/diskN here.
            completion(true)
            return
        }
        EDPIOMediaGoneWaitOperation(
            queue: operationQueue,
            generation: generation,
            timeout: timeout,
            completion: completion
        ).start()
    }

    private static func mountSource(mountedAt mountpoint: String) -> String? {
        let expectedTarget = URL(fileURLWithPath: mountpoint)
            .resolvingSymlinksInPath().standardizedFileURL.path
        var entries: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&entries, MNT_NOWAIT)
        guard count > 0, let entries else { return nil }
        for index in 0..<Int(count) {
            let entry = entries[index]
            let target = withUnsafePointer(to: entry.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) {
                    String(cString: $0)
                }
            }
            let actualTarget = URL(fileURLWithPath: target)
                .resolvingSymlinksInPath().standardizedFileURL.path
            guard actualTarget == expectedTarget else { continue }
            return withUnsafePointer(to: entry.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) {
                    String(cString: $0)
                }
            }
        }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        return value as? Int
    }

    private static func integer64(_ value: Any?) -> Int64? {
        if let value = value as? NSNumber { return value.int64Value }
        return value as? Int64
    }

    @discardableResult
    private static func runHdiutilAsync(
        _ arguments: [String],
        completion: @escaping @Sendable (EDPBoundedProcessResult?, String?) -> Void
    ) -> any EDPCancellableOperation {
        runBoundedProcessAsync(
            on: operationQueue,
            executable: "/usr/bin/hdiutil",
            arguments: arguments,
            timeout: 8,
            label: "hdiutil \(arguments.first ?? "operation")",
            completion: completion
        )
    }
}

private final class EDPPublicationTerminationOperation: @unchecked Sendable {
    private let queue: DispatchQueue
    private let generation: EDPIOMediaGeneration
    private let diskArbitration: any EDPDaemonDiskArbitrating
    private let timeout: TimeInterval
    private let fallback: @Sendable (String?) -> Void
    private let completion: EDPBlockDeviceCompletion
    private var monitor: EDPIOMediaTerminationMonitor?
    private var finished = false
    private var fallbackStarted = false
    private var keepAlive: EDPPublicationTerminationOperation?

    init(
        queue: DispatchQueue,
        generation: EDPIOMediaGeneration,
        diskArbitration: any EDPDaemonDiskArbitrating,
        timeout: TimeInterval = 5,
        fallback: @escaping @Sendable (String?) -> Void,
        completion: @escaping EDPBlockDeviceCompletion
    ) {
        self.queue = queue
        self.generation = generation
        self.diskArbitration = diskArbitration
        self.timeout = timeout
        self.fallback = fallback
        self.completion = completion
    }

    func start() {
        queue.async { [self] in
            guard !finished else { return }
            keepAlive = self
            guard let current = EDPIOKitMediaLifecycle.mediaGeneration(forBSDName: generation.bsdName) else {
                finish(nil)
                return
            }
            guard current.registryEntryID == generation.registryEntryID else {
                finish(
                    "disk-image IOMedia generation changed for \(generation.bsdName); refusing stale teardown"
                )
                return
            }
            do {
                monitor = try EDPIOMediaTerminationMonitor(
                    generation: generation,
                    queue: queue
                ) { [weak self] in
                    self?.finish(nil)
                }
            } catch {
                finish("disk-image IOMedia termination monitor failed: \(error)")
                return
            }

            diskArbitration.ejectAsync(
                generation.bsdName,
                expectedRegistryEntryID: generation.registryEntryID
            ) { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    guard !self.finished else { return }
                    if !EDPIOKitMediaLifecycle.registryEntryExists(self.generation.registryEntryID) {
                        self.finish(nil)
                        return
                    }
                    if let error {
                        self.startFallback(String(describing: error))
                    }
                }
            }

            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, !self.finished else { return }
                if !EDPIOKitMediaLifecycle.registryEntryExists(self.generation.registryEntryID) {
                    self.finish(nil)
                    return
                }
                self.startFallback(
                    "exact disk-image IOMedia generation did not terminate after eject"
                )
            }
        }
    }

    private func startFallback(_ error: String?) {
        guard !finished, !fallbackStarted else { return }
        fallbackStarted = true
        monitor = nil
        keepAlive = nil
        fallback(error)
    }

    private func finish(_ error: String?) {
        guard !finished else { return }
        finished = true
        monitor = nil
        completion(error)
        keepAlive = nil
    }
}

final class EDPHdiutilBlockDevicePublisher: EDPBlockDevicePublisher, @unchecked Sendable {
    private let hdiutilPath = "/usr/bin/hdiutil"
    private let consoleLauncherPath: String
    private let diskArbitration: any EDPDaemonDiskArbitrating
    private let metrics: EDPRuntimeMetrics
    private let operationQueue = DispatchQueue(label: "com.edp.drive.block-publication")

    init(
        binaryRoot: String,
        diskArbitration: any EDPDaemonDiskArbitrating,
        metrics: EDPRuntimeMetrics = EDPRuntimeMetrics()
    ) {
        consoleLauncherPath = binaryRoot + "/edp-console-exec"
        self.diskArbitration = diskArbitration
        self.metrics = metrics
    }

    @discardableResult
    func publishWritableImageAsync(
        at path: String,
        completion: @escaping EDPBlockDevicePublishCompletion
    ) -> (any EDPCancellableOperation)? {
        guard FileManager.default.fileExists(atPath: path) else {
            operationQueue.async {
                completion(nil, "block image does not exist: \(path)")
            }
            return nil
        }
        guard FileManager.default.isExecutableFile(atPath: hdiutilPath) else {
            operationQueue.async {
                completion(nil, "Apple hdiutil is unavailable: \(self.hdiutilPath)")
            }
            return nil
        }
        guard FileManager.default.isExecutableFile(atPath: consoleLauncherPath) else {
            operationQueue.async {
                completion(nil, "console launcher is missing: \(self.consoleLauncherPath)")
            }
            return nil
        }
        let identity: (uid_t, gid_t)
        do {
            identity = try publisherConsoleIdentity()
        } catch {
            operationQueue.async {
                completion(nil, String(describing: error))
            }
            return nil
        }

        // The macFUSE Local transport and volume.raw are owned by the logged-in
        // console user. Use Apple's documented hdiutil frontend rather than
        // linking or dynamically loading the private DiskImages2 framework.
        // `-nomount` publishes the raw image as IOMedia without asking the OS to
        // mount a filesystem; the exact IOKit generation remains our lifecycle
        // authority after publication.
        return runBoundedProcessAsync(
            on: operationQueue,
            executable: consoleLauncherPath,
            arguments: [
                String(identity.0), String(identity.1), "--",
                hdiutilPath, "attach", "-nomount", "-readwrite", "-plist", path,
            ],
            timeout: 15,
            label: "console-user hdiutil raw attach"
        ) { result, errorMessage in
            if let errorMessage {
                completion(nil, errorMessage)
                return
            }
            guard let result, result.status == 0 else {
                let status = result?.status ?? -1
                let detail = result.map { String(decoding: $0.stderr, as: UTF8.self) } ?? ""
                completion(nil, "hdiutil raw attach failed (\(status)): \(detail)")
                return
            }

            guard let root = try? PropertyListSerialization.propertyList(
                from: result.stdout,
                options: [],
                format: nil
            ) as? [String: Any],
            let entities = root["system-entities"] as? [[String: Any]] else {
                completion(nil, "hdiutil attach returned an invalid property list")
                return
            }
            let wholeDevices = entities
                .compactMap { $0["dev-entry"] as? String }
                .compactMap { Self.wholeBSDName(fromDevicePath: $0) }
            guard let bsdName = wholeDevices.first,
                  let generation = EDPIOKitMediaLifecycle.mediaGeneration(forBSDName: bsdName) else {
                completion(nil, "hdiutil did not publish a stable whole IOMedia generation")
                return
            }
            completion(
                EDPPublishedBlockDevice(
                    bsdName: bsdName,
                    backingPath: URL(fileURLWithPath: path).standardizedFileURL.path,
                    registryEntryID: generation.registryEntryID
                ),
                nil
            )
        }
    }

    func unpublishAsync(
        _ device: EDPPublishedBlockDevice,
        completion: @escaping EDPBlockDeviceCompletion
    ) {
        operationQueue.async { [weak self] in
            guard let self else {
                completion("block publisher was released")
                return
            }
            guard let backingPath = device.backingPath,
                  self.isEDPTransportBackingPath(backingPath) else {
                completion("disk-image publication is missing its EDP backing identity")
                return
            }

            // Normal product sessions capture the exact synthetic IOMedia
            // registry generation at publication time.  That generation's IOKit
            // termination event is the teardown authority; do not poll hdiutil
            // or sleep waiting for a guessed quiescence interval.
            if let registryEntryID = device.registryEntryID {
                EDPPublicationTerminationOperation(
                    queue: self.operationQueue,
                    generation: EDPIOMediaGeneration(
                        bsdName: device.bsdName,
                        registryEntryID: registryEntryID
                    ),
                    diskArbitration: self.diskArbitration,
                    fallback: { [weak self] ejectError in
                        guard let self else {
                            completion("block publisher was released")
                            return
                        }
                        self.operationQueue.async {
                            self.recoverPublicationAfterEventTimeoutAsync(
                                device,
                                backingPath: backingPath,
                                ejectError: ejectError,
                                completion: completion
                            )
                        }
                    },
                    completion: completion
                ).start()
                return
            }

            // Legacy persisted sessions predate registry-generation persistence.
            // They cannot safely trust diskN because BSD names are reusable, so
            // use one exact backing-owner lookup only on this recovery path.
            self.unpublishLegacyPersistedDeviceAsync(
                device,
                backingPath: backingPath,
                completion: completion
            )
        }
    }

    private func unpublishLegacyPersistedDeviceAsync(
        _ device: EDPPublishedBlockDevice,
        backingPath: String,
        completion: @escaping EDPBlockDeviceCompletion
    ) {
        publicationAsync(backingPath: backingPath) { [weak self] candidate, lookupError in
            guard let self else {
                completion("block publisher was released")
                return
            }
            if let lookupError {
                completion(lookupError)
                return
            }
            guard let candidate else {
                completion(nil)
                return
            }
            if candidate.devicePaths.isEmpty {
                self.confirmDeadOwnerOnlyRetirementAsync(
                    candidate,
                    backingPath: backingPath
                ) { retired in
                    completion(retired ? nil : "disk image publication remains system-owned for \(backingPath)")
                }
                return
            }
            let expectedDevicePath = "/dev/\(device.bsdName)"
            guard candidate.devicePaths.contains(expectedDevicePath),
                  let generation = EDPIOKitMediaLifecycle.mediaGeneration(forBSDName: device.bsdName) else {
                completion(
                    "DiskImages2 persisted publication identity changed for \(backingPath); refusing stale teardown"
                )
                return
            }
            EDPPublicationTerminationOperation(
                queue: self.operationQueue,
                generation: generation,
                diskArbitration: self.diskArbitration,
                fallback: { [weak self] ejectError in
                    guard let self else {
                        completion("block publisher was released")
                        return
                    }
                    self.operationQueue.async {
                        self.recoverPublicationAfterEventTimeoutAsync(
                            EDPPublishedBlockDevice(
                                bsdName: device.bsdName,
                                backingPath: backingPath,
                                registryEntryID: generation.registryEntryID
                            ),
                            backingPath: backingPath,
                            ejectError: ejectError,
                            completion: completion
                        )
                    }
                },
                completion: completion
            ).start()
        }
    }

    private func recoverPublicationAfterEventTimeoutAsync(
        _ device: EDPPublishedBlockDevice,
        backingPath: String,
        ejectError: String?,
        completion: @escaping EDPBlockDeviceCompletion
    ) {
        metrics.increment(.diskImagesDetachRecovery)
        guard let registryEntryID = device.registryEntryID else {
            completion("disk image recovery requires an exact IOMedia generation")
            return
        }
        let expectedGeneration = EDPIOMediaGeneration(
            bsdName: device.bsdName,
            registryEntryID: registryEntryID
        )
        guard EDPIOKitMediaLifecycle.mediaGeneration(forBSDName: device.bsdName) == expectedGeneration else {
            completion("disk image generation changed for \(device.bsdName); refusing stale detach")
            return
        }
        if let ejectError {
            NSLog(
                "EDP exact-generation eject for %@ reported %@; trying bounded public hdiutil detach",
                backingPath,
                ejectError
            )
        }

        EDPExactResourceTerminationWaiter(
            queue: operationQueue,
            media: [expectedGeneration],
            timeout: 3.0
        ) { terminated in
            completion(
                terminated
                    ? nil
                    : "exact disk image IOMedia generation remained after public detach for \(backingPath)"
            )
        }.start(afterArming: { [weak self] in
            guard let self,
                  EDPIOKitMediaLifecycle.mediaGeneration(forBSDName: device.bsdName) == expectedGeneration else {
                return
            }
            _ = runBoundedProcessAsync(
                on: self.operationQueue,
                executable: self.hdiutilPath,
                arguments: ["detach", "/dev/\(device.bsdName)", "-force"],
                timeout: 8,
                label: "hdiutil exact-generation detach"
            ) { result, errorMessage in
                if let errorMessage {
                    NSLog("EDP hdiutil detach failed for %@: %@", backingPath, errorMessage)
                } else if let result, result.status != 0 {
                    NSLog("EDP hdiutil detach exited %d for %@", result.status, backingPath)
                }
            }
        })
    }

    private struct DiskImagesPublication: Equatable {
        let pid: pid_t
        let imagePath: String
        let ownerUID: uid_t
        let devicePaths: [String]
    }

    private static func isStableDeadOwnerOnlyRetirement(
        original: DiskImagesPublication,
        revalidated: DiskImagesPublication,
        revalidatedOwnerExecutablePath: String?
    ) -> Bool {
        original.devicePaths.isEmpty
            && revalidated == original
            && revalidatedOwnerExecutablePath == nil
    }

    private func confirmDeadOwnerOnlyRetirementAsync(
        _ original: DiskImagesPublication,
        backingPath: String,
        completion: @escaping EDPBooleanCompletion
    ) {
        guard geteuid() == 0,
              original.devicePaths.isEmpty,
              processExecutablePath(original.pid) == nil else {
            completion(false)
            return
        }

        // macOS 26 can retain an hdiutil metadata tombstone after the exact
        // diskimagesiod owner has exited and all IOMedia entities are gone.
        // Revalidate the exact owner snapshot immediately; time is not an
        // ownership signal. Any PID/entity/owner change is a new or ambiguous
        // generation and remains fail-closed.
        publicationAsync(backingPath: backingPath) { revalidated, errorMessage in
            guard errorMessage == nil else {
                completion(false)
                return
            }
            guard let revalidated else {
                completion(true)
                return
            }
            completion(
                Self.isStableDeadOwnerOnlyRetirement(
                    original: original,
                    revalidated: revalidated,
                    revalidatedOwnerExecutablePath: processExecutablePath(revalidated.pid)
                )
            )
        }
    }

    private func publicationAsync(
        backingPath: String,
        completion: @escaping @Sendable (DiskImagesPublication?, String?) -> Void
    ) {
        _ = runBoundedProcessAsync(
            on: operationQueue,
            executable: "/usr/bin/hdiutil",
            arguments: ["info", "-plist"],
            timeout: 8,
            label: "hdiutil info for DiskImages2 recovery"
        ) { [weak self] result, errorMessage in
            guard let self else {
                completion(nil, "block publisher was released")
                return
            }
            if let errorMessage {
                completion(nil, errorMessage)
                return
            }
            guard let result, result.status == 0 else {
                let status = result?.status ?? -1
                completion(nil, "hdiutil info failed (\(status))")
                return
            }
            completion(self.parsePublication(result.stdout, backingPath: backingPath), nil)
        }
    }

    private func parsePublication(
        _ data: Data,
        backingPath: String
    ) -> DiskImagesPublication? {
        guard let root = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
        let images = root["images"] as? [[String: Any]] else {
            return nil
        }

        let expected = URL(fileURLWithPath: backingPath).standardizedFileURL.path
        var consoleStatus = stat()
        let consoleUID: uid_t? = stat("/dev/console", &consoleStatus) == 0
            ? consoleStatus.st_uid
            : nil

        for item in images {
            guard let imagePath = item["image-path"] as? String,
                  URL(fileURLWithPath: imagePath).standardizedFileURL.path == expected,
                  let ownerValue = item["owner-uid"] as? NSNumber,
                  ownerValue.intValue >= 0,
                  let ownerUID = uid_t(exactly: ownerValue.uint64Value),
                  ownerUID == 0 || ownerUID == consoleUID,
                  (item["diskimages2"] as? NSNumber)?.boolValue == true,
                  (item["autodiskmount"] as? NSNumber)?.boolValue == false,
                  (item["image-encrypted"] as? NSNumber)?.boolValue == false,
                  (item["owner-mode"] as? NSNumber)?.intValue == 0o600,
                  let entities = item["system-entities"] as? [[String: Any]],
                  let pidValue = item["hdid-pid"] as? NSNumber,
                  pidValue.intValue > 1 else {
                continue
            }
            // Teardown must never synchronously stat the macFUSE backing path or
            // the synthetic BSD nodes. Either can be in a transient FSKit/LIFS
            // generation while DiskImages2 is exiting and can place the root
            // service itself into an uninterruptible wait. The exact hdiutil
            // owner snapshot is authoritative here: image-path + owner/mode +
            // DiskImages2/autodiskmount/encryption flags + hdid PID + exact
            // system-entity strings. Process identity is revalidated separately
            // before any owner recovery signal is sent.
            let devicePaths = entities.compactMap { $0["dev-entry"] as? String }
            guard devicePaths.allSatisfy(Self.isSyntheticBSDDevicePath) else {
                continue
            }
            return DiskImagesPublication(
                pid: pid_t(pidValue.intValue),
                imagePath: imagePath,
                ownerUID: ownerUID,
                devicePaths: devicePaths
            )
        }
        return nil
    }

    private static func wholeBSDName(fromDevicePath path: String) -> String? {
        let prefix = "/dev/disk"
        guard path.hasPrefix(prefix) else { return nil }
        let suffix = path.dropFirst(prefix.count)
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return nil }
        return "disk\(suffix)"
    }

    private static func isSyntheticBSDDevicePath(_ path: String) -> Bool {
        let prefix = "/dev/disk"
        guard path.hasPrefix(prefix) else { return false }
        let suffix = path.dropFirst(prefix.count)
        guard !suffix.isEmpty else { return false }
        return suffix.split(separator: "s", omittingEmptySubsequences: false).allSatisfy { component in
            !component.isEmpty && component.allSatisfy { $0.isNumber }
        }
    }

    private func isEDPTransportBackingPath(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path.hasPrefix("/Volumes/.edp-block-"),
              url.lastPathComponent == "volume.raw",
              url.deletingLastPathComponent().lastPathComponent.hasPrefix(".edp-block-") else {
            return false
        }
        return true
    }

}

#if EDP_REGRESSION_TESTS
extension EDPHdiutilBlockDevicePublisher {
    static func regressionStableDeadOwnerOnlyRetirement(
        originalPID: Int32,
        originalOwnerUID: UInt32,
        originalDevices: [String],
        revalidatedPID: Int32,
        revalidatedOwnerUID: UInt32,
        revalidatedDevices: [String],
        revalidatedOwnerExecutablePath: String?
    ) -> Bool {
        let imagePath = "/Volumes/.edp-block-regression/volume.raw"
        return isStableDeadOwnerOnlyRetirement(
            original: DiskImagesPublication(
                pid: pid_t(originalPID),
                imagePath: imagePath,
                ownerUID: uid_t(originalOwnerUID),
                devicePaths: originalDevices
            ),
            revalidated: DiskImagesPublication(
                pid: pid_t(revalidatedPID),
                imagePath: imagePath,
                ownerUID: uid_t(revalidatedOwnerUID),
                devicePaths: revalidatedDevices
            ),
            revalidatedOwnerExecutablePath: revalidatedOwnerExecutablePath
        )
    }
}

private let edpPublisherRegressionQueue = DispatchQueue(
    label: "com.edp.drive.block-publication-regression"
)

enum EDPAsyncPublisherProcessRegressionHarness {
    @discardableResult
    static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        completion: @escaping @Sendable (Int32?, String, String?) -> Void
    ) -> any EDPCancellableOperation {
        runBoundedProcessAsync(
            on: edpPublisherRegressionQueue,
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            label: "publisher regression process"
        ) { result, errorMessage in
            completion(
                result?.status,
                result.map { String(decoding: $0.stdout, as: UTF8.self) } ?? "",
                errorMessage
            )
        }
    }
}
#endif
