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

            var serialBuffer = [CChar](
                repeating: 0,
                count: Int(EDP_PROBE_SERIAL_CAPACITY)
            )

            let probeRC: Int32 = reserved.lba4.withUnsafeBufferPointer { lba4 in
                reserved.lba7.withUnsafeBufferPointer { lba7 in
                    serialBuffer.withUnsafeMutableBufferPointer { serial in
                        edp_probe_reserved_sectors(
                            lba4.baseAddress,
                            lba7.baseAddress,
                            serial.baseAddress,
                            serial.count
                        )
                    }
                }
            }

            switch probeRC {
            case EDP_PROBE_NOT_RECOGNIZED:
                logger.notice("PROBE_CORE=rust-c-abi")
                logger.notice("PROBE_EDP_RESERVED_SIGNATURE=false")
                logger.notice("PROBE_MATCH=notRecognized")
                reply(.notRecognized, nil)

            case EDP_PROBE_RECOGNIZED:
                guard let serialBase = serialBuffer.withUnsafeBufferPointer({ $0.baseAddress }) else {
                    logger.error("PROBE_CORE_SERIAL_BUFFER_MISSING")
                    reply(nil, POSIXError(.EIO))
                    return
                }

                let serial = String(cString: serialBase)
                logger.notice("PROBE_CORE=rust-c-abi")
                logger.notice("PROBE_EDP_RESERVED_SIGNATURE=true")
                logger.notice("PROBE_EDP_SERIAL=\(serial, privacy: .public)")

                // The passwordless reserved-sector evidence does not expose a
                // durable container UUID. A stable identifier can be introduced
                // later when LBA11/device identity is wired into the Rust bridge.
                let containerID = FSContainerIdentifier()
                logger.notice("PROBE_MATCH=recognized")
                reply(.recognized(name: "EDP USB Vault", containerID: containerID), nil)

            default:
                logger.error("PROBE_CORE_ERROR=\(probeRC, privacy: .public)")
                reply(nil, POSIXError(.EIO))
            }
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
