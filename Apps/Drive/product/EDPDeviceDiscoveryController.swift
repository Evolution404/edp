import Foundation

final class EDPDeviceDiscoveryController: @unchecked Sendable {
    private let mediaProvider: any EDPWholeUSBMediaProviding
    private let metadataReader: any EDPRawMetadataReading

    // Owner-queue confined by EDPServiceController.
    private(set) var diagnostics = ["discovery_not_started"]
    private(set) var scanCount: UInt64 = 0
    private(set) var lastScanTimestamp = ""

    init(
        mediaProvider: any EDPWholeUSBMediaProviding,
        metadataReader: any EDPRawMetadataReading
    ) {
        self.mediaProvider = mediaProvider
        self.metadataReader = metadataReader
    }

    func scan() throws -> [PhysicalDisk] {
        var scanDiagnostics = [String]()
        scanCount &+= 1
        lastScanTimestamp = ISO8601DateFormatter().string(from: Date())
        do {
            let disks = try discoverEDPDisks(
                mediaProvider: mediaProvider,
                metadataReader: metadataReader,
                diagnostic: { scanDiagnostics.append($0) }
            )
            diagnostics = scanDiagnostics.isEmpty
                ? ["no whole USB media scanned"]
                : scanDiagnostics
            return disks
        } catch {
            diagnostics = ["discovery_error:\(error)"]
            throw error
        }
    }
}
