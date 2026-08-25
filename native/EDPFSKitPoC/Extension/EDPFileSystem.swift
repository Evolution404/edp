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
            reply(nil, POSIXError(.ENODEV))
            return
        }

        logger.notice("PROBE_BLOCK_DEVICE=\(block.bsdName, privacy: .public)")
        logger.notice(
            "PROBE_GEOMETRY=physical:\(block.physicalBlockSize, privacy: .public) logical:\(block.blockSize, privacy: .public) blocks:\(block.blockCount, privacy: .public)"
        )

        do {
            let rawLBA7 = try EDPMetadataProbe.readLBA7(from: block)
            logger.notice("PROBE_LBA7_READ=\(rawLBA7.count, privacy: .public)")

            if let recognition = EDPMetadataProbe.recognizeOldFormatLBA7(rawLBA7) {
                let k0 = String(format: "0x%04x", recognition.k0)
                logger.notice("PROBE_EDPF_OLD_FORMAT=true")
                logger.notice("PROBE_LBA7_K0=\(k0, privacy: .public)")
            } else {
                logger.notice("PROBE_EDPF_OLD_FORMAT=false")
            }
        } catch {
            logger.error("PROBE_LBA7_READ_ERROR=\(String(describing: error), privacy: .public)")
            reply(nil, error)
            return
        }

        // Phase 2 still stops before declaring a mountable FSVolume. The next
        // step is to return a real FSProbeResult for recognized EDP media and
        // then implement loadResource using the existing edp-core data model.
        reply(nil, POSIXError(.ENOTSUP))
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
