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

        // Stable markers keep runtime diagnostics specific to this module.
        logger.notice("PROBE_BLOCK_DEVICE=\(block.bsdName, privacy: .public)")
        logger.notice(
            "PROBE_GEOMETRY=physical:\(block.physicalBlockSize, privacy: .public) logical:\(block.blockSize, privacy: .public) blocks:\(block.blockCount, privacy: .public)"
        )

        // Read exactly one physical sector at offset zero. FSBlockDeviceResource
        // requires device-compatible transfer sizes and offsets, so using the
        // reported physical block size keeps this primitive valid for real media.
        let physicalBlockSize = block.physicalBlockSize
        guard physicalBlockSize > 0, physicalBlockSize <= UInt64(Int.max) else {
            logger.error("PROBE_INVALID_PHYSICAL_BLOCK_SIZE=\(physicalBlockSize, privacy: .public)")
            reply(nil, POSIXError(.EINVAL))
            return
        }

        let readLength = Int(physicalBlockSize)
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: readLength,
            alignment: MemoryLayout<UInt64>.alignment
        )
        defer { storage.deallocate() }

        let buffer = UnsafeMutableRawBufferPointer(start: storage, count: readLength)

        do {
            let bytesRead = try block.read(into: buffer, startingAt: 0, length: readLength)
            let prefixLength = min(bytesRead, 32)
            let prefix = buffer.prefix(prefixLength)
                .map { String(format: "%02x", $0) }
                .joined()

            logger.notice("PROBE_SECTOR0_READ=\(bytesRead, privacy: .public)")
            logger.notice("PROBE_SECTOR0_HEX=\(prefix, privacy: .public)")
        } catch {
            logger.error("PROBE_SECTOR0_READ_ERROR=\(String(describing: error), privacy: .public)")
            reply(nil, error)
            return
        }

        // Recognition/mount semantics are intentionally not implemented yet.
        // Returning ENOTSUP keeps this phase read-only while proving native block I/O.
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
