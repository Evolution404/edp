import Foundation

struct EDPPublishedBlockDevice: Sendable {
    let bsdName: String
}

protocol EDPBlockDevicePublisher: AnyObject {
    func publishWritableImage(at path: String) throws -> EDPPublishedBlockDevice
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

    init(helperPath: String, diskArbitration: EDPDiskArbitrationController) {
        self.helperPath = helperPath
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
