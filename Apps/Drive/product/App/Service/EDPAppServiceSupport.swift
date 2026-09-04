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
var edpFSKitEnabledModulesURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.fskit.settings", isDirectory: true)
        .appendingPathComponent("enabledModules.plist", isDirectory: false)
}

enum EDPUserToolError: Error, LocalizedError, Sendable {
    case launchFailed(executable: String, detail: String)
    case timedOut(executable: String)
    case failed(executable: String, status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let executable, let detail):
            return "\(executable) launch failed: \(detail)"
        case .timedOut(let executable):
            return "\(executable) timed out"
        case .failed(let executable, let status, let output):
            return "\(executable) failed (\(status)): \(output)"
        }
    }
}

private let edpUserToolLifecycleQueue = DispatchQueue(
    label: "com.edp.drive.user-tool-lifecycle"
)

private func edpDurationSeconds(_ duration: Duration) -> TimeInterval {
    let components = duration.components
    return max(
        0,
        TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    )
}

private final class EDPUserToolExitOperation: @unchecked Sendable {
    private let process: Process
    private let executable: String
    private let timeout: TimeInterval
    private let queue: DispatchQueue
    private var continuation: CheckedContinuation<Int32, Error>?
    private var exitStatus: Int32?
    private var terminalError: Error?
    private var timeoutArmed = false
    private var finished = false

    init(
        process: Process,
        executable: String,
        timeout: Duration,
        queue: DispatchQueue = edpUserToolLifecycleQueue
    ) {
        self.process = process
        self.executable = executable
        self.timeout = edpDurationSeconds(timeout)
        self.queue = queue
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.queue.async {
                self.processDidExit(process.terminationStatus)
            }
        }
    }

    func wait() async throws -> Int32 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !finished else {
                        if let terminalError {
                            continuation.resume(throwing: terminalError)
                        } else {
                            continuation.resume(returning: exitStatus ?? process.terminationStatus)
                        }
                        return
                    }
                    self.continuation = continuation
                    if let exitStatus {
                        finish(status: exitStatus, error: nil)
                        return
                    }
                    guard !timeoutArmed else { return }
                    timeoutArmed = true
                    queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.timeoutExpired()
                    }
                }
            }
        } onCancel: { [weak self] in
            self?.requestCancellation()
        }
    }

    private func requestCancellation() {
        queue.async { [self] in
            cancelled()
        }
    }

    private func processDidExit(_ status: Int32) {
        guard !finished else { return }
        exitStatus = status
        if let terminalError {
            finish(status: status, error: terminalError)
        } else if continuation != nil {
            finish(status: status, error: nil)
        }
    }

    private func timeoutExpired() {
        guard !finished, exitStatus == nil else { return }
        terminalError = EDPUserToolError.timedOut(executable: executable)
        terminateThenEscalate()
    }

    private func cancelled() {
        guard !finished else { return }
        terminalError = CancellationError()
        if exitStatus != nil {
            finish(status: exitStatus ?? -1, error: terminalError)
            return
        }
        terminateThenEscalate()
    }

    private func terminateThenEscalate() {
        guard process.isRunning else {
            finish(status: process.terminationStatus, error: terminalError)
            return
        }
        process.terminate()
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.finished, self.process.isRunning else { return }
            if self.process.processIdentifier > 1 {
                _ = Darwin.kill(self.process.processIdentifier, SIGKILL)
            }
        }
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.finished else { return }
            self.finish(status: self.exitStatus ?? -1, error: self.terminalError)
        }
    }

    private func finish(status: Int32, error: Error?) {
        guard !finished else { return }
        finished = true
        process.terminationHandler = nil
        exitStatus = status
        terminalError = error
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: status)
        }
    }
}

func runUserTool(
    _ executable: String,
    _ arguments: [String],
    timeout: Duration = .seconds(8)
) async throws -> String {
    let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("edp-user-tool-\(UUID().uuidString).log", isDirectory: false)
    guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
          let output = FileHandle(forWritingAtPath: outputURL.path) else {
        throw EDPUserToolError.launchFailed(
            executable: executable,
            detail: "cannot create bounded output file"
        )
    }
    defer {
        try? output.close()
        try? FileManager.default.removeItem(at: outputURL)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    let exitOperation = EDPUserToolExitOperation(
        process: process,
        executable: executable,
        timeout: timeout
    )
    do {
        try process.run()
    } catch {
        throw EDPUserToolError.launchFailed(
            executable: executable,
            detail: error.localizedDescription
        )
    }

    let status = try await exitOperation.wait()
    try? output.synchronize()
    let data = (try? Data(contentsOf: outputURL)) ?? Data()
    let text = String(decoding: data, as: UTF8.self)
    guard status == 0 else {
        throw EDPUserToolError.failed(
            executable: executable,
            status: status,
            output: text
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

func noActiveFSKitMountsForAgentReset() -> Bool {
    var mounts: UnsafeMutablePointer<statfs>?
    let count = getmntinfo(&mounts, MNT_NOWAIT)
    guard count >= 0 else { return false }
    if count == 0 { return true }
    guard let mounts else { return false }
    for index in 0..<Int(count) {
        if (mounts[index].f_flags_ext & UInt32(MNT_EXT_FSKIT)) != 0 {
            return false
        }
    }
    return true
}

func macFUSELocalEnablementReady() async -> Bool {
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
    guard let listing = try? await runUserTool("/usr/bin/pluginkit", ["-m", "-A", "-D"]) else {
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
func ensureMacFUSELocalEnablement() async throws -> Bool {
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
    let before = (try? await runUserTool(pluginKit, ["-m", "-A", "-D"])) ?? ""
    let pluginsWereEnabled = macFUSEPluginsEnabled(before)
    let settingsWereEnabled = macFUSEModulesEnabledInSettings()
    if pluginsWereEnabled && settingsWereEnabled {
        return false
    }

    if !pluginsWereEnabled {
        let launchServices = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        _ = try await runUserTool(launchServices, ["-f", "-R", "-trusted", edpMacFUSEHostPath])
        for modulePath in [genericModule, localModule] {
            _ = try await runUserTool(pluginKit, ["-a", modulePath])
        }
        for moduleID in edpMacFUSEModuleIDs {
            _ = try await runUserTool(pluginKit, ["-e", "use", "-i", moduleID])
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

    let after = try await runUserTool(pluginKit, ["-m", "-A", "-D"])
    guard macFUSEPluginsEnabled(after) else {
        throw NSError(
            domain: "com.edp.drive.fskit",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "macFUSE FSKit 模块未被 PluginKit 启用"]
        )
    }

    if settingsChanged || !pluginsWereEnabled {
        // Never recycle FSKit user agents while any FSKit volume is active.
        // Registration/settings have already been persisted above, so a busy
        // system can converge naturally without disrupting EDP or unrelated
        // FSKit mounts. A later launch may perform the reset once mount-free.
        guard noActiveFSKitMountsForAgentReset() else {
            return false
        }
        // Only the current user's agents can be restarted here. The system
        // fskitd observes their new registration without requiring sudo. Agent
        // readiness is awaited asynchronously by the view model; never block
        // the main actor after sending this reset.
        _ = try? await runUserTool("/usr/bin/killall", ["-9", "fskit_agent", "extensionkitservice"])
        return true
    }
    return false
}
