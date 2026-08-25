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
            let rawLBA7 = try EDPMetadataProbe.readLBA7(from: block)
            logger.notice("PROBE_LBA7_READ=\(rawLBA7.count, privacy: .public)")

            guard let recognition = EDPMetadataProbe.recognizeOldFormatLBA7(rawLBA7) else {
                logger.notice("PROBE_EDPF_OLD_FORMAT=false")
                logger.notice("PROBE_MATCH=notRecognized")
                reply(.notRecognized, nil)
                return
            }

            let k0 = String(format: "0x%04x", recognition.k0)
            logger.notice("PROBE_EDPF_OLD_FORMAT=true")
            logger.notice("PROBE_LBA7_K0=\(k0, privacy: .public)")

            // EDP's legacy metadata doesn't expose a durable container UUID at
            // this recognition stage. FSKit explicitly permits unary file systems
            // to use a random FSContainerIdentifier when no durable UUID exists.
            // Once LBA11/device identity is integrated we can make this stable.
            let containerID = FSContainerIdentifier()
            logger.notice("PROBE_MATCH=recognized")
            reply(.recognized(name: "EDP USB Vault", containerID: containerID), nil)
        } catch {
            logger.error("PROBE_LBA7_READ_ERROR=\(String(describing: error), privacy: .public)")
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
