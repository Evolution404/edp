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
