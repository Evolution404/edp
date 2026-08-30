import AppKit
import Darwin
import Foundation
import ServiceManagement
import SwiftUI

private let edpDriveAppPath = "/Applications/EDP Drive.app"
private let edpDriveServicePath = edpDriveAppPath
    + "/Contents/Library/LaunchServices/edp-drive-service"

private let edpMacFUSEModuleIDs = [
    "io.macfuse.app.fsmodule.macfuse",
    "io.macfuse.app.fsmodule.macfuse-local",
]

private let edpMacFUSEHostPath = "/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app"

private var edpFSKitEnabledModulesURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.fskit.settings", isDirectory: true)
        .appendingPathComponent("enabledModules.plist", isDirectory: false)
}

private func runUserTool(_ executable: String, _ arguments: [String]) throws -> String {
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

private func macFUSEModulesEnabledInSettings() -> Bool {
    guard let data = try? Data(contentsOf: edpFSKitEnabledModulesURL),
          let modules = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else {
        return false
    }
    return Set(edpMacFUSEModuleIDs).isSubset(of: Set(modules))
}

/// macFUSE's signed installer deploys the FSKit host and modules system-wide,
/// while FSKit keeps module enablement in the console user's settings. Perform
/// this user-context step once from the signed App so a clean install does not
/// require a terminal workaround before the first Direct MFMount.
private func ensureMacFUSELocalEnablement() throws {
    let genericModule = edpMacFUSEHostPath
        + "/Contents/Extensions/io.macfuse.app.fsmodule.macfuse.appex"
    let localModule = edpMacFUSEHostPath
        + "/Contents/Extensions/io.macfuse.app.fsmodule.macfuse-local.appex"
    guard FileManager.default.fileExists(atPath: edpMacFUSEHostPath),
          FileManager.default.fileExists(atPath: genericModule),
          FileManager.default.fileExists(atPath: localModule) else {
        return
    }

    let pluginKit = "/usr/bin/pluginkit"
    let before = (try? runUserTool(pluginKit, ["-m", "-A", "-D"])) ?? ""
    let pluginsWereEnabled = edpMacFUSEModuleIDs.allSatisfy { moduleID in
        before.split(separator: "\n").contains { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("+ \(moduleID)")
                || (line.trimmingCharacters(in: .whitespaces).hasPrefix("+")
                    && line.contains(moduleID))
        }
    }
    let settingsWereEnabled = macFUSEModulesEnabledInSettings()
    if pluginsWereEnabled && settingsWereEnabled {
        return
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
    guard edpMacFUSEModuleIDs.allSatisfy({ after.contains("+    \($0)") || after.contains("+\t\($0)") }) else {
        throw NSError(
            domain: "com.edp.drive.fskit",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "macFUSE FSKit 模块未被 PluginKit 启用"]
        )
    }

    if settingsChanged || !pluginsWereEnabled {
        // Only the current user's agents can be restarted here. The system
        // fskitd observes their new registration without requiring sudo.
        _ = try? runUserTool("/usr/bin/killall", ["-9", "fskit_agent", "extensionkitservice"])
        Thread.sleep(forTimeInterval: 3)
    }
}

@MainActor
final class EDPVaultViewModel: ObservableObject {
    @Published var snapshot = EDPXPCSnapshot(devices: [], serviceVersion: "-", timestamp: "-")
    @Published var serviceStatus = "检查中…"
    @Published var lastError: String?
    @Published var diagnostics = ""
    @Published var isBusy = false
    @Published var transportRuntimeReady: Bool?
    @Published private(set) var serviceDesiredRunning = true

    private let serviceMode: String
    private let daemonService: SMAppService?
    private let daemonPlistName = "com.edp.drive.service.plist"
    private let legacyPlistURL = URL(fileURLWithPath: "/Library/LaunchDaemons/com.edp.drive.service.plist")
    private let servicePreferenceKey = "com.edp.drive.service.desired-running"
    private var connection: NSXPCConnection?
    private var connectionGeneration: UUID?
    private var serviceOperationID: UUID?
    private var restartAfterStop = false
    private var stopCompletion: (() -> Void)?

    var needsFullDiskAccess: Bool {
        snapshot.devices.contains { $0.connected && !$0.privilegedAccessReady }
    }

    var rawAccessHelperInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: edpDriveServicePath)
    }

    var rawAccessStatusText: String {
        guard rawAccessHelperInstalled else { return "组件未安装" }
        if needsFullDiskAccess { return "需要完全磁盘访问" }
        if snapshot.devices.contains(where: { $0.connected && $0.privilegedAccessReady }) {
            return "已验证"
        }
        return "待连接 EDP U 盘验证"
    }

    var setupReady: Bool {
        serviceStatus == "运行中"
            && transportRuntimeReady == true
            && rawAccessHelperInstalled
            && snapshot.devices.contains { $0.connected && $0.privilegedAccessReady }
    }

    init() {
#if EDP_UI_PREVIEW
        serviceMode = "preview"
        daemonService = nil
        snapshot = Self.previewSnapshot
        serviceStatus = "运行中"
        transportRuntimeReady = true
        return
#else
        serviceMode = Bundle.main.object(forInfoDictionaryKey: "EDPServiceMode") as? String ?? "legacy"
        daemonService = serviceMode == "smappservice"
            ? SMAppService.daemon(plistName: daemonPlistName)
            : nil
        if UserDefaults.standard.object(forKey: servicePreferenceKey) != nil {
            serviceDesiredRunning = UserDefaults.standard.bool(forKey: servicePreferenceKey)
        }
        ensureServiceRegistration()
        do {
            try ensureMacFUSELocalEnablement()
        } catch {
            lastError = "macFUSE Local 启用失败：\(error.localizedDescription)"
        }
        refreshTransportRuntimeState()
        refresh()
        if transportRuntimeReady == true {
            retryTransientAutomaticMounts()
        }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.refresh()
            }
        }
#endif
    }

#if EDP_UI_PREVIEW
    private static let previewSnapshot = EDPXPCSnapshot(
        devices: [
            EDPXPCDevice(
                deviceID: "disk&ven_lexar&prod_usb_flash_drive#preview-v3",
                metadataDeviceID: "disk&ven_lexar&prod_usb_flash_drive",
                bsdName: "disk6",
                mediaName: "Lexar USB Flash Drive",
                displayName: "EDP 工作盘",
                vidPID: "21c4:0cd1",
                labelOnlyID: 3_164_177_653,
                sizeBytes: 124_736_503_808,
                connected: true,
                privilegedAccessReady: true,
                partitions: [
                    EDPXPCPartition(
                        partitionType: EDPPartitionKind.boot.rawValue,
                        displayName: "启动区",
                        encrypted: false,
                        autoMount: true,
                        credentialStatus: .notRequired,
                        mountState: .mounted,
                        filesystem: "FAT16",
                        readOnly: true,
                        mountPoint: "/Volumes/EDP Boot",
                        lastError: nil
                    ),
                    EDPXPCPartition(
                        partitionType: EDPPartitionKind.exchange.rawValue,
                        displayName: "交换区",
                        encrypted: true,
                        autoMount: true,
                        credentialStatus: .saved,
                        mountState: .mounted,
                        filesystem: "ExFAT",
                        readOnly: false,
                        mountPoint: "/Volumes/交换区",
                        lastError: nil
                    ),
                    EDPXPCPartition(
                        partitionType: EDPPartitionKind.secure.rawValue,
                        displayName: "保密区",
                        encrypted: true,
                        autoMount: false,
                        credentialStatus: .saved,
                        mountState: .unmounted,
                        filesystem: "ExFAT",
                        readOnly: false,
                        mountPoint: nil,
                        lastError: nil
                    )
                ]
            ),
            EDPXPCDevice(
                deviceID: "disk&ven_edp&prod_backup_drive#preview-v3",
                metadataDeviceID: nil,
                bsdName: "disk7",
                mediaName: "EDP Backup Drive",
                displayName: "EDP 备份盘",
                vidPID: "1209:ed02",
                labelOnlyID: nil,
                sizeBytes: 64_000_000_000,
                connected: false,
                privilegedAccessReady: true,
                partitions: [
                    EDPXPCPartition(
                        partitionType: EDPPartitionKind.secure.rawValue,
                        displayName: "保密区",
                        encrypted: true,
                        autoMount: true,
                        credentialStatus: .saved,
                        mountState: .unmounted,
                        filesystem: "ExFAT",
                        readOnly: false,
                        mountPoint: nil,
                        lastError: nil
                    )
                ]
            )
        ],
        activities: [
            EDPXPCActivity(
                id: UUID(),
                timestamp: "22:30:08",
                level: "info",
                deviceID: "disk&ven_lexar&prod_usb_flash_drive-49979b696404",
                partitionType: EDPPartitionKind.exchange.rawValue,
                message: "交换区已自动挂载"
            ),
            EDPXPCActivity(
                id: UUID(),
                timestamp: "22:29:56",
                level: "info",
                deviceID: "disk&ven_lexar&prod_usb_flash_drive-49979b696404",
                partitionType: nil,
                message: "已识别标准 EDP 加密盘"
            )
        ],
        serviceVersion: "0.6.0",
        timestamp: "2026-08-29T22:30:08+08:00"
    )
