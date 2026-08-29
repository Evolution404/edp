import Foundation

private final class EDPReadWriteBridgeContext {
    let raw: EDPFileRawDevice
    let block: any EDPBlockWritable

    init(cipherPath: String, key: [UInt8]) throws {
        raw = try EDPFileRawDevice(path: cipherPath, writable: true)
        guard let sizeBytes = raw.sizeBytes else {
            throw EDPNativeCoreError.invalidInput("cipher backing has no size")
        }
        let descriptor = EDPVolumeDescriptor(
            partitionType: 2,
            startSector: 0,
            sizeBytes: sizeBytes,
            algorithm: 2,
            fileKey: key,
            passwordCRC: 0,
            keyCRC: 0
        )
        let reader = try EDPEncryptedPartitionReader(raw: raw, descriptor: descriptor)
        block = try EDPEncryptedReadWriteBlockDevice(reader: reader)
    }

    init(
        rawPath: String,
        vidHex: String,
        pidHex: String,
        deviceSizeBytes: UInt64,
        passwordBytes: [UInt8],
        partitionType: UInt32
    ) throws {
        raw = try EDPFileRawDevice(
            path: rawPath,
            declaredSizeBytes: deviceSizeBytes,
            writable: true
        )
        if partitionType == 1 {
            block = try EDPBootUnlock.unlock(
                raw: raw,
                vidHex: vidHex,
                pidHex: pidHex,
                deviceSizeBytes: deviceSizeBytes
            ).block
        } else {
            let unlocked = try EDPReadWriteUnlock.unlock(
                raw: raw,
                request: EDPReadWriteUnlockRequest(
                    vidHex: vidHex,
                    pidHex: pidHex,
                    deviceSizeBytes: deviceSizeBytes,
                    passwordBytes: passwordBytes,
                    partitionType: partitionType
                )
            )
            block = unlocked.block
        }
    }

    init(
        rawFileDescriptor: Int32,
        vidHex: String,
        pidHex: String,
        deviceSizeBytes: UInt64,
        passwordBytes: [UInt8],
        partitionType: UInt32
    ) throws {
        raw = try EDPFileRawDevice(
            fileDescriptor: rawFileDescriptor,
            declaredSizeBytes: deviceSizeBytes,
            writable: true
        )
        if partitionType == 1 {
            block = try EDPBootUnlock.unlock(
                raw: raw,
                vidHex: vidHex,
                pidHex: pidHex,
                deviceSizeBytes: deviceSizeBytes
            ).block
        } else {
            let unlocked = try EDPReadWriteUnlock.unlock(
                raw: raw,
                request: EDPReadWriteUnlockRequest(
                    vidHex: vidHex,
                    pidHex: pidHex,
                    deviceSizeBytes: deviceSizeBytes,
                    passwordBytes: passwordBytes,
                    partitionType: partitionType
                )
            )
            block = unlocked.block
        }
    }
}

private func logReadWriteBridgeError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

private func parseReadWriteHexKey(_ pointer: UnsafePointer<CChar>?) -> [UInt8]? {
    guard let pointer else { return nil }
    let text = String(cString: pointer)
    guard text.count == 32 else { return nil }

    var bytes = [UInt8]()
    bytes.reserveCapacity(16)
    var index = text.startIndex
    for _ in 0..<16 {
        let next = text.index(index, offsetBy: 2)
        guard let value = UInt8(text[index..<next], radix: 16) else { return nil }
        bytes.append(value)
        index = next
    }
    return bytes
}

