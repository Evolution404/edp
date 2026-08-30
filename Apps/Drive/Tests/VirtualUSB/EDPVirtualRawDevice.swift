import Foundation

final class EDPVirtualRawDevice: EDPRawWritable, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Data
    private var fault: EDPVirtualRawFault = .none

    init(sizeBytes: Int, fill: UInt8 = 0) {
        storage = Data(repeating: fill, count: sizeBytes)
    }

    var sizeBytes: UInt64? {
        lock.lock()
        let value = UInt64(storage.count)
        lock.unlock()
        return value
    }

    let supportsConcurrentReads = false
    let allowsWrites = true

    func setFault(_ fault: EDPVirtualRawFault) {
        lock.lock()
        self.fault = fault
        lock.unlock()
    }

    func readExact(at offset: UInt64, length: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try throwIfUnavailable(forWrite: false)
        guard length >= 0,
              offset <= UInt64(Int.max),
              Int(offset) <= storage.count,
              length <= storage.count - Int(offset) else {
            throw EDPVirtualUSBError("virtual raw read out of bounds")
        }
        return storage.subdata(in: Int(offset)..<(Int(offset) + length))
    }

    func writeExact(at offset: UInt64, data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try throwIfUnavailable(forWrite: true)
        guard offset <= UInt64(Int.max),
              Int(offset) <= storage.count,
              data.count <= storage.count - Int(offset) else {
            throw EDPVirtualUSBError("virtual raw write out of bounds")
        }
        storage.replaceSubrange(Int(offset)..<(Int(offset) + data.count), with: data)
    }

    func synchronize() throws {
        lock.lock()
        defer { lock.unlock() }
        switch fault {
        case .detached:
            throw EDPVirtualUSBError("ENODEV: virtual raw device detached")
        case .syncEIO:
            throw EDPVirtualUSBError("EIO: virtual raw sync failed")
        default:
            return
        }
    }

    func forceDurability() throws {
        try synchronize()
    }

    private func throwIfUnavailable(forWrite: Bool) throws {
        switch fault {
        case .detached:
            throw EDPVirtualUSBError("ENODEV: virtual raw device detached")
        case .readEIO where !forWrite:
            throw EDPVirtualUSBError("EIO: virtual raw read failed")
        case .writeEIO where forWrite:
            throw EDPVirtualUSBError("EIO: virtual raw write failed")
        default:
            return
        }
    }
}
