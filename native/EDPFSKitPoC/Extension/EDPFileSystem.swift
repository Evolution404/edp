import Foundation
import FSKit
import os

final class EDPFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    private let logger = Logger(subsystem: "com.edp.usbvault.fskit-poc.extension", category: "filesystem")

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

        logger.notice("PROBE_BLOCK_DEVICE=\(block.bsdName, privacy: .public)")
        logger.notice(
            "PROBE_GEOMETRY=physical:\(block.physicalBlockSize, privacy: .public) logical:\(block.blockSize, privacy: .public) blocks:\(block.blockCount, privacy: .public)"
        )

        do {
            let reserved = try EDPMetadataProbe.readReservedSectors(from: block)
            logger.notice("PROBE_RESERVED_SECTORS_READ=true")

            guard let recognition = EDPMetadataProbe.recognizeReservedSectors(
                lba4: reserved.lba4,
                lba7: reserved.lba7
            ) else {
                logger.notice("PROBE_EDP_RESERVED_SIGNATURE=false")
                logger.notice("PROBE_MATCH=notRecognized")
                reply(.notRecognized, nil)
                return
            }

            let k0 = String(format: "0x%04x", recognition.lba7K0)
            let partitionTypes = recognition.partitionTypes.map(String.init).joined(separator: ",")
            logger.notice("PROBE_EDP_RESERVED_SIGNATURE=true")
            logger.notice("PROBE_EDP_SERIAL=\(recognition.serial, privacy: .public)")
            logger.notice("PROBE_LBA7_K0=\(k0, privacy: .public)")
            logger.notice("PROBE_PARTITION_TYPES=\(partitionTypes, privacy: .public)")

            // No durable container UUID is exposed by these two passwordless
            // sectors. FSKit permits a unary file system to use a random ID in
            // this case. A stable identity can be introduced when LBA11 is wired.
            let containerID = FSContainerIdentifier()
            logger.notice("PROBE_MATCH=recognized")
            reply(.recognized(name: "EDP USB Vault", containerID: containerID), nil)
        } catch {
            logger.error("PROBE_RESERVED_READ_ERROR=\(String(describing: error), privacy: .public)")
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
