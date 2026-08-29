import Foundation

enum EDPNTFSWriteSafety {
    static func refusalReason(for status: Int32) -> String? {
        switch status {
        case 0:
            return nil
        case 12:
            return "not a valid NTFS volume"
        case 13:
            return "inconsistent NTFS volume"
        case 14:
            return "Windows hibernation/fast startup is active"
        case 15:
            return "NTFS was not cleanly unmounted"
        case 16:
            return "volume is already in use"
        case 19:
            return "insufficient privilege"
        default:
            return "exit \(status)"
        }
    }

    static func refusalMessage(for status: Int32) -> String? {
        guard let reason = refusalReason(for: status) else { return nil }
        return "NTFS write probe refused the volume: \(reason)"
    }
}