#endif

    private func currentServiceStatus() -> SMAppService.Status {
        if let daemonService { return daemonService.status }
        return SMAppService.statusForLegacyPlist(at: legacyPlistURL)
    }

    private func connectIfNeeded() -> NSXPCConnection? {
        guard serviceDesiredRunning, currentServiceStatus() == .enabled else { return nil }
        if let connection { return connection }
        let newConnection = NSXPCConnection(machServiceName: edpVaultMachServiceName, options: .privileged)
        let generation = UUID()
        newConnection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
        newConnection.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor in
                guard let self, self.connectionGeneration == generation else { return }
                self.serviceConnectionEnded()
            }
        }
        newConnection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor in
                guard let self, self.connectionGeneration == generation else { return }
                self.serviceConnectionEnded()
            }
        }
        newConnection.resume()
        connection = newConnection
        connectionGeneration = generation
        return newConnection
    }

    private func proxy() -> EDPVaultXPCProtocol? {
        guard let connection = connectIfNeeded() else { return nil }
        return connection.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
            Task { @MainActor in self?.lastError = error.localizedDescription }
        } as? EDPVaultXPCProtocol
    }

    func ensureServiceRegistration() {
        if let daemonService,
           daemonService.status != .enabled,
           daemonService.status != .requiresApproval {
            do {
                try daemonService.register()
            } catch {
                lastError = "后台服务注册失败：\(error.localizedDescription)"
            }
        }
        refreshServiceStatus()
    }

    func refreshServiceStatus() {
        switch currentServiceStatus() {
        case .enabled:
            if !serviceDesiredRunning {
                serviceStatus = launchdServiceIsRunning() ? "正在停止…" : "已停止"
            } else if connection == nil {
                serviceStatus = launchdServiceIsRunning() ? "正在连接…" : "等待按需启动"
            }
        case .requiresApproval: serviceStatus = "需要系统批准"
        case .notRegistered: serviceStatus = "未注册"
        case .notFound: serviceStatus = "未安装"
        @unknown default: serviceStatus = "未知"
        }
    }

    private func launchdServiceIsRunning() -> Bool {
        guard let output = try? runUserTool(
            "/bin/launchctl",
            ["print", "system/com.edp.drive.service"]
        ) else { return false }
        return output.contains("state = running") || output.contains("\n\tpid = ")
    }

    private func persistServicePreference() {
        UserDefaults.standard.set(serviceDesiredRunning, forKey: servicePreferenceKey)
    }

    private func armServiceTimeout(id: UUID, operation: String, seconds: Double = 12) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.serviceOperationID == id else { return }
            self.serviceOperationID = nil
            self.isBusy = false
            if operation == "重启" {
                self.serviceDesiredRunning = true
                self.persistServicePreference()
            }
            self.restartAfterStop = false
            self.stopCompletion = nil
            self.lastError = "后台服务\(operation)超时"
            self.refreshServiceStatus()
        }
    }

    private func serviceConnectionEnded() {
        connection = nil
        connectionGeneration = nil
        guard !serviceDesiredRunning else {
            serviceStatus = "连接已中断"
            return
        }

        // A service exit can report both interruption and invalidation. Clear
        // the lifecycle operation exactly once so an intentional restart can
        // never be scheduled twice by the two NSXPCConnection callbacks.
        let shouldRestart = restartAfterStop
        let completion = stopCompletion
        restartAfterStop = false
        stopCompletion = nil
        serviceOperationID = nil
        isBusy = false
        serviceStatus = "已停止"
        if shouldRestart {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.startService()
            }
        } else {
            completion?()
        }
    }

    func startService() {
        restartAfterStop = false
        stopCompletion = nil
        serviceDesiredRunning = true
        persistServicePreference()
        ensureServiceRegistration()
        guard currentServiceStatus() == .enabled else {
            lastError = "后台服务尚未注册、启用或批准"
            return
        }
        connection?.invalidate()
        connection = nil
        connectionGeneration = nil
        isBusy = true
        serviceStatus = "正在启动…"
        lastError = nil
        let operationID = UUID()
        serviceOperationID = operationID
        armServiceTimeout(id: operationID, operation: "启动")
        guard let connection = connectIfNeeded(),
              let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable [weak self] error in
                  Task { @MainActor in
                      guard let self, self.serviceOperationID == operationID else { return }
                      self.serviceOperationID = nil
                      self.isBusy = false
                      self.lastError = "后台服务启动失败：\(error.localizedDescription)"
                      self.refreshServiceStatus()
                  }
              }) as? EDPVaultXPCProtocol else {
            serviceOperationID = nil
            isBusy = false
            lastError = "无法建立后台服务连接"
            return
        }
        proxy.healthCheck { @Sendable [weak self] response in
            Task { @MainActor in
                guard let self, self.serviceOperationID == operationID else { return }
                guard response == "com.edp.drive.service:running" else {
                    self.lastError = "后台服务返回了无效健康状态"
                    self.isBusy = false
                    self.serviceOperationID = nil
                    return
                }
                self.serviceOperationID = nil
                self.isBusy = false
                self.serviceStatus = "运行中"
                self.retryTransientAutomaticMounts()
                self.refresh()
            }
        }
    }

    func stopService(restart: Bool = false, completion: (() -> Void)? = nil) {
        let activeConnection = connection ?? connectIfNeeded()
        guard let activeConnection,
              let proxy = activeConnection.remoteObjectProxyWithErrorHandler({ @Sendable [weak self] error in
                  Task { @MainActor in
                      guard let self else { return }
                      self.serviceDesiredRunning = true
                      self.persistServicePreference()
                      self.restartAfterStop = false
                      self.stopCompletion = nil
                      self.serviceOperationID = nil
                      self.isBusy = false
                      self.lastError = "后台服务停止失败：\(error.localizedDescription)"
                      self.refreshServiceStatus()
                  }
              }) as? EDPVaultXPCProtocol else {
            if launchdServiceIsRunning() {
                serviceDesiredRunning = true
                persistServicePreference()
                restartAfterStop = false
                stopCompletion = nil
                serviceStatus = "运行中（XPC 不可用）"
                lastError = "后台服务仍在运行，但无法建立安全 XPC 连接；未执行强制终止。"
                return
            }
            serviceDesiredRunning = false
            persistServicePreference()
            restartAfterStop = false
            stopCompletion = nil
            serviceStatus = "已停止"
            if restart { startService() }
            else { completion?() }
            return
        }
        serviceDesiredRunning = false
        persistServicePreference()
        restartAfterStop = restart
        stopCompletion = restart ? nil : completion
        isBusy = true
        serviceStatus = restart ? "正在重启…" : "正在停止…"
        lastError = nil
        let operationID = UUID()
        serviceOperationID = operationID
        armServiceTimeout(id: operationID, operation: restart ? "重启" : "停止")
        proxy.requestGracefulShutdown { @Sendable [weak self] errorMessage in
            Task { @MainActor in
                guard let self, self.serviceOperationID == operationID else { return }
                if let errorMessage {
                    self.serviceDesiredRunning = true
                    self.persistServicePreference()
                    self.restartAfterStop = false
                    self.stopCompletion = nil
                    self.serviceOperationID = nil
                    self.isBusy = false
                    self.lastError = "后台服务停止失败：\(errorMessage)"
                    self.refreshServiceStatus()
                }
                // Success completes through XPC invalidation after the service
                // has torn down every session and exited normally.
            }
        }
    }

    func restartService() {
        stopService(restart: true)
    }

    func openServiceSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func refreshTransportRuntimeState() {
        let root = "/Library/Filesystems/macfuse.fs/Contents"
        let hostApp = root + "/Resources/macfuse.app"
        let genericModule = hostApp
            + "/Contents/Extensions/io.macfuse.app.fsmodule.macfuse.appex"
        let localModule = hostApp
            + "/Contents/Extensions/io.macfuse.app.fsmodule.macfuse-local.appex"
        let framework = root + "/Frameworks/MFMount.framework"
        transportRuntimeReady = FileManager.default.fileExists(atPath: hostApp)
            && FileManager.default.fileExists(atPath: genericModule)
            && FileManager.default.fileExists(atPath: localModule)
            && FileManager.default.fileExists(atPath: framework)
            && macFUSEModulesEnabledInSettings()
    }

    private func requireTransportRuntime() -> Bool {
        guard transportRuntimeReady == true else {
            lastError = "macFUSE Local 运行组件未安装或尚未启用，请重新打开 EDP Drive 或运行安装器。"
            return false
        }
        return true
    }

    func refresh() {
        refreshServiceStatus()
        refreshTransportRuntimeState()
        guard let proxy = proxy() else {
            let status = currentServiceStatus()
            if status == .requiresApproval {
                // Settings already presents the required approval state and
                // action. Avoid recreating a modal alert on every poll.
                lastError = nil
            } else if status != .enabled {
                lastError = serviceMode == "smappservice"
                    ? "后台服务尚未启用"
                    : "后台服务尚未安装或启动"
            }
            return
        }
        proxy.snapshot { @Sendable [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                do {
                    self.snapshot = try JSONDecoder().decode(EDPXPCSnapshot.self, from: data)
                    self.serviceStatus = "运行中"
                } catch {
                    self.lastError = String(data: data, encoding: .utf8) ?? error.localizedDescription
                }
                self.refreshServiceStatus()
            }
        }
    }

    func openFullDiskAccessSettings() {
        guard FileManager.default.isExecutableFile(atPath: edpDriveServicePath) else {
            lastError = "磁盘访问组件尚未安装，请重新运行 EDP Drive 安装器。"
            return
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
            lastError = "无法打开完全磁盘访问设置。"
            return
        }
        NSWorkspace.shared.open(url)
    }

    func revealRawAccessHelper() {
        guard FileManager.default.isExecutableFile(atPath: edpDriveServicePath) else {
            lastError = "磁盘访问组件尚未安装，请重新运行 EDP Drive 安装器。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: edpDriveAppPath)
        ])
    }

    func refreshRawAccess() {
        guard let proxy = proxy() else { return }
        isBusy = true
        proxy.refreshRawAccess { @Sendable [weak self] errorMessage in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                self.lastError = errorMessage
                self.refresh()
            }
        }
    }

    private func retryTransientAutomaticMounts() {
        guard let proxy = proxy() else { return }
        proxy.retryTransientAutomaticMounts { @Sendable [weak self] errorMessage in
            Task { @MainActor in
                guard let self else { return }
                if let errorMessage { self.lastError = errorMessage }
                self.refresh()
            }
        }
    }

    func saveCredential(deviceID: String, partitionType: UInt32, password: String) {
        guard requireTransportRuntime(), !password.isEmpty, let proxy = proxy() else { return }
        isBusy = true
        proxy.saveCredential(
            deviceID: deviceID,
            partitionType: partitionType,
            password: Data(password.utf8)
        ) { @Sendable [weak self] errorMessage in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                self.lastError = errorMessage
                self.refresh()
            }
        }
    }

    func mountPartition(deviceID: String, partitionType: UInt32) {
        guard requireTransportRuntime(), let proxy = proxy() else { return }
        isBusy = true
        proxy.mountPartition(deviceID: deviceID, partitionType: partitionType) { @Sendable [weak self] errorMessage in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                self.lastError = errorMessage
                self.refresh()
            }
        }
    }

    func mountAllAvailablePartitions(_ device: EDPXPCDevice) {
        guard requireTransportRuntime() else { return }
        let partitionTypes = device.partitions.compactMap { partition -> UInt32? in
            guard partition.mountState != .mounted,
                  !partition.encrypted || partition.credentialStatus == .saved else {
                return nil
            }
            return partition.partitionType
        }
        guard !partitionTypes.isEmpty else { return }
        isBusy = true
        mountNextPartition(deviceID: device.deviceID, remaining: partitionTypes)
    }

    private func mountNextPartition(deviceID: String, remaining: [UInt32]) {
        guard let partitionType = remaining.first else {
            isBusy = false
            refresh()
            return
        }
        guard let proxy = proxy() else {
            isBusy = false
            return
        }
        proxy.mountPartition(deviceID: deviceID, partitionType: partitionType) { @Sendable [weak self] errorMessage in
            Task { @MainActor in
                guard let self else { return }
                if let errorMessage {
                    self.isBusy = false
                    self.lastError = errorMessage
                    self.refresh()
                    return
                }
                self.mountNextPartition(deviceID: deviceID, remaining: Array(remaining.dropFirst()))
            }
        }
    }

    func unmountAllMountedPartitions(_ device: EDPXPCDevice) {
        let partitionTypes = device.partitions.compactMap { partition in
            partition.mountState == .mounted ? partition.partitionType : nil
        }
        guard !partitionTypes.isEmpty else { return }
        isBusy = true
        unmountNextPartition(deviceID: device.deviceID, remaining: partitionTypes)
    }

    private func unmountNextPartition(deviceID: String, remaining: [UInt32]) {
        guard let partitionType = remaining.first else {
            isBusy = false
            refresh()
            return
        }
        guard let proxy = proxy() else {
            isBusy = false
            return
        }
        proxy.unmountPartition(deviceID: deviceID, partitionType: partitionType) { @Sendable [weak self] errorMessage in
            Task { @MainActor in
                guard let self else { return }
                if let errorMessage {
                    self.isBusy = false
                    self.lastError = errorMessage
                    self.refresh()
                    return
                }
                self.unmountNextPartition(deviceID: deviceID, remaining: Array(remaining.dropFirst()))
            }
        }
    }

    func unmountPartition(deviceID: String, partitionType: UInt32) {
        guard let proxy = proxy() else { return }
        isBusy = true
        proxy.unmountPartition(deviceID: deviceID, partitionType: partitionType) { @Sendable [weak self] errorMessage in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                self.lastError = errorMessage
                self.refresh()
            }
        }
    }

    func deleteCredential(deviceID: String, partitionType: UInt32) {
        guard let proxy = proxy() else { return }
        isBusy = true
        proxy.deleteCredential(deviceID: deviceID, partitionType: partitionType) { @Sendable [weak self] errorMessage in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                self.lastError = errorMessage
                self.refresh()
            }
        }
    }

    func deleteDeviceRecord(deviceID: String) {
        guard let proxy = proxy() else { return }
        isBusy = true
        proxy.deleteDeviceRecord(deviceID: deviceID) { @Sendable [weak self] errorMessage in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                self.lastError = errorMessage
                self.refresh()
            }
        }
    }

    func setAutoMount(deviceID: String, partitionType: UInt32, enabled: Bool) {
        guard let proxy = proxy() else { return }
        proxy.setPartitionAutoMount(
            deviceID: deviceID,
            partitionType: partitionType,
            enabled: enabled
        ) { @Sendable [weak self] errorMessage in
            Task { @MainActor in
                self?.lastError = errorMessage
                self?.refresh()
            }
        }
    }

    func setGlobalAutoMount(_ enabled: Bool) {
        guard let proxy = proxy() else { return }
        proxy.setGlobalAutoMount(enabled: enabled) { @Sendable [weak self] errorMessage in
            Task { @MainActor in
                self?.lastError = errorMessage
                self?.refresh()
            }
        }
    }

    func rename(deviceID: String, displayName: String) {
        guard let proxy = proxy() else { return }
        proxy.setDeviceDisplayName(deviceID: deviceID, displayName: displayName) { @Sendable [weak self] errorMessage in
            Task { @MainActor in
                self?.lastError = errorMessage
                self?.refresh()
            }
        }
    }

    func openInFinder(_ partition: EDPXPCPartition) {
        guard let mountPoint = partition.mountPoint, !mountPoint.isEmpty else { return }
        let url = URL(fileURLWithPath: mountPoint, isDirectory: true)
        guard NSWorkspace.shared.open(url) else {
            lastError = "Finder 无法打开挂载目录：\(mountPoint)"
            return
        }
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
            .first?
            .activate(options: [.activateAllWindows])
    }

    func eject(deviceID: String) {
        guard let proxy = proxy() else { return }
        isBusy = true
        proxy.eject(deviceID: deviceID) { @Sendable [weak self] errorMessage in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                self.lastError = errorMessage
                self.refresh()
            }
        }
    }

    func loadDiagnostics() {
        guard let proxy = proxy() else { return }
        proxy.diagnostics { @Sendable [weak self] data in
            Task { @MainActor in
                self?.diagnostics = String(decoding: data, as: UTF8.self)
            }
        }
    }
}

