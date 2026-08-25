import Foundation

private final class EDPReadOnlyBridgeContext {
    let raw: EDPFileRawDevice
    let block: EDPEncryptedReadOnlyBlockDevice

    init(cipherPath: String, key: [UInt8]) throws {
        raw = try EDPFileRawDevice(path: cipherPath)
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
        block = try EDPEncryptedReadOnlyBlockDevice(reader: reader)
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
            declaredSizeBytes: deviceSizeBytes
        )
        let unlocked = try EDPReadOnlyUnlock.unlock(
            raw: raw,
            request: EDPReadOnlyUnlockRequest(
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

private func logBridgeError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

private func parseHexKey(_ pointer: UnsafePointer<CChar>?) -> [UInt8]? {
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

@_cdecl("edp_ro_open")
public func edp_ro_open(
    _ cipherPathPointer: UnsafePointer<CChar>?,
    _ keyHexPointer: UnsafePointer<CChar>?
) -> UnsafeMutableRawPointer? {
    guard let cipherPathPointer,
          let key = parseHexKey(keyHexPointer) else {
        return nil
    }

    do {
        let context = try EDPReadOnlyBridgeContext(
            cipherPath: String(cString: cipherPathPointer),
            key: key
        )
        return Unmanaged.passRetained(context).toOpaque()
    } catch {
        logBridgeError("EDP_RO_OPEN_ERROR=\(error)\n")
        return nil
    }
}

@_cdecl("edp_ro_open_device")
public func edp_ro_open_device(
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
          let passwordPointer,
          passwordLength > 0,
          passwordLength <= UInt64(Int.max) else {
        return nil
    }

    let passwordBytes = Array(
        UnsafeBufferPointer(
            start: passwordPointer,
            count: Int(passwordLength)
        )
    )

    do {
        let context = try EDPReadOnlyBridgeContext(
            rawPath: String(cString: rawPathPointer),
            vidHex: String(cString: vidPointer),
            pidHex: String(cString: pidPointer),
            deviceSizeBytes: deviceSizeBytes,
            passwordBytes: passwordBytes,
            partitionType: partitionType
        )
        return Unmanaged.passRetained(context).toOpaque()
    } catch {
        logBridgeError("EDP_RO_OPEN_DEVICE_ERROR=\(error)\n")
        return nil
    }
}

@_cdecl("edp_ro_size")
public func edp_ro_size(_ opaque: UnsafeMutableRawPointer?) -> UInt64 {
    guard let opaque else { return 0 }
    return Unmanaged<EDPReadOnlyBridgeContext>.fromOpaque(opaque)
        .takeUnretainedValue().block.sizeBytes
}

@_cdecl("edp_ro_read")
public func edp_ro_read(
    _ opaque: UnsafeMutableRawPointer?,
    _ offset: UInt64,
    _ buffer: UnsafeMutableRawPointer?,
    _ requestedLength: UInt64
) -> Int64 {
    guard let opaque, let buffer else { return -22 }
    let context = Unmanaged<EDPReadOnlyBridgeContext>.fromOpaque(opaque).takeUnretainedValue()
    let size = context.block.sizeBytes
    if offset >= size { return 0 }

    let remaining = size - offset
    let length64 = min(requestedLength, remaining)
    guard length64 <= UInt64(Int.max) else { return -22 }

    do {
        let data = try context.block.read(at: offset, length: Int(length64))
        data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
        return Int64(data.count)
    } catch {
        logBridgeError("EDP_RO_READ_ERROR offset=\(offset) length=\(length64) error=\(error)\n")
        return -5
    }
}

@_cdecl("edp_ro_close")
public func edp_ro_close(_ opaque: UnsafeMutableRawPointer?) {
    guard let opaque else { return }
    Unmanaged<EDPReadOnlyBridgeContext>.fromOpaque(opaque).release()
}
