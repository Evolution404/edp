import Foundation
import Darwin
import DiskArbitration
import IOKit

struct ValidatedRawDisk {
    let diskNumber: UInt32
    let bsdName: String
    let rawPath: String
    let mediaPath: String
    let sizeBytes: UInt64
    let vendor: String
    let model: String
}

enum RawDiskValidationError: LocalizedError {
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .rejected(let message): message
        }
    }
}

enum RawDiskValidator {
    static func enumerateExternalUSBWholeDisks() -> [ValidatedRawDisk] {
        guard let matching = IOServiceMatching("IOMedia") else { return [] }
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var disks: [ValidatedRawDisk] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(service) }

            guard let bsdName = IORegistryEntryCreateCFProperty(
                service,
                "BSD Name" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? String,
            bsdName.hasPrefix("disk"),
            let diskNumber = UInt32(bsdName.dropFirst(4)) else {
                continue
            }

            if let validated = try? validate(diskNumber) {
                disks.append(validated)
            }
        }

        return disks.sorted { $0.diskNumber < $1.diskNumber }
    }

    static func validate(_ diskNumber: UInt32) throws -> ValidatedRawDisk {
        guard diskNumber >= 2 else {
            throw RawDiskValidationError.rejected("disk0/disk1 永久拒绝")
        }

        let bsdName = "disk\(diskNumber)"
        let blockPath = "/dev/\(bsdName)"
        let rawPath = "/dev/r\(bsdName)"

        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            throw RawDiskValidationError.rejected("DASessionCreate 失败")
        }
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, blockPath) else {
            throw RawDiskValidationError.rejected("Disk Arbitration 找不到 \(bsdName)")
        }
        guard let desc = DADiskCopyDescription(disk) as NSDictionary? else {
            throw RawDiskValidationError.rejected("无法获取 \(bsdName) 描述")
        }

        let whole = desc[kDADiskDescriptionMediaWholeKey] as? Bool ?? false
        let internalDisk = desc[kDADiskDescriptionDeviceInternalKey] as? Bool ?? true
        let protocolName = desc[kDADiskDescriptionDeviceProtocolKey] as? String ?? ""
        let mediaPath = desc[kDADiskDescriptionMediaPathKey] as? String ?? ""
        let sizeBytes = (desc[kDADiskDescriptionMediaSizeKey] as? NSNumber)?.uint64Value ?? 0
        let vendor = (desc[kDADiskDescriptionDeviceVendorKey] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (desc[kDADiskDescriptionDeviceModelKey] as? String ?? "USB Disk").trimmingCharacters(in: .whitespacesAndNewlines)

        guard whole else {
            throw RawDiskValidationError.rejected("拒绝非 whole disk: \(bsdName)")
        }
        guard !internalDisk else {
            throw RawDiskValidationError.rejected("拒绝 internal disk: \(bsdName)")
        }
        guard protocolName.caseInsensitiveCompare("USB") == .orderedSame else {
            throw RawDiskValidationError.rejected("拒绝非 USB 设备: protocol=\(protocolName)")
        }
        try validateIOKitUSBWholeDisk(bsdName)

        return ValidatedRawDisk(
            diskNumber: diskNumber,
            bsdName: bsdName,
            rawPath: rawPath,
            mediaPath: mediaPath,
            sizeBytes: sizeBytes,
            vendor: vendor,
            model: model
        )
    }

    private static func validateIOKitUSBWholeDisk(_ bsdName: String) throws {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else {
            throw RawDiskValidationError.rejected("IOBSDNameMatching 失败")
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else {
            throw RawDiskValidationError.rejected("IOKit 找不到 \(bsdName)")
        }
        defer { IOObjectRelease(service) }

        if let whole = IORegistryEntryCreateCFProperty(
            service,
            "Whole" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Bool, !whole {
            throw RawDiskValidationError.rejected("IOKit IOMedia Whole=false")
        }

        var current = service
        var ownsCurrent = false
        defer {
            if ownsCurrent && current != IO_OBJECT_NULL { IOObjectRelease(current) }
        }

        for _ in 0..<24 {
            if IOObjectConformsTo(current, "IOUSBHostDevice") != 0 {
                return
            }
            var parent: io_registry_entry_t = IO_OBJECT_NULL
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            guard kr == KERN_SUCCESS, parent != IO_OBJECT_NULL else { break }
            if ownsCurrent { IOObjectRelease(current) }
            current = parent
            ownsCurrent = true
        }

        throw RawDiskValidationError.rejected("IOKit 未找到 IOUSBHostDevice ancestor")
    }
}
