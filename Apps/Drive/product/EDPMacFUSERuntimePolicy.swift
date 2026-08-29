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

/// Supply-chain policy for the exact macFUSE 5.3.3 FSKit runtime proven by the
/// macOS 26 Direct MFMount lifecycle and product transport experiments. The
/// application bundle's marketing version is not the macFUSE package version,
/// so the policy pins signed executable hashes from the official 5.3.3 DMG in
/// addition to bundle identifiers and Developer ID TeamIdentifier.
enum EDPMacFUSERuntimePolicy {
    static let appPath = "/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app"
    static let frameworkPath = "/Library/Filesystems/macfuse.fs/Contents/Frameworks/MFMount.framework"
    static let hostBundleID = "io.macfuse.app"
    static let genericModuleBundleID = "io.macfuse.app.fsmodule.macfuse"
    static let localModuleBundleID = "io.macfuse.app.fsmodule.macfuse-local"
    static let teamID = "3T5GSNBU6W"

    // Official macFUSE 5.3.3 DMG SHA256:
    // 7a0b7b66c0e7f8932707d1215dc9cf486e178d097ae0a2dcdf17d8530566aa15
    static let hostExecutableSHA256 = "edce4ab3187be038929488a053e0c8e9170dd1b042f41131cb08c190c412e189"
    static let genericExecutableSHA256 = "534b421574c276ef98ef95f492d05adfb0210580d3fa663a6617794b56562822"
    static let localExecutableSHA256 = "569a2a6eb649b584606e5eeae5d1ea37f842ed84624744255ec7e74ff130b16c"

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
                "supported macFUSE 5.3.3 FSKit runtime is not installed"
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
