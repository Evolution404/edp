import Darwin
import Foundation

enum EDPNTFSMountPolicy {
    static let fixedOptions: [String] = [
        "backend=fskit",
        "local",
        "no_detach",
        "norecover",
        "windows_names",
        "streams_interface=openxattr",
        "noatime",
        "big_writes",
        "allow_other",
    ]

    static func optionValues(uid: uid_t, gid: gid_t, volumeName: String) -> [String] {
        fixedOptions + [
            "uid=\(uid)",
            "gid=\(gid)",
            "volname=\(volumeName)",
        ]
    }

    static func commandArguments(uid: uid_t, gid: gid_t, volumeName: String) -> [String] {
        optionValues(uid: uid, gid: gid, volumeName: volumeName).flatMap { ["-o", $0] }
    }

    static func readOnlyCommandArguments(uid: uid_t, gid: gid_t, volumeName: String) -> [String] {
        let options = fixedOptions.filter { $0 != "allow_other" } + [
            "ro",
            "uid=\(uid)",
            "gid=\(gid)",
            "volname=\(volumeName)",
        ]
        return options.flatMap { ["-o", $0] }
    }
}
