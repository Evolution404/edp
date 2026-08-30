import Foundation

private struct VirtualUSBValidationError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@main
struct ValidateVirtualPhysicalUSB {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw VirtualUSBValidationError("usage: validate-virtual-physical-usb <real_disks/disk4>")
        }

        let fixtureA = try EDPVirtualDiskFactory.capturedDisk4(
            fixtureDirectory: CommandLine.arguments[1]
        )
        let fixtureB = try EDPVirtualDiskFactory.changingOnlyID(fixtureA, to: 3_164_177_654)
        let baselineIdentity = try discoverSingle(
            fixtureA,
            bsdName: "disk4",
            registryEntryID: 0x4100,
            usbRegistryEntryID: 0x4101
        ).deviceID

        try validateP16(fixtureA, baselineIdentity: baselineIdentity)
        try validateP17(fixtureA, fixtureB)
        try validateP18(fixtureA, fixtureB)
        try validateP19(fixtureA, fixtureB)
        try validateP20(fixtureA)
        try validateP21(fixtureA)
        try validateP22(fixtureA)
        try validateP23(fixtureA)
        try validateP24()
        try validateP25(fixtureA, baselineIdentity: baselineIdentity)
        try validateP26(fixtureA, fixtureB)
        try validateP27(fixtureA, fixtureB)
        try validateP28(fixtureA, fixtureB)
        try validateP29()
        try validateP30(fixtureA)

        print("RESULT=DRIVE_VIRTUAL_PHYSICAL_USB_OK")
    }

    private static func discovery(_ state: EDPVirtualUSBState) -> EDPPhysicalDiskDiscovery {
        EDPPhysicalDiskDiscovery(
            mediaProvider: EDPVirtualWholeUSBMediaProvider(state: state),
            metadataReader: EDPVirtualRawMetadataReader(state: state)
        )
    }

    private static func discoverSingle(
        _ fixture: EDPVirtualMediaDevice,
        bsdName: String,
        registryEntryID: UInt64,
        usbRegistryEntryID: UInt64
    ) throws -> PhysicalDisk {
        let state = EDPVirtualUSBState()
        state.insert(
            fixture,
            as: bsdName,
            registryEntryID: registryEntryID,
            usbRegistryEntryID: usbRegistryEntryID
        )
        let disks = try discovery(state).discover()
        guard disks.count == 1, let disk = disks.first else {
            throw VirtualUSBValidationError("expected one recognized virtual disk")
        }
        return disk
    }

    private static func validateP16(
        _ fixture: EDPVirtualMediaDevice,
        baselineIdentity: String
    ) throws {
        let state = EDPVirtualUSBState()
        state.insert(fixture, as: "disk4", registryEntryID: 0x1600, usbRegistryEntryID: 0x1601)
        let first = try requireSingle(try discovery(state).discover(), "P16 first insert")
        state.remove("disk4")
        state.insert(fixture, as: "disk9", registryEntryID: 0x1602, usbRegistryEntryID: 0x1603)
        let second = try requireSingle(try discovery(state).discover(), "P16 reinsert")
        guard first.deviceID == baselineIdentity,
              second.deviceID == baselineIdentity,
              first.bsdName != second.bsdName else {
            throw VirtualUSBValidationError("P16 diskN change altered stable identity")
        }
        print("SCENARIO=P16_OK same_identity_diskN_changed")
    }

    private static func validateP17(
        _ fixtureA: EDPVirtualMediaDevice,
        _ fixtureB: EDPVirtualMediaDevice
    ) throws {
        let state = EDPVirtualUSBState()
        state.insert(fixtureA, as: "disk4", registryEntryID: 0x1700, usbRegistryEntryID: 0x1701)
        let first = try requireSingle(try discovery(state).discover(), "P17 device A")
        state.remove("disk4")
        state.insert(fixtureB, as: "disk4", registryEntryID: 0x1702, usbRegistryEntryID: 0x1703)
        let second = try requireSingle(try discovery(state).discover(), "P17 device B")
        guard first.deviceID != second.deviceID else {
            throw VirtualUSBValidationError("P17 reused diskN inherited the removed device identity")
        }
        print("SCENARIO=P17_OK diskN_reuse_different_device")
    }

    private static func validateP18(
        _ fixtureA: EDPVirtualMediaDevice,
        _ fixtureB: EDPVirtualMediaDevice
    ) throws {
        let state = EDPVirtualUSBState()
        state.insert(fixtureA, as: "disk6", registryEntryID: 0x1800, usbRegistryEntryID: 0x1801)
        let discovered = try requireSingle(try discovery(state).discover(), "P18 discovery")
        state.replace(
            "disk6",
            with: fixtureB,
            registryEntryID: 0x1800,
            usbRegistryEntryID: 0x1801
        )
        guard let replacement = state.device(for: "disk6") else {
            throw VirtualUSBValidationError("P18 replacement disappeared")
        }
        guard EDPPhysicalDeviceRevalidation.mediaStillMatches(replacement.media, disk: discovered),
              !EDPPhysicalDeviceRevalidation.metadataStillMatches(replacement.metadata, disk: discovered) else {
            throw VirtualUSBValidationError("P18 replacement race was not rejected by metadata revalidation")
        }
        print("SCENARIO=P18_OK replacement_between_discovery_and_raw_lease")
    }

    private static func validateP19(
        _ fixtureA: EDPVirtualMediaDevice,
        _ onlyIDMutation: EDPVirtualMediaDevice
    ) throws {
        let disk = try discoverSingle(
            fixtureA,
            bsdName: "disk7",
            registryEntryID: 0x1900,
            usbRegistryEntryID: 0x1901
        )
        guard !EDPPhysicalDeviceRevalidation.metadataStillMatches(onlyIDMutation.metadata, disk: disk) else {
            throw VirtualUSBValidationError("P19 changed onlyId passed raw-lease revalidation")
        }
        print("SCENARIO=P19_OK onlyId_mutation_refused")
    }

    private static func validateP20(_ fixtureA: EDPVirtualMediaDevice) throws {
        let disk = try discoverSingle(
            fixtureA,
            bsdName: "disk8",
            registryEntryID: 0x2000,
            usbRegistryEntryID: 0x2001
        )
        let mutated = EDPVirtualDiskFactory.corruptingLBA11(fixtureA)
        guard !EDPPhysicalDeviceRevalidation.metadataStillMatches(mutated.metadata, disk: disk) else {
            throw VirtualUSBValidationError("P20 changed LBA11 passed raw-lease revalidation")
        }
        print("SCENARIO=P20_OK lba11_mutation_refused")
    }

    private static func validateP21(_ fixtureA: EDPVirtualMediaDevice) throws {
        let disk = try discoverSingle(
            fixtureA,
            bsdName: "disk10",
            registryEntryID: 0x2100,
            usbRegistryEntryID: 0x2101
        )
        let reconnected = fixtureA.connected(
            as: "disk10",
            registryEntryID: 0x21ff,
            usbRegistryEntryID: 0x21fe
        )
        guard !EDPPhysicalDeviceRevalidation.mediaStillMatches(reconnected.media, disk: disk) else {
            throw VirtualUSBValidationError("P21 registry mutation passed target revalidation")
        }
        print("SCENARIO=P21_OK registry_mutation_refused")
    }

    private static func validateP22(_ fixtureA: EDPVirtualMediaDevice) throws {
        let state = EDPVirtualUSBState()
        state.insert(fixtureA, as: "disk11", registryEntryID: 0x2200, usbRegistryEntryID: 0x2201)
        state.setMetadataFault(.detachDuringRead(afterSector: 2), for: "disk11")
        let failed = try discovery(state).discover()
        guard failed.isEmpty, state.currentMedia().isEmpty else {
            throw VirtualUSBValidationError("P22 detach during metadata read left a partial discovered device")
        }
        state.insert(fixtureA, as: "disk12", registryEntryID: 0x2202, usbRegistryEntryID: 0x2203)
        _ = try requireSingle(try discovery(state).discover(), "P22 recovery")
        print("SCENARIO=P22_OK detach_during_metadata_read_recovers")
    }

    private static func validateP23(_ fixtureA: EDPVirtualMediaDevice) throws {
        let state = EDPVirtualUSBState()
        state.insert(fixtureA, as: "disk13", registryEntryID: 0x2300, usbRegistryEntryID: 0x2301)
        let disk = try requireSingle(try discovery(state).discover(), "P23 discovery")
        state.remove("disk13")
        let stillPresent = try EDPVirtualWholeUSBMediaProvider(state: state).allWholeUSBMedia()
            .contains { EDPPhysicalDeviceRevalidation.mediaStillMatches($0, disk: disk) }
        guard !stillPresent else {
            throw VirtualUSBValidationError("P23 detached device remained eligible before mount")
        }
        print("SCENARIO=P23_OK detach_after_discovery_before_mount")
    }

    private static func validateP24() throws {
        let raw = EDPVirtualRawDevice(sizeBytes: 4096, fill: 0x5a)
        let block = try EDPPlaintextReadWriteBlockDevice(
            raw: raw,
            startSector: 0,
            sizeBytes: 4096
        )
        _ = try block.read(at: 0, length: 64)
        raw.setFault(.detached)
        try expectThrows("P24 mounted block access survived virtual detach") {
            _ = try block.read(at: 0, length: 64)
        }
        print("SCENARIO=P24_OK detach_during_block_access_propagates")
    }

    private static func validateP25(
        _ fixtureA: EDPVirtualMediaDevice,
        baselineIdentity: String
    ) throws {
        let disk = try discoverSingle(
            fixtureA,
            bsdName: "disk14",
            registryEntryID: 0x2500,
            usbRegistryEntryID: 0x2501
        )
        guard disk.deviceID == baselineIdentity else {
            throw VirtualUSBValidationError("P25 same identity did not recover the stable device ID")
        }
        print("SCENARIO=P25_OK reinsert_same_identity")
    }

    private static func validateP26(
        _ fixtureA: EDPVirtualMediaDevice,
        _ fixtureB: EDPVirtualMediaDevice
    ) throws {
        let state = EDPVirtualUSBState()
        state.insert(fixtureA, as: "disk15", registryEntryID: 0x2600, usbRegistryEntryID: 0x2601)
        state.insert(fixtureB, as: "disk16", registryEntryID: 0x2602, usbRegistryEntryID: 0x2603)
        let disks = try discovery(state).discover()
        guard disks.count == 2, Set(disks.map(\.deviceID)).count == 2 else {
            throw VirtualUSBValidationError("P26 same-model concurrent devices were conflated")
        }
        print("SCENARIO=P26_OK two_same_model_devices_independent")
    }

    private static func validateP27(
        _ fixtureA: EDPVirtualMediaDevice,
        _ fixtureB: EDPVirtualMediaDevice
    ) throws {
        let state = EDPVirtualUSBState()
        state.insert(fixtureA, as: "disk17", registryEntryID: 0x2700, usbRegistryEntryID: 0x2701)
        state.insert(fixtureB, as: "disk18", registryEntryID: 0x2702, usbRegistryEntryID: 0x2703)
        state.setMetadataFault(.readFailure("EIO: synthetic metadata failure"), for: "disk18")
        var diagnostics = [String]()
        let disks = try discovery(state).discover { diagnostics.append($0) }
        guard disks.count == 1,
              disks[0].bsdName == "disk17",
              diagnostics.contains(where: { $0.contains("bsd=disk18;result=raw_metadata_failed") }) else {
            throw VirtualUSBValidationError("P27 one broken device poisoned discovery of the good device")
        }
        print("SCENARIO=P27_OK broken_device_isolated")
    }

    private static func validateP28(
        _ fixtureA: EDPVirtualMediaDevice,
        _ fixtureB: EDPVirtualMediaDevice
    ) throws {
        let state = EDPVirtualUSBState()
        state.insert(fixtureA, as: "disk19", registryEntryID: 0x2800, usbRegistryEntryID: 0x2801)
        state.insert(fixtureB, as: "disk20", registryEntryID: 0x2802, usbRegistryEntryID: 0x2803)
        state.setMetadataFault(.shortLBA11(128), for: "disk20")
        let disks = try discovery(state).discover()
        guard disks.count == 1, disks[0].bsdName == "disk19" else {
            throw VirtualUSBValidationError("P28 short LBA11 was claimed or crashed discovery")
        }
        print("SCENARIO=P28_OK short_read_refused")
    }

    private static func validateP29() throws {
        let window = try EDPAlignedRead.window(
            byteOffset: EDPVolumeMetadata.lba11ByteOffset,
            byteLength: EDPMetadataProbe.legacySectorByteLength,
            transferAlignment: 4096
        )
        guard window.start == 4096,
              window.length == 4096,
              window.sliceOffset == Int(EDPVolumeMetadata.lba11ByteOffset - 4096),
              window.sliceLength == 512 else {
            throw VirtualUSBValidationError("P29 4K transfer alignment changed legacy-sector semantics")
        }
        print("SCENARIO=P29_OK four_k_transfer_alignment")
    }

    private static func validateP30(_ fixtureA: EDPVirtualMediaDevice) throws {
        let tiny = EDPVirtualDiskFactory.withCapacity(fixtureA, sizeBytes: 4096)
        let state = EDPVirtualUSBState()
        state.insert(tiny, as: "disk21", registryEntryID: 0x3000, usbRegistryEntryID: 0x3001)
        let disks = try discovery(state).discover()
        guard disks.isEmpty else {
            throw VirtualUSBValidationError("P30 invalid tiny capacity was claimed as standard EDP")
        }
        print("SCENARIO=P30_OK invalid_capacity_refused")
    }

    private static func requireSingle(
        _ disks: [PhysicalDisk],
        _ label: String
    ) throws -> PhysicalDisk {
        guard disks.count == 1, let disk = disks.first else {
            throw VirtualUSBValidationError("\(label): expected exactly one disk, got \(disks.count)")
        }
        return disk
    }

    private static func expectThrows(
        _ message: String,
        _ operation: () throws -> Void
    ) throws {
        do {
            try operation()
        } catch {
            return
        }
        throw VirtualUSBValidationError(message)
    }
}
