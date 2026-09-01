import Darwin
import Foundation

@_silgen_name("edp_raw_fd_broker_spawn")
private func edpRawFDBrokerSpawn(
    _ appExecutable: UnsafePointer<CChar>,
    _ rawPath: UnsafePointer<CChar>,
    _ timeoutMilliseconds: Int32,
    _ outError: UnsafeMutablePointer<Int32>
) -> Int32

let edpRawAccessBrokerAppPath = "/Applications/EDP Drive.app/Contents/MacOS/EDP Drive"

final class EDPRawAccessLease: @unchecked Sendable {
    let deviceID: String
    let registryEntryID: UInt64
    let rawPath: String
    private(set) var fd: Int32

    init(deviceID: String, registryEntryID: UInt64, rawPath: String, fd: Int32) {
        self.deviceID = deviceID
        self.registryEntryID = registryEntryID
        self.rawPath = rawPath
        self.fd = fd
    }

    func invalidate() {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
    }

    deinit {
        invalidate()
    }
}

private func preadExact(fd: Int32, offset: UInt64, length: Int) throws -> Data {
    guard offset <= UInt64(Int64.max) else { throw fail("raw read offset exceeds off_t") }
    var data = Data(count: length)
    try data.withUnsafeMutableBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        var completed = 0
        while completed < length {
            let result = Darwin.pread(
                fd,
                base.advanced(by: completed),
                length - completed,
                off_t(offset + UInt64(completed))
            )
            if result < 0 {
                if errno == EINTR { continue }
                throw fail("raw pread failed: errno=\(errno)")
            }
            guard result > 0 else { throw fail("raw pread reached EOF") }
            completed += result
        }
    }
    return data
}

func rawMetadataSnapshot(fd: Int32) throws -> EDPRawMetadataSnapshot {
    guard fd >= 0 else { throw fail("EDP raw access lease is closed") }
    let sector = Int(EDPMetadataProbe.legacySectorByteLength)
    return EDPRawMetadataSnapshot(
        lba0: try preadExact(fd: fd, offset: 0, length: sector),
        lba4: try preadExact(fd: fd, offset: EDPMetadataProbe.lba4ByteOffset, length: sector),
        lba7: try preadExact(fd: fd, offset: EDPMetadataProbe.lba7ByteOffset, length: sector),
        lba11: try preadExact(fd: fd, offset: EDPVolumeMetadata.lba11ByteOffset, length: sector),
        lba12: try preadExact(fd: fd, offset: EDPVolumeMetadata.lba12ByteOffset, length: sector)
    )
}

func wholeUSBMediaStillMatches(
    _ disk: PhysicalDisk,
    mediaProvider: any EDPWholeUSBMediaProviding
) throws -> Bool {
    try mediaProvider.allWholeUSBMedia().contains {
        $0.bsdName == disk.bsdName
            && $0.sizeBytes == disk.sizeBytes
            && $0.vidHex.lowercased() == disk.vidHex
            && $0.pidHex.lowercased() == disk.pidHex
            && $0.registryEntryID == disk.registryEntryID
            && $0.usbRegistryEntryID == disk.usbRegistryEntryID
    }
}

func openPersistentRawAccess(
    for disk: PhysicalDisk,
    mediaProvider: any EDPWholeUSBMediaProviding = EDPIOKitWholeUSBMediaProvider()
) throws -> EDPRawAccessLease {
    guard geteuid() == 0, try wholeUSBMediaStillMatches(disk, mediaProvider: mediaProvider) else {
        throw fail("EDP_RAW_LEASE_TARGET_REFUSED")
    }
    var before = stat()
    guard lstat(disk.rawPath, &before) == 0, (before.st_mode & S_IFMT) == S_IFCHR else {
        throw fail("EDP_RAW_LEASE_PATH_REFUSED")
    }

    var brokerError: Int32 = 0
    let fd = edpRawAccessBrokerAppPath.withCString { appPath in
        disk.rawPath.withCString { rawPath in
            edpRawFDBrokerSpawn(appPath, rawPath, 5_000, &brokerError)
        }
    }
    guard fd >= 0 else {
        throw fail("EDP_RAW_LEASE_OPEN_FAILED:\(brokerError)")
    }
    do {
        var opened = stat()
        var after = stat()
        guard fstat(fd, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFCHR,
              lstat(disk.rawPath, &after) == 0,
              (after.st_mode & S_IFMT) == S_IFCHR,
              opened.st_rdev == before.st_rdev,
              opened.st_rdev == after.st_rdev,
              try wholeUSBMediaStillMatches(disk, mediaProvider: mediaProvider) else {
            throw fail("EDP_RAW_LEASE_TYPE_REFUSED")
        }

        let metadata = try rawMetadataSnapshot(fd: fd)
        guard EDPPhysicalDeviceRevalidation.metadataStillMatches(metadata, disk: disk) else {
            throw fail("EDP_RAW_LEASE_METADATA_REFUSED")
        }
        return EDPRawAccessLease(
            deviceID: disk.deviceID,
            registryEntryID: disk.registryEntryID,
            rawPath: disk.rawPath,
            fd: fd
        )
    } catch {
        close(fd)
        throw error
    }
}

func userFacingRawAccessFailure(_ error: Error) -> EDPLifecycleFailure {
    let failure = EDPLifecycleFailure.classifyRawAccess(error)
    guard failure.code == .rawAccessPermission else { return failure }
    return EDPLifecycleFailure(
        code: .rawAccessPermission,
        detail: "需要为“EDP Drive 磁盘访问”开启完全磁盘访问："
            + "系统设置 → 隐私与安全性 → 完全磁盘访问"
    )
}

func rawMetadataSnapshot(for rawPath: String) throws -> EDPRawMetadataSnapshot {
    let uid = try consoleIdentity().0
    let result = try run(
        runtimeBinaryRoot() + "/edp-raw-metadata",
        [rawPath, String(uid)]
    )
    return try decodeRawMetadataOutput(result.stdout)
}

private func decodeRawMetadataOutput(_ output: Data) throws -> EDPRawMetadataSnapshot {
    let sector = Int(EDPMetadataProbe.legacySectorByteLength)
    guard output.count == sector * 5 else {
        throw fail("raw metadata helper returned \(output.count) bytes; expected \(sector * 5)")
    }
    func slice(_ index: Int) -> Data {
        let start = index * sector
        return output.subdata(in: start..<(start + sector))
    }
    return EDPRawMetadataSnapshot(
        lba0: slice(0),
        lba4: slice(1),
        lba7: slice(2),
        lba11: slice(3),
        lba12: slice(4)
    )
}

struct EDPPrivilegedRawMetadataReader: EDPRawMetadataReading {
    func snapshot(for media: EDPWholeUSBMedia) throws -> EDPRawMetadataSnapshot {
        guard FileManager.default.fileExists(atPath: media.rawPath) else {
            throw fail("raw device missing: \(media.rawPath)")
        }
        return try rawMetadataSnapshot(for: media.rawPath)
    }
}
