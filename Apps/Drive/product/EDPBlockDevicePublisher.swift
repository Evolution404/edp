import Darwin
import Foundation

struct EDPPublishedBlockDevice: Sendable {
    let bsdName: String
    let backingPath: String?

    init(bsdName: String, backingPath: String? = nil) {
        self.bsdName = bsdName
        self.backingPath = backingPath
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
/// lifecycle queue never waits for DiskImages2, hdiutil, or Disk Arbitration.
protocol EDPBlockDevicePublisher: AnyObject, Sendable {
    @discardableResult
    func publishWritableImageAsync(
        at path: String,
        completion: @escaping EDPBlockDevicePublishCompletion
    ) -> (any EDPCancellableOperation)?
    func unpublishAsync(_ device: EDPPublishedBlockDevice, completion: @escaping EDPBlockDeviceCompletion)
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
        throw EDPBlockDevicePublisherError("no authenticated console user is available for DiskImages2 publication")
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
        // Give macFUSE's normal failure teardown a short opportunity to remove
        // its scratch image before applying the orphan-only fallback. This is a
        // scheduled delay, never a blocking sleep on the mount lifecycle queue.
        operationQueue.asyncAfter(deadline: .now() + .milliseconds(500)) {
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
    }

    /// Recovers one persisted macFUSE Local bridge after its transport process
    /// crashed before the normal signal-driven teardown could close MFChannel.
    /// The mountpoint and its exact /dev/diskN source must still match a narrow
    /// 4 KiB macFUSE scratch image candidate before its helper can be signalled.
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
            if detach?.status == 0 || !FileManager.default.fileExists(atPath: device) {
                NSLog("EDP cleaned orphan macFUSE scratch device %@", device)
                completion()
                return
            }

            // hdiutil can report EBUSY for the exact failure mode this path handles.
            // Revalidate the tuple immediately before signalling the helper so PID
            // reuse or an unrelated disk image can never turn into a kill target.
            stillMatchesAsync(image) { matches in
                guard matches else {
                    NSLog("EDP refused to signal changed macFUSE scratch helper for %@", device)
                    completion()
                    return
                }
                _ = Darwin.kill(image.helperPID, SIGTERM)
                waitUntilGoneAsync(device, timeout: 0.75) { gone in
                    if gone {
                        NSLog("EDP cleaned orphan macFUSE scratch device %@ after helper SIGTERM", device)
                        completion()
                        return
                    }
                    stillMatchesAsync(image) { matchesAfterTerm in
                        guard matchesAfterTerm else {
                            completion()
                            return
                        }
                        _ = Darwin.kill(image.helperPID, SIGKILL)
                        waitUntilGoneAsync(device, timeout: 1.0) { killed in
                            if killed {
                                NSLog("EDP cleaned orphan macFUSE scratch device %@ after helper SIGKILL", device)
                            } else {
                                NSLog("EDP macFUSE scratch device remained after forced cleanup: %@", device)
                            }
                            completion()
                        }
                    }
                }
            }
        }
    }

    private static func stillMatchesAsync(
        _ expected: EDPMacFUSEScratchImage,
        completion: @escaping EDPBooleanCompletion
    ) {
        currentImagesAsync { images, _ in
            completion((images ?? []).contains {
                $0.identity == expected.identity
                    && $0.helperPID == expected.helperPID
                    && $0.devices == expected.devices
                    && $0.isOrphanCleanupCandidate
            })
        }
    }

