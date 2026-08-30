import Foundation

private struct StorageFailureValidationError: Error, CustomStringConvertible {
    let description: String
}

@main
private enum ValidateStorageFailureContracts {
    static func main() throws {
        try validateSynchronizeFailure()
        try validateFinalDurabilityFailure()
        print("SCENARIO=M13_OK fsync_and_final_durability_failures_propagate")
        print("RESULT=DRIVE_STORAGE_FAILURE_CONTRACTS_OK")
    }

    private static func makeContext(
        raw: EDPVirtualRawDevice
    ) throws -> UnsafeMutableRawPointer {
        let block = try EDPPlaintextReadWriteBlockDevice(
            raw: raw,
            startSector: 0,
            sizeBytes: raw.sizeBytes ?? 0
        )
        let context = EDPReadWriteBridgeContext(raw: raw, block: block)
        return Unmanaged.passRetained(context).toOpaque()
    }

    private static func validateSynchronizeFailure() throws {
        let raw = EDPVirtualRawDevice(sizeBytes: 8192)
        let opaque = try makeContext(raw: raw)
        raw.setFault(.syncEIO)
        guard edp_rw_sync(opaque) == -5 else {
            _ = edp_rw_close(opaque)
            throw StorageFailureValidationError(
                description: "M13 synchronize failure did not cross the production C boundary"
            )
        }
        raw.setFault(.none)
        guard edp_rw_close(opaque) == 0 else {
            throw StorageFailureValidationError(
                description: "M13 recovery close unexpectedly failed"
            )
        }
    }

    private static func validateFinalDurabilityFailure() throws {
        let raw = EDPVirtualRawDevice(sizeBytes: 8192)
        let opaque = try makeContext(raw: raw)
        raw.setFault(.syncEIO)
        guard edp_rw_close(opaque) == -5 else {
            throw StorageFailureValidationError(
                description: "M13 final durability failure was swallowed by edp_rw_close"
            )
        }
    }
}