private enum EDPMainSection: String, CaseIterable, Identifiable {
    case overview = "总览"
    case devices = "设备"
    case activity = "活动"
    case settings = "设置"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .devices: return "externaldrive"
        case .activity: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

private enum EDPDeviceSection: String, CaseIterable, Identifiable {
    case overview = "概览"
    case partitions = "分区"
    case security = "安全"

    var id: String { rawValue }
}

struct EDPCredentialTarget: Identifiable {
    let deviceID: String
    let partitionType: UInt32
    let partitionName: String
    var id: String { "\(deviceID):\(partitionType)" }
}

struct EDPMainView: View {
    @ObservedObject var model: EDPVaultViewModel
    @State private var section: EDPMainSection? = .overview
    @StateObject private var splitBridge = EDPNativeSplitBridge()

    var body: some View {
        EDPNativeSplitView(model: model, section: $section, bridge: splitBridge)
            .frame(minWidth: 900, minHeight: 620)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { splitBridge.toggleSidebar() } label: {
                        Label("显示或隐藏侧栏", systemImage: "sidebar.leading")
                    }
                    .labelStyle(.iconOnly)
                    .focusEffectDisabled()
                    .help("显示或隐藏侧栏")
                }
            }
            .alert("操作失败", isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } }
            )) {
                Button("好") { model.lastError = nil }
            } message: {
                Text(model.lastError ?? "未知错误")
            }
    }
}

@MainActor
private final class EDPNativeSplitBridge: ObservableObject {
    weak var controller: EDPNativeSplitViewController?

    func toggleSidebar() {
        controller?.toggleSidebar(nil)
    }
}

private struct EDPNativeSplitView: NSViewControllerRepresentable {
    @ObservedObject var model: EDPVaultViewModel
    @Binding var section: EDPMainSection?
    @ObservedObject var bridge: EDPNativeSplitBridge

    func makeNSViewController(context: Context) -> EDPNativeSplitViewController {
        let controller = EDPNativeSplitViewController(model: model, section: $section)
        bridge.controller = controller
        return controller
    }

    func updateNSViewController(_ nsViewController: EDPNativeSplitViewController, context: Context) {
        nsViewController.update(model: model, section: $section)
        bridge.controller = nsViewController
    }
}

private struct EDPNativeSidebarView: View {
    @Binding var section: EDPMainSection?

