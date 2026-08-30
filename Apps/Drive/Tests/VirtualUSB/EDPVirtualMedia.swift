import Foundation

struct EDPVirtualMediaDevice: Sendable {
    var media: EDPWholeUSBMedia
    var metadata: EDPRawMetadataSnapshot
    var metadataFault: EDPVirtualMetadataFault = .none

    func connected(
        as bsdName: String,
        registryEntryID: UInt64,
        usbRegistryEntryID: UInt64
    ) -> EDPVirtualMediaDevice {
        var copy = self
        copy.media = EDPWholeUSBMedia(
            bsdName: bsdName,
            sizeBytes: media.sizeBytes,
            mediaName: media.mediaName,
            vidHex: media.vidHex,
            pidHex: media.pidHex,
            registryEntryID: registryEntryID,
            usbRegistryEntryID: usbRegistryEntryID
        )
        return copy
    }
}
