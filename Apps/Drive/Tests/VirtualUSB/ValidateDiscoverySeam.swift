import Foundation

private struct FixtureMediaProvider: EDPWholeUSBMediaProviding {
    let media: [EDPWholeUSBMedia]
    let existingRegistryIDs: Set<UInt64>

    func allWholeUSBMedia() throws -> [EDPWholeUSBMedia] {
        media
    }

    func registryEntryExists(_ registryEntryID: UInt64) -> Bool {
        existingRegistryIDs.contains(registryEntryID)
    }
}

private struct FixtureMetadataReader: EDPRawMetadataReading {
    let fixtureDirectory: String

    func snapshot(for media: EDPWholeUSBMedia) throws -> EDPRawMetadataSnapshot {
        let root = URL(fileURLWithPath: fixtureDirectory, isDirectory: true)
        let front = try Data(contentsOf: root.appendingPathComponent("lba0_16.bin"))
        guard front.count >= 512 else {
            throw ValidationFailure("fixture lba0_16.bin is shorter than one sector")
        }
        return EDPRawMetadataSnapshot(
            lba0: Data(front.prefix(512)),
            lba4: try Data(contentsOf: root.appendingPathComponent("LBA4.bin")),
            lba7: try Data(contentsOf: root.appendingPathComponent("LBA7.bin")),
            lba11: try Data(contentsOf: root.appendingPathComponent("LBA11.bin")),
            lba12: try Data(contentsOf: root.appendingPathComponent("LBA12.bin"))
        )
    }
}

private struct FailingMetadataReader: EDPRawMetadataReading {
    func snapshot(for media: EDPWholeUSBMedia) throws -> EDPRawMetadataSnapshot {
        throw ValidationFailure("synthetic metadata failure for \(media.bsdName)")
    }
}

private struct ValidationFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@main
struct ValidateDiscoverySeam {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw ValidationFailure("usage: validate-discovery-seam <real_disks/disk4>")
        }

        let media = EDPWholeUSBMedia(
            bsdName: "disk42",
            sizeBytes: 124_736_503_808,
            mediaName: "Virtual Lexar EDP",
            vidHex: "21c4",
            pidHex: "0cd1",
            registryEntryID: 0x4200,
            usbRegistryEntryID: 0x4242
        )
        let provider = FixtureMediaProvider(
            media: [media],
            existingRegistryIDs: [media.usbRegistryEntryID]
        )

        var diagnostics = [String]()
        let disks = try EDPPhysicalDiskDiscovery(
            mediaProvider: provider,
            metadataReader: FixtureMetadataReader(fixtureDirectory: CommandLine.arguments[1])
        ).discover { diagnostics.append($0) }

        guard disks.count == 1, let disk = disks.first else {
            throw ValidationFailure("injected discovery did not recognize the captured standard fixture")
        }
        guard disk.bsdName == "disk42",
              disk.rawPath == "/dev/rdisk42",
              disk.labelOnlyID == 3_164_177_653,
              disk.metadataDeviceID == "disk&ven_lexar&prod_usb_flash_drive",
              disk.identity == EDPPhysicalIdentity(
                  vidHex: "21c4",
                  pidHex: "0cd1",
                  labelOnlyID: 3_164_177_653,
                  sizeBytes: 124_736_503_808,
                  metadataDeviceID: "disk&ven_lexar&prod_usb_flash_drive"
              ) else {
            throw ValidationFailure("discovery seam changed physical identity semantics")
        }
        guard provider.registryEntryExists(media.usbRegistryEntryID),
              !provider.registryEntryExists(0xDEAD) else {
            throw ValidationFailure("virtual registry existence contract is inconsistent")
        }
        guard diagnostics.contains(where: { $0.contains("classification=standardEncrypted") }),
              diagnostics.contains(where: { $0.contains("result=recognized") }) else {
            throw ValidationFailure("discovery diagnostics did not expose classification/recognition")
        }
        print("SCENARIO=TEST_C_INJECTED_DISCOVERY_OK")

        diagnostics.removeAll()
        let failed = try EDPPhysicalDiskDiscovery(
            mediaProvider: provider,
            metadataReader: FailingMetadataReader()
        ).discover { diagnostics.append($0) }
        guard failed.isEmpty,
              diagnostics.contains(where: { $0.contains("result=raw_metadata_failed") }) else {
            throw ValidationFailure("metadata-reader failure was not isolated to the affected virtual media")
        }
        print("SCENARIO=TEST_C_METADATA_READER_FAILURE_ISOLATED")
        print("RESULT=DRIVE_DISCOVERY_SEAM_OK")
    }
}
