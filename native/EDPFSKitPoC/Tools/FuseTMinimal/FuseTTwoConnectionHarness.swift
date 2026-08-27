import Darwin
import Foundation

@main
private enum FuseTTwoConnectionHarness {
    static func main() {
        do {
            guard CommandLine.arguments.count == 4 else {
                fputs("usage: FuseTTwoConnectionHarness <backing> <mountpoint> <volume-name>\n", stderr)
                exit(64)
            }
            dumpFSKitOptionEvidence()

            let backingPath = CommandLine.arguments[1]
            let mountpoint = CommandLine.arguments[2]
            let volumeName = CommandLine.arguments[3]
            let backing = try FixedReadWriteBacking(path: backingPath)
            let fileManager = FileManager.default
            try fileManager.createDirectory(atPath: mountpoint, withIntermediateDirectories: true)

            let socketDirectory = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Group Containers/group.org.fuset.fskit-srv/s", isDirectory: true)
            try fileManager.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
            chmod(socketDirectory.path, 0o700)

            let sessionID = "edp-remount-\(UUID().uuidString.lowercased())"
            let authToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let socketPath = socketDirectory.appendingPathComponent("\(sessionID.prefix(20)).sock").path
            let sessionDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent(sessionID, isDirectory: true)
            try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: false)
            let sessionURL = sessionDirectory.appendingPathComponent("session.json")

            let descriptor: [String: Any] = [
                "session_id": sessionID,
                "socket_path": socketPath,
                "auth_token": authToken,
                "namedattr": false,
                "readonly": false,
                "volume_name": volumeName,
            ]
            let descriptorData = try JSONSerialization.data(withJSONObject: descriptor, options: [.sortedKeys])
            try descriptorData.write(to: sessionURL, options: .atomic)
            chmod(sessionURL.path, 0o600)

            let server = UnixRPCServer(
                socketPath: socketPath,
                sessionID: sessionID,
                authToken: authToken,
                backing: backing,
                readOnly: false
            )
            try server.listen()

            defer {
                try? backing.synchronize()
                try? fileManager.removeItem(at: sessionDirectory)
                unlink(socketPath)
            }

            let mount = Process()
            mount.executableURL = URL(fileURLWithPath: "/sbin/mount")
            mount.arguments = ["-t", "fuset", sessionURL.path, mountpoint]
            mount.standardOutput = FileHandle.standardOutput
            mount.standardError = FileHandle.standardError
            try mount.run()

            print("SESSION_ID=\(sessionID)")
            print("SESSION_JSON=\(sessionURL.path)")
            print("SOCKET=\(socketPath)")
            print("MOUNTPOINT=\(mountpoint)")
            print("ACCESS_MODE=read-write")
            fflush(stdout)

            try server.serveOneConnection()
            print("FIRST_CONNECTION_DONE=1")
            fflush(stdout)
            try server.serveOneConnection()
            print("SECOND_CONNECTION_DONE=1")
            fflush(stdout)
        } catch {
            fputs("FuseTTwoConnectionHarness: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func dumpFSKitOptionEvidence() {
        let binary = "/Applications/fuse-t.app/Contents/Extensions/FskitSrvModule.appex/Contents/MacOS/FskitSrvModule"
        let keywords = [
            "nobrowse", "dontbrowse", "browse", "mount option", "mountoption",
            "requestedmount", "session", "volume_name", "readonly", "config",
        ]

        print("FSKIT_OPTION_EVIDENCE_BEGIN")
        for (label, executable, arguments) in [
            ("STRINGS", "/usr/bin/strings", ["-a", binary]),
            ("GO_NM", "/usr/bin/env", ["go", "tool", "nm", binary]),
            ("OTOOL", "/usr/bin/otool", ["-ov", binary]),
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard let text = String(data: data, encoding: .utf8) else { continue }
                let matching = text.split(separator: "\n").filter { line in
                    let lower = line.lowercased()
                    return keywords.contains { lower.contains($0) }
                }
                print("FSKIT_OPTION_EVIDENCE_\(label)_STATUS=\(process.terminationStatus)")
                for line in matching.prefix(500) {
                    print("[\(label)] \(line)")
                }
            } catch {
                print("FSKIT_OPTION_EVIDENCE_\(label)_ERROR=\(error)")
            }
        }
        print("FSKIT_OPTION_EVIDENCE_END")
        fflush(stdout)
    }
}