@_cdecl("edp_rw_open")
public func edp_rw_open(
    _ cipherPathPointer: UnsafePointer<CChar>?,
    _ keyHexPointer: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer? {
    guard let cipherPathPointer,
          let key = parseReadWriteHexKey(keyHexPointer) else {
        return nil
    }

    do {
        let context = try EDPReadWriteBridgeContext(
            cipherPath: String(cString: cipherPathPointer),
            key: key
        )
        return Unmanaged.passRetained(context).toOpaque()
    } catch {
        logReadWriteBridgeError("EDP_RW_OPEN_ERROR=\(error)\n")
        return nil
    }
}

@_cdecl("edp_rw_open_device")
public func edp_rw_open_device(
    _ rawPathPointer: UnsafePointer<CChar>?,
    _ vidPointer: UnsafePointer<CChar>?,
    _ pidPointer: UnsafePointer<CChar>?,
    _ deviceSizeBytes: UInt64,
    _ passwordPointer: UnsafePointer<UInt8>?,
    _ passwordLength: UInt64,
    _ partitionType: UInt32
) -> UnsafeMutableRawPointer? {
    guard let rawPathPointer,
          let vidPointer,
          let pidPointer,
          [UInt32(1), 2, 4].contains(partitionType),
          passwordLength <= UInt64(Int.max) else {
        return nil
    }
    guard partitionType == 1 || (passwordPointer != nil && passwordLength > 0) else {
        return nil
    }

    let passwordBytes: [UInt8]
    if let passwordPointer, passwordLength > 0 {
        passwordBytes = Array(
            UnsafeBufferPointer(start: passwordPointer, count: Int(passwordLength))
        )
    } else {
        passwordBytes = []
    }

    do {
        let context = try EDPReadWriteBridgeContext(
            rawPath: String(cString: rawPathPointer),
            vidHex: String(cString: vidPointer),
            pidHex: String(cString: pidPointer),
            deviceSizeBytes: deviceSizeBytes,
            passwordBytes: passwordBytes,
            partitionType: partitionType
        )
        return Unmanaged.passRetained(context).toOpaque()
    } catch {
        logReadWriteBridgeError("EDP_RW_OPEN_DEVICE_ERROR=\(error)\n")
        return nil
    }
}

@_cdecl("edp_rw_open_device_fd")
public func edp_rw_open_device_fd(
    _ rawFileDescriptor: Int32,
    _ vidPointer: UnsafePointer<CChar>?,
    _ pidPointer: UnsafePointer<CChar>?,
    _ deviceSizeBytes: UInt64,
    _ passwordPointer: UnsafePointer<UInt8>?,
    _ passwordLength: UInt64,
    _ partitionType: UInt32
) -> UnsafeMutableRawPointer? {
    guard rawFileDescriptor >= 0,
          let vidPointer,
          let pidPointer,
          [UInt32(1), 2, 4].contains(partitionType),
          passwordLength <= UInt64(Int.max) else {
        return nil
    }
    guard partitionType == 1 || (passwordPointer != nil && passwordLength > 0) else {
        return nil
    }
    let passwordBytes: [UInt8]
    if let passwordPointer, passwordLength > 0 {
        passwordBytes = Array(
            UnsafeBufferPointer(start: passwordPointer, count: Int(passwordLength))
        )
    } else {
        passwordBytes = []
    }
    do {
        let context = try EDPReadWriteBridgeContext(
            rawFileDescriptor: rawFileDescriptor,
            vidHex: String(cString: vidPointer),
            pidHex: String(cString: pidPointer),
            deviceSizeBytes: deviceSizeBytes,
            passwordBytes: passwordBytes,
            partitionType: partitionType
        )
        return Unmanaged.passRetained(context).toOpaque()
    } catch {
        logReadWriteBridgeError("EDP_RW_OPEN_DEVICE_FD_ERROR=\(error)\n")
        return nil
    }
}

@_cdecl("edp_rw_size")
public func edp_rw_size(_ opaque: UnsafeMutableRawPointer?) -> UInt64 {
    guard let opaque else { return 0 }
    return Unmanaged<EDPReadWriteBridgeContext>.fromOpaque(opaque)
        .takeUnretainedValue().block.sizeBytes
}

@_cdecl("edp_rw_read")
public func edp_rw_read(
    _ opaque: UnsafeMutableRawPointer?,
    _ offset: UInt64,
    _ buffer: UnsafeMutableRawPointer?,
    _ requestedLength: UInt64
) -> Int64 {
    guard let opaque else { return -22 }
    if requestedLength == 0 { return 0 }
    guard let buffer else { return -22 }

    let context = Unmanaged<EDPReadWriteBridgeContext>.fromOpaque(opaque)
        .takeUnretainedValue()
    let size = context.block.sizeBytes
    if offset >= size { return 0 }

    let length64 = min(requestedLength, size - offset)
    guard length64 <= UInt64(Int.max) else { return -22 }
    do {
        let data = try context.block.read(at: offset, length: Int(length64))
        data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
        return Int64(data.count)
    } catch {
        logReadWriteBridgeError(
            "EDP_RW_READ_ERROR offset=\(offset) length=\(length64) error=\(error)\n"
        )
        return -5
    }
}

@_cdecl("edp_rw_write")
public func edp_rw_write(
    _ opaque: UnsafeMutableRawPointer?,
    _ offset: UInt64,
    _ buffer: UnsafeRawPointer?,
    _ requestedLength: UInt64
) -> Int64 {
    guard let opaque else { return -22 }
    if requestedLength == 0 { return 0 }
    guard let buffer,
          requestedLength <= UInt64(Int.max) else { return -22 }

    let context = Unmanaged<EDPReadWriteBridgeContext>.fromOpaque(opaque)
        .takeUnretainedValue()
    let size = context.block.sizeBytes
    guard offset <= size, requestedLength <= size - offset else { return -28 }

    let data = Data(bytes: buffer, count: Int(requestedLength))
    do {
        try context.block.write(at: offset, data: data)
        return Int64(requestedLength)
    } catch {
        logReadWriteBridgeError(
            "EDP_RW_WRITE_ERROR offset=\(offset) length=\(requestedLength) error=\(error)\n"
        )
        return -5
    }
}

@_cdecl("edp_rw_sync")
public func edp_rw_sync(_ opaque: UnsafeMutableRawPointer?) -> Int32 {
    guard let opaque else { return -22 }
    let context = Unmanaged<EDPReadWriteBridgeContext>.fromOpaque(opaque)
        .takeUnretainedValue()
    do {
        try context.block.synchronize()
        return 0
    } catch {
        logReadWriteBridgeError("EDP_RW_SYNC_ERROR=\(error)\n")
        return -5
    }
}

@_cdecl("edp_rw_close")
public func edp_rw_close(_ opaque: UnsafeMutableRawPointer?) {
    guard let opaque else { return }
    let context = Unmanaged<EDPReadWriteBridgeContext>.fromOpaque(opaque)
        .takeRetainedValue()
    do {
        try context.block.synchronize()
    } catch {
        logReadWriteBridgeError("EDP_RW_CLOSE_SYNC_ERROR=\(error)\n")
    }
}
