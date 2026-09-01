import Darwin
import Foundation

func discoverEDPDisks(
    mediaProvider: any EDPWholeUSBMediaProviding = EDPIOKitWholeUSBMediaProvider(),
    metadataReader: any EDPRawMetadataReading = EDPPrivilegedRawMetadataReader(),
    diagnostic: ((String) -> Void)? = nil
) throws -> [PhysicalDisk] {
    try EDPPhysicalDiskDiscovery(
        mediaProvider: mediaProvider,
        metadataReader: metadataReader
    ).discover(diagnostic: diagnostic)
}

func readPassword(prompt: String) throws -> [UInt8] {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard readpassphrase(prompt, &buffer, buffer.count, 0) != nil else {
        throw fail("password input failed")
    }
    let length = buffer.firstIndex(of: 0) ?? buffer.count
    guard length > 0 else { throw fail("password must not be empty") }
    let result = buffer[..<length].map { UInt8(bitPattern: $0) }
    secureZero(&buffer)
    return result
}

func filesystemMagic(_ rawPath: String) throws -> String {
    let fd = open(rawPath, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { throw fail("cannot open published device \(rawPath): errno=\(errno)") }
    defer { close(fd) }
    var bytes = [UInt8](repeating: 0, count: 512)
    let count = bytes.withUnsafeMutableBytes { raw in
        pread(fd, raw.baseAddress, raw.count, 0)
    }
    guard count == bytes.count else {
        throw fail("cannot read decrypted filesystem boot sector")
    }
    if String(bytes: bytes[3..<11], encoding: .ascii) == "NTFS    " { return "NTFS" }
    if String(bytes: bytes[3..<11], encoding: .ascii) == "EXFAT   " { return "EXFAT" }
    if String(bytes: bytes[54..<62], encoding: .ascii)?.hasPrefix("FAT") == true
        || String(bytes: bytes[82..<90], encoding: .ascii)?.hasPrefix("FAT") == true {
        return "FAT"
    }
    return "UNKNOWN"
}

func resolveFilesystemDevice(_ rootBSD: String) throws -> (bsdName: String, magic: String) {
    let rootMagic = try filesystemMagic("/dev/r\(rootBSD)")
    if rootMagic != "UNKNOWN" { return (rootBSD, rootMagic) }

    for bsd in try EDPNativeDeviceDiscovery.descendantBSDNames(of: rootBSD) {
        guard FileManager.default.fileExists(atPath: "/dev/r\(bsd)"),
              let magic = try? filesystemMagic("/dev/r\(bsd)"),
              magic != "UNKNOWN" else {
            continue
        }
        return (bsd, magic)
    }
    return (rootBSD, "UNKNOWN")
}

func uniqueMountpoint(_ name: String) -> String {
    let base = "/Volumes/\(name)"
    if !FileManager.default.fileExists(atPath: base) { return base }
    for index in 2...999 {
        let candidate = base + " \(index)"
        if !FileManager.default.fileExists(atPath: candidate) { return candidate }
    }
    return base + "-\(UUID().uuidString.prefix(8))"
}

func requireRoot() throws {
    guard geteuid() == 0 else { throw fail("this command must run as root (use sudo)") }
}

func selectDisk(_ argument: String?, from disks: [PhysicalDisk]) throws -> PhysicalDisk {
    if let argument {
        let normalized = argument.replacingOccurrences(of: "/dev/r", with: "")
            .replacingOccurrences(of: "/dev/", with: "")
        guard let disk = disks.first(where: { $0.bsdName == normalized }) else {
            throw fail("EDP disk not found: \(argument)")
        }
        return disk
    }
    guard disks.count == 1, let disk = disks.first else {
        throw fail(disks.isEmpty ? "no EDP disk found" : "multiple EDP disks found; specify diskN")
    }
    return disk
}

func verifiedPartitionTypes(
    disk: PhysicalDisk,
    password: [UInt8],
    rawFD: Int32? = nil
) throws -> [UInt32] {
    let metadata: EDPRawMetadataSnapshot
    if let rawFD {
        metadata = try rawMetadataSnapshot(fd: rawFD)
    } else {
        metadata = try rawMetadataSnapshot(for: disk.rawPath)
    }
    guard let metadataDeviceID = EDPVolumeMetadata.deviceIDFromLBA11(
        [UInt8](metadata.lba11),
        vidHex: disk.vidHex,
        pidHex: disk.pidHex,
        sizeBytes: disk.sizeBytes
    ), metadataDeviceID == disk.metadataDeviceID else {
        throw fail("EDP device identity changed during authorization")
    }
    let plain = try EDPVolumeMetadata.decodeLBA12(
        [UInt8](metadata.lba12),
        deviceID: metadataDeviceID
    )
    let volumes = try EDPVolumeMetadata.parseLBA12Entries(plain, password: password)
    let verified = volumes.map(\.partitionType).filter { $0 == 2 || $0 == 4 }
    guard !verified.isEmpty else { throw fail("password did not unlock EDP partition 2 or 4") }
    return Array(Set(verified)).sorted()
}

func verifyPartitionType(
    disk: PhysicalDisk,
    partitionType: UInt32,
    password: [UInt8],
    rawFD: Int32? = nil
) throws {
    guard [UInt32(2), 4].contains(partitionType) else {
        throw fail("password validation is only valid for partition 2 or 4")
    }
    guard try verifiedPartitionTypes(
        disk: disk,
        password: password,
        rawFD: rawFD
    ).contains(partitionType) else {
        throw fail("password did not unlock partition \(partitionType)")
    }
}

func authorize(_ diskArgument: String?) throws {
    try requireRoot()
    let disk = try selectDisk(diskArgument, from: discoverEDPDisks())
    var password = try readPassword(prompt: "EDP password for \(disk.mediaName): ")
    defer { secureZero(&password) }
    let verified = try verifiedPartitionTypes(disk: disk, password: password)
    try makeCredentialStore().put(
        deviceID: disk.deviceID,
        password: password,
        partitionTypes: verified
    )
    print("AUTHORIZED_DEVICE=\(disk.deviceID)")
    print("AUTHORIZED_PARTITIONS=\(verified.map(String.init).joined(separator: ","))")
}
