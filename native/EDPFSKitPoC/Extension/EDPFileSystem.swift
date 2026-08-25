import Foundation
import FSKit
import os

final class EDPFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    private let logger = Logger(subsystem: "com.edp.usbvault.fskit-poc.extension", category: "filesystem")

    private static let lba4Offset = EDPMetadataProbe.lba4ByteOffset
    private static let lba7Offset = EDPMetadataProbe.lba7ByteOffset
    private static let sectorLength = Int(EDPMetadataProbe.legacySectorByteLength)

    func didFinishLoading() {
        logger.notice("EDP native FSKit extension loaded")
    }

    func probeResource(
        resource: FSResource,
        replyHandler reply: @escaping @Sendable (FSProbeResult?, (any Error)?) -> Void
    ) {
        guard let block = resource as? FSBlockDeviceResource else {
            logger.notice("PROBE_NON_BLOCK_RESOURCE")
            reply(.notRecognized, nil)
            return
        }

        let accessor = FSBlockRawAccessor(resource: block)
        let raw: any EDPRawReadable = accessor
        logger.notice("PROBE_BLOCK_DEVICE=\(accessor.bsdName, privacy: .public)")
        logger.notice(
            "PROBE_GEOMETRY=physical:\(block.physicalBlockSize, privacy: .public) logical:\(block.blockSize, privacy: .public) blocks:\(block.blockCount, privacy: .public)"
        )

        do {
            let lba4 = try raw.readExact(at: Self.lba4Offset, length: Self.sectorLength)
            let lba7 = try raw.readExact(at: Self.lba7Offset, length: Self.sectorLength)
            logger.notice("PROBE_RESERVED_SECTORS_READ=true")
            logger.notice("PROBE_CORE=swift-native")

            guard let evidence = EDPMetadataProbe.recognizeReservedSectors(
                lba4: [UInt8](lba4),
                lba7: [UInt8](lba7)
            ) else {
                logger.notice("PROBE_EDP_RESERVED_SIGNATURE=false")
                logger.notice("PROBE_MATCH=notRecognized")
                reply(.notRecognized, nil)
                return
            }

            logger.notice("PROBE_EDP_RESERVED_SIGNATURE=true")
            logger.notice("PROBE_EDP_SERIAL=\(evidence.serial, privacy: .public)")

            // The passwordless reserved-sector evidence does not expose a
            // durable container UUID. A stable identifier can be introduced
            // when LBA11/device identity is implemented in the native core.
            let containerID = FSContainerIdentifier()
            logger.notice("PROBE_MATCH=recognized")
            reply(.recognized(name: "EDP USB Vault", containerID: containerID), nil)
        } catch {
            logger.error("PROBE_NATIVE_OR_READ_ERROR=\(String(describing: error), privacy: .public)")
            reply(nil, error)
        }
    }

    func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping @Sendable (FSVolume?, (any Error)?) -> Void
    ) {
        logger.notice("loadResource resource=\(String(describing: resource), privacy: .public)")
        reply(nil, POSIXError(.ENOTSUP))
    }

    func unloadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        logger.notice("unloadResource resource=\(String(describing: resource), privacy: .public)")
        reply(nil)
    }
}