    private static func waitUntilGoneAsync(
        _ device: String,
        timeout: TimeInterval,
        completion: @escaping EDPBooleanCompletion
    ) {
        let deadline = DispatchTime.now() + timeout
        @Sendable func poll() {
            if !FileManager.default.fileExists(atPath: device) {
                completion(true)
                return
            }
            if DispatchTime.now() >= deadline {
                completion(false)
                return
            }
            operationQueue.asyncAfter(deadline: .now() + .milliseconds(50)) {
                poll()
            }
        }
        poll()
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

final class EDPDiskImages2Publisher: EDPBlockDevicePublisher, @unchecked Sendable {
    private let helperPath: String
    private let consoleLauncherPath: String
    private let diskArbitration: any EDPDaemonDiskArbitrating
    private let operationQueue = DispatchQueue(label: "com.edp.drive.block-publication")

    init(binaryRoot: String, diskArbitration: any EDPDaemonDiskArbitrating) {
        helperPath = binaryRoot + "/diskimages2-attach"
        consoleLauncherPath = binaryRoot + "/edp-console-exec"
        self.diskArbitration = diskArbitration
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
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            operationQueue.async {
                completion(nil, "DiskImages2 adapter helper is missing: \(self.helperPath)")
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
        // console user. Publishing in that user session preserves the TEST-F-
        // proven IOMedia lifecycle without blocking the mount lifecycle queue.
        return runBoundedProcessAsync(
            on: operationQueue,
            executable: consoleLauncherPath,
            arguments: [
                String(identity.0), String(identity.1), "--",
                helperPath, "--writable-noautomount", path,
            ],
            timeout: 15,
            label: "console-user DiskImages2 writable attach"
        ) { result, errorMessage in
            if let errorMessage {
                completion(nil, errorMessage)
                return
            }
            guard let result, result.status == 0 else {
                let status = result?.status ?? -1
                let detail = result.map { String(decoding: $0.stderr, as: UTF8.self) } ?? ""
                completion(nil, "DiskImages2 adapter failed (\(status)): \(detail)")
                return
            }

            let text = String(decoding: result.stdout, as: UTF8.self)
            guard let bsdName = text.split(separator: "\n")
                .first(where: { $0.hasPrefix("DI_BSD_NAME=") })?
                .split(separator: "=", maxSplits: 1).last.map(String.init),
                FileManager.default.fileExists(atPath: "/dev/\(bsdName)") else {
                completion(nil, "DiskImages2 adapter did not publish a BSD device")
                return
            }
            completion(
                EDPPublishedBlockDevice(
                    bsdName: bsdName,
                    backingPath: URL(fileURLWithPath: path).standardizedFileURL.path
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
                completion("DiskImages2 publication is missing its EDP backing identity")
                return
            }

            // Never trust a persisted diskN by itself. macOS can reuse that BSD
            // name for an unrelated device after the synthetic publication
            // disappears. Exact volume.raw backing identity remains authoritative.
            self.publicationAsync(backingPath: backingPath) { [weak self] candidate, lookupError in
                guard let self else {
                    completion("block publisher was released")
                    return
                }
                if let lookupError {
                    completion(lookupError)
                    return
                }
                guard let candidate else {
                    NSLog(
                        "EDP DiskImages2 publication already absent for %@; ignoring stale BSD name %@",
                        backingPath,
                        device.bsdName
                    )
                    completion(nil)
                    return
                }

                if candidate.devicePaths.isEmpty {
                    self.recoverPublicationAsync(candidate, backingPath: backingPath) { recovered in
                        if recovered {
                            NSLog("EDP released owner-only DiskImages2 publication for %@", backingPath)
                            completion(nil)
                        } else {
                            completion("DiskImages2 publication owner did not exit for \(backingPath)")
                        }
                    }
                    return
                }

                let expectedDevicePath = "/dev/\(device.bsdName)"
                guard candidate.devicePaths.contains(expectedDevicePath) else {
                    completion(
                        "DiskImages2 BSD identity changed for \(backingPath); refusing to touch \(device.bsdName)"
                    )
                    return
                }

                self.diskArbitration.ejectAsync(device.bsdName) { [weak self] error in
                    guard let self else {
                        completion("block publisher was released")
                        return
                    }
                    self.operationQueue.async {
                        guard let error else {
                            completion(nil)
                            return
                        }
                        self.recoverPublicationAsync(candidate, backingPath: backingPath) { recovered in
                            if recovered {
                                NSLog("EDP recovered DiskImages2 publication %@", device.bsdName)
                                completion(nil)
                            } else {
                                completion(String(describing: error))
                            }
                        }
                    }
                }
            }
        }
    }

    private struct DiskImagesPublication {
        let pid: pid_t
        let imagePath: String
        let ownerUID: uid_t
        let devicePaths: [String]
    }

    private func recoverPublicationAsync(
        _ candidate: DiskImagesPublication,
        backingPath: String,
        completion: @escaping EDPBooleanCompletion
    ) {
        guard geteuid() == 0,
              processExecutablePath(candidate.pid) == "/usr/libexec/diskimagesiod" else {
            completion(false)
            return
        }

        _ = Darwin.kill(candidate.pid, SIGTERM)
        waitForPublicationToDisappearAsync(backingPath, timeout: 1.5) { [weak self] disappeared in
            guard let self else {
                completion(false)
                return
            }
            if disappeared {
                completion(true)
                return
            }
            self.publicationAsync(backingPath: backingPath) { revalidated, errorMessage in
                guard errorMessage == nil,
                      let revalidated,
                      revalidated.pid == candidate.pid,
                      revalidated.ownerUID == candidate.ownerUID,
                      revalidated.devicePaths == candidate.devicePaths,
                      processExecutablePath(revalidated.pid) == "/usr/libexec/diskimagesiod" else {
                    completion(false)
                    return
                }
                _ = Darwin.kill(revalidated.pid, SIGKILL)
                self.waitForPublicationToDisappearAsync(
                    backingPath,
                    timeout: 2.0,
                    completion: completion
                )
            }
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
        var backingStatus = stat()
        guard stat(expected, &backingStatus) == 0 else { return nil }
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
                  backingStatus.st_uid == ownerUID,
                  (item["diskimages2"] as? NSNumber)?.boolValue == true,
                  (item["autodiskmount"] as? NSNumber)?.boolValue == false,
                  (item["image-encrypted"] as? NSNumber)?.boolValue == false,
                  (item["owner-mode"] as? NSNumber)?.intValue == 0o600,
                  let entities = item["system-entities"] as? [[String: Any]],
                  let pidValue = item["hdid-pid"] as? NSNumber,
                  pidValue.intValue > 1 else {
                continue
            }
            let devicePaths = entities.compactMap { $0["dev-entry"] as? String }
            guard devicePaths.allSatisfy({ path in
                var status = stat()
                return stat(path, &status) == 0
                    && (status.st_mode & S_IFMT) == S_IFBLK
                    && status.st_uid == ownerUID
            }) else {
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

    private func isEDPTransportBackingPath(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path.hasPrefix("/Volumes/.edp-block-"),
              url.lastPathComponent == "volume.raw",
              url.deletingLastPathComponent().lastPathComponent.hasPrefix(".edp-block-") else {
            return false
        }
        return true
    }

    private func waitForPublicationToDisappearAsync(
        _ backingPath: String,
        timeout: TimeInterval,
        completion: @escaping EDPBooleanCompletion
    ) {
        let deadline = DispatchTime.now() + timeout
        @Sendable func poll() {
            publicationAsync(backingPath: backingPath) { [weak self] publication, errorMessage in
                guard let self else {
                    completion(false)
                    return
                }
                if errorMessage == nil, publication == nil {
                    completion(true)
                    return
                }
                guard DispatchTime.now() < deadline else {
                    completion(false)
                    return
                }
                self.operationQueue.asyncAfter(deadline: .now() + .milliseconds(100)) {
                    poll()
                }
            }
        }
        poll()
    }
}

#if EDP_REGRESSION_TESTS
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
