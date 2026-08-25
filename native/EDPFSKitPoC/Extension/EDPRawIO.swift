import Foundation

/// Native byte-oriented storage boundary used by EDP parsing and crypto code.
///
/// FSKit-specific transfer alignment belongs in the concrete adapter. Higher
/// layers can request exact byte ranges without importing FSKit or depending on
/// any foreign-language ABI.
protocol EDPRawReadable: AnyObject {
    var sizeBytes: UInt64? { get }

    func readExact(at offset: UInt64, length: Int) throws -> Data
}

/// Mutable raw-storage boundary used only after an EDP volume has been
/// explicitly opened for read/write access.
///
/// Implementations must complete an entire write or throw. `synchronize()` is
/// the durability boundary used by FUSE flush/fsync and before device eject.
protocol EDPRawWritable: EDPRawReadable {
    var allowsWrites: Bool { get }

    func writeExact(at offset: UInt64, data: Data) throws
    func synchronize() throws
}
