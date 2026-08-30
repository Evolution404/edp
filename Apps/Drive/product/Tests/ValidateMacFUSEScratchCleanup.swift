import Foundation

// The production publisher only needs this dependency for normal Disk
// Arbitration publication. The scratch-cleanup contract test does not perform
// any real mount/eject operation.
final class EDPDiskArbitrationController {
    func eject(_ bsdName: String) throws {
        _ = bsdName
    }
}

private struct ValidationFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw ValidationFailure(description: message) }
}

private func infoPlist(
    imagePath: String = "/var/folders/zz/zyxvpxvq6csfxvn_n0000000000000/T/BEE619C6-A086-43DD-B761-8E9426D565A1.dmg",
    helperPID: Int = 86105,
    ownerUID: Int = 0,
    blockCount: Int = 8,
    blockSize: Int = 512,
    autoDiskMount: Bool = false,
    diskImages2: Bool = false,
    writable: Bool = true,
    removable: Bool = true,
    device: String = "/dev/disk7"
) throws -> Data {
    try PropertyListSerialization.data(
        fromPropertyList: [
            "framework": "683.160.3",
            "images": [[
                "autodiskmount": autoDiskMount,
                "blockcount": blockCount,
                "blocksize": blockSize,
                "diskimages2": diskImages2,
                "hdid-pid": helperPID,
                "image-path": imagePath,
                "owner-uid": ownerUID,
                "removable": removable,
                "system-entities": [["dev-entry": device]],
                "writeable": writable,
            ]],
        ],
        format: .xml,
        options: 0
    )
}

private func candidate(
    imagePath: String = "/var/folders/zz/zyxvpxvq6csfxvn_n0000000000000/T/BEE619C6-A086-43DD-B761-8E9426D565A1.dmg",
    helperPID: Int = 86105,
    ownerUID: Int = 0,
    blockCount: Int = 8,
    blockSize: Int = 512,
    autoDiskMount: Bool = false,
    diskImages2: Bool = false,
    writable: Bool = true,
    removable: Bool = true,
    device: String = "/dev/disk7"
) throws -> EDPMacFUSEScratchImage {
    let parsed = try EDPMacFUSEScratchImageCleanup.parseInfoPlist(infoPlist(
        imagePath: imagePath,
        helperPID: helperPID,
        ownerUID: ownerUID,
        blockCount: blockCount,
        blockSize: blockSize,
        autoDiskMount: autoDiskMount,
        diskImages2: diskImages2,
        writable: writable,
        removable: removable,
        device: device
    ))
    guard let image = parsed.first else {
        throw ValidationFailure(description: "scratch image plist was not parsed")
    }
    return image
}

@main
private enum ValidateMacFUSEScratchCleanup {
    static func main() throws {
        try require(EDPMacFUSEScratchImageCleanup.captureBaseline() != nil,
                    "live hdiutil info plist must be parseable")

        let valid = try candidate()
        try require(valid.isOrphanCleanupCandidate, "known macFUSE scratch signature must match")
        try require(valid.helperPID == 86105, "helper PID changed during plist parsing")
        try require(valid.devices == ["/dev/disk7"], "whole BSD device changed during plist parsing")
        try require(
            EDPMacFUSEScratchImageCleanup.orphanCandidate(
                forSource: "/dev/disk7",
                in: [try candidate(device: "/dev/disk8"), valid]
            ) == valid,
            "exact persisted mount source did not select its matching scratch image"
        )
        try require(
            EDPMacFUSEScratchImageCleanup.orphanCandidate(
                forSource: "/dev/disk8",
                in: [valid]
            ) == nil,
            "orphan recovery selected a different mount source"
        )

        try require(!(try candidate(ownerUID: 501)).isOrphanCleanupCandidate,
                    "non-root disk image must be rejected")
        try require(!(try candidate(blockCount: 16)).isOrphanCleanupCandidate,
                    "non-4KiB disk image must be rejected")
        try require(!(try candidate(diskImages2: true)).isOrphanCleanupCandidate,
                    "product DiskImages2 publication must be rejected")
        try require(!(try candidate(autoDiskMount: true)).isOrphanCleanupCandidate,
                    "auto-mounted disk image must be rejected")
        try require(!(try candidate(writable: false)).isOrphanCleanupCandidate,
                    "read-only disk image must be rejected")
        try require(!(try candidate(removable: false)).isOrphanCleanupCandidate,
                    "non-removable disk image must be rejected")
        try require(!(try candidate(device: "/dev/disk7s1")).isOrphanCleanupCandidate,
                    "partition device must be rejected")
        try require(!(try candidate(imagePath: "/tmp/BEE619C6-A086-43DD-B761-8E9426D565A1.dmg")).isOrphanCleanupCandidate,
                    "non-root-temporary disk image must be rejected")
        try require(!(try candidate(imagePath: "/var/folders/zz/zyx/T/not-a-uuid.dmg")).isOrphanCleanupCandidate,
                    "non-UUID disk image must be rejected")

        let empty = try PropertyListSerialization.data(
            fromPropertyList: ["images": []],
            format: .xml,
            options: 0
        )
        try require(try EDPMacFUSEScratchImageCleanup.parseInfoPlist(empty).isEmpty,
                    "empty hdiutil image list must remain empty")

        print("RESULT=MACFUSE_SCRATCH_CLEANUP_CONTRACT_OK")
    }
}
