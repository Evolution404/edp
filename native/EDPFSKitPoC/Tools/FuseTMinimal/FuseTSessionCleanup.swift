import Darwin
import Foundation

private enum CleanupError: Error, CustomStringConvertible {
    case usage(String)
    case invalid(String)

    var description: String {
        switch self {
        case .usage(let message), .invalid(let message):
            return message
        }
    }
}

private struct Arguments {
    let sessionJSON: String
    let mountpoint: String
}

private func parseArguments() throws -> Arguments {
    var values = [String: String]()
    let args = CommandLine.arguments
    var index = 1
    while index < args.count {
        let key = args[index]
        guard key.hasPrefix("--") else { throw CleanupError.usage("unexpected argument: \(key)") }
        index += 1
        guard index < args.count else { throw CleanupError.usage("\(key) requires a value") }
        values[key] = args[index]
        index += 1
    }
    guard let sessionJSON = values["--session-json"], let mountpoint = values["--mountpoint"] else {
        throw CleanupError.usage("usage: FuseTSessionCleanup --session-json <path> --mountpoint <path>")
    }
    return Arguments(sessionJSON: sessionJSON, mountpoint: mountpoint)
}

private func validatedSession(sessionJSON: String) throws -> (directory: URL, socketPath: String, sessionID: String) {
    let sessionURL = URL(fileURLWithPath: sessionJSON).standardizedFileURL
    guard sessionURL.lastPathComponent == "session.json" else {
        throw CleanupError.invalid("session path must end in session.json")
    }
    let data = try Data(contentsOf: sessionURL)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sessionID = object["session_id"] as? String,
          let socketPath = object["socket_path"] as? String,
          sessionID.hasPrefix("edp-fuset-") else {
        throw CleanupError.invalid("invalid EDP FUSE-T session descriptor")
    }

    let sessionDirectory = sessionURL.deletingLastPathComponent().standardizedFileURL
    guard sessionDirectory.lastPathComponent == sessionID else {
        throw CleanupError.invalid("session directory does not match session id")
    }
    let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).standardizedFileURL.path
    guard sessionDirectory.path.hasPrefix(tempRoot + "/") else {
        throw CleanupError.invalid("session directory is outside the temporary root")
    }

    let expectedSocketRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.org.fuset.fskit-srv/s", isDirectory: true)
        .standardizedFileURL.path
    let socketURL = URL(fileURLWithPath: socketPath).standardizedFileURL
    guard socketURL.deletingLastPathComponent().path == expectedSocketRoot,
          socketURL.lastPathComponent.hasPrefix(String(sessionID.prefix(20))),
          socketURL.pathExtension == "sock" else {
        throw CleanupError.invalid("socket path is outside the EDP FUSE-T app-group socket directory")
    }
    return (sessionDirectory, socketURL.path, sessionID)
}

private func forceUnmount(_ mountpoint: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/sbin/umount")
    process.arguments = ["-f", mountpoint]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        // Cleanup continues because the mount may already have disappeared after a backend crash.
    }
}

private func run() throws {
    let args = try parseArguments()
    let validated = try validatedSession(sessionJSON: args.sessionJSON)
    forceUnmount(args.mountpoint)
    unlink(validated.socketPath)
    try? FileManager.default.removeItem(at: validated.directory)
    try? FileManager.default.removeItem(atPath: args.mountpoint)

    guard !FileManager.default.fileExists(atPath: validated.directory.path),
          !FileManager.default.fileExists(atPath: validated.socketPath) else {
        throw CleanupError.invalid("EDP FUSE-T session artifacts remain after cleanup")
    }
    print("CLEANED_SESSION_ID=\(validated.sessionID)")
    print("RESULT=FUSET_SESSION_CRASH_CLEANUP_COMPLETE")
}

do {
    try run()
} catch {
    fputs("FuseTSessionCleanup: \(error)\n", stderr)
    exit(1)
}
