import CoreFoundation
import Darwin
import DiskArbitration
import Dispatch
import Foundation
import IOKit

struct EDPWholeUSBMedia: Hashable, Sendable {
    let bsdName: String
    let sizeBytes: UInt64
    let mediaName: String
    let vidHex: String
    let pidHex: String
    let registryEntryID: UInt64
    let usbRegistryEntryID: UInt64

    var rawPath: String { "/dev/r\(bsdName)" }
}

struct EDPRawMetadataSnapshot: Sendable {
    let lba0: Data
    let lba4: Data
    let lba7: Data
    let lba11: Data
    let lba12: Data
}

struct EDPPhysicalIdentity: Hashable, Sendable {
    let vidHex: String
    let pidHex: String
    let labelOnlyID: UInt64
    let sizeBytes: UInt64
    let metadataDeviceID: String

    init(
        vidHex: String,
        pidHex: String,
        labelOnlyID: UInt64,
        sizeBytes: UInt64,
        metadataDeviceID: String
    ) {
        self.vidHex = vidHex.lowercased()
        self.pidHex = pidHex.lowercased()
        self.labelOnlyID = labelOnlyID
        self.sizeBytes = sizeBytes
        self.metadataDeviceID = metadataDeviceID
    }

    var stableDeviceID: String {
        EDPVolumeMetadata.stablePhysicalDeviceID(
            metadataDeviceID: metadataDeviceID,
            labelOnlyID: labelOnlyID,
            vidHex: vidHex,
            pidHex: pidHex,
            sizeBytes: sizeBytes
        )
    }
}

struct EDPResolvedPhysicalMetadata: Sendable {
    let mediaKind: EDPMetadataProbe.MediaKind
    let labelOnlyID: UInt64?
    let metadataDeviceID: String?
    let identity: EDPPhysicalIdentity?
}

struct EDPPhysicalIdentityResolver {
    static func resolve(
        media: EDPWholeUSBMedia,
        metadata: EDPRawMetadataSnapshot
    ) -> EDPResolvedPhysicalMetadata {
        let labelOnlyID = EDPMetadataProbe.lba4OnlyID([UInt8](metadata.lba4))
        let metadataDeviceID = EDPVolumeMetadata.deviceIDFromLBA11(
            [UInt8](metadata.lba11),
            vidHex: media.vidHex,
            pidHex: media.pidHex,
            sizeBytes: media.sizeBytes
        )
        let lba12Plain = metadataDeviceID.flatMap { deviceID in
            try? EDPVolumeMetadata.decodeLBA12([UInt8](metadata.lba12), deviceID: deviceID)
        }
        let mediaKind = EDPMetadataProbe.classifyMedia(
            lba0: [UInt8](metadata.lba0),
            lba4: [UInt8](metadata.lba4),
            lba7: [UInt8](metadata.lba7),
            lba12Plain: lba12Plain,
            hasLBA11Identity: metadataDeviceID != nil
        )
        let identity: EDPPhysicalIdentity?
        if mediaKind == .standardEncrypted,
           let labelOnlyID,
           let metadataDeviceID {
            identity = EDPPhysicalIdentity(
                vidHex: media.vidHex,
                pidHex: media.pidHex,
                labelOnlyID: labelOnlyID,
                sizeBytes: media.sizeBytes,
                metadataDeviceID: metadataDeviceID
            )
        } else {
            identity = nil
        }
        return EDPResolvedPhysicalMetadata(
            mediaKind: mediaKind,
            labelOnlyID: labelOnlyID,
            metadataDeviceID: metadataDeviceID,
            identity: identity
        )
    }
}

struct EDPPhysicalDeviceRevalidation {
    static func mediaStillMatches(_ media: EDPWholeUSBMedia, disk: PhysicalDisk) -> Bool {
        media.bsdName == disk.bsdName
            && media.sizeBytes == disk.sizeBytes
            && media.vidHex.lowercased() == disk.vidHex
            && media.pidHex.lowercased() == disk.pidHex
            && media.registryEntryID == disk.registryEntryID
            && media.usbRegistryEntryID == disk.usbRegistryEntryID
    }

