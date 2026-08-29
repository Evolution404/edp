import Foundation

/// Native byte-oriented storage boundary used by EDP parsing and crypto code.
///
/// FSKit-specific transfer alignment belongs in the concrete adapter. Higher
/// layers can request exact byte ranges without importing FSKit or depending on
/// any foreign-language ABI.
protocol EDPRawReadable: AnyObject {
    var sizeBytes: UInt64? { get }
    var supportsConcurrentReads: Bool { get }

    func readExact(at offset: UInt64, length: Int) throws -> Data
    func readExact(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws
}

extension EDPRawReadable {
    var supportsConcurrentReads: Bool { false }

    func readExact(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws {
        let data = try readExact(at: offset, length: buffer.count)
        guard data.count == buffer.count else {
            throw EDPNativeCoreError.verify("raw read returned an unexpected byte count")
        }
        _ = data.copyBytes(to: buffer.bindMemory(to: UInt8.self))
    }
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
