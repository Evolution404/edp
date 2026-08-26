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