    static func metadataStillMatches(_ metadata: EDPRawMetadataSnapshot, disk: PhysicalDisk) -> Bool {
        let media = EDPWholeUSBMedia(
            bsdName: disk.bsdName,
            sizeBytes: disk.sizeBytes,
            mediaName: disk.mediaName,
            vidHex: disk.vidHex,
            pidHex: disk.pidHex,
            registryEntryID: disk.registryEntryID,
            usbRegistryEntryID: disk.usbRegistryEntryID
        )
        return EDPPhysicalIdentityResolver.resolve(media: media, metadata: metadata).identity == disk.identity
    }
}

protocol EDPWholeUSBMediaProviding: Sendable {
    func allWholeUSBMedia() throws -> [EDPWholeUSBMedia]
    func registryEntryExists(_ registryEntryID: UInt64) -> Bool
}

protocol EDPRawMetadataReading: Sendable {
    func snapshot(for media: EDPWholeUSBMedia) throws -> EDPRawMetadataSnapshot
}

struct PhysicalDisk: Hashable, Sendable {
    let bsdName: String
    let rawPath: String
    let mediaName: String
    let registryEntryID: UInt64
    let usbRegistryEntryID: UInt64
    let identity: EDPPhysicalIdentity

    var sizeBytes: UInt64 { identity.sizeBytes }
    var vidHex: String { identity.vidHex }
    var pidHex: String { identity.pidHex }
    var labelOnlyID: UInt64 { identity.labelOnlyID }
    var metadataDeviceID: String { identity.metadataDeviceID }
    var deviceID: String { identity.stableDeviceID }
}

private func ioRegistryProperty(_ entry: io_registry_entry_t, _ key: String) -> CFTypeRef? {
    IORegistryEntryCreateCFProperty(
        entry,
        key as CFString,
        kCFAllocatorDefault,
        0
    )?.takeRetainedValue()
}

