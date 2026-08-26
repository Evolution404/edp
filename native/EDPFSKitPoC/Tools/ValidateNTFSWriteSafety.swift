import Foundation

@main
struct ValidateNTFSWriteSafety {
    static func main() {
        precondition(EDPNTFSWriteSafety.refusalMessage(for: 0) == nil)
        precondition(
            EDPNTFSWriteSafety.refusalMessage(for: 14) ==
            "NTFS write probe refused the volume: Windows hibernation/fast startup is active"
        )
        precondition(
            EDPNTFSWriteSafety.refusalMessage(for: 15) ==
            "NTFS write probe refused the volume: NTFS was not cleanly unmounted"
        )
        precondition(
            EDPNTFSWriteSafety.refusalMessage(for: 21) ==
            "NTFS write probe refused the volume: exit 21"
        )
        print("RESULT=NTFS_WRITE_SAFETY_STATUS_MAPPING_OK")
    }
}
