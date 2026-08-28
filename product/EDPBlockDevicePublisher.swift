import Darwin
import Foundation

struct EDPPublishedBlockDevice: Sendable {
    let bsdName: String
}

/// Explicitly writable publication boundary used by the existing read/write
/// product path. Read-only callers must not conform to or receive this type.
protocol EDPBlockDevicePublisher: AnyObject {
    func publishWritableImage(at path: String) throws -> EDPPublishedBlockDevice
    func unpublish(_ device: EDPPublishedBlockDevice) throws
}

/// Separate read-only publication boundary for the FUSE-T thin transport.
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

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        return value as? Int
    }

    private static func integer64(_ value: Any?) -> Int64? {
        if let value = value as? NSNumber { return value.int64Value }
        return value as? Int64
    }

    private static func runHdiutil(_ arguments: [String]) throws -> (status: Int32, stdout: Data, stderr: Data) {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, stdout, stderr)
    }
}

final class EDPDiskImages2Publisher: EDPBlockDevicePublisher {
    private let helperPath: String
    private let diskArbitration: EDPDiskArbitrationController

    init(binaryRoot: String, diskArbitration: EDPDiskArbitrationController) {
        helperPath = binaryRoot + "/diskimages2-attach"
        self.diskArbitration = diskArbitration
    }

    func publishWritableImage(at path: String) throws -> EDPPublishedBlockDevice {
        guard FileManager.default.fileExists(atPath: path) else {
            throw EDPBlockDevicePublisherError("block image does not exist: \(path)")
        }
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            throw EDPBlockDevicePublisherError("DiskImages2 adapter helper is missing: \(helperPath)")
        }

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: helperPath)
        process.arguments = ["--writable-noautomount", path]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw EDPBlockDevicePublisherError(
                "DiskImages2 adapter failed (\(process.terminationStatus)): "
                    + String(decoding: stderr, as: UTF8.self)
            )
        }

        let text = String(decoding: stdout, as: UTF8.self)
        guard let bsdName = text.split(separator: "\n")
            .first(where: { $0.hasPrefix("DI_BSD_NAME=") })?
            .split(separator: "=", maxSplits: 1).last.map(String.init),
            FileManager.default.fileExists(atPath: "/dev/\(bsdName)") else {
            throw EDPBlockDevicePublisherError("DiskImages2 adapter did not publish a BSD device")
        }
        return EDPPublishedBlockDevice(bsdName: bsdName)
    }

    func unpublish(_ device: EDPPublishedBlockDevice) throws {
        try diskArbitration.eject(device.bsdName)
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