private func ioUInt64(_ value: CFTypeRef?) -> UInt64? {
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

private func ioBool(_ value: CFTypeRef?) -> Bool? {
    if let number = value as? NSNumber { return number.boolValue }
    return nil
}

private struct USBAncestorIdentity {
    let vid: UInt64
    let pid: UInt64
    let productName: String?
    let registryEntryID: UInt64
}

private func usbAncestorIdentity(of service: io_registry_entry_t) -> USBAncestorIdentity? {
    var current = service
    var currentMustRelease = false
    defer {
        if currentMustRelease { IOObjectRelease(current) }
    }

    for _ in 0..<32 {
        if let vid = ioUInt64(ioRegistryProperty(current, "idVendor")),
           let pid = ioUInt64(ioRegistryProperty(current, "idProduct")) {
            let name = (ioRegistryProperty(current, "USB Product Name") as? String)
                ?? (ioRegistryProperty(current, "Product Name") as? String)
            var registryEntryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(current, &registryEntryID) == KERN_SUCCESS else {
                return nil
            }
            return USBAncestorIdentity(
                vid: vid,
                pid: pid,
                productName: name,
                registryEntryID: registryEntryID
            )
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

private func hasAncestorBSDName(_ service: io_registry_entry_t, _ target: String) -> Bool {
    var current = service
    var currentMustRelease = false
    defer {
        if currentMustRelease { IOObjectRelease(current) }
    }

    for _ in 0..<32 {
        if (ioRegistryProperty(current, "BSD Name") as? String) == target { return true }
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
            return false
        }
        if currentMustRelease { IOObjectRelease(current) }
        current = parent
        currentMustRelease = true
    }
    return false
}

struct EDPIOKitWholeUSBMediaProvider: EDPWholeUSBMediaProviding {
    func allWholeUSBMedia() throws -> [EDPWholeUSBMedia] {
        guard let matching = IOServiceMatching("IOMedia") else {
            throw RuntimeNativeError("IOServiceMatching(IOMedia) failed")
        }
        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard status == KERN_SUCCESS else {
            throw RuntimeNativeError("IOServiceGetMatchingServices failed: \(status)")
        }
        defer { IOObjectRelease(iterator) }

        var answer = [EDPWholeUSBMedia]()
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard ioBool(ioRegistryProperty(service, "Whole")) == true,
                  let bsd = ioRegistryProperty(service, "BSD Name") as? String,
                  bsd.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil,
                  let size = ioUInt64(ioRegistryProperty(service, "Size")),
                  size > 0,
                  let usb = usbAncestorIdentity(of: service) else {
                continue
            }
            var registryEntryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &registryEntryID) == KERN_SUCCESS else {
                continue
            }
            let mediaName = usb.productName
                ?? (ioRegistryProperty(service, "Media Name") as? String)
                ?? "EDP USB"
            answer.append(EDPWholeUSBMedia(
                bsdName: bsd,
                sizeBytes: size,
                mediaName: mediaName,
                vidHex: String(format: "%04x", usb.vid),
                pidHex: String(format: "%04x", usb.pid),
                registryEntryID: registryEntryID,
                usbRegistryEntryID: usb.registryEntryID
            ))
        }
        return answer
    }

    func registryEntryExists(_ registryEntryID: UInt64) -> Bool {
        guard let matching = IORegistryEntryIDMatching(registryEntryID) else { return false }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }
}

struct EDPFileRawMetadataReader: EDPRawMetadataReading {
    func snapshot(for media: EDPWholeUSBMedia) throws -> EDPRawMetadataSnapshot {
        guard FileManager.default.fileExists(atPath: media.rawPath) else {
            throw RuntimeNativeError("raw device missing: \(media.rawPath)")
        }
        let raw = try EDPFileRawDevice(path: media.rawPath, declaredSizeBytes: media.sizeBytes)
        let sector = Int(EDPMetadataProbe.legacySectorByteLength)
        return EDPRawMetadataSnapshot(
            lba0: try raw.readExact(at: 0, length: sector),
            lba4: try raw.readExact(at: EDPMetadataProbe.lba4ByteOffset, length: sector),
            lba7: try raw.readExact(at: EDPMetadataProbe.lba7ByteOffset, length: sector),
            lba11: try raw.readExact(at: EDPVolumeMetadata.lba11ByteOffset, length: sector),
            lba12: try raw.readExact(at: EDPVolumeMetadata.lba12ByteOffset, length: sector)
        )
    }
}

struct EDPPhysicalDiskDiscovery: Sendable {
    let mediaProvider: any EDPWholeUSBMediaProviding
    let metadataReader: any EDPRawMetadataReading

    func discover(diagnostic: ((String) -> Void)? = nil) throws -> [PhysicalDisk] {
        var answer = [PhysicalDisk]()
        for media in try mediaProvider.allWholeUSBMedia() {
            let metadata: EDPRawMetadataSnapshot
            do {
                metadata = try metadataReader.snapshot(for: media)
            } catch {
                let detail = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
                diagnostic?("bsd=\(media.bsdName);result=raw_metadata_failed;error=\(detail)")
                continue
            }

            let resolved = EDPPhysicalIdentityResolver.resolve(media: media, metadata: metadata)
            diagnostic?("bsd=\(media.bsdName);classification=\(resolved.mediaKind.rawValue)")
            guard resolved.mediaKind == .standardEncrypted else { continue }
            guard let labelOnlyID = resolved.labelOnlyID else {
                diagnostic?("bsd=\(media.bsdName);result=lba4_only_id_invalid")
                continue
            }
            guard resolved.metadataDeviceID != nil else {
                diagnostic?("bsd=\(media.bsdName);result=device_id_invalid")
                continue
            }
            guard let identity = resolved.identity else { continue }
            diagnostic?(
                "bsd=\(media.bsdName);result=recognized;onlyID=\(labelOnlyID);deviceID=\(identity.stableDeviceID)"
            )
            answer.append(PhysicalDisk(
                bsdName: media.bsdName,
                rawPath: media.rawPath,
                mediaName: media.mediaName,
                registryEntryID: media.registryEntryID,
                usbRegistryEntryID: media.usbRegistryEntryID,
                identity: identity
            ))
        }
        return answer.sorted { $0.bsdName < $1.bsdName }
    }
}

enum EDPNativeDeviceDiscovery {
    static func allWholeUSBMedia() throws -> [EDPWholeUSBMedia] {
        try EDPIOKitWholeUSBMediaProvider().allWholeUSBMedia()
    }

    static func registryEntryExists(_ registryEntryID: UInt64) -> Bool {
        EDPIOKitWholeUSBMediaProvider().registryEntryExists(registryEntryID)
    }

    static func diagnosticReport() -> [String] {
        do {
            let media = try allWholeUSBMedia()
            if media.isEmpty { return ["no whole USB media"] }
            return media.map { item in
                [
                    "bsd=\(item.bsdName)",
                    "usb=\(item.vidHex):\(item.pidHex)",
                    "size=\(item.sizeBytes)",
                    "name=\(item.mediaName)",
                    "rawAccess=fda-broker",
                ].joined(separator: ";")
            }
        } catch {
            return ["discovery_error:\(error)"]
        }
    }

    static func discoverEDPDisks() throws -> [PhysicalDisk] {
        try EDPPhysicalDiskDiscovery(
            mediaProvider: EDPIOKitWholeUSBMediaProvider(),
            metadataReader: EDPFileRawMetadataReader()
        ).discover()
    }

    static func usbRegistryEntryID(forBSDName bsdName: String) -> UInt64? {
        guard let matching = IOServiceMatching("IOMedia") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard (ioRegistryProperty(service, "BSD Name") as? String) == bsdName,
                  let usb = usbAncestorIdentity(of: service) else { continue }
            return usb.registryEntryID
        }
        return nil
    }

    static func descendantBSDNames(of rootBSD: String) throws -> [String] {
        guard let matching = IOServiceMatching("IOMedia") else {
            throw RuntimeNativeError("IOServiceMatching(IOMedia) failed")
        }
        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard status == KERN_SUCCESS else {
            throw RuntimeNativeError("IOServiceGetMatchingServices failed: \(status)")
        }
        defer { IOObjectRelease(iterator) }

        var answer: [String] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let bsd = ioRegistryProperty(service, "BSD Name") as? String,
                  bsd != rootBSD,
                  hasAncestorBSDName(service, rootBSD) else {
                continue
            }
            answer.append(bsd)
        }
        return answer.sorted()
    }
}

