import Foundation

/// Filesystem-agnostic logical block view exposed by the EDP crypto layer.
///
/// This protocol intentionally knows nothing about macFUSE, DiskImages2,
/// FSKit, partitions inside the decrypted volume, or any concrete filesystem.
/// The first product milestone is read-only; write/flush are added only after
/// real-device read-only mounting is proven safe.
protocol EDPBlockReadable: AnyObject {
    var sizeBytes: UInt64 { get }

    func read(at offset: UInt64, length: Int) throws -> Data
}

/// Adapts the existing encrypted-partition reader to the product block-view
/// contract without changing its crypto semantics.
final class EDPEncryptedReadOnlyBlockDevice: EDPBlockReadable {
    private let reader: EDPEncryptedPartitionReader

    init(reader: EDPEncryptedPartitionReader) throws {
        guard let sizeBytes = reader.sizeBytes else {
            throw EDPNativeCoreError.invalidInput("EDP encrypted partition has no logical size")
        }
        self.reader = reader
        self.sizeBytes = sizeBytes
    }

    let sizeBytes: UInt64

    func read(at offset: UInt64, length: Int) throws -> Data {
        try reader.readExact(at: offset, length: length)
    }
}
