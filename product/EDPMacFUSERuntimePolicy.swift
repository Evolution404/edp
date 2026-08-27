import CryptoKit
import Foundation

struct EDPMacFUSERuntimeStatus: Sendable {
    let appPath: String
    let hostBundleID: String
    let genericModuleBundleID: String
    let localModuleBundleID: String
    let teamID: String
    let localRegisteredWithPluginKit: Bool
    let mfMountFrameworkPresent: Bool
}

struct EDPMacFUSERuntimePolicyError: Error, CustomStringConvertible, Sendable {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// Supply-chain policy for the exact macFUSE 5.3.2 FSKit runtime proven by the
/// macOS 26 Direct MFMount experiments. The application bundle's marketing
/// version is not the macFUSE package version, so the policy pins the signed
/// executable hashes captured from the official 5.3.2 DMG in addition to
/// bundle identifiers and Developer ID TeamIdentifier.
enum EDPMacFUSERuntimePolicy {
    static let appPath = "/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app"
    static let frameworkPath = "/Library/Filesystems/macfuse.fs/Contents/Frameworks/MFMount.framework"
    static let hostBundleID = "io.macfuse.app"
    static let genericModuleBundleID = "io.macfuse.app.fsmodule.macfuse"
    static let localModuleBundleID = "io.macfuse.app.fsmodule.macfuse-local"
    static let teamID = "3T5GSNBU6W"

    // Official macFUSE 5.3.2 DMG SHA256:
    // 9328a8cd0b893b4347097270d6605408630dd764ddca275256959dc0e9a07936
    // Runtime executable hashes captured by run 33035902893.
    static let hostExecutableSHA256 = "d508ecad04802a382319378bc86e04fc7c2e9adab602e82a15fd29d1a7eef98e"
    static let genericExecutableSHA256 = "073c51eea3fa3dcc7b3c7f789af86ecf7020029e2e1d1704007976e14192050f"
    static let localExecutableSHA256 = "4888d6d1a029f813d4700cc4a0575a4407cf799b25268fcbe1e1264a00955f4a"

    private static let extensionsRelativePath = "Contents/Extensions"

    static func verifyInstalled() throws -> EDPMacFUSERuntimeStatus {
        let fileManager = FileManager.default
        let genericPath = URL(fileURLWithPath: appPath)
            .appendingPathComponent(extensionsRelativePath)
            .appendingPathComponent("\(genericModuleBundleID).appex").path
        let localPath = URL(fileURLWithPath: appPath)
            .appendingPathComponent(extensionsRelativePath)
            .appendingPathComponent("\(localModuleBundleID).appex").path

        guard fileManager.fileExists(atPath: appPath),
              fileManager.fileExists(atPath: genericPath),
              fileManager.fileExists(atPath: localPath),
              fileManager.fileExists(atPath: frameworkPath) else {
            throw EDPMacFUSERuntimePolicyError(
                "supported macFUSE 5.3.2 FSKit runtime is not installed"
            )
        }

        try verifyCodesign(path: appPath)
        try verifyCodesign(path: genericPath)
        try verifyCodesign(path: localPath)
        try verifyBundle(
            path: appPath,
            expectedBundleID: hostBundleID,
            expectedExecutableSHA256: hostExecutableSHA256
        )
        try verifyBundle(
            path: genericPath,
            expectedBundleID: genericModuleBundleID,
            expectedExecutableSHA256: genericExecutableSHA256
        )
        try verifyBundle(
            path: localPath,
            expectedBundleID: localModuleBundleID,
            expectedExecutableSHA256: localExecutableSHA256
        )

        for path in [appPath, genericPath, localPath] {
            let team = try codesignTeamIdentifier(path: path)
            guard team == teamID else {
                throw EDPMacFUSERuntimePolicyError(
                    "macFUSE TeamIdentifier mismatch at \(path): expected \(teamID), found \(team)"
                )
            }
        }

        return EDPMacFUSERuntimeStatus(
            appPath: appPath,
            hostBundleID: hostBundleID,
            genericModuleBundleID: genericModuleBundleID,
            localModuleBundleID: localModuleBundleID,
            teamID: teamID,
            localRegisteredWithPluginKit: pluginKitContainsModule(localModuleBundleID),
            mfMountFrameworkPresent: fileManager.fileExists(atPath: frameworkPath)
        )
    }

    private static func verifyCodesign(path: String) throws {
        let result = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", path])
        guard result.status == 0 else {
            throw EDPMacFUSERuntimePolicyError(
                "macFUSE codesign verification failed at \(path): \(result.stderr)"
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
            throw EDPMacFUSERuntimePolicyError("invalid macFUSE bundle metadata at \(path)")
        }
        guard bundleID == expectedBundleID else {
            throw EDPMacFUSERuntimePolicyError(
                "macFUSE bundle identifier mismatch: expected \(expectedBundleID), found \(bundleID)"
            )
        }
        let executablePath = URL(fileURLWithPath: path)
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(executable).path
        let digest = try sha256(path: executablePath)
        guard digest == expectedExecutableSHA256 else {
            throw EDPMacFUSERuntimePolicyError(
                "unsupported macFUSE executable hash for \(expectedBundleID): \(digest)"
            )
        }
    }

    private static func sha256(path: String) throws -> String {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw EDPMacFUSERuntimePolicyError("cannot read macFUSE executable at \(path)")
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func codesignTeamIdentifier(path: String) throws -> String {
        let result = try run("/usr/bin/codesign", ["-dv", "--verbose=4", path])
        guard result.status == 0 else {
            throw EDPMacFUSERuntimePolicyError("cannot inspect macFUSE code signature at \(path)")
        }
        let combined = result.stdout + "\n" + result.stderr
        guard let line = combined.split(separator: "\n")
            .first(where: { $0.hasPrefix("TeamIdentifier=") }) else {
            throw EDPMacFUSERuntimePolicyError("macFUSE signature has no TeamIdentifier at \(path)")
        }
        return String(line.dropFirst("TeamIdentifier=".count))
    }

    private static func pluginKitContainsModule(_ bundleID: String) -> Bool {
        guard let result = try? run(
            "/usr/bin/pluginkit",
            ["-m", "-p", "com.apple.fskit.fsmodule", "-A", "-D", "-vv"]
        ) else {
            return false
        }
        return result.status == 0 && (result.stdout + result.stderr).contains(bundleID)
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