struct RuntimeNativeError: Error, CustomStringConvertible, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

enum EDPNativeBoundedProcess {
    static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        label: String,
        terminateGrace: TimeInterval = 0.75,
        killGrace: TimeInterval = 0.75
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let pid = process.processIdentifier

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if !process.isRunning {
            return process.terminationStatus
        }

        process.terminate()
        let terminateDeadline = Date().addingTimeInterval(terminateGrace)
        while process.isRunning && Date() < terminateDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            _ = Darwin.kill(pid, SIGKILL)
            let killDeadline = Date().addingTimeInterval(killGrace)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        if process.isRunning {
            throw RuntimeNativeError(
                "\(label) timed out after \(Int(timeout)) seconds and helper remained alive after SIGKILL"
            )
        }
        throw RuntimeNativeError("\(label) timed out after \(Int(timeout)) seconds")
    }
}

private final class DAOperationBox: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    var status: DAReturn = DAReturn(kDAReturnSuccess)
    var statusDescription: String?
}

private func daMountApprovalCallback(
    _ disk: DADisk,
    _ context: UnsafeMutableRawPointer?
) -> Unmanaged<DADissenter>? {
    guard let context else { return nil }
    let controller = Unmanaged<EDPDiskArbitrationController>.fromOpaque(context).takeUnretainedValue()
    guard controller.shouldDenyMount(disk) else { return nil }
    let dissenter = DADissenterCreate(
        kCFAllocatorDefault,
        DAReturn(kDAReturnNotPermitted),
        "EDP Drive safely ejected this device" as CFString
    )
    return Unmanaged.passRetained(dissenter)
}

private func daOperationCallback(
    _ disk: DADisk,
    _ dissenter: DADissenter?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let box = Unmanaged<DAOperationBox>.fromOpaque(context).takeUnretainedValue()
    if let dissenter {
        box.status = DADissenterGetStatus(dissenter)
        if let description = DADissenterGetStatusString(dissenter) {
            box.statusDescription = description as String
        }
    }
    box.semaphore.signal()
}

protocol EDPDaemonDiskArbitrating: AnyObject, Sendable {
    func suppressAutomount(usbRegistryEntryID: UInt64)
    func allowAutomount(usbRegistryEntryID: UInt64)
    func unmountWhole(_ bsdName: String) throws
    func eject(_ bsdName: String) throws
}

final class EDPDiskArbitrationController: EDPDaemonDiskArbitrating, @unchecked Sendable {
    private let session: DASession
    private let queue = DispatchQueue(label: "com.edp.drive.disk-arbitration")
    private let stateLock = NSLock()
    private var suppressedUSBRegistryEntryIDs = Set<UInt64>()

