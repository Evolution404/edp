import CryptoKit
import Foundation

struct EDPFuseTRuntimeStatus: Sendable {
    let appPath: String
    let hostBundleID: String
    let moduleBundleID: String
    let teamID: String
    let registeredWithPluginKit: Bool
}

struct EDPFuseTRuntimePolicyError: Error, CustomStringConvertible, Sendable {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// Product supply-chain policy for the exact FUSE-T runtime proven by the
/// macOS 26 experiment. This policy deliberately does not read or write
/// Apple's private FSKit enabledModules storage. Actual enablement is proven by
/// attempting the standard FSKit mount path and surfacing its failure to UI.
enum EDPFuseTRuntimePolicy {
    static let appPath = "/Applications/fuse-t.app"
    static let hostBundleID = "org.fuset.fskit-srv"
    static let moduleBundleID = "org.fuset.fskit-srv.module"
    static let teamID = "6DY7Z4SVDZ"

    // Package 1.2.7 evidence captured in Phase A. We pin the signed executable
    // hashes in addition to codesign identity so an arbitrary newer FUSE-T
    // protocol is never silently accepted by the private RPC adapter.
    static let hostExecutableSHA256 = "fc64ae9c17efc70540db07f256ecd75af1ff174a9fb83611bb6ffdb1cba8f2c5"
    static let moduleExecutableSHA256 = "199ba1246d36db18ebf45c60abd3d68ca4b4ad9d8080d55aa8e856f574772086"

    private static let moduleRelativePath = "Contents/Extensions/FskitSrvModule.appex"

    static func verifyInstalled() throws -> EDPFuseTRuntimeStatus {
        let fileManager = FileManager.default
        let modulePath = URL(fileURLWithPath: appPath)
            .appendingPathComponent(moduleRelativePath).path
        guard fileManager.fileExists(atPath: appPath),
              fileManager.fileExists(atPath: modulePath) else {
            throw EDPFuseTRuntimePolicyError(
                "supported FUSE-T FSKit runtime is not installed at \(appPath)"
            )
        }

        try verifyCodesign(path: appPath)
        try verifyBundle(
            path: appPath,
            expectedBundleID: hostBundleID,
            expectedExecutableSHA256: hostExecutableSHA256
        )
        try verifyBundle(
            path: modulePath,
            expectedBundleID: moduleBundleID,
            expectedExecutableSHA256: moduleExecutableSHA256
        )
        let team = try codesignTeamIdentifier(path: modulePath)
        guard team == teamID else {
            throw EDPFuseTRuntimePolicyError(
                "FUSE-T FSKit module TeamIdentifier mismatch: expected \(teamID), found \(team)"
            )
        }

        return EDPFuseTRuntimeStatus(
            appPath: appPath,
            hostBundleID: hostBundleID,
            moduleBundleID: moduleBundleID,
            teamID: teamID,
            registeredWithPluginKit: pluginKitContainsModule()
        )
    }

    private static func verifyCodesign(path: String) throws {
        let result = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", path])
        guard result.status == 0 else {
            throw EDPFuseTRuntimePolicyError(
                "FUSE-T codesign verification failed: \(result.stderr)"
            )
        }
    }

    private static func verifyBundle(
        path: String,
        expectedBundleID: String,
        expectedExecutableSHA256: String
    ) throws {
        let plistPath = URL(fileURLWithPath: path)
            .appendingPathComponent("Contents/Info.plist").path
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String,
              let executable = plist["CFBundleExecutable"] as? String else {
            throw EDPFuseTRuntimePolicyError("invalid FUSE-T bundle metadata at \(path)")
        }
        guard bundleID == expectedBundleID else {
            throw EDPFuseTRuntimePolicyError(
                "FUSE-T bundle identifier mismatch: expected \(expectedBundleID), found \(bundleID)"
            )
        }
        let executablePath = URL(fileURLWithPath: path)
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(executable).path
        let digest = try sha256(path: executablePath)
        guard digest == expectedExecutableSHA256 else {
            throw EDPFuseTRuntimePolicyError(
                "unsupported FUSE-T executable hash for \(expectedBundleID): \(digest)"
            )
        }
    }

    private static func sha256(path: String) throws -> String {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw EDPFuseTRuntimePolicyError("cannot read FUSE-T executable at \(path)")
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func codesignTeamIdentifier(path: String) throws -> String {
        let result = try run("/usr/bin/codesign", ["-dv", "--verbose=4", path])
        guard result.status == 0 else {
            throw EDPFuseTRuntimePolicyError("cannot inspect FUSE-T code signature")
        }
        let combined = result.stdout + "\n" + result.stderr
        guard let line = combined.split(separator: "\n")
            .first(where: { $0.hasPrefix("TeamIdentifier=") }) else {
            throw EDPFuseTRuntimePolicyError("FUSE-T signature has no TeamIdentifier")
        }
        return String(line.dropFirst("TeamIdentifier=".count))
    }

    private static func pluginKitContainsModule() -> Bool {
        guard let result = try? run(
            "/usr/bin/pluginkit",
            ["-m", "-p", "com.apple.fskit.fsmodule", "-A", "-D", "-vv"]
        ) else {
            return false
        }
        return result.status == 0 && (result.stdout + result.stderr).contains(moduleBundleID)
    }

    private struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
    }
}
