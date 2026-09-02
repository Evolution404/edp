import Darwin
import Foundation

let edpDriveAppPath = "/Applications/EDP Drive.app"
let edpDriveServicePath = edpDriveAppPath
    + "/Contents/Library/LaunchServices/edp-drive-service"

let edpMacFUSEModuleIDs = [
    "io.macfuse.app.fsmodule.macfuse",
    "io.macfuse.app.fsmodule.macfuse-local",
]

let edpMacFUSEHostPath = "/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app"
let edpMacFUSEEnablementMaxAttempts = 5

var edpFSKitEnabledModulesURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.fskit.settings", isDirectory: true)
        .appendingPathComponent("enabledModules.plist", isDirectory: false)
}

func runUserTool(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "com.edp.drive.fskit",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "\(executable) \(arguments.joined(separator: " ")) failed: \(text)"]
        )
    }
    return text
}

func macFUSEModulesEnabledInSettings() -> Bool {
    guard let data = try? Data(contentsOf: edpFSKitEnabledModulesURL),
          let modules = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else {
        return false
    }
    return Set(edpMacFUSEModuleIDs).isSubset(of: Set(modules))
}

func macFUSEPluginsEnabled(_ listing: String) -> Bool {
    edpMacFUSEModuleIDs.allSatisfy { moduleID in
        listing.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("+ \(moduleID)")
                || (trimmed.hasPrefix("+") && line.contains(moduleID))
        }
    }
}

func macFUSELocalEnablementReady() -> Bool {
    let genericModule = edpMacFUSEHostPath
        + "/Contents/Extensions/io.macfuse.app.fsmodule.macfuse.appex"
    let localModule = edpMacFUSEHostPath
        + "/Contents/Extensions/io.macfuse.app.fsmodule.macfuse-local.appex"
    guard FileManager.default.fileExists(atPath: edpMacFUSEHostPath),
          FileManager.default.fileExists(atPath: genericModule),
          FileManager.default.fileExists(atPath: localModule),
          macFUSEModulesEnabledInSettings() else {
        return false
    }
    guard let listing = try? runUserTool("/usr/bin/pluginkit", ["-m", "-A", "-D"]) else {
        return false
    }
    return macFUSEPluginsEnabled(listing)
}

/// macFUSE's signed installer deploys the FSKit host and modules system-wide,
/// while FSKit keeps module enablement in the console user's settings. Perform
/// this user-context step from the signed App so a clean install does not
/// require a terminal workaround before the first Direct MFMount. The caller
/// performs a bounded stability retry because installer/FSKit registration can
/// still be converging during the first foreground launch.
func ensureMacFUSELocalEnablement() throws -> Bool {
    let genericModule = edpMacFUSEHostPath
        + "/Contents/Extensions/io.macfuse.app.fsmodule.macfuse.appex"
    let localModule = edpMacFUSEHostPath
        + "/Contents/Extensions/io.macfuse.app.fsmodule.macfuse-local.appex"
    guard FileManager.default.fileExists(atPath: edpMacFUSEHostPath),
          FileManager.default.fileExists(atPath: genericModule),
          FileManager.default.fileExists(atPath: localModule) else {
        return false
    }

    let pluginKit = "/usr/bin/pluginkit"
    let before = (try? runUserTool(pluginKit, ["-m", "-A", "-D"])) ?? ""
    let pluginsWereEnabled = macFUSEPluginsEnabled(before)
    let settingsWereEnabled = macFUSEModulesEnabledInSettings()
    if pluginsWereEnabled && settingsWereEnabled {
        return false
    }

    if !pluginsWereEnabled {
        let launchServices = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        _ = try runUserTool(launchServices, ["-f", "-R", "-trusted", edpMacFUSEHostPath])
        for modulePath in [genericModule, localModule] {
            _ = try runUserTool(pluginKit, ["-a", modulePath])
        }
        for moduleID in edpMacFUSEModuleIDs {
            _ = try runUserTool(pluginKit, ["-e", "use", "-i", moduleID])
        }
    }

    var enabledModules = [String]()
    if FileManager.default.fileExists(atPath: edpFSKitEnabledModulesURL.path) {
        let data = try Data(contentsOf: edpFSKitEnabledModulesURL)
        guard let existing = try PropertyListSerialization.propertyList(
            from: data,
            format: nil
        ) as? [String] else {
            throw NSError(
                domain: "com.edp.drive.fskit",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "FSKit 模块启用设置格式无效"]
            )
        }
        enabledModules = existing
    }
    let settingsChanged = edpMacFUSEModuleIDs.contains { !enabledModules.contains($0) }
    for moduleID in edpMacFUSEModuleIDs where !enabledModules.contains(moduleID) {
        enabledModules.append(moduleID)
    }
    try FileManager.default.createDirectory(
        at: edpFSKitEnabledModulesURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let settingsData = try PropertyListSerialization.data(
        fromPropertyList: enabledModules,
        format: .xml,
        options: 0
    )
    try settingsData.write(to: edpFSKitEnabledModulesURL, options: .atomic)
    guard chmod(edpFSKitEnabledModulesURL.path, 0o600) == 0 else {
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "无法保护 FSKit 模块启用设置"]
        )
    }

    let after = try runUserTool(pluginKit, ["-m", "-A", "-D"])
    guard macFUSEPluginsEnabled(after) else {
        throw NSError(
            domain: "com.edp.drive.fskit",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "macFUSE FSKit 模块未被 PluginKit 启用"]
        )
    }

    if settingsChanged || !pluginsWereEnabled {
        // Only the current user's agents can be restarted here. The system
        // fskitd observes their new registration without requiring sudo. Agent
        // readiness is awaited asynchronously by the view model; never block
        // the main actor after sending this reset.
        _ = try? runUserTool("/usr/bin/killall", ["-9", "fskit_agent", "extensionkitservice"])
        return true
    }
    return false
}