    init() throws {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            throw RuntimeNativeError("DASessionCreate failed")
        }
        self.session = session
        DARegisterDiskMountApprovalCallback(
            session,
            nil,
            daMountApprovalCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        DASessionSetDispatchQueue(session, queue)
    }

    deinit {
        DASessionSetDispatchQueue(session, nil)
    }

    fileprivate func shouldDenyMount(_ disk: DADisk) -> Bool {
        guard let name = DADiskGetBSDName(disk),
              let usbRegistryEntryID = EDPNativeDeviceDiscovery.usbRegistryEntryID(
                  forBSDName: String(cString: name)
              ) else { return false }
        stateLock.lock()
        defer { stateLock.unlock() }
        return suppressedUSBRegistryEntryIDs.contains(usbRegistryEntryID)
    }

    func suppressAutomount(usbRegistryEntryID: UInt64) {
        stateLock.lock()
        suppressedUSBRegistryEntryIDs.insert(usbRegistryEntryID)
        stateLock.unlock()
    }

    func allowAutomount(usbRegistryEntryID: UInt64) {
        stateLock.lock()
        suppressedUSBRegistryEntryIDs.remove(usbRegistryEntryID)
        stateLock.unlock()
    }

    private func disk(_ bsdName: String) throws -> DADisk {
        let path = "/dev/\(bsdName)"
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, path) else {
            throw RuntimeNativeError("DADiskCreateFromBSDName failed for \(path)")
        }
        return disk
    }

    private func perform(
        timeout: TimeInterval = 20,
        _ body: (DADisk, UnsafeMutableRawPointer) -> Void,
        bsdName: String
    ) throws {
        let target = try disk(bsdName)
        let box = DAOperationBox()
        let context = Unmanaged.passUnretained(box).toOpaque()
        body(target, context)
        guard box.semaphore.wait(timeout: .now() + timeout) == .success else {
            throw RuntimeNativeError("Disk Arbitration operation timed out for \(bsdName)")
        }
        guard box.status == kDAReturnSuccess else {
            let detail = box.statusDescription.map { " (\($0))" } ?? ""
            throw RuntimeNativeError(
                "Disk Arbitration refused \(bsdName): status=\(box.status)\(detail)"
            )
        }
    }

    func unmountWhole(_ bsdName: String) throws {
        try perform({ disk, context in
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionWhole), daOperationCallback, context)
        }, bsdName: bsdName)
    }

    func unmount(_ bsdName: String) throws {
        try perform({ disk, context in
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), daOperationCallback, context)
        }, bsdName: bsdName)
    }

    func mount(_ bsdName: String) throws -> String {
        try perform({ disk, context in
            DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), daOperationCallback, context)
        }, bsdName: bsdName)
        if let mountpoint = EDPNativeMountTable.mountPoint(forBSD: bsdName) { return mountpoint }
        throw RuntimeNativeError("Disk Arbitration mounted \(bsdName) but no mount point appeared")
    }

    func mountNobrowse(_ bsdName: String, at mountPoint: String) throws -> String {
        let mountURL = URL(fileURLWithPath: mountPoint, isDirectory: true) as CFURL
        let nobrowse = "nobrowse" as CFString
        var arguments: [Unmanaged<CFString>?] = [Unmanaged.passUnretained(nobrowse), nil]
        try arguments.withUnsafeMutableBufferPointer { buffer in
            try perform({ disk, context in
                DADiskMountWithArguments(
                    disk,
                    mountURL,
                    DADiskMountOptions(kDADiskMountOptionDefault),
                    daOperationCallback,
                    context,
                    buffer.baseAddress
                )
            }, bsdName: bsdName)
        }
        guard let actual = EDPNativeMountTable.mountPoint(forBSD: bsdName) else {
            throw RuntimeNativeError("Disk Arbitration mounted \(bsdName) but no mount point appeared")
        }
        guard actual == mountPoint else {
            throw RuntimeNativeError(
                "Disk Arbitration mounted \(bsdName) at unexpected path \(actual), expected \(mountPoint)"
            )
        }
        return actual
    }

    func eject(_ bsdName: String) throws {
        try perform({ disk, context in
            DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), daOperationCallback, context)
        }, bsdName: bsdName)
    }
}

private func statfsString<T>(_ field: inout T) -> String {
    withUnsafePointer(to: &field) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
            String(cString: $0)
        }
    }
}

