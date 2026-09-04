import Darwin
import Foundation

private final class EDPXPCListenerBox: @unchecked Sendable {
    let listener: NSXPCListener
    init(_ listener: NSXPCListener) { self.listener = listener }
}

private func daemon() throws -> Never {
    try requireRoot()
    let controller = try EDPServiceController()
    let monitor = try EDPDiskEventMonitor()
    let stopped = DispatchSemaphore(value: 0)
    let listener = NSXPCListener(machServiceName: edpVaultMachServiceName)
    let listenerBox = EDPXPCListenerBox(listener)
    let xpcService = EDPXPCService(controller: controller) {
        // The client sends this acknowledgement only after receiving the
        // graceful-shutdown reply, so no fixed reply-drain delay is needed.
        monitor.stop()
        listenerBox.listener.invalidate()
        stopped.signal()
    }
    listener.delegate = xpcService
    listener.resume()
    Darwin.signal(SIGTERM, runtimeSignalHandler)
    Darwin.signal(SIGINT, runtimeSignalHandler)
    monitor.start { controller.reconcile() }
    withExtendedLifetime((monitor, listenerBox, xpcService)) {
        stopped.wait()
    }
    Darwin.exit(EXIT_SUCCESS)
}

private func runtimeSignalHandler(_ signalNumber: Int32) {
    // Only async-signal-safe work is allowed here. The next daemon instance
    // recovers the persisted session state before scanning physical disks.
    _exit(128 + signalNumber)
}

private func doctor() -> Int32 {
    var ok = true
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let macOSOK = version.majorVersion >= 26
    print("MACOS_26_OR_NEWER=\(macOSOK ? "YES" : "NO")")
    ok = ok && macOSOK
    let runtimeStatus = try? EDPTransportRuntimePolicy.verifySelectedRuntime(
        requireFinderHidden: true
    )
    print("TRANSPORT_RUNTIME=\(runtimeStatus?.runtimeDescription ?? "MISSING_OR_UNSUPPORTED")")
    print("TRANSPORT_BACKEND=\(runtimeStatus?.backend.rawValue ?? "unavailable")")
    ok = ok && runtimeStatus != nil
    let binaryRoot = runtimeBinaryRoot()
    let transportBackend = runtimeStatus?.backend ?? .macFUSELocal
    let transportTools = [false, true].map {
        EDPTransportProvider.executableName(for: transportBackend, readOnly: $0)
    }
    for tool in transportTools + ["edp-console-exec", "edp-raw-metadata", "diskimages2-attach"] {
        let path = binaryRoot + "/" + tool
        let present = FileManager.default.isExecutableFile(atPath: path)
        print("TOOL_\(tool.uppercased().replacingOccurrences(of: ".", with: "_"))=\(present ? "OK" : "MISSING")")
        ok = ok && present
    }
    let rawDaemon = rawAccessDaemonPath()
    let rawDaemonPresent = FileManager.default.isExecutableFile(atPath: rawDaemon)
    print("RAW_ACCESS_DAEMON=\(rawDaemonPresent ? rawDaemon : "MISSING")")
    print("RAW_ACCESS_MODEL=FULL_DISK_ACCESS_RETAINED_FD")
    ok = ok && rawDaemonPresent
    if geteuid() == 0 {
        let count = (try? discoverEDPDisks().count) ?? 0
        print("EDP_DISKS=\(count)")
    } else {
        print("EDP_DISKS=REQUIRES_ROOT")
    }
    print("RESULT=\(ok ? "EDP_RUNTIME_READY" : "EDP_RUNTIME_NOT_READY")")
    return ok ? 0 : 1
}

private func usage() {
    print("""
    Usage:
      edp-drive-service doctor
      edp-drive-service status
      sudo edp-drive-service list
      sudo edp-drive-service authorize [diskN]
      sudo edp-drive-service revoke <device-id>
      sudo edp-drive-service cleanup
      sudo edp-drive-service daemon

    After passwords are verified and saved, the privileged launch daemon
    automatically mounts configured EDP partitions when the USB disk appears.
    """)
}

#if !EDP_REGRESSION_TESTS
@main
private enum EDPVaultMain {
    static func main() {
        do {
            let command = CommandLine.arguments.dropFirst().first ?? "help"
            switch command {
            case "doctor": exit(doctor())
            case "status":
                let path = dataRoot + "/sessions.json"
                if let data = FileManager.default.contents(atPath: path) {
                    FileHandle.standardOutput.write(data)
                    print()
                } else {
                    print("[]")
                }
            case "list":
                try requireRoot()
                for disk in try discoverEDPDisks() {
                    print("\(disk.bsdName)\t\(disk.deviceID)\t\(disk.vidHex):\(disk.pidHex)\t\(disk.sizeBytes)\t\(disk.mediaName)")
                }
            case "authorize":
                try authorize(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil)
            case "revoke":
                try requireRoot()
                guard CommandLine.arguments.count == 3 else {
                    throw fail("revoke requires a device id")
                }
                try makeCredentialStore().remove(deviceID: CommandLine.arguments[2])
            case "cleanup":
                try requireRoot()
                try recoverPersistedMountSessionsForServiceCleanup { errorMessage in
                    if let errorMessage {
                        FileHandle.standardError.write(Data("ERROR=\(errorMessage)\n".utf8))
                        exit(1)
                    }
                    print("RESULT=EDP_PERSISTED_SESSION_CLEANUP_OK")
                    exit(0)
                }
                dispatchMain()
            case "daemon": try daemon()
            default: usage()
            }
        } catch {
            FileHandle.standardError.write(Data("ERROR=\(error)\n".utf8))
            exit(1)
        }
    }
}
#endif
