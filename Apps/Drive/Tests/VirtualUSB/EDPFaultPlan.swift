import Foundation

enum EDPVirtualMetadataFault: Sendable, Equatable {
    case none
    case readFailure(String)
    case shortLBA11(Int)
    case detachDuringRead(afterSector: Int)
}

enum EDPVirtualRawFault: Sendable, Equatable {
    case none
    case detached
    case readEIO
    case writeEIO
    case syncEIO
}

struct EDPVirtualUSBError: Error, CustomStringConvertible, Sendable {
    let description: String
    init(_ description: String) { self.description = description }
}
