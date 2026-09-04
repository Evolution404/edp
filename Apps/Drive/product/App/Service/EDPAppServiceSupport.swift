import Darwin
import Foundation

let edpDriveAppPath = "/Applications/EDP Drive.app"
let edpDriveServicePath = edpDriveAppPath
    + "/Contents/Library/LaunchServices/edp-drive-service"

let edpMacFUSEHostPath = "/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app"
let edpMacFUSEInstallerPath = edpMacFUSEHostPath + "/Contents/MacOS/macfuse"

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

func macFUSELocalRuntimeReady() -> Bool {
    let genericModule = edpMacFUSEHostPath
        + "/Contents/Extensions/io.macfuse.app.fsmodule.macfuse.appex"
    let localModule = edpMacFUSEHostPath
        + "/Contents/Extensions/io.macfuse.app.fsmodule.macfuse-local.appex"
    let framework = "/Library/Filesystems/macfuse.fs/Contents/Frameworks/MFMount.framework"
    return FileManager.default.fileExists(atPath: edpMacFUSEHostPath)
        && FileManager.default.isExecutableFile(atPath: edpMacFUSEInstallerPath)
        && FileManager.default.fileExists(atPath: genericModule)
        && FileManager.default.fileExists(atPath: localModule)
        && FileManager.default.fileExists(atPath: framework)
}

/// macFUSE owns registration and FSKit-subsystem convergence for its bundled
/// file-system extensions. Do not duplicate that private lifecycle with
/// PlugInKit discovery or direct writes to FSKit's enabledModules.plist.
/// macFUSE 5.1.2+ exposes this supported installer entry point, and 5.2+
/// includes a workaround for FSKit/PluginKit re-registration races.
func ensureMacFUSELocalEnablement() async throws -> Bool {
    guard macFUSELocalRuntimeReady() else { return false }

    var arguments = ["install", "--components", "file-system-extensions"]
    let forceRegistration = noActiveFSKitMountsForAgentReset()
    if forceRegistration {
        arguments.append("--force")
    }
    _ = try await runUserTool(
        edpMacFUSEInstallerPath,
        arguments,
        timeout: .seconds(15)
    )
    return forceRegistration
}
