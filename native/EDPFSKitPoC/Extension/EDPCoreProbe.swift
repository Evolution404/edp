import Foundation

enum EDPCoreProbeError: Error {
    case invalidSectorLength
    case invalidArgument
    case serialBufferTooSmall
    case unexpectedResult(Int32)
}

enum EDPCoreProbe {
    static func recognize(lba4: Data, lba7: Data) throws -> String? {
        guard lba4.count == Int(EDP_PROBE_SECTOR_SIZE),
              lba7.count == Int(EDP_PROBE_SECTOR_SIZE) else {
            throw EDPCoreProbeError.invalidSectorLength
        }

        var serial = [CChar](
            repeating: 0,
            count: Int(EDP_PROBE_SERIAL_CAPACITY)
        )

        let result: Int32 = lba4.withUnsafeBytes { lba4Buffer in
            lba7.withUnsafeBytes { lba7Buffer in
                guard let lba4Base = lba4Buffer.bindMemory(to: UInt8.self).baseAddress,
                      let lba7Base = lba7Buffer.bindMemory(to: UInt8.self).baseAddress else {
                    return Int32(EDP_PROBE_INVALID_ARGUMENT)
                }

                return edp_probe_reserved_sectors(
                    lba4Base,
                    lba7Base,
                    &serial,
                    serial.count
                )
            }
        }

        switch result {
        case Int32(EDP_PROBE_RECOGNIZED):
            return serial.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return nil }
                return String(cString: base)
            }
        case Int32(EDP_PROBE_NOT_RECOGNIZED):
            return nil
        case Int32(EDP_PROBE_INVALID_ARGUMENT):
            throw EDPCoreProbeError.invalidArgument
        case Int32(EDP_PROBE_SERIAL_BUFFER_TOO_SMALL):
            throw EDPCoreProbeError.serialBufferTooSmall
        default:
            throw EDPCoreProbeError.unexpectedResult(result)
        }
    }
}
