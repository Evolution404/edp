import Foundation

final class EDPVirtualUSBState: @unchecked Sendable {
    private let lock = NSLock()
    private var devicesByBSD = [String: EDPVirtualMediaDevice]()

    func insert(
        _ device: EDPVirtualMediaDevice,
        as bsdName: String,
        registryEntryID: UInt64,
        usbRegistryEntryID: UInt64
    ) {
        lock.lock()
        devicesByBSD[bsdName] = device.connected(
            as: bsdName,
            registryEntryID: registryEntryID,
            usbRegistryEntryID: usbRegistryEntryID
        )
        lock.unlock()
    }

    func remove(_ bsdName: String) {
        lock.lock()
        devicesByBSD.removeValue(forKey: bsdName)
        lock.unlock()
    }

    func replace(
        _ bsdName: String,
        with device: EDPVirtualMediaDevice,
        registryEntryID: UInt64,
        usbRegistryEntryID: UInt64
    ) {
        insert(
            device,
            as: bsdName,
            registryEntryID: registryEntryID,
            usbRegistryEntryID: usbRegistryEntryID
        )
    }

    func setMetadataFault(_ fault: EDPVirtualMetadataFault, for bsdName: String) {
        lock.lock()
        if var device = devicesByBSD[bsdName] {
            device.metadataFault = fault
            devicesByBSD[bsdName] = device
        }
        lock.unlock()
    }

    func updateMetadata(
        for bsdName: String,
        _ transform: (inout EDPRawMetadataSnapshot) -> Void
    ) {
        lock.lock()
        if var device = devicesByBSD[bsdName] {
            var metadata = device.metadata
            transform(&metadata)
            device.metadata = metadata
            devicesByBSD[bsdName] = device
        }
        lock.unlock()
    }

    func currentMedia() -> [EDPWholeUSBMedia] {
        lock.lock()
        let media = devicesByBSD.values.map(\.media).sorted { $0.bsdName < $1.bsdName }
        lock.unlock()
        return media
    }

    func registryEntryExists(_ registryEntryID: UInt64) -> Bool {
        lock.lock()
        let exists = devicesByBSD.values.contains {
            $0.media.registryEntryID == registryEntryID
                || $0.media.usbRegistryEntryID == registryEntryID
        }
        lock.unlock()
        return exists
    }

    func snapshot(for bsdName: String) throws -> EDPRawMetadataSnapshot {
        lock.lock()
        guard let device = devicesByBSD[bsdName] else {
            lock.unlock()
            throw EDPVirtualUSBError("detached: \(bsdName)")
        }
        let fault = device.metadataFault
        let metadata = device.metadata
        if case .detachDuringRead = fault {
            devicesByBSD.removeValue(forKey: bsdName)
        }
        lock.unlock()

        switch fault {
        case .none:
            return metadata
        case .readFailure(let detail):
            throw EDPVirtualUSBError(detail)
        case .shortLBA11(let byteCount):
            return EDPRawMetadataSnapshot(
                lba0: metadata.lba0,
                lba4: metadata.lba4,
                lba7: metadata.lba7,
                lba11: Data(metadata.lba11.prefix(max(0, byteCount))),
                lba12: metadata.lba12
            )
        case .detachDuringRead(let afterSector):
            throw EDPVirtualUSBError("detached during metadata read after sector \(afterSector)")
        }
    }

    func device(for bsdName: String) -> EDPVirtualMediaDevice? {
        lock.lock()
        let device = devicesByBSD[bsdName]
        lock.unlock()
        return device
    }
}

struct EDPVirtualWholeUSBMediaProvider: EDPWholeUSBMediaProviding {
    let state: EDPVirtualUSBState

    func allWholeUSBMedia() throws -> [EDPWholeUSBMedia] {
        state.currentMedia()
    }

    func registryEntryExists(_ registryEntryID: UInt64) -> Bool {
        state.registryEntryExists(registryEntryID)
    }
}

struct EDPVirtualRawMetadataReader: EDPRawMetadataReading {
    let state: EDPVirtualUSBState

    func snapshot(for media: EDPWholeUSBMedia) throws -> EDPRawMetadataSnapshot {
        try state.snapshot(for: media.bsdName)
    }
}
