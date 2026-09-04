import Darwin
import Foundation
import IOKit

private struct InstallerUSBMedia {
    let bsdName: String
    let sizeBytes: UInt64
    let vidHex: String
    let pidHex: String

    var rawPath: String { "/dev/r\(bsdName)" }
}

private struct InstallerMetadataSnapshot {
    let lba0: [UInt8]
    let lba4: [UInt8]
    let lba7: [UInt8]
    let lba11: [UInt8]
    let lba12: [UInt8]
}

private struct InstallerProbeError: Error, CustomStringConvertible {
    let description: String
}

private func registryProperty(_ entry: io_registry_entry_t, _ key: String) -> CFTypeRef? {
    IORegistryEntryCreateCFProperty(
        entry,
        key as CFString,
        kCFAllocatorDefault,
        0
    )?.takeRetainedValue()
}

private func uint64Property(_ value: CFTypeRef?) -> UInt64? {
    if let number = value as? NSNumber { return number.uint64Value }
    if let data = value as? Data {
        var result: UInt64 = 0
        for (index, byte) in data.prefix(8).enumerated() {
            result |= UInt64(byte) << UInt64(index * 8)
        }
        return result
    }
    if let string = value as? String {
        let lower = string.lowercased()
        if lower.hasPrefix("0x") { return UInt64(lower.dropFirst(2), radix: 16) }
        return UInt64(lower)
    }
    return nil
}

private func boolProperty(_ value: CFTypeRef?) -> Bool? {
    (value as? NSNumber)?.boolValue
}

private func usbVIDPID(of service: io_registry_entry_t) -> (UInt64, UInt64)? {
    var current = service
    var currentMustRelease = false
    defer {
        if currentMustRelease { IOObjectRelease(current) }
    }

    for _ in 0..<32 {
        if let vid = uint64Property(registryProperty(current, "idVendor")),
           let pid = uint64Property(registryProperty(current, "idProduct")) {
            return (vid, pid)
        }
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
            return nil
        }
        if currentMustRelease { IOObjectRelease(current) }
        current = parent
        currentMustRelease = true
    }
    return nil
}

private func wholeUSBMedia() throws -> [InstallerUSBMedia] {
    guard let matching = IOServiceMatching("IOMedia") else {
        throw InstallerProbeError(description: "IOServiceMatching(IOMedia) failed")
    }
    var iterator: io_iterator_t = 0
    let status = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
    guard status == KERN_SUCCESS else {
        throw InstallerProbeError(description: "IOServiceGetMatchingServices failed: \(status)")
    }
    defer { IOObjectRelease(iterator) }

    var answer = [InstallerUSBMedia]()
    while case let service = IOIteratorNext(iterator), service != 0 {
        defer { IOObjectRelease(service) }
        guard boolProperty(registryProperty(service, "Whole")) == true,
              let bsdName = registryProperty(service, "BSD Name") as? String,
              bsdName.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil,
              let sizeBytes = uint64Property(registryProperty(service, "Size")),
              sizeBytes > 0,
              let (vid, pid) = usbVIDPID(of: service) else {
            continue
        }
        answer.append(InstallerUSBMedia(
            bsdName: bsdName,
            sizeBytes: sizeBytes,
            vidHex: String(format: "%04x", vid),
            pidHex: String(format: "%04x", pid)
        ))
    }
    return answer.sorted { $0.bsdName < $1.bsdName }
}

private func preadExact(fd: Int32, offset: UInt64, length: Int) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: length)
    try bytes.withUnsafeMutableBytes { buffer in
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
                throw InstallerProbeError(description: "pread failed: errno=\(errno)")
            }
            guard result > 0 else {
                throw InstallerProbeError(description: "pread reached EOF")
            }
            completed += result
        }
    }
    return bytes
}

