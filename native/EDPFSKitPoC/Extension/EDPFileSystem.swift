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

        // This marker is deliberately stable so CI/runtime diagnostics cannot
        // confuse another FSKit module's probeResource callback with ours.
        logger.notice("PROBE_BLOCK_DEVICE=\(block.bsdName, privacy: .public)")

        // Phase 1 intentionally stops here. Reaching this callback with a real
        // FSBlockDeviceResource proves that fskitd can launch our own module and
        // deliver block media without macFUSE. Phase 2 will inspect EDP metadata.
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