enum EDPNativeMountTable {
    static func entries() -> [(source: String, mountpoint: String, filesystem: String, flags: UInt32)] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        let capacity = Int(count)
        let buffer = UnsafeMutablePointer<statfs>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let bytes = Int32(capacity * MemoryLayout<statfs>.size)
        let actual = getfsstat(buffer, bytes, MNT_NOWAIT)
        guard actual > 0 else { return [] }
        return (0..<Int(actual)).map { index in
            var mutable = buffer[index]
            return (
                statfsString(&mutable.f_mntfromname),
                statfsString(&mutable.f_mntonname),
                statfsString(&mutable.f_fstypename),
                mutable.f_flags
            )
        }
    }

    static func isMountpoint(_ path: String) -> Bool {
        entries().contains { $0.mountpoint == path }
    }

    static func mountPoint(forBSD bsdName: String) -> String? {
        let source = "/dev/\(bsdName)"
        return entries().first { $0.source == source }?.mountpoint
    }

    static func filesystem(forBSD bsdName: String) -> String? {
        let source = "/dev/\(bsdName)"
        return entries().first { $0.source == source }?.filesystem
    }

    static func hasMountedBSDPrefix(_ bsdName: String) -> Bool {
        let prefix = "/dev/\(bsdName)"
        return entries().contains { $0.source.hasPrefix(prefix) }
    }

    static func isReadOnly(_ path: String) -> Bool? {
        guard let entry = entries().first(where: { $0.mountpoint == path }) else { return nil }
        return (entry.flags & UInt32(MNT_RDONLY)) != 0
    }

    static func unmountPath(_ path: String, force: Bool = false) throws {
        guard isMountpoint(path) else { return }
        let arguments = force ? ["-f", path] : [path]
        do {
            let status = try EDPNativeBoundedProcess.run(
                executable: "/sbin/umount",
                arguments: arguments,
                timeout: force ? 8 : 15,
                label: force ? "forced VFS unmount \(path)" : "VFS unmount \(path)"
            )
            if status != 0 && isMountpoint(path) {
                throw RuntimeNativeError(
                    "umount helper failed for \(path): status=\(status)"
                )
            }
        } catch {
            if !isMountpoint(path) { return }
            throw error
        }
        guard !isMountpoint(path) else {
            throw RuntimeNativeError("mount remained active after unmount helper: \(path)")
        }
    }
}

private func diskEventCallback(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    guard let properties = DADiskCopyDescription(disk) as? [String: Any],
          (properties[kDADiskDescriptionMediaWholeKey as String] as? Bool) == true,
          let deviceProtocol = properties[kDADiskDescriptionDeviceProtocolKey as String] as? String,
          deviceProtocol.caseInsensitiveCompare("USB") == .orderedSame else {
        return
    }
    let monitor = Unmanaged<EDPDiskEventMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.handleDiskEvent()
}

final class EDPDiskEventMonitor: @unchecked Sendable {
    private let session: DASession
    private let queue = DispatchQueue(label: "com.edp.drive.disk-events")
    private var reconciliationTimer: DispatchSourceTimer?
    private var eventGeneration: UInt64 = 0
    private var onChange: (@Sendable () -> Void)?

    init() throws {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            throw RuntimeNativeError("DASessionCreate failed")
        }
        self.session = session
    }

    func start(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, diskEventCallback, context)
        DARegisterDiskDisappearedCallback(session, nil, diskEventCallback, context)
        DASessionSetDispatchQueue(session, queue)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in self?.onChange?() }
        timer.resume()
        reconciliationTimer = timer
        queue.async { [weak self] in self?.onChange?() }
    }

    func stop() {
        queue.sync {
            reconciliationTimer?.cancel()
            reconciliationTimer = nil
            onChange = nil
            eventGeneration &+= 1
            DASessionSetDispatchQueue(session, nil)
        }
    }

    fileprivate func handleDiskEvent() {
        // Only whole USB media reaches this point. Coalesce the remaining
        // attach/disappear burst so raw metadata discovery runs once after the
        // device graph settles.
        eventGeneration &+= 1
        let generation = eventGeneration
        queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
            guard let self, self.eventGeneration == generation else { return }
            self.onChange?()
        }
    }

    deinit {
        stop()
    }
}