    var body: some View {
        List(EDPMainSection.allCases, selection: $section) { item in
            Label(item.rawValue, systemImage: item.icon)
                .padding(.vertical, 3)
                .tag(item)
        }
        .listStyle(.sidebar)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EDPNativeDetailView: View {
    @ObservedObject var model: EDPVaultViewModel
    let section: EDPMainSection?

    var body: some View {
        ZStack {
            EDPWindowBackdrop()
            switch section ?? .overview {
            case .overview: EDPOverviewView(model: model)
            case .devices: EDPDevicesView(model: model)
            case .activity: EDPActivityView(model: model)
            case .settings: EDPSettingsView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private final class EDPNativeSplitViewController: NSSplitViewController {
    private let sidebarHost: NSHostingController<EDPNativeSidebarView>
    private let detailHost: NSHostingController<EDPNativeDetailView>

    init(model: EDPVaultViewModel, section: Binding<EDPMainSection?>) {
        sidebarHost = NSHostingController(rootView: EDPNativeSidebarView(section: section))
        detailHost = NSHostingController(
            rootView: EDPNativeDetailView(model: model, section: section.wrappedValue)
        )
        super.init(nibName: nil, bundle: nil)

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        minimumThicknessForInlineSidebars = 0

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 220
        sidebarItem.canCollapse = true
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView

        let detailItem = NSSplitViewItem(viewController: detailHost)
        detailItem.minimumThickness = 500

        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(model: EDPVaultViewModel, section: Binding<EDPMainSection?>) {
        sidebarHost.rootView = EDPNativeSidebarView(section: section)
        detailHost.rootView = EDPNativeDetailView(model: model, section: section.wrappedValue)
    }

}

struct EDPOverviewView: View {
    @ObservedObject var model: EDPVaultViewModel

    private var primaryDevice: EDPXPCDevice? {
        model.snapshot.devices.first(where: \.connected) ?? model.snapshot.devices.first
    }

    private var firstFinderPartition: EDPXPCPartition? {
        primaryDevice?.partitions.first { $0.mountState == .mounted && $0.mountPoint != nil }
    }

    private var mountablePartitionCount: Int {
        primaryDevice?.partitions.filter {
            $0.mountState != .mounted && (!$0.encrypted || $0.credentialStatus == .saved)
        }.count ?? 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EDPTheme.Spacing.lg) {
                deviceHero
                systemStatusStrip

                if let device = primaryDevice {
                    partitionStructure(device)
                    quickActions(device)
                }

                recentActivity
            }
            .padding(EDPTheme.Spacing.lg)
        }
        .navigationTitle("总览")
        .toolbar {
            ToolbarItem {
                Button { model.refresh() } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .help("刷新设备与服务状态")
            }
        }
    }

    @ViewBuilder
    private var deviceHero: some View {
        if let device = primaryDevice {
            EDPContentCard {
                HStack(spacing: EDPTheme.Spacing.md) {
                    Image(systemName: device.connected ? "externaldrive.fill" : "externaldrive")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(device.connected ? Color.accentColor : .secondary)
                        .frame(width: 62, height: 62)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(device.displayName)
                                .font(.title2.weight(.semibold))
                            EDPStatusPill(
                                title: device.connected ? "已连接" : "已保存",
                                systemImage: device.connected ? "checkmark.circle.fill" : "circle.dashed",
                                tone: device.connected ? .success : .neutral
                            )
                        }
                        Text(device.mediaName)
                            .foregroundStyle(.secondary)
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(device.sizeBytes), countStyle: .file)) · USB · \(device.vidPID)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        } else {
            EDPEmptyState(
                "未发现 EDP U 盘",
                message: "插入标准 EDP 加密盘后会自动识别；普通 U 盘和免密改造盘继续由 macOS 接管。",
                systemImage: "externaldrive.badge.questionmark"
            )
        }
    }

    private var systemStatusStrip: some View {
        VStack(alignment: .leading, spacing: EDPTheme.Spacing.sm) {
            EDPSectionHeader(
                "系统状态",
                subtitle: "关键集成状态一览",
                systemImage: "checklist"
            )
            EDPContentCard(padding: 0) {
                HStack(spacing: 0) {
                    EDPOverviewStatusCell(
                        title: "后台服务",
                        value: model.serviceStatus,
                        systemImage: "gearshape.2",
                        ready: model.serviceStatus == "运行中"
                    )
                    Divider().frame(height: 42)
                    EDPOverviewStatusCell(
                        title: "磁盘访问",
                        value: model.rawAccessStatusText,
                        systemImage: "externaldrive.badge.checkmark",
                        ready: primaryDevice?.privilegedAccessReady == true || !model.needsFullDiskAccess
                    )
                    Divider().frame(height: 42)
                    EDPOverviewStatusCell(
                        title: "macFUSE Local",
                        value: model.transportRuntimeReady == true ? "已就绪" : "需安装",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        ready: model.transportRuntimeReady == true
                    )
                    Divider().frame(height: 42)
                    EDPOverviewStatusCell(
                        title: "自动挂载",
                        value: model.snapshot.globalAutoMountEnabled ? "已开启" : "已暂停",
                        systemImage: "bolt.horizontal.circle",
                        ready: model.snapshot.globalAutoMountEnabled
                    )
                }
            }
        }
    }

    private func partitionStructure(_ device: EDPXPCDevice) -> some View {
        VStack(alignment: .leading, spacing: EDPTheme.Spacing.sm) {
            EDPSectionHeader(
                "分区结构",
                subtitle: "当前设备的启动区、交换区与保密区",
                systemImage: "rectangle.split.3x1"
            )
            HStack(spacing: 8) {
                ForEach(device.partitions) { partition in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Image(systemName: partitionIcon(partition))
                            Text(partition.displayName)
                                .font(.headline)
                            Spacer(minLength: 4)
                        }
                        Text(partition.filesystem ?? (partition.encrypted ? "加密" : "文件系统待检测"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(partitionStatus(partition))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(partition.mountState == .failed ? .red : .secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    private func quickActions(_ device: EDPXPCDevice) -> some View {
        EDPGlassToolbar {
            HStack(spacing: 10) {
                if let partition = firstFinderPartition {
                    Button("在 Finder 中显示") { model.openInFinder(partition) }
                        .buttonStyle(.glass)
                }
                Button("挂载全部") { model.mountAllAvailablePartitions(device) }
                    .buttonStyle(.glassProminent)
                    .disabled(!device.connected || model.isBusy || mountablePartitionCount == 0)
                Button("安全推出整盘") { model.eject(deviceID: device.deviceID) }
                    .buttonStyle(.glass)
                    .disabled(!device.connected || model.isBusy)
                Spacer()
                Text("\(device.partitions.filter { $0.mountState == .mounted }.count) / \(device.partitions.count) 已挂载")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: EDPTheme.Spacing.sm) {
            EDPSectionHeader(
                "最近活动",
                subtitle: "最新的设备与挂载事件",
                systemImage: "clock.arrow.circlepath"
            )
            if model.snapshot.activities.isEmpty {
                Text("暂无活动记录")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.snapshot.activities.prefix(5)).indices, id: \.self) { index in
                        let activity = model.snapshot.activities[index]
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: activity.level == "error" ? "exclamationmark.triangle.fill" : "circle.fill")
                                .font(.caption2)
                                .foregroundStyle(activity.level == "error" ? .red : .secondary)
                            Text(activity.message)
                                .lineLimit(2)
                            Spacer()
                            Text(activity.timestamp)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 9)
                        if index < min(4, model.snapshot.activities.count - 1) {
                            Divider().padding(.leading, 20)
                        }
                    }
                }
            }
        }
    }

    private func partitionIcon(_ partition: EDPXPCPartition) -> String {
        switch EDPPartitionKind(rawValue: partition.partitionType) {
        case .boot: return "shippingbox"
        case .exchange: return "arrow.left.arrow.right"
        case .secure: return "lock.shield"
        case nil: return "externaldrive"
        }
    }

    private func partitionStatus(_ partition: EDPXPCPartition) -> String {
        switch partition.mountState {
        case .mounted: return partition.readOnly == true ? "已挂载 · 只读" : "已挂载"
        case .mounting: return "正在挂载"
        case .failed: return "挂载失败"
        case .unavailable: return "不可用"
        case .unmounted:
            if partition.encrypted && partition.credentialStatus != .saved { return "未挂载 · 需要密码" }
            return "未挂载"
        }
    }
}

private struct EDPOverviewStatusCell: View {
    let title: String
    let value: String
    let systemImage: String
    let ready: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                Circle()
                    .fill(ready ? Color.green : Color.secondary.opacity(0.65))
                    .frame(width: 7, height: 7)
                Text(value)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct EDPDevicesView: View {
    @ObservedObject var model: EDPVaultViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedDeviceID: String?

    private var selectedDevice: EDPXPCDevice? {
        if let selectedDeviceID,
           let selected = model.snapshot.devices.first(where: { $0.deviceID == selectedDeviceID }) {
            return selected
        }
        return model.snapshot.devices.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.needsFullDiskAccess {
                EDPNoticeBanner(
                    title: "需要完全磁盘访问",
                    message: "EDP U 盘已识别。为“EDP Drive 磁盘访问”开启一次即可。",
                    systemImage: "externaldrive.badge.exclamationmark",
                    tone: .warning
                ) {
                    Button("显示组件") { model.revealRawAccessHelper() }
                        .buttonStyle(.glass)
                    Button("打开完全磁盘访问") { model.openFullDiskAccessSettings() }
                        .buttonStyle(.glassProminent)
                    Button("重新检测") { model.refreshRawAccess() }
                        .buttonStyle(.glass)
                        .disabled(model.isBusy)
                }
                .padding(EDPTheme.Spacing.sm)
            }

            Group {
                if let selectedDevice {
                    EDPDeviceDetailView(device: selectedDevice, model: model)
                        .id(selectedDevice.deviceID)
                        .transition(.opacity)
                } else {
                    EDPEmptyState(
                        "未发现 EDP U 盘",
                        message: "插入设备后会自动识别，也可以查看此前保存的设备。",
                        systemImage: "externaldrive.badge.questionmark"
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(
                reduceMotion ? EDPTheme.Motion.reduced : EDPTheme.Motion.navigation,
                value: selectedDeviceID
            )
        }
        .navigationTitle("设备")
        .toolbar {
            ToolbarItemGroup {
                Picker("切换设备", selection: deviceSelection) {
                    if model.snapshot.devices.isEmpty {
                        Text("未发现设备").tag("")
                    } else {
                        ForEach(model.snapshot.devices) { device in
                            Text("\(device.displayName) · \(device.connected ? "已连接" : "已保存")")
                                .tag(device.deviceID)
                        }
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 170)
                .disabled(model.snapshot.devices.isEmpty)
                .help("切换当前管理的 EDP 设备")
                .accessibilityLabel("切换设备")

                Button { model.refresh() } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
            }
        }
        .onAppear {
            if selectedDeviceID == nil {
                selectedDeviceID = model.snapshot.devices.first(where: \.connected)?.deviceID
                    ?? model.snapshot.devices.first?.deviceID
            }
        }
        .onChange(of: model.snapshot.devices.map { "\($0.deviceID):\($0.connected)" }) { _, _ in
            let selectedIsConnected = model.snapshot.devices.first {
                $0.deviceID == selectedDeviceID
            }?.connected == true
            if !selectedIsConnected,
               let connected = model.snapshot.devices.first(where: \.connected) {
                selectedDeviceID = connected.deviceID
            } else if selectedDeviceID == nil
                        || !model.snapshot.devices.contains(where: { $0.deviceID == selectedDeviceID }) {
                selectedDeviceID = model.snapshot.devices.first?.deviceID
            }
        }
    }

    private var deviceSelection: Binding<String> {
        Binding(
            get: { selectedDevice?.deviceID ?? "" },
            set: { selectedDeviceID = $0 }
        )
    }
}

struct EDPDeviceDetailView: View {
    let device: EDPXPCDevice
    @ObservedObject var model: EDPVaultViewModel
    @State private var credentialTarget: EDPCredentialTarget?
    @State private var displayName = ""
    @State private var confirmingRecordDeletion = false
    @State private var deviceSection: EDPDeviceSection = .overview

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("设备页面", selection: $deviceSection) {
                    ForEach(EDPDeviceSection.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .accessibilityLabel("设备页面")

                if deviceSection == .overview {
                EDPContentCard {
                    HStack(alignment: .center, spacing: EDPTheme.Spacing.md) {
                        Image(systemName: device.connected ? "externaldrive.fill" : "externaldrive")
                            .font(.system(size: 29, weight: .medium))
                            .foregroundStyle(device.connected ? Color.accentColor : .secondary)
                            .frame(width: 62, height: 62)
                            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                        VStack(alignment: .leading, spacing: 5) {
                            TextField("设备名称", text: $displayName)
                                .font(.title2.weight(.semibold))
                                .textFieldStyle(.plain)
                                .onSubmit {
                                    model.rename(deviceID: device.deviceID, displayName: displayName)
                                }
                            Text("\(device.vidPID) · \(ByteCountFormatter.string(fromByteCount: Int64(device.sizeBytes), countStyle: .file))")
                                .foregroundStyle(.secondary)
                            Text(device.deviceID)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .layoutPriority(-1)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        EDPStatusPill(
                            title: device.connected ? "已连接" : "未连接",
                            systemImage: device.connected ? "checkmark.circle.fill" : "circle.dashed",
                            tone: device.connected ? .success : .neutral
                        )
                        .fixedSize()
                    }
                }

                EDPContentCard(padding: 16) {
                    VStack(spacing: 10) {
                        LabeledContent("Media Name", value: device.mediaName)
                        Divider()
                        LabeledContent("VID / PID", value: device.vidPID)
                        LabeledContent("LBA4 onlyId", value: device.labelOnlyID.map(String.init) ?? "不可用")
                        LabeledContent("LBA11 deviceId", value: device.metadataDeviceID ?? "不可用")
                        Divider()
                        LabeledContent(
                            "整盘容量",
                            value: ByteCountFormatter.string(fromByteCount: Int64(device.sizeBytes), countStyle: .file)
                        )
                        LabeledContent("当前 BSD 名", value: device.bsdName.isEmpty ? "未连接" : device.bsdName)
                        LabeledContent("分区数", value: "\(device.partitions.count)")
                        LabeledContent("Raw Access", value: device.privilegedAccessReady ? "已就绪" : "未就绪")
                        Divider()
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Drive 内部稳定设备 ID")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(device.deviceID)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text("设备身份由 VID、PID、LBA4 onlyId、整盘容量和 LBA11 deviceId 共同确定；diskN 仅是当前动态名称。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                }

                if deviceSection == .partitions {
                EDPSectionHeader(
                    "分区",
                    subtitle: "\(device.partitions.filter { $0.mountState == .mounted }.count) / \(device.partitions.count) 已挂载",
                    systemImage: "rectangle.split.3x1"
                ) {
                    HStack(spacing: 8) {
                        Button("挂载全部") { model.mountAllAvailablePartitions(device) }
                            .buttonStyle(.glass)
                            .disabled(
                                model.isBusy || !device.connected
                                    || !device.partitions.contains {
                                        $0.mountState != .mounted
                                            && (!$0.encrypted || $0.credentialStatus == .saved)
                                    }
                            )
                        Button("卸载全部") { model.unmountAllMountedPartitions(device) }
                            .buttonStyle(.glass)
                            .disabled(model.isBusy || !device.partitions.contains { $0.mountState == .mounted })
                    }
                }

                ForEach(device.partitions) { partition in
                    EDPPartitionCard(
                        device: device,
                        partition: partition,
                        model: model,
                        onSetPassword: {
                            credentialTarget = EDPCredentialTarget(
                                deviceID: device.deviceID,
                                partitionType: partition.partitionType,
                                partitionName: partition.displayName
                            )
                        }
                    )
                }
                }

                if deviceSection == .security {
                    EDPSectionHeader(
                        "分区凭据",
                        subtitle: "交换区与保密区密码相互独立",
                        systemImage: "lock.shield"
                    )
                    ForEach(device.partitions.filter(\.encrypted)) { partition in
                        EDPContentCard(padding: 14) {
                            HStack(spacing: 12) {
                                Image(systemName: partition.partitionType == EDPPartitionKind.secure.rawValue ? "lock.shield" : "arrow.left.arrow.right.circle")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(partition.displayName)密码")
                                        .font(.headline)
                                    Text(partition.credentialStatus == .saved ? "已保存到系统钥匙串" : "尚未保存")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(partition.credentialStatus == .saved ? "更新" : "设置") {
                                    credentialTarget = EDPCredentialTarget(
                                        deviceID: device.deviceID,
                                        partitionType: partition.partitionType,
                                        partitionName: partition.displayName
                                    )
                                }
                                .buttonStyle(.glass)
                                if partition.credentialStatus == .saved {
                                    Button("删除", role: .destructive) {
                                        model.deleteCredential(
                                            deviceID: device.deviceID,
                                            partitionType: partition.partitionType
                                        )
                                    }
                                    .buttonStyle(.glass)
                                }
                            }
                        }
                    }

                    EDPSectionHeader(
                        "系统集成",
                        subtitle: "全局权限与文件系统运行组件",
                        systemImage: "gearshape.2"
                    )
                    EDPContentCard(padding: 14) {
                        VStack(spacing: 10) {
                            LabeledContent("完全磁盘访问", value: model.rawAccessStatusText)
                            LabeledContent("Raw Access", value: device.privilegedAccessReady ? "已就绪" : "未就绪")
                            LabeledContent(
                                "macFUSE Local",
                                value: model.transportRuntimeReady == true ? "已就绪" : "需要重新安装"
                            )
                            Divider()
                            HStack {
                                Button("打开系统设置") { model.openFullDiskAccessSettings() }
                                    .buttonStyle(.glass)
                                Button("重新检测权限") { model.refreshRawAccess() }
                                    .buttonStyle(.glass)
                                    .disabled(model.isBusy)
                                Spacer()
                            }
                        }
                    }
                }

                if deviceSection == .overview {
                HStack {
                    Button("安全推出整盘") { model.eject(deviceID: device.deviceID) }
                        .buttonStyle(.glass)
                        .disabled(!device.connected || model.isBusy)
                    if !device.connected {
                        Button("删除设备记录", role: .destructive) {
                            confirmingRecordDeletion = true
                        }
                        .buttonStyle(.glass)
                        .disabled(model.isBusy)
                    }
                    Spacer()
                    Text("关闭窗口不会停止自动挂载服务")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                }
            }
            .padding(EDPTheme.Spacing.lg)
        }
        .onAppear { displayName = device.displayName }
        .onChange(of: device.displayName) { _, value in displayName = value }
        .sheet(item: $credentialTarget) { target in
            EDPCredentialSheet(target: target, model: model)
        }
        .alert("删除此 U 盘记录？", isPresented: $confirmingRecordDeletion) {
            Button("删除记录", role: .destructive) {
                model.deleteDeviceRecord(deviceID: device.deviceID)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除这台 Mac 上保存的设备名称、自动挂载设置和分区密码，不会擦除 U 盘中的任何数据。")
        }
    }
}

struct EDPPartitionCard: View {
    let device: EDPXPCDevice
    let partition: EDPXPCPartition
    @ObservedObject var model: EDPVaultViewModel
    let onSetPassword: () -> Void

    private var mounted: Bool { partition.mountState == .mounted }

    var body: some View {
        EDPContentCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.title3)
                        .frame(width: 30)
                        .foregroundStyle(mounted ? Color.accentColor : .secondary)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(partition.displayName)
                                .font(.headline)
                            statusBadge
                        }
                        Text(partitionSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Toggle("自动挂载", isOn: Binding(
                        get: { partition.autoMount },
                        set: {
                            model.setAutoMount(
                                deviceID: device.deviceID,
                                partitionType: partition.partitionType,
                                enabled: $0
                            )
                        }
                    ))
                    .toggleStyle(.switch)
                    .fixedSize()
                    .disabled(!device.connected && partition.partitionType == EDPPartitionKind.boot.rawValue)

                    if mounted, partition.mountPoint != nil {
                        Button("Finder") { model.openInFinder(partition) }
                            .buttonStyle(.glass)
                    }

                    if mounted {
                        Button("卸载") {
                            model.unmountPartition(
                                deviceID: device.deviceID,
                                partitionType: partition.partitionType
                            )
                        }
                        .buttonStyle(.glass)
                        .disabled(model.isBusy)
                    } else {
                        Button("挂载") {
                            model.mountPartition(
                                deviceID: device.deviceID,
                                partitionType: partition.partitionType
                            )
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(
                            !device.connected || model.isBusy
                                || (partition.encrypted && partition.credentialStatus != .saved)
                        )
                    }

                    if partition.encrypted {
                        Menu {
                            Button(partition.credentialStatus == .saved ? "更新密码" : "设置密码") {
                                onSetPassword()
                            }
                            if partition.credentialStatus == .saved {
                                Button("删除密码", role: .destructive) {
                                    model.deleteCredential(
                                        deviceID: device.deviceID,
                                        partitionType: partition.partitionType
                                    )
                                }
                            }
                            if mounted {
                                Divider()
                                Text("可在 Finder 中抹掉并格式化为 ExFAT")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("更多分区操作")
                        .accessibilityLabel("\(partition.displayName)更多操作")
                    }
                }

                if let error = partition.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var icon: String {
        switch EDPPartitionKind(rawValue: partition.partitionType) {
        case .boot: return "shippingbox"
        case .exchange: return "arrow.left.arrow.right"
        case .secure: return "lock.shield"
        case nil: return "externaldrive"
        }
    }

    private var description: String {
        switch EDPPartitionKind(rawValue: partition.partitionType) {
        case .boot: return "普通启动分区，无需密码"
        case .exchange: return "受控交换分区"
        case .secure: return "保密资料分区"
        case nil: return "EDP 分区"
        }
    }

    private var partitionSummary: String {
        var parts = [description]
        if let filesystem = partition.filesystem, !filesystem.isEmpty {
            parts.append(filesystem)
        }
        if mounted, partition.readOnly == true {
            parts.append("只读")
        }
        if partition.encrypted {
            parts.append(partition.credentialStatus == .saved ? "密码已保存" : "缺少密码")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var statusBadge: some View {
        let title = mounted ? (partition.readOnly == true ? "只读" : "已挂载")
            : (partition.credentialStatus == .saved ? "密码已保存" : "未挂载")
        EDPStatusPill(
            title: title,
            systemImage: mounted ? "checkmark.circle.fill" : "circle",
            tone: mounted ? .success : .neutral
        )
    }
}

struct EDPCredentialSheet: View {
    let target: EDPCredentialTarget
    @ObservedObject var model: EDPVaultViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            EDPSectionHeader(
                "设置\(target.partitionName)密码",
                subtitle: "安全验证后保存到系统钥匙串",
                systemImage: "key.fill"
            )
            Text("密码会先在当前 U 盘上验证，成功后才保存到系统钥匙串。应用不会修改盘上的密码。")
                .foregroundStyle(.secondary)
            SecureField("现有分区密码", text: $password)
                .textFieldStyle(.roundedBorder)
            EDPGlassToolbar {
                HStack {
                    Spacer()
                    Button("取消") { dismiss() }
                        .buttonStyle(.glass)
                        .keyboardShortcut(.cancelAction)
                    Button("验证并保存") {
                        model.saveCredential(
                            deviceID: target.deviceID,
                            partitionType: target.partitionType,
                            password: password
                        )
                        password = ""
                        dismiss()
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || model.isBusy)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .background { EDPWindowBackdrop() }
    }
}

private enum EDPActivityFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case device = "设备"
    case mount = "挂载"
    case security = "安全"
    case error = "错误"

    var id: String { rawValue }
}

struct EDPActivityView: View {
    @ObservedObject var model: EDPVaultViewModel
    @State private var filter: EDPActivityFilter = .all

    private var filteredActivities: [EDPXPCActivity] {
        model.snapshot.activities.filter { activity in
            switch filter {
            case .all:
                return true
            case .device:
                return activity.deviceID != nil && activity.partitionType == nil && activity.level != "error"
            case .mount:
                return activity.partitionType != nil
                    || activity.message.contains("挂载")
                    || activity.message.contains("卸载")
                    || activity.message.contains("推出")
            case .security:
                return activity.message.contains("密码")
                    || activity.message.contains("凭据")
                    || activity.message.contains("权限")
                    || activity.message.contains("磁盘访问")
            case .error:
                return activity.level == "error"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("活动筛选", selection: $filter) {
                ForEach(EDPActivityFilter.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
            .padding(.top, EDPTheme.Spacing.lg)
            .padding(.horizontal, EDPTheme.Spacing.lg)
            .accessibilityLabel("活动筛选")

            if model.snapshot.activities.isEmpty {
                EDPEmptyState(
                    "暂无活动记录",
                    message: "设备插入、挂载和凭据变更会显示在这里。",
                    systemImage: "clock.arrow.circlepath"
                )
            } else if filteredActivities.isEmpty {
                EDPEmptyState(
                    "当前筛选没有记录",
                    message: "切换上方筛选条件查看其他活动。",
                    systemImage: "line.3.horizontal.decrease.circle"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredActivities.enumerated()), id: \.element.id) { index, activity in
                            EDPActivityTimelineRow(activity: activity, isLast: index == filteredActivities.count - 1)
                        }
                    }
                    .padding(.horizontal, EDPTheme.Spacing.lg)
                    .padding(.vertical, EDPTheme.Spacing.md)
                }
            }
        }
        .navigationTitle("活动")
    }
}

private struct EDPActivityTimelineRow: View {
    let activity: EDPXPCActivity
    let isLast: Bool

    private var isError: Bool { activity.level == "error" }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: isError ? "exclamationmark.circle.fill" : "circle.fill")
                    .font(isError ? .callout : .caption2)
                    .foregroundStyle(isError ? Color.red : Color.secondary)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: 1)
                        .frame(minHeight: 42)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(activity.message)
                    .font(.body)
                    .foregroundStyle(isError ? Color.red : Color.primary)
                HStack(spacing: 6) {
                    Text(activity.timestamp)
                    if let type = activity.partitionType,
                       let kind = EDPPartitionKind(rawValue: type) {
                        Text("·")
                        Text(kind.displayName)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.bottom, isLast ? 0 : 16)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct EDPSettingsView: View {
    @ObservedObject var model: EDPVaultViewModel
    @State private var showingDiagnostics = false
    @State private var loginItemEnabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EDPTheme.Spacing.lg) {
                EDPSectionHeader(
                    "常规",
                    subtitle: "EDP Drive 的全局行为",
                    systemImage: "switch.2"
                )
                EDPContentCard(padding: 0) {
                    VStack(spacing: 0) {
                        settingsToggleRow(
                            title: "全局自动挂载",
                            subtitle: "允许已配置设备按各分区策略自动挂载",
                            isOn: Binding(
                                get: { model.snapshot.globalAutoMountEnabled },
                                set: { model.setGlobalAutoMount($0) }
                            )
                        )
                        Divider().padding(.leading, 48)
                        settingsToggleRow(
                            title: "登录时启动 EDP Drive",
                            subtitle: "登录后启动菜单栏界面，不改变后台服务策略",
                            isOn: Binding(
                                get: { loginItemEnabled },
                                set: { updateLoginItem($0) }
                            )
                        )
                    }
                }

                EDPSectionHeader(
                    "系统集成",
                    subtitle: "磁盘访问、Raw Access 与 macFUSE Local",
                    systemImage: "externaldrive.connected.to.line.below"
                )
                EDPContentCard(padding: 16) {
                    VStack(spacing: 12) {
                        settingsStatusRow(
                            title: "完全磁盘访问",
                            value: model.rawAccessStatusText,
                            ready: !model.needsFullDiskAccess
                        )
                        Divider()
                        settingsStatusRow(
                            title: "Raw Access",
                            value: model.snapshot.devices.contains { $0.connected && $0.privilegedAccessReady }
                                ? "已就绪" : (model.needsFullDiskAccess ? "需要授权" : "等待设备验证"),
                            ready: model.snapshot.devices.contains { $0.connected && $0.privilegedAccessReady }
                        )
                        Divider()
                        settingsStatusRow(
                            title: "macFUSE Local",
                            value: model.transportRuntimeReady == true ? "已就绪" : "需要重新安装",
                            ready: model.transportRuntimeReady == true
                        )
                        Divider()
                        Text(setupDescription)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 8) {
                            Button("打开系统设置") { model.openFullDiskAccessSettings() }
                                .buttonStyle(.glass)
                            Button("重新检测权限") { model.refreshRawAccess() }
                                .buttonStyle(.glassProminent)
                                .disabled(model.isBusy)
                            Button("显示组件") { model.revealRawAccessHelper() }
                                .buttonStyle(.glass)
                            Spacer()
                        }
                    }
                }

                EDPSectionHeader(
                    "后台服务",
                    subtitle: "特权服务状态与生命周期",
                    systemImage: "gearshape.2"
                )
                EDPContentCard(padding: 16) {
                    VStack(spacing: 12) {
                        settingsStatusRow(
                            title: "状态",
                            value: model.serviceStatus,
                            ready: model.serviceStatus == "运行中"
                        )
                        Divider()
                        LabeledContent("版本", value: model.snapshot.serviceVersion)
                        HStack(spacing: 8) {
                            Button("启动") { model.startService() }
                                .buttonStyle(.glassProminent)
                                .disabled(model.isBusy || model.serviceStatus == "运行中")
                            Button("停止") { model.stopService() }
                                .buttonStyle(.glass)
                                .disabled(model.isBusy || model.serviceStatus == "已停止")
                            Button("重启") { model.restartService() }
                                .buttonStyle(.glass)
                                .disabled(model.isBusy || model.serviceStatus != "运行中")
                            Spacer()
                            if model.serviceStatus == "需要系统批准" {
                                Button("打开登录项与扩展设置") { model.openServiceSettings() }
                                    .buttonStyle(.glass)
                            }
                        }
                    }
                }

                EDPSectionHeader(
                    "高级",
                    subtitle: "诊断和低频维护工具",
                    systemImage: "wrench.and.screwdriver"
                )
                EDPContentCard(padding: 16) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("诊断信息")
                                .font(.headline)
                            Text("查看服务、设备、挂载和运行组件诊断输出")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("查看诊断") {
                            model.diagnostics = ""
                            model.loadDiagnostics()
                            showingDiagnostics = true
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            .padding(EDPTheme.Spacing.lg)
        }
        .navigationTitle("设置")
        .sheet(isPresented: $showingDiagnostics) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("诊断信息")
                        .font(.headline)
                    Spacer()
                    Button("复制诊断") { copyDiagnostics() }
                        .buttonStyle(.glass)
                        .disabled(model.diagnostics.isEmpty)
                    Button("关闭") { showingDiagnostics = false }
                        .buttonStyle(.glassProminent)
                }
                Divider()
                ScrollView {
                    Text(model.diagnostics.isEmpty ? "正在读取…" : model.diagnostics)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            .frame(width: 680, height: 460)
            .background { EDPWindowBackdrop() }
        }
    }

    private var setupDescription: String {
        if model.setupReady {
            return "系统集成已就绪。后台服务按需打开经校验的 EDP 整盘；App、Mac 重启或重新插盘不需要重复管理员授权。"
        }
        if model.needsFullDiskAccess {
            return "请为 EDP Drive 磁盘访问组件开启一次完全磁盘访问，然后重新检测权限。"
        }
        return "完全磁盘访问会在连接标准 EDP 加密盘后进行验证；macFUSE Local 必须保持可用。"
    }

    @ViewBuilder
    private func settingsToggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    @ViewBuilder
    private func settingsStatusRow(title: String, value: String, ready: Bool) -> some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer()
            Circle()
                .fill(ready ? Color.green : Color.secondary.opacity(0.65))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(value)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.diagnostics, forType: .string)
    }

    private func updateLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginItemEnabled = enabled
        } catch {
            model.lastError = "登录项更新失败：\(error.localizedDescription)"
            loginItemEnabled = SMAppService.mainApp.status == .enabled
        }
    }
}

struct EDPMenuBarView: View {
    @ObservedObject var model: EDPVaultViewModel
    @Environment(\.openWindow) private var openWindow

    private var connectedDevices: [EDPXPCDevice] {
        model.snapshot.devices.filter(\.connected)
    }

    private var serviceIsRunning: Bool {
        model.serviceStatus == "运行中"
    }

    private var serviceIsStopped: Bool {
        model.serviceStatus == "已停止"
    }

    private var bodyHeight: CGFloat {
        let partitionCount = connectedDevices.reduce(0) { $0 + $1.partitions.count }
        let estimated = 288 + connectedDevices.count * 58 + partitionCount * 52
        return min(520, max(340, CGFloat(estimated)))
    }

    var body: some View {
        VStack(spacing: 0) {
            EDPMenuPanelHeader(title: "EDP Drive", subtitle: "标准 EDP 加密盘")

            ScrollView {
                VStack(spacing: 0) {
                    openMainAppRow

                    Divider().padding(.horizontal, 12)
                    serviceControls

                    Divider().padding(.horizontal, 12)
                    autoMountRow

                    Divider().padding(.horizontal, 12)
                    devicesSection

                    if !connectedDevices.isEmpty && model.needsFullDiskAccess {
                        Divider().padding(.horizontal, 12)
                        permissionSection
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(height: bodyHeight)

            Divider().padding(.horizontal, 12)
            footer
        }
        .frame(width: 390)
        .background(.clear)
        .onAppear { model.refresh() }
    }

    private var openMainAppRow: some View {
        EDPMenuNavigationRow(
            title: "打开 EDP Drive",
            subtitle: "设备、密码与自动挂载设置",
            systemImage: "macwindow",
            trailingSystemImage: "arrow.up.forward.app"
        ) {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")
    }

    private var serviceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("后台服务", systemImage: "gearshape.2")
                    .font(.caption.weight(.semibold))
                Spacer()
                Label(
                    model.serviceStatus,
                    systemImage: serviceIsRunning ? "checkmark.circle.fill" : "circle"
                )
                .font(.caption)
                .foregroundStyle(serviceIsRunning ? Color.green : .secondary)
            }

            HStack(spacing: 8) {
                EDPMenuServiceButton(
                    title: "启动",
                    systemImage: "play.fill",
                    isEnabled: !model.isBusy && !serviceIsRunning
                ) {
                    model.startService()
                }
                EDPMenuServiceButton(
                    title: "停止",
                    systemImage: "stop.fill",
                    isEnabled: !model.isBusy && !serviceIsStopped
                ) {
                    model.stopService()
                }
                EDPMenuServiceButton(
                    title: "重启",
                    systemImage: "arrow.clockwise",
                    isEnabled: !model.isBusy && serviceIsRunning
                ) {
                    model.restartService()
                }
            }

            if model.serviceStatus == "需要系统批准" {
                Button("打开登录项与扩展设置") { model.openServiceSettings() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(EDPTheme.quietFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(EDPTheme.cardStroke, lineWidth: 0.5)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private var autoMountRow: some View {
        EDPMenuNavigationRow(
            title: model.snapshot.globalAutoMountEnabled ? "暂停自动挂载" : "恢复自动挂载",
            subtitle: model.snapshot.globalAutoMountEnabled ? "当前自动挂载已启用" : "当前自动挂载已暂停",
            systemImage: model.snapshot.globalAutoMountEnabled ? "pause.circle" : "play.circle"
        ) {
            model.setGlobalAutoMount(!model.snapshot.globalAutoMountEnabled)
        }
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("设备与分区")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(connectedDevices.count) 台")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if connectedDevices.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: "externaldrive.badge.questionmark")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("未连接标准 EDP 加密盘")
                        Text("连接后可在此直接挂载分区")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            } else {
                ForEach(connectedDevices) { device in
                    deviceCard(device)
                }
            }
        }
        .padding(.bottom, 8)
    }

    private func deviceCard(_ device: EDPXPCDevice) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "externaldrive.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.displayName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(device.vidPID)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    model.eject(deviceID: device.deviceID)
                } label: {
                    Label("推出", systemImage: "eject")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(model.isBusy)
            }
            .padding(10)

            ForEach(device.partitions) { partition in
                Divider().padding(.leading, 36)
                partitionRow(device: device, partition: partition)
            }
        }
        .background(EDPTheme.quietFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(EDPTheme.cardStroke, lineWidth: 0.5)
        }
        .padding(.horizontal, 8)
    }

    private func partitionRow(device: EDPXPCDevice, partition: EDPXPCPartition) -> some View {
        HStack(spacing: 9) {
            Image(systemName: partitionIcon(partition))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(partition.mountState == .mounted ? Color.accentColor : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(partition.displayName)
                    .font(.caption.weight(.medium))
                Text(mountAvailabilityText(partition) ?? partitionStatus(partition))
                    .font(.caption2)
                    .foregroundStyle(partition.mountState == .failed ? Color.red : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if partition.mountState == .mounted {
                if partition.mountPoint != nil {
                    Button { model.openInFinder(partition) } label: {
                        Label("Finder", systemImage: "folder")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
                Button {
                    model.unmountPartition(
                        deviceID: device.deviceID,
                        partitionType: partition.partitionType
                    )
                } label: {
                    Label("卸载", systemImage: "externaldrive.badge.minus")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(model.isBusy)
            } else {
                Button {
                    model.mountPartition(
                        deviceID: device.deviceID,
                        partitionType: partition.partitionType
                    )
                } label: {
                    Label(
                        partition.mountState == .mounting ? "挂载中" : "挂载",
                        systemImage: "externaldrive.badge.plus"
                    )
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(!canMount(partition))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var permissionSection: some View {
        VStack(spacing: 2) {
            EDPMenuNavigationRow(
                title: "需要完全磁盘访问",
                subtitle: "为 EDP Drive 开启一次即可",
                systemImage: "lock.trianglebadge.exclamationmark"
            ) {
                model.openFullDiskAccessSettings()
            }
            EDPMenuNavigationRow(
                title: "重新检测权限",
                systemImage: "arrow.clockwise",
                isEnabled: !model.isBusy
            ) {
                model.refreshRawAccess()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            EDPMenuCompactButton(title: "刷新", systemImage: "arrow.clockwise") {
                model.refresh()
            }
            Spacer(minLength: 6)
            EDPMenuCompactButton(title: "仅退出界面", systemImage: "rectangle.portrait.and.arrow.right") {
                NSApplication.shared.terminate(nil)
            }
            EDPMenuCompactButton(
                title: "完全退出",
                systemImage: "power",
                tint: .red,
                isEnabled: !model.isBusy
            ) {
                model.stopService {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(8)
    }

    private func canMount(_ partition: EDPXPCPartition) -> Bool {
        guard !model.isBusy, partition.mountState != .mounting else { return false }
        return !partition.encrypted || partition.credentialStatus == .saved
    }

    private func mountAvailabilityText(_ partition: EDPXPCPartition) -> String? {
        if partition.encrypted && partition.credentialStatus != .saved {
            return "请先在主界面保存密码"
        }
        if partition.mountState == .failed {
            return partition.lastError ?? "上次挂载失败"
        }
        return nil
    }

    private func partitionStatus(_ partition: EDPXPCPartition) -> String {
        switch partition.mountState {
        case .unavailable: return "不可用"
        case .unmounted: return "未挂载"
        case .mounting: return "正在挂载"
        case .mounted: return partition.readOnly == true ? "只读" : "已挂载"
        case .failed: return "挂载失败"
        }
    }

    private func partitionIcon(_ partition: EDPXPCPartition) -> String {
        switch EDPPartitionKind(rawValue: partition.partitionType) {
        case .boot: return "externaldrive"
        case .exchange: return "arrow.left.arrow.right.square"
        case .secure: return "lock.square"
        case nil: return "externaldrive.badge.questionmark"
        }
    }
}

private struct EDPMenuServiceButton: View {
    let title: String
    let systemImage: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .disabled(!isEnabled)
    }
}

private struct EDPMenuPanelHeader: View {
    let title: String
    var subtitle: String? = nil
    var backAction: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 9) {
            if let backAction {
                Button(action: backAction) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.glass)
                .help("返回")
            } else {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.025))
    }
}

private struct EDPMenuNavigationRow: View {
    let title: String
    var subtitle: String? = nil
    let systemImage: String
    var trailingSystemImage: String? = nil
    var tint: Color? = nil
    var isEnabled = true
    var isSelected = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint ?? .secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(tint ?? .primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let trailingSystemImage {
                    Image(systemName: trailingSystemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, subtitle == nil ? 8 : 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.16)
                : Color.primary.opacity(hovering && isEnabled ? 0.075 : 0),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .padding(.horizontal, 4)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? EDPTheme.Motion.reduced : EDPTheme.Motion.hover, value: hovering)
        .animation(reduceMotion ? EDPTheme.Motion.reduced : EDPTheme.Motion.navigation, value: isSelected)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.48)
    }
}

private struct EDPMenuCompactButton: View {
    let title: String
    let systemImage: String
    var tint: Color? = nil
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(tint ?? .primary)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
        }
        .buttonStyle(.glass)
        .disabled(!isEnabled)
    }
}

private final class EDPXPCSmokeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var passed = false
    private var detail = "no reply"

    func set(passed: Bool, detail: String) {
        lock.lock()
        self.passed = passed
        self.detail = detail
        lock.unlock()
    }

    func snapshot() -> (Bool, String) {
        lock.lock()
        defer { lock.unlock() }
        return (passed, detail)
    }
}

private final class EDPXPCDataResult: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var errorMessage: String?

    func set(data: Data) {
        lock.lock()
        self.data = data
        lock.unlock()
    }

    func set(error: String) {
        lock.lock()
        errorMessage = error
        lock.unlock()
    }

    func snapshot() -> (Data?, String?) {
        lock.lock()
        defer { lock.unlock() }
        return (data, errorMessage)
    }
}

private struct EDPXPCPolicySmokeError: Error, CustomStringConvertible {
    let description: String
}

private enum EDPXPCPolicySmokeRunner {
    private static func waitReply(
        label: String,
        timeout: DispatchTime = .now() + 15,
        invoke: (@escaping (String?) -> Void) -> Void
    ) throws {
        let result = EDPXPCSmokeResult()
        let semaphore = DispatchSemaphore(value: 0)
        invoke { errorMessage in
            result.set(passed: errorMessage == nil, detail: errorMessage ?? "\(label) completed")
            semaphore.signal()
        }
        guard semaphore.wait(timeout: timeout) == .success else {
            throw EDPXPCPolicySmokeError(description: "\(label) timed out")
        }
        let captured = result.snapshot()
        guard captured.0 else {
            throw EDPXPCPolicySmokeError(description: "\(label) failed: \(captured.1)")
        }
    }

    private static func snapshot(proxy: EDPVaultXPCProtocol) throws -> EDPXPCSnapshot {
        let result = EDPXPCDataResult()
        let semaphore = DispatchSemaphore(value: 0)
        proxy.snapshot { @Sendable data in
            result.set(data: data)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 15) == .success else {
            throw EDPXPCPolicySmokeError(description: "snapshot timed out")
        }
        let captured = result.snapshot()
        if let errorMessage = captured.1 {
            throw EDPXPCPolicySmokeError(description: "snapshot failed: \(errorMessage)")
        }
        guard let data = captured.0,
              let snapshot = try? JSONDecoder().decode(EDPXPCSnapshot.self, from: data) else {
            throw EDPXPCPolicySmokeError(description: "snapshot decode failed")
        }
        return snapshot
    }

    static func run(deviceID: String) -> Bool {
        let connection = NSXPCConnection(
            machServiceName: edpVaultMachServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
            fputs("XPC_POLICY_SMOKE_ERROR=\(error.localizedDescription)\n", stderr)
        }) as? EDPVaultXPCProtocol else {
            print("RESULT=XPC_POLICY_SMOKE_PROXY_UNAVAILABLE")
            return false
        }
        connection.resume()
        defer { connection.invalidate() }

        do {
            let before = try snapshot(proxy: proxy)
            guard let device = before.devices.first(where: { $0.deviceID == deviceID }) else {
                throw EDPXPCPolicySmokeError(description: "device not found in snapshot")
            }
            let originalGlobal = before.globalAutoMountEnabled
            let originalDisplayName = device.displayName
            let originalAutoMount = Dictionary(
                uniqueKeysWithValues: device.partitions.map { ($0.partitionType, $0.autoMount) }
            )
            guard Set(originalAutoMount.keys) == Set(EDPPartitionKind.allCases.map(\.rawValue)) else {
                throw EDPXPCPolicySmokeError(description: "snapshot is missing one or more partition policies")
            }

            let acceptanceName = "EDP Acceptance \(UUID().uuidString.prefix(8))"
            var restoreRequired = false

            func restore() {
                for kind in EDPPartitionKind.allCases {
                    if let enabled = originalAutoMount[kind.rawValue] {
                        try? waitReply(label: "restore partition \(kind.rawValue)") { reply in
                            proxy.setPartitionAutoMount(
                                deviceID: deviceID,
                                partitionType: kind.rawValue,
                                enabled: enabled,
                                withReply: reply
                            )
                        }
                    }
                }
                try? waitReply(label: "restore display name") { reply in
                    proxy.setDeviceDisplayName(
                        deviceID: deviceID,
                        displayName: originalDisplayName,
                        withReply: reply
                    )
                }
                try? waitReply(label: "restore global automount") { reply in
                    proxy.setGlobalAutoMount(enabled: originalGlobal, withReply: reply)
                }
            }

            defer {
                if restoreRequired {
                    restore()
                }
            }

            restoreRequired = true
            try waitReply(label: "disable global automount") { reply in
                proxy.setGlobalAutoMount(enabled: false, withReply: reply)
            }
            for kind in EDPPartitionKind.allCases {
                try waitReply(label: "disable partition \(kind.rawValue) automount") { reply in
                    proxy.setPartitionAutoMount(
                        deviceID: deviceID,
                        partitionType: kind.rawValue,
                        enabled: false,
                        withReply: reply
                    )
                }
            }
            try waitReply(label: "set acceptance display name") { reply in
                proxy.setDeviceDisplayName(
                    deviceID: deviceID,
                    displayName: acceptanceName,
                    withReply: reply
                )
            }

            var check = try snapshot(proxy: proxy)
            guard check.globalAutoMountEnabled == false,
                  let disabledDevice = check.devices.first(where: { $0.deviceID == deviceID }),
                  disabledDevice.displayName == acceptanceName,
                  disabledDevice.partitions.allSatisfy({ !$0.autoMount }) else {
                throw EDPXPCPolicySmokeError(description: "disabled policy state did not round-trip")
            }

            try waitReply(label: "enable global automount") { reply in
                proxy.setGlobalAutoMount(enabled: true, withReply: reply)
            }
            check = try snapshot(proxy: proxy)
            guard check.globalAutoMountEnabled else {
                throw EDPXPCPolicySmokeError(description: "global automount enable did not round-trip")
            }
            try waitReply(label: "disable global automount after probe") { reply in
                proxy.setGlobalAutoMount(enabled: false, withReply: reply)
            }

            for kind in EDPPartitionKind.allCases {
                let toggled = !(originalAutoMount[kind.rawValue] ?? false)
                try waitReply(label: "toggle partition \(kind.rawValue) automount") { reply in
                    proxy.setPartitionAutoMount(
                        deviceID: deviceID,
                        partitionType: kind.rawValue,
                        enabled: toggled,
                        withReply: reply
                    )
                }
            }
            check = try snapshot(proxy: proxy)
            guard let toggledDevice = check.devices.first(where: { $0.deviceID == deviceID }) else {
                throw EDPXPCPolicySmokeError(description: "device disappeared during policy probe")
            }
            for kind in EDPPartitionKind.allCases {
                let expected = !(originalAutoMount[kind.rawValue] ?? false)
                guard toggledDevice.partitions.first(where: { $0.partitionType == kind.rawValue })?.autoMount == expected else {
                    throw EDPXPCPolicySmokeError(description: "partition \(kind.rawValue) automount did not round-trip")
                }
            }

            restore()
            restoreRequired = false
            let restored = try snapshot(proxy: proxy)
            guard restored.globalAutoMountEnabled == originalGlobal,
                  let restoredDevice = restored.devices.first(where: { $0.deviceID == deviceID }),
                  restoredDevice.displayName == originalDisplayName else {
                throw EDPXPCPolicySmokeError(description: "policy restore verification failed")
            }
            for kind in EDPPartitionKind.allCases {
                guard restoredDevice.partitions.first(where: { $0.partitionType == kind.rawValue })?.autoMount
                        == originalAutoMount[kind.rawValue] else {
                    throw EDPXPCPolicySmokeError(description: "partition \(kind.rawValue) restore verification failed")
                }
            }

            print("POLICY_SMOKE_DEVICE_ID=\(deviceID)")
            print("POLICY_SMOKE_DISPLAY_NAME_RESTORED=\(originalDisplayName)")
            print("RESULT=XPC_POLICY_SMOKE_OK")
            return true
        } catch {
            fputs("XPC_POLICY_SMOKE_ERROR=\(error)\n", stderr)
            print("RESULT=XPC_POLICY_SMOKE_FAILED")
            return false
        }
    }
}

@main
struct EDPUSBVaultApp: App {
    @StateObject private var model = EDPVaultViewModel()

    init() {
        if CommandLine.arguments.contains("--refresh-raw-access-smoke") {
            let connection = NSXPCConnection(
                machServiceName: edpVaultMachServiceName,
                options: .privileged
            )
            connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
            let result = EDPXPCSmokeResult()
            let semaphore = DispatchSemaphore(value: 0)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
                result.set(passed: false, detail: error.localizedDescription)
                semaphore.signal()
            }) as? EDPVaultXPCProtocol else {
                print("RESULT=RAW_ACCESS_XPC_PROXY_UNAVAILABLE")
                exit(1)
            }
            connection.resume()
            proxy.refreshRawAccess { @Sendable errorMessage in
                result.set(
                    passed: errorMessage == nil,
                    detail: errorMessage ?? "Full Disk Access broker probe accepted"
                )
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 30) == .success else {
                connection.invalidate()
                print("RESULT=RAW_ACCESS_XPC_TIMEOUT")
                exit(1)
            }
            connection.invalidate()
            let captured = result.snapshot()
            print("RAW_ACCESS_XPC_DETAIL=\(captured.1)")
            print(captured.0 ? "RESULT=RAW_ACCESS_XPC_OK" : "RESULT=RAW_ACCESS_XPC_FAILED")
            exit(captured.0 ? 0 : 1)
        }

        if let index = CommandLine.arguments.firstIndex(of: "--xpc-policy-smoke"),
           CommandLine.arguments.count > index + 1 {
            let deviceID = CommandLine.arguments[index + 1]
            exit(EDPXPCPolicySmokeRunner.run(deviceID: deviceID) ? 0 : 1)
        }

        if let index = CommandLine.arguments.firstIndex(of: "--xpc-mount-smoke"),
           CommandLine.arguments.count > index + 2,
           let partitionType = UInt32(CommandLine.arguments[index + 1]),
           [UInt32(1), 2, 4].contains(partitionType) {
            let deviceID = CommandLine.arguments[index + 2]
            let connection = NSXPCConnection(machServiceName: edpVaultMachServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
            connection.resume()
            defer { connection.invalidate() }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
                fputs("XPC_MOUNT_SMOKE_ERROR=\(error.localizedDescription)\n", stderr)
            }) as? EDPVaultXPCProtocol else {
                print("RESULT=XPC_MOUNT_SMOKE_PROXY_UNAVAILABLE")
                exit(1)
            }
            let mountResult = EDPXPCSmokeResult()
            let mountSemaphore = DispatchSemaphore(value: 0)
            proxy.mountPartition(
                deviceID: deviceID,
                partitionType: partitionType
            ) { @Sendable errorMessage in
                mountResult.set(passed: errorMessage == nil, detail: errorMessage ?? "mount completed")
                mountSemaphore.signal()
            }
            guard mountSemaphore.wait(timeout: .now() + 90) == .success else {
                print("RESULT=XPC_MOUNT_SMOKE_MOUNT_TIMEOUT")
                exit(1)
            }
            let mounted = mountResult.snapshot()
            print("XPC_MOUNT_SMOKE_DETAIL=\(mounted.1)")
            print(mounted.0 ? "RESULT=XPC_MOUNT_SMOKE_OK" : "RESULT=XPC_MOUNT_SMOKE_FAILED")
            exit(mounted.0 ? 0 : 1)
        }

        if let index = CommandLine.arguments.firstIndex(of: "--xpc-unmount-smoke"),
           CommandLine.arguments.count > index + 2,
           let partitionType = UInt32(CommandLine.arguments[index + 1]),
           [UInt32(1), 2, 4].contains(partitionType) {
            let deviceID = CommandLine.arguments[index + 2]
            let connection = NSXPCConnection(machServiceName: edpVaultMachServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
            connection.resume()
            defer { connection.invalidate() }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
                fputs("XPC_UNMOUNT_SMOKE_ERROR=\(error.localizedDescription)\n", stderr)
            }) as? EDPVaultXPCProtocol else {
                print("RESULT=XPC_UNMOUNT_SMOKE_PROXY_UNAVAILABLE")
                exit(1)
            }
            let unmountResult = EDPXPCSmokeResult()
            let unmountSemaphore = DispatchSemaphore(value: 0)
            proxy.unmountPartition(
                deviceID: deviceID,
                partitionType: partitionType
            ) { @Sendable errorMessage in
                unmountResult.set(passed: errorMessage == nil, detail: errorMessage ?? "unmount completed")
                unmountSemaphore.signal()
            }
            guard unmountSemaphore.wait(timeout: .now() + 90) == .success else {
                print("RESULT=XPC_UNMOUNT_SMOKE_TIMEOUT")
                exit(1)
            }
            let unmounted = unmountResult.snapshot()
            print("XPC_UNMOUNT_SMOKE_DETAIL=\(unmounted.1)")
            print(unmounted.0 ? "RESULT=XPC_UNMOUNT_SMOKE_OK" : "RESULT=XPC_UNMOUNT_SMOKE_FAILED")
            exit(unmounted.0 ? 0 : 1)
        }

        if let index = CommandLine.arguments.firstIndex(of: "--xpc-eject-smoke"),
           CommandLine.arguments.count > index + 1 {
            let deviceID = CommandLine.arguments[index + 1]
            let connection = NSXPCConnection(machServiceName: edpVaultMachServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
            connection.resume()
            defer { connection.invalidate() }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
                fputs("XPC_EJECT_SMOKE_ERROR=\(error.localizedDescription)\n", stderr)
            }) as? EDPVaultXPCProtocol else {
                print("RESULT=XPC_EJECT_SMOKE_PROXY_UNAVAILABLE")
                exit(1)
            }
            let ejectResult = EDPXPCSmokeResult()
            let ejectSemaphore = DispatchSemaphore(value: 0)
            proxy.eject(deviceID: deviceID) { @Sendable errorMessage in
                ejectResult.set(passed: errorMessage == nil, detail: errorMessage ?? "eject completed")
                ejectSemaphore.signal()
            }
            guard ejectSemaphore.wait(timeout: .now() + 90) == .success else {
                print("RESULT=XPC_EJECT_SMOKE_TIMEOUT")
                exit(1)
            }
            let ejected = ejectResult.snapshot()
            print("XPC_EJECT_SMOKE_DETAIL=\(ejected.1)")
            print(ejected.0 ? "RESULT=XPC_EJECT_SMOKE_OK" : "RESULT=XPC_EJECT_SMOKE_FAILED")
            exit(ejected.0 ? 0 : 1)
        }

        if CommandLine.arguments.contains("--xpc-diagnostics") {
            let result = EDPXPCDataResult()
            let semaphore = DispatchSemaphore(value: 0)
            let connection = NSXPCConnection(machServiceName: edpVaultMachServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
                result.set(error: error.localizedDescription)
                semaphore.signal()
            }) as? EDPVaultXPCProtocol else {
                print("RESULT=XPC_DIAGNOSTICS_PROXY_UNAVAILABLE")
                exit(1)
            }
            connection.resume()
            proxy.diagnostics { @Sendable data in
                result.set(data: data)
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 10) == .success else {
                connection.invalidate()
                print("RESULT=XPC_DIAGNOSTICS_TIMEOUT")
                exit(1)
            }
            connection.invalidate()
            let captured = result.snapshot()
            if let error = captured.1 {
                print("XPC_DIAGNOSTICS_ERROR=\(error)")
                print("RESULT=XPC_DIAGNOSTICS_FAILED")
                exit(1)
            }
            guard let data = captured.0 else {
                print("RESULT=XPC_DIAGNOSTICS_EMPTY")
                exit(1)
            }
            print(String(decoding: data, as: UTF8.self))
            print("RESULT=PRIVILEGED_XPC_DIAGNOSTICS_OK")
            exit(0)
        }

        if CommandLine.arguments.contains("--xpc-snapshot") {
            let result = EDPXPCDataResult()
            let semaphore = DispatchSemaphore(value: 0)
            let connection = NSXPCConnection(machServiceName: edpVaultMachServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
                result.set(error: error.localizedDescription)
                semaphore.signal()
            }) as? EDPVaultXPCProtocol else {
                print("RESULT=XPC_SNAPSHOT_PROXY_UNAVAILABLE")
                exit(1)
            }
            connection.resume()
            proxy.snapshot { @Sendable data in
                result.set(data: data)
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 10) == .success else {
                connection.invalidate()
                print("RESULT=XPC_SNAPSHOT_TIMEOUT")
                exit(1)
            }
            connection.invalidate()
            let captured = result.snapshot()
            if let error = captured.1 {
                print("XPC_SNAPSHOT_ERROR=\(error)")
                print("RESULT=XPC_SNAPSHOT_FAILED")
                exit(1)
            }
            guard let data = captured.0,
                  let snapshot = try? JSONDecoder().decode(EDPXPCSnapshot.self, from: data) else {
                print("RESULT=XPC_SNAPSHOT_DECODE_FAILED")
                exit(1)
            }
            print("SNAPSHOT_SERVICE_VERSION=\(snapshot.serviceVersion)")
            print("SNAPSHOT_DEVICE_COUNT=\(snapshot.devices.count)")
            for device in snapshot.devices {
                print("SNAPSHOT_DEVICE=\(device.bsdName)|\(device.deviceID)|metadataDeviceID=\(device.metadataDeviceID ?? "-")|\(device.vidPID)|onlyID=\(device.labelOnlyID.map(String.init) ?? "-")|\(device.sizeBytes)|authorized=\(device.authorized)|mounted=\(device.mounted)|privilegedAccessReady=\(device.privilegedAccessReady)|partitions=\(device.partitionTypes.map(String.init).joined(separator: ","))")
                for partition in device.partitions.sorted(by: { $0.partitionType < $1.partitionType }) {
                    print("SNAPSHOT_PARTITION=\(device.deviceID)|type=\(partition.partitionType)|autoMount=\(partition.autoMount)|credential=\(partition.credentialStatus.rawValue)|mount=\(partition.mountState.rawValue)|filesystem=\(partition.filesystem ?? "-")|readOnly=\(partition.readOnly.map(String.init) ?? "-")|mountPoint=\(partition.mountPoint ?? "-")")
                }
            }
            print("SNAPSHOT_GLOBAL_AUTOMOUNT=\(snapshot.globalAutoMountEnabled)")
            print("RESULT=PRIVILEGED_XPC_SNAPSHOT_OK")
            exit(0)
        }

        if CommandLine.arguments.contains("--xpc-health") {
            let result = EDPXPCSmokeResult()
            let semaphore = DispatchSemaphore(value: 0)
            let connection = NSXPCConnection(
                machServiceName: edpVaultMachServiceName,
                options: .privileged
            )
            connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
                result.set(passed: false, detail: error.localizedDescription)
                semaphore.signal()
            }) as? EDPVaultXPCProtocol else {
                print("RESULT=XPC_HEALTH_PROXY_UNAVAILABLE")
                exit(1)
            }
            connection.resume()
            proxy.healthCheck { @Sendable response in
                let valid = response == "com.edp.drive.service:running"
                result.set(passed: valid, detail: response)
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 12) == .success else {
                connection.invalidate()
                print("RESULT=XPC_HEALTH_TIMEOUT")
                exit(1)
            }
            connection.invalidate()
            let snapshot = result.snapshot()
            print("XPC_HEALTH_DETAIL=\(snapshot.1)")
            print(snapshot.0 ? "RESULT=EDP_SERVICE_HEALTH_OK" : "RESULT=EDP_SERVICE_HEALTH_FAILED")
            exit(snapshot.0 ? 0 : 1)
        }

        if CommandLine.arguments.contains("--xpc-graceful-stop") {
            let result = EDPXPCSmokeResult()
            let replySemaphore = DispatchSemaphore(value: 0)
            let disconnectSemaphore = DispatchSemaphore(value: 0)
            let connection = NSXPCConnection(
                machServiceName: edpVaultMachServiceName,
                options: .privileged
            )
            connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
            connection.interruptionHandler = { @Sendable in disconnectSemaphore.signal() }
            connection.invalidationHandler = { @Sendable in disconnectSemaphore.signal() }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
                result.set(passed: false, detail: error.localizedDescription)
                replySemaphore.signal()
            }) as? EDPVaultXPCProtocol else {
                print("RESULT=XPC_GRACEFUL_STOP_PROXY_UNAVAILABLE")
                exit(1)
            }
            connection.resume()
            proxy.requestGracefulShutdown { @Sendable errorMessage in
                result.set(
                    passed: errorMessage == nil,
                    detail: errorMessage ?? "graceful teardown completed"
                )
                replySemaphore.signal()
            }
            guard replySemaphore.wait(timeout: .now() + 90) == .success else {
                connection.invalidate()
                print("RESULT=XPC_GRACEFUL_STOP_TIMEOUT")
                exit(1)
            }
            let snapshot = result.snapshot()
            guard snapshot.0 else {
                connection.invalidate()
                print("XPC_GRACEFUL_STOP_DETAIL=\(snapshot.1)")
                print("RESULT=EDP_SERVICE_GRACEFUL_STOP_FAILED")
                exit(1)
            }
            var disconnected = false
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline {
                if disconnectSemaphore.wait(timeout: .now() + 0.25) == .success {
                    disconnected = true
                    break
                }
                let launchctl = Process()
                launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                launchctl.arguments = ["print", "system/com.edp.drive.service"]
                launchctl.standardOutput = FileHandle.nullDevice
                launchctl.standardError = FileHandle.nullDevice
                do {
                    try launchctl.run()
                    launchctl.waitUntilExit()
                    if launchctl.terminationStatus != 0 {
                        disconnected = true
                        break
                    }
                } catch {
                    disconnected = true
                    break
                }
            }
            connection.invalidate()
            guard disconnected else {
                print("RESULT=XPC_GRACEFUL_STOP_EXIT_TIMEOUT")
                exit(1)
            }
            print("XPC_GRACEFUL_STOP_DETAIL=\(snapshot.1)")
            print("RESULT=EDP_SERVICE_GRACEFUL_STOP_OK")
            exit(0)
        }

        if CommandLine.arguments.contains("--xpc-smoke") {
            let result = EDPXPCSmokeResult()
            let semaphore = DispatchSemaphore(value: 0)
            let connection = NSXPCConnection(machServiceName: edpVaultMachServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in
                result.set(passed: false, detail: error.localizedDescription)
                semaphore.signal()
            }) as? EDPVaultXPCProtocol else {
                print("RESULT=XPC_SMOKE_PROXY_UNAVAILABLE")
                exit(1)
            }
            connection.resume()
            proxy.diagnostics { @Sendable data in
                let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let valid = payload?["eventDrivenDiscovery"] as? Bool == true
                    && payload?["credentialStore"] as? String == "System Keychain"
                result.set(
                    passed: valid,
                    detail: valid ? "diagnostics contract OK" : "unexpected diagnostics payload"
                )
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 10) == .success else {
                connection.invalidate()
                print("RESULT=XPC_SMOKE_TIMEOUT")
                exit(1)
            }
            connection.invalidate()
            let snapshot = result.snapshot()
            print("XPC_SMOKE_DETAIL=\(snapshot.1)")
            print(snapshot.0 ? "RESULT=PRIVILEGED_XPC_ROUNDTRIP_OK" : "RESULT=PRIVILEGED_XPC_ROUNDTRIP_FAILED")
            exit(snapshot.0 ? 0 : 1)
        }

        if CommandLine.arguments.contains("--register-service") {
            let mode = Bundle.main.object(forInfoDictionaryKey: "EDPServiceMode") as? String ?? "legacy"
            print("EDP_SERVICE_MODE=\(mode)")
            if mode == "smappservice" {
                let service = SMAppService.daemon(plistName: "com.edp.drive.service.plist")
                do {
                    if service.status != .enabled && service.status != .requiresApproval {
                        try service.register()
                    }
                    switch service.status {
                    case .enabled:
                        print("EDP_SERVICE_STATUS=enabled")
                        exit(0)
                    case .requiresApproval:
                        print("EDP_SERVICE_STATUS=requiresApproval")
                        exit(0)
                    case .notRegistered:
                        print("EDP_SERVICE_STATUS=notRegistered")
                        exit(1)
                    case .notFound:
                        print("EDP_SERVICE_STATUS=notFound")
                        exit(1)
                    @unknown default:
                        print("EDP_SERVICE_STATUS=unknown")
                        exit(1)
                    }
                } catch {
                    FileHandle.standardError.write(Data("EDP_SERVICE_ERROR=\(error)\n".utf8))
                    exit(1)
                }
            } else {
                let legacyURL = URL(fileURLWithPath: "/Library/LaunchDaemons/com.edp.drive.service.plist")
                switch SMAppService.statusForLegacyPlist(at: legacyURL) {
                case .enabled:
                    print("EDP_SERVICE_STATUS=enabled")
                    exit(0)
                case .requiresApproval:
                    print("EDP_SERVICE_STATUS=requiresApproval")
                    exit(0)
                case .notRegistered:
                    print("EDP_SERVICE_STATUS=notRegistered")
                    exit(1)
                case .notFound:
                    print("EDP_SERVICE_STATUS=notFound")
                    exit(1)
                @unknown default:
                    print("EDP_SERVICE_STATUS=unknown")
                    exit(1)
                }
            }
        }

        if CommandLine.arguments.contains("--reregister-service") {
            let mode = Bundle.main.object(forInfoDictionaryKey: "EDPServiceMode") as? String ?? "legacy"
            guard mode == "smappservice" else {
                print("RESULT=SERVICE_REREGISTER_NOT_APPLICABLE")
                exit(1)
            }
            let service = SMAppService.daemon(plistName: "com.edp.drive.service.plist")
            do {
                try service.unregister()
                try service.register()
                switch service.status {
                case .enabled:
                    print("RESULT=SERVICE_REREGISTERED_ENABLED")
                    exit(0)
                case .requiresApproval:
                    print("RESULT=SERVICE_REREGISTERED_REQUIRES_APPROVAL")
                    exit(0)
                case .notRegistered:
                    print("RESULT=SERVICE_REREGISTER_NOT_REGISTERED")
                    exit(1)
                case .notFound:
                    print("RESULT=SERVICE_REREGISTER_NOT_FOUND")
                    exit(1)
                @unknown default:
                    print("RESULT=SERVICE_REREGISTER_UNKNOWN")
                    exit(1)
                }
            } catch {
                print("SERVICE_REREGISTER_ERROR=\(error)")
                print("RESULT=SERVICE_REREGISTER_FAILED")
                exit(1)
            }
        }
    }

    var body: some Scene {
        Window("EDP Drive", id: "main") {
            EDPMainView(model: model)
        }
        .defaultSize(width: 980, height: 680)

        MenuBarExtra {
            EDPMenuBarView(model: model)
        } label: {
            Label(
                "EDP Drive",
                systemImage: model.snapshot.devices.contains(where: { $0.connected })
                    ? "externaldrive.fill.badge.checkmark"
                    : "externaldrive"
            )
        }
        // Window style keeps one stable popover alive while the user drills through
        // device -> partition pages. Unlike AppKit cascading NSMenu submenus, there is
        // no narrow hover corridor that can accidentally dismiss the hierarchy.
        .menuBarExtraStyle(.window)
    }
}
