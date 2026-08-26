import Darwin
import Foundation

@main
enum RenderNTFSMountPolicy {
    static func main() {
        guard CommandLine.arguments.count == 4,
              let uidValue = UInt32(CommandLine.arguments[1]),
              let gidValue = UInt32(CommandLine.arguments[2]) else {
            FileHandle.standardError.write(Data("usage: render-ntfs-mount-policy <uid> <gid> <volume-name>\n".utf8))
            exit(64)
        }
        let volumeName = CommandLine.arguments[3]
        for value in EDPNTFSMountPolicy.optionValues(
            uid: uid_t(uidValue),
            gid: gid_t(gidValue),
            volumeName: volumeName
        ) {
            print(value)
        }
    }
}
