import Foundation

enum EDPVirtualDiskFactory {
    static func capturedDisk4(fixtureDirectory: String) throws -> EDPVirtualMediaDevice {
        let root = URL(fileURLWithPath: fixtureDirectory, isDirectory: true)
        let front = try Data(contentsOf: root.appendingPathComponent("lba0_16.bin"))
        guard front.count >= 512 else {
            throw EDPVirtualUSBError("captured disk4 lba0_16.bin is shorter than one sector")
        }
        let metadata = EDPRawMetadataSnapshot(
            lba0: Data(front.prefix(512)),
            lba4: try Data(contentsOf: root.appendingPathComponent("LBA4.bin")),
            lba7: try Data(contentsOf: root.appendingPathComponent("LBA7.bin")),
            lba11: try Data(contentsOf: root.appendingPathComponent("LBA11.bin")),
            lba12: try Data(contentsOf: root.appendingPathComponent("LBA12.bin"))
        )
        let media = EDPWholeUSBMedia(
            bsdName: "disk4",
            sizeBytes: 124_736_503_808,
            mediaName: "Virtual Lexar EDP",
            vidHex: "21c4",
            pidHex: "0cd1",
            registryEntryID: 0x4000,
            usbRegistryEntryID: 0x4040
        )
        return EDPVirtualMediaDevice(media: media, metadata: metadata)
    }

    static func changingOnlyID(
        _ device: EDPVirtualMediaDevice,
        to onlyID: UInt64
    ) throws -> EDPVirtualMediaDevice {
        var copy = device
        var bytes = [UInt8](copy.metadata.lba4)
        let delimiter = [UInt8](repeating: 0x24, count: 3)
        guard let first = delimiterIndex(in: bytes, from: 0),
              let second = delimiterIndex(in: bytes, from: first + delimiter.count) else {
            throw EDPVirtualUSBError("captured LBA4 has no onlyId delimiter")
        }
        let start = first + delimiter.count
        let replacement = Array(String(onlyID).utf8)
        guard replacement.count == second - start else {
            throw EDPVirtualUSBError("test onlyId mutation must preserve marker byte length")
        }
        bytes.replaceSubrange(start..<second, with: replacement)
        copy.metadata = EDPRawMetadataSnapshot(
            lba0: copy.metadata.lba0,
            lba4: Data(bytes),
            lba7: copy.metadata.lba7,
            lba11: copy.metadata.lba11,
            lba12: copy.metadata.lba12
        )
        return copy
    }

    static func corruptingLBA11(_ device: EDPVirtualMediaDevice) -> EDPVirtualMediaDevice {
        var copy = device
        var bytes = [UInt8](copy.metadata.lba11)
        if bytes.count > 0x100 { bytes[0x100] ^= 0x5a }
        copy.metadata = EDPRawMetadataSnapshot(
            lba0: copy.metadata.lba0,
            lba4: copy.metadata.lba4,
            lba7: copy.metadata.lba7,
            lba11: Data(bytes),
            lba12: copy.metadata.lba12
        )
        return copy
    }

    static func withCapacity(
        _ device: EDPVirtualMediaDevice,
        sizeBytes: UInt64
    ) -> EDPVirtualMediaDevice {
        var copy = device
        copy.media = EDPWholeUSBMedia(
            bsdName: copy.media.bsdName,
            sizeBytes: sizeBytes,
            mediaName: copy.media.mediaName,
            vidHex: copy.media.vidHex,
            pidHex: copy.media.pidHex,
            registryEntryID: copy.media.registryEntryID,
            usbRegistryEntryID: copy.media.usbRegistryEntryID
        )
        return copy
    }

    private static func delimiterIndex(in bytes: [UInt8], from start: Int) -> Int? {
        guard start >= 0, start + 3 <= bytes.count else { return nil }
        for index in start...(bytes.count - 3) {
            if bytes[index] == 0x24,
               bytes[index + 1] == 0x24,
               bytes[index + 2] == 0x24 {
                return index
            }
        }
        return nil
    }
}