private func metadataSnapshot(for media: InstallerUSBMedia) throws -> InstallerMetadataSnapshot {
    let fd = Darwin.open(media.rawPath, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else {
        throw InstallerProbeError(
            description: "open \(media.rawPath) failed: errno=\(errno)"
        )
    }
    defer { Darwin.close(fd) }
    let sector = Int(EDPMetadataProbe.legacySectorByteLength)
    return InstallerMetadataSnapshot(
        lba0: try preadExact(fd: fd, offset: 0, length: sector),
        lba4: try preadExact(fd: fd, offset: EDPMetadataProbe.lba4ByteOffset, length: sector),
        lba7: try preadExact(fd: fd, offset: EDPMetadataProbe.lba7ByteOffset, length: sector),
        lba11: try preadExact(fd: fd, offset: EDPVolumeMetadata.lba11ByteOffset, length: sector),
        lba12: try preadExact(fd: fd, offset: EDPVolumeMetadata.lba12ByteOffset, length: sector)
    )
}

private func classify(
    snapshot: InstallerMetadataSnapshot,
    vidHex: String,
    pidHex: String,
    sizeBytes: UInt64
) -> EDPMetadataProbe.MediaKind {
    let metadataDeviceID = EDPVolumeMetadata.deviceIDFromLBA11(
        snapshot.lba11,
        vidHex: vidHex,
        pidHex: pidHex,
        sizeBytes: sizeBytes
    )
    let lba12Plain = metadataDeviceID.flatMap { deviceID in
        try? EDPVolumeMetadata.decodeLBA12(snapshot.lba12, deviceID: deviceID)
    }
    return EDPMetadataProbe.classifyMedia(
        lba0: snapshot.lba0,
        lba4: snapshot.lba4,
        lba7: snapshot.lba7,
        lba12Plain: lba12Plain,
        hasLBA11Identity: metadataDeviceID != nil
    )
}

private func readFixtureSector(_ path: String) throws -> [UInt8] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let sector = Int(EDPMetadataProbe.legacySectorByteLength)
    guard data.count >= sector else {
        throw InstallerProbeError(description: "fixture sector too short: \(path)")
    }
    return Array(data.prefix(sector))
}

private func runFixture(arguments: [String]) throws {
    guard arguments.count == 6, let sizeBytes = UInt64(arguments[5]) else {
        throw InstallerProbeError(
            description: "usage: --fixture <dir> <vid> <pid> <sizeBytes>"
        )
    }
    let root = arguments[2]
    let snapshot = InstallerMetadataSnapshot(
        lba0: try readFixtureSector(root + "/lba0_16.bin"),
        lba4: try readFixtureSector(root + "/LBA4.bin"),
        lba7: try readFixtureSector(root + "/LBA7.bin"),
        lba11: try readFixtureSector(root + "/LBA11.bin"),
        lba12: try readFixtureSector(root + "/LBA12.bin")
    )
    let kind = classify(
        snapshot: snapshot,
        vidHex: arguments[3],
        pidHex: arguments[4],
        sizeBytes: sizeBytes
    )
    print("EDP_INSTALLER_FIXTURE_KIND=\(kind.rawValue)")
}

@main
private struct EDPInstallerMediaProbeMain {
    static func main() {
        do {
            let arguments = CommandLine.arguments
            if arguments.count > 1, arguments[1] == "--fixture" {
                try runFixture(arguments: arguments)
                exit(0)
            }

            var standardMedia = [String]()
            for media in try wholeUSBMedia() {
                let kind = classify(
                    snapshot: try metadataSnapshot(for: media),
                    vidHex: media.vidHex,
                    pidHex: media.pidHex,
                    sizeBytes: media.sizeBytes
                )
                print("EDP_INSTALLER_MEDIA=\(media.bsdName):\(kind.rawValue)")
                if kind == .standardEncrypted { standardMedia.append(media.bsdName) }
            }
            if !standardMedia.isEmpty {
                print("EDP_INSTALLER_STANDARD_MEDIA=\(standardMedia.joined(separator: ","))")
                exit(42)
            }
            print("RESULT=EDP_INSTALLER_NO_STANDARD_MEDIA")
            exit(0)
        } catch {
            FileHandle.standardError.write(
                Data("EDP_INSTALLER_MEDIA_PROBE_ERROR=\(error)\n".utf8)
            )
            exit(43)
        }
    }
}
