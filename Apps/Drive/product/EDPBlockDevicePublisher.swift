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

/// Explicitly writable publication boundary used by the existing read/write
/// product path. Read-only callers must not conform to or receive this type.
protocol EDPBlockDevicePublisher: AnyObject {
    func publishWritableImage(at path: String) throws -> EDPPublishedBlockDevice
    func unpublish(_ device: EDPPublishedBlockDevice) throws
}

/// Separate read-only publication boundary for read-only product flows.
///
/// Keeping this protocol distinct makes it impossible for the read-only path
/// to accidentally call the existing writable DiskImages2 helper.
protocol EDPReadOnlyBlockDevicePublisher: AnyObject {
    func publishReadOnlyImage(at path: String) throws -> EDPPublishedBlockDevice
    func unpublish(_ device: EDPPublishedBlockDevice) throws
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
    return String(cString: buffer)
}

private func runBoundedProcess(
    executable: String,
    arguments: [String],
    timeout: TimeInterval,
    label: String
) throws -> EDPBoundedProcessResult {
    let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let token = UUID().uuidString
    let stdoutURL = temporaryRoot.appendingPathComponent("edp-\(token).stdout")
    let stderrURL = temporaryRoot.appendingPathComponent("edp-\(token).stderr")
    _ = FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
    defer {
        try? FileManager.default.removeItem(at: stdoutURL)
        try? FileManager.default.removeItem(at: stderrURL)
    }

    let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
    let stderrHandle = try FileHandle(forWritingTo: stderrURL)
    defer {
        try? stdoutHandle.close()
        try? stderrHandle.close()
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle
    try process.run()

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
        process.terminate()
        let terminateDeadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < terminateDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
    if process.isRunning {
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        let killDeadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < killDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
    guard !process.isRunning else {
        throw EDPBlockDevicePublisherError("\(label) remained alive after timeout and SIGKILL")
    }
    guard Date() < deadline else {
        throw EDPBlockDevicePublisherError("\(label) timed out after \(Int(timeout)) seconds")
    }

    try? stdoutHandle.synchronize()
    try? stderrHandle.synchronize()
    return EDPBoundedProcessResult(
        status: process.terminationStatus,
        stdout: (try? Data(contentsOf: stdoutURL)) ?? Data(),
        stderr: (try? Data(contentsOf: stderrURL)) ?? Data()
    )
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
    /// Returns nil when the baseline cannot be captured. Callers must skip
    /// cleanup in that case rather than treating an unknown baseline as empty.
    static func captureBaseline() -> Set<String>? {
        do {
            return Set(try currentImages().map(\.identity))
        } catch {
            NSLog("EDP macFUSE scratch baseline unavailable: %@", String(describing: error))
            return nil
        }
    }

    static func cleanupNewOrphans(since baseline: Set<String>?) {
        guard geteuid() == 0, let baseline else { return }
        // Give macFUSE's normal failure teardown a short opportunity to remove
        // its scratch image before applying the orphan-only fallback.
        Thread.sleep(forTimeInterval: 0.5)
        let images: [EDPMacFUSEScratchImage]
        do {
            images = try currentImages()
        } catch {
            NSLog("EDP macFUSE scratch cleanup skipped: %@", String(describing: error))
            return
        }

        for image in images where !baseline.contains(image.identity) && image.isOrphanCleanupCandidate {
            cleanup(image)
        }
    }

    /// Recovers one persisted macFUSE Local bridge after its transport process
    /// crashed before the normal signal-driven teardown could close MFChannel.
    /// The mountpoint and its exact /dev/diskN source must still match a narrow
    /// 4 KiB macFUSE scratch image candidate before its helper can be signalled.
    @discardableResult
    static func cleanupOrphan(mountedAt mountpoint: String) -> Bool {
        guard let source = mountSource(mountedAt: mountpoint),
              source.hasPrefix("/dev/disk") else {
            return false
        }
        let images: [EDPMacFUSEScratchImage]
        do {
            images = try currentImages()
        } catch {
            NSLog("EDP exact macFUSE orphan lookup failed: %@", String(describing: error))
            return false
        }
        guard let image = orphanCandidate(forSource: source, in: images) else {
            return false
        }
        cleanup(image)
        return waitUntilGone(source, timeout: 2.0) && mountSource(mountedAt: mountpoint) == nil
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

    private static func currentImages() throws -> [EDPMacFUSEScratchImage] {
        let result = try runHdiutil(["info", "-plist"])
        guard result.status == 0 else {
            throw EDPBlockDevicePublisherError(
                "hdiutil info failed (\(result.status)): \(String(decoding: result.stderr, as: UTF8.self))"
            )
        }
        return try parseInfoPlist(result.stdout)
    }

    private static func cleanup(_ image: EDPMacFUSEScratchImage) {
        guard let device = image.devices.first else { return }
        let detach = try? runHdiutil(["detach", device, "-force"])
        if detach?.status == 0 || !FileManager.default.fileExists(atPath: device) {
            NSLog("EDP cleaned orphan macFUSE scratch device %@", device)
            return
        }

        // hdiutil can report EBUSY for the exact failure mode this path handles.
        // Revalidate the tuple immediately before signalling the helper so PID
        // reuse or an unrelated disk image can never turn into a kill target.
        guard stillMatches(image) else {
            NSLog("EDP refused to signal changed macFUSE scratch helper for %@", device)
            return
        }

        _ = Darwin.kill(image.helperPID, SIGTERM)
        if waitUntilGone(device, timeout: 0.75) {
            NSLog("EDP cleaned orphan macFUSE scratch device %@ after helper SIGTERM", device)
            return
        }

        guard stillMatches(image) else { return }
        _ = Darwin.kill(image.helperPID, SIGKILL)
        if waitUntilGone(device, timeout: 1.0) {
            NSLog("EDP cleaned orphan macFUSE scratch device %@ after helper SIGKILL", device)
        } else {
            NSLog("EDP macFUSE scratch device remained after forced cleanup: %@", device)
        }
    }

    private static func stillMatches(_ expected: EDPMacFUSEScratchImage) -> Bool {
        guard let images = try? currentImages() else { return false }
        return images.contains {
            $0.identity == expected.identity
                && $0.helperPID == expected.helperPID
                && $0.devices == expected.devices
                && $0.isOrphanCleanupCandidate
        }
    }

    private static func waitUntilGone(_ device: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while FileManager.default.fileExists(atPath: device), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !FileManager.default.fileExists(atPath: device)
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

    private static func runHdiutil(_ arguments: [String]) throws -> (status: Int32, stdout: Data, stderr: Data) {
        let result = try runBoundedProcess(
            executable: "/usr/bin/hdiutil",
            arguments: arguments,
            timeout: 8,
            label: "hdiutil \(arguments.first ?? "operation")"
        )
        return (result.status, result.stdout, result.stderr)
    }
}

final class EDPDiskImages2Publisher: EDPBlockDevicePublisher {
    private let helperPath: String
    private let consoleLauncherPath: String
    private let diskArbitration: any EDPDaemonDiskArbitrating

    init(binaryRoot: String, diskArbitration: any EDPDaemonDiskArbitrating) {
        helperPath = binaryRoot + "/diskimages2-attach"
        consoleLauncherPath = binaryRoot + "/edp-console-exec"
        self.diskArbitration = diskArbitration
    }

    func publishWritableImage(at path: String) throws -> EDPPublishedBlockDevice {
        guard FileManager.default.fileExists(atPath: path) else {
            throw EDPBlockDevicePublisherError("block image does not exist: \(path)")
        }
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            throw EDPBlockDevicePublisherError("DiskImages2 adapter helper is missing: \(helperPath)")
        }
        guard FileManager.default.isExecutableFile(atPath: consoleLauncherPath) else {
            throw EDPBlockDevicePublisherError("console launcher is missing: \(consoleLauncherPath)")
        }
        let identity = try publisherConsoleIdentity()

        // The macFUSE Local transport and volume.raw are owned by the logged-in
        // console user.  Publishing the same file from the root daemon creates
        // a DiskImages2 device with no IOMedia identity on macOS 26; Disk
        // Arbitration then rejects teardown with kDAReturnBadArgument.  Keep
        // publication in the same user session as the transport so attach and
        // eject use the normal, TEST-F-covered IOMedia lifecycle.
        let result = try runBoundedProcess(
            executable: consoleLauncherPath,
            arguments: [
                String(identity.0), String(identity.1), "--",
                helperPath, "--writable-noautomount", path,
            ],
            timeout: 15,
            label: "console-user DiskImages2 writable attach"
        )
        guard result.status == 0 else {
            throw EDPBlockDevicePublisherError(
                "DiskImages2 adapter failed (\(result.status)): "
                    + String(decoding: result.stderr, as: UTF8.self)
            )
        }

        let text = String(decoding: result.stdout, as: UTF8.self)
        guard let bsdName = text.split(separator: "\n")
            .first(where: { $0.hasPrefix("DI_BSD_NAME=") })?
            .split(separator: "=", maxSplits: 1).last.map(String.init),
            FileManager.default.fileExists(atPath: "/dev/\(bsdName)") else {
            throw EDPBlockDevicePublisherError("DiskImages2 adapter did not publish a BSD device")
        }
        return EDPPublishedBlockDevice(
            bsdName: bsdName,
            backingPath: URL(fileURLWithPath: path).standardizedFileURL.path
        )
    }

    func unpublish(_ device: EDPPublishedBlockDevice) throws {
        guard let backingPath = device.backingPath,
              isEDPTransportBackingPath(backingPath) else {
            throw EDPBlockDevicePublisherError("DiskImages2 publication is missing its EDP backing identity")
        }

        // Never trust a persisted diskN by itself. macOS can reuse that BSD name
        // for an unrelated device (including the physical EDP USB) after the
        // synthetic publication disappears. The authoritative identity is the
        // exact volume.raw backing path plus its DiskImages2 owner process.
        guard let candidate = publication(backingPath: backingPath) else {
            NSLog(
                "EDP DiskImages2 publication already absent for %@; ignoring stale BSD name %@",
                backingPath,
                device.bsdName
            )
            return
        }

        if candidate.devicePaths.isEmpty {
            guard recoverPublication(candidate, backingPath: backingPath) else {
                throw EDPBlockDevicePublisherError(
                    "DiskImages2 publication owner did not exit for \(backingPath)"
                )
            }
            NSLog("EDP released owner-only DiskImages2 publication for %@", backingPath)
            return
        }

        let expectedDevicePath = "/dev/\(device.bsdName)"
        guard candidate.devicePaths.contains(expectedDevicePath) else {
            throw EDPBlockDevicePublisherError(
                "DiskImages2 BSD identity changed for \(backingPath); refusing to touch \(device.bsdName)"
            )
        }

        do {
            try diskArbitration.eject(device.bsdName)
        } catch {
            guard recoverPublication(candidate, backingPath: backingPath) else { throw error }
            NSLog("EDP recovered DiskImages2 publication %@", device.bsdName)
        }
    }

    private struct DiskImagesPublication {
        let pid: pid_t
        let imagePath: String
        let ownerUID: uid_t
        let devicePaths: [String]
    }

    private func recoverPublication(
        _ candidate: DiskImagesPublication,
        backingPath: String
    ) -> Bool {
        guard geteuid() == 0,
              processExecutablePath(candidate.pid) == "/usr/libexec/diskimagesiod" else {
            return false
        }

        _ = Darwin.kill(candidate.pid, SIGTERM)
        if waitForPublicationToDisappear(backingPath, timeout: 1.5) { return true }

        guard let revalidated = publication(backingPath: backingPath),
              revalidated.pid == candidate.pid,
              revalidated.ownerUID == candidate.ownerUID,
              revalidated.devicePaths == candidate.devicePaths,
              processExecutablePath(revalidated.pid) == "/usr/libexec/diskimagesiod" else {
            return false
        }
        _ = Darwin.kill(revalidated.pid, SIGKILL)
        return waitForPublicationToDisappear(backingPath, timeout: 2.0)
    }

    private func publication(backingPath: String) -> DiskImagesPublication? {
        guard let result = try? runBoundedProcess(
            executable: "/usr/bin/hdiutil",
            arguments: ["info", "-plist"],
            timeout: 8,
            label: "hdiutil info for legacy DiskImages2 recovery"
        ), result.status == 0,
        let root = try? PropertyListSerialization.propertyList(
            from: result.stdout,
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

    private func waitForPublicationToDisappear(
        _ backingPath: String,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while publication(backingPath: backingPath) != nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return publication(backingPath: backingPath) == nil
    }
}

/// Public, read-only Apple DiskImages publication used by the thin bridge.
/// No filesystem type is supplied here; Disk Arbitration remains responsible
/// for recognizing and mounting the decrypted filesystem.
final class EDPHdiutilReadOnlyPublisher: EDPReadOnlyBlockDevicePublisher {
    private let diskArbitration: EDPDiskArbitrationController

    init(diskArbitration: EDPDiskArbitrationController) {
        self.diskArbitration = diskArbitration
    }

    func publishReadOnlyImage(at path: String) throws -> EDPPublishedBlockDevice {
        guard FileManager.default.fileExists(atPath: path) else {
            throw EDPBlockDevicePublisherError("read-only block image does not exist: \(path)")
        }

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "attach", "-readonly", "-nomount",
            "-imagekey", "diskimage-class=CRawDiskImage",
            path,
        ]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw EDPBlockDevicePublisherError(
                "hdiutil read-only attach failed (\(process.terminationStatus)): "
                    + String(decoding: stderr, as: UTF8.self)
            )
        }

        let text = String(decoding: stdout, as: UTF8.self)
        let candidates = text.split(whereSeparator: \Character.isWhitespace)
            .map(String.init)
            .filter { $0.hasPrefix("/dev/disk") }
        guard let devicePath = candidates.first,
              devicePath.dropFirst("/dev/disk".count).allSatisfy({ $0.isNumber }) else {
            throw EDPBlockDevicePublisherError(
                "hdiutil did not return a whole BSD disk: \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        let bsdName = String(devicePath.dropFirst("/dev/".count))
        guard FileManager.default.fileExists(atPath: devicePath) else {
            throw EDPBlockDevicePublisherError("published BSD device is missing: \(devicePath)")
        }
        return EDPPublishedBlockDevice(bsdName: bsdName)
    }

    func unpublish(_ device: EDPPublishedBlockDevice) throws {
        try diskArbitration.eject(device.bsdName)
    }
}
