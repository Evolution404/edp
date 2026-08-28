import Foundation
import Darwin
import DiskArbitration
import IOKit

private let probeId = "com.evolution404.edpopen.rawbroker.poc"

private func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("ERROR: \(message)\n").utf8))
    exit(code)
}

private func cfBool(_ dict: NSDictionary, _ key: CFString) -> Bool? {
    dict[key] as? Bool
}

private func cfString(_ dict: NSDictionary, _ key: CFString) -> String? {
    dict[key] as? String
}

private func iokitValidateUSBWholeDisk(_ bsdName: String) -> (Bool, String) {
    guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else {
        return (false, "IOBSDNameMatching failed")
    }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != IO_OBJECT_NULL else {
        return (false, "no IOKit service for \(bsdName)")
    }
    defer { IOObjectRelease(service) }

    if let wholeValue = IORegistryEntryCreateCFProperty(
        service,
        "Whole" as CFString,
        kCFAllocatorDefault,
        0
    )?.takeRetainedValue() as? Bool, !wholeValue {
        return (false, "IOMedia is not whole")
    }

    var current = service
    var ownedCurrent = false
    defer {
        if ownedCurrent && current != IO_OBJECT_NULL { IOObjectRelease(current) }
    }

    for _ in 0..<24 {
        if IOObjectConformsTo(current, "IOUSBHostDevice") != 0 {
            return (true, "IOKit ancestor=IOUSBHostDevice")
        }
        var parent: io_registry_entry_t = IO_OBJECT_NULL
        let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
        if kr != KERN_SUCCESS || parent == IO_OBJECT_NULL { break }
        if ownedCurrent { IOObjectRelease(current) }
        current = parent
        ownedCurrent = true
    }
    return (false, "no IOUSBHostDevice ancestor")
}

private func validateDisk(_ diskNumber: UInt32) -> String {
    guard diskNumber >= 2 else { fail("disk0/disk1 are permanently rejected", code: 2) }
    let bsdName = "disk\(diskNumber)"
    let blockPath = "/dev/\(bsdName)"

    guard let session = DASessionCreate(kCFAllocatorDefault) else {
        fail("DASessionCreate failed")
    }
    guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, blockPath) else {
        fail("DADiskCreateFromBSDName failed for \(blockPath)")
    }
    guard let desc = DADiskCopyDescription(disk) as NSDictionary? else {
        fail("DADiskCopyDescription failed")
    }

    let whole = cfBool(desc, kDADiskDescriptionMediaWholeKey) ?? false
    let internalDisk = cfBool(desc, kDADiskDescriptionDeviceInternalKey) ?? true
    let protocolName = cfString(desc, kDADiskDescriptionDeviceProtocolKey) ?? ""
    let mediaPath = cfString(desc, kDADiskDescriptionMediaPathKey) ?? ""

    guard whole else { fail("Disk Arbitration: not a whole disk") }
    guard !internalDisk else { fail("Disk Arbitration: internal disk rejected") }
    guard protocolName.caseInsensitiveCompare("USB") == .orderedSame else {
        fail("Disk Arbitration: protocol is \(protocolName), not USB")
    }

    let (usbOK, iokitReason) = iokitValidateUSBWholeDisk(bsdName)
    guard usbOK else { fail("IOKit validation failed: \(iokitReason)") }

    return "DA whole=true internal=false protocol=\(protocolName) mediaPath=\(mediaPath); \(iokitReason)"
}

private func probe(_ diskNumber: UInt32) {
    let validation = validateDisk(diskNumber)
    let rawPath = "/dev/rdisk\(diskNumber)"

    print("PROBE_ID=\(probeId)")
    print("EUID=\(geteuid())")
    print("PATH=\(rawPath)")
    print("VALIDATION=\(validation)")

    // SECURITY INVARIANT FOR THE FDA PoC:
    // The raw device is opened O_RDWR only to test TCC/FDA authorization.
    // No read(2), write(2), pread(2), pwrite(2), ioctl that mutates media,
    // formatting, partitioning, or filesystem operation is performed.
    let fd = Darwin.open(rawPath, O_RDWR | O_CLOEXEC)
    guard fd >= 0 else {
        let e = errno
        print("DIRECT_RAW_OPEN=FAIL errno=\(e) \(String(cString: strerror(e)))")
        exit(10)
    }
    defer { Darwin.close(fd) }

    var st = stat()
    guard fstat(fd, &st) == 0 else {
        let e = errno
        fail("fstat failed errno=\(e) \(String(cString: strerror(e)))", code: 11)
    }
    guard (st.st_mode & S_IFMT) == S_IFCHR else {
        fail("opened object is not a character device", code: 12)
    }

    print("FSTAT_CHAR_DEVICE=OK rdev=\(st.st_rdev)")
    print("DIRECT_RAW_OPEN=OK")
}

guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "probe" else {
    fail("usage: RawBrokerProbe probe <disk-number>", code: 64)
}
guard let diskNumber = UInt32(CommandLine.arguments[2]) else {
    fail("disk number must be numeric", code: 64)
}
probe(diskNumber)
