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

    private let serviceMode: String
    private let daemonService: SMAppService?
    private let daemonPlistName = "com.edp.drive.service.plist"
    private let legacyPlistURL = URL(fileURLWithPath: "/Library/LaunchDaemons/com.edp.drive.service.plist")
    private var connection: NSXPCConnection?

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
        currentServiceStatus() == .enabled
            && transportRuntimeReady == true
            && rawAccessHelperInstalled
            && snapshot.devices.contains { $0.connected && $0.privilegedAccessReady }
    }

    init() {
        serviceMode = Bundle.main.object(forInfoDictionaryKey: "EDPServiceMode") as? String ?? "legacy"
        daemonService = serviceMode == "smappservice"
            ? SMAppService.daemon(plistName: daemonPlistName)
            : nil
        ensureServiceRegistration()
        do {
            try ensureMacFUSELocalEnablement()
        } catch {
            lastError = "macFUSE Local 启用失败：\(error.localizedDescription)"
        }
        refreshTransportRuntimeState()
        refresh()
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.refresh()
            }
        }
    }

    private func currentServiceStatus() -> SMAppService.Status {
        if let daemonService { return daemonService.status }
        return SMAppService.statusForLegacyPlist(at: legacyPlistURL)
    }

    private func connectIfNeeded() -> NSXPCConnection? {
        guard currentServiceStatus() == .enabled else { return nil }
        if let connection { return connection }
        let newConnection = NSXPCConnection(machServiceName: edpVaultMachServiceName, options: .privileged)
        newConnection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
        newConnection.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.lastError = "后台服务连接已中断"
            }
        }
        newConnection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.lastError = "后台服务连接已失效"
            }
        }
        newConnection.resume()
        connection = newConnection
        return newConnection
    }

    private func proxy() -> EDPVaultXPCProtocol? {
        guard let connection = connectIfNeeded() else { return nil }
        return connection.remoteObjectProxyWithErrorHandler { [weak self] error in
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
        case .enabled: serviceStatus = "已启用"
        case .requiresApproval: serviceStatus = "需要系统批准"
        case .notRegistered: serviceStatus = "未注册"
        case .notFound: serviceStatus = "未安装"
        @unknown default: serviceStatus = "未知"
        }
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
        proxy.snapshot { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                do {
                    self.snapshot = try JSONDecoder().decode(EDPXPCSnapshot.self, from: data)
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
        proxy.refreshRawAccess { [weak self] errorMessage in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                self.lastError = errorMessage
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
        ) { [weak self] errorMessage in
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
        proxy.mountPartition(deviceID: deviceID, partitionType: partitionType) { [weak self] errorMessage in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                self.lastError = errorMessage
                self.refresh()
            }
        }
    }

    func unmountPartition(deviceID: String, partitionType: UInt32) {
        guard let proxy = proxy() else { return }
        isBusy = true
        proxy.unmountPartition(deviceID: deviceID, partitionType: partitionType) { [weak self] errorMessage in
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
        proxy.deleteCredential(deviceID: deviceID, partitionType: partitionType) { [weak self] errorMessage in
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
        proxy.deleteDeviceRecord(deviceID: deviceID) { [weak self] errorMessage in
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
        ) { [weak self] errorMessage in
            Task { @MainActor in
                self?.lastError = errorMessage
                self?.refresh()
            }
        }
    }

    func setGlobalAutoMount(_ enabled: Bool) {
        guard let proxy = proxy() else { return }
        proxy.setGlobalAutoMount(enabled: enabled) { [weak self] errorMessage in
            Task { @MainActor in
                self?.lastError = errorMessage
                self?.refresh()
            }
        }
    }

    func rename(deviceID: String, displayName: String) {
        guard let proxy = proxy() else { return }
        proxy.setDeviceDisplayName(deviceID: deviceID, displayName: displayName) { [weak self] errorMessage in
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
        proxy.eject(deviceID: deviceID) { [weak self] errorMessage in
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
        proxy.diagnostics { [weak self] data in
            Task { @MainActor in
                self?.diagnostics = String(decoding: data, as: UTF8.self)
            }
        }
    }
}

struct EDPDeviceCard: View {
    let device: EDPXPCDevice
    @ObservedObject var model: EDPVaultViewModel
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.mediaName).font(.headline)
                    Text("\(device.vidPID) · \(ByteCountFormatter.string(fromByteCount: Int64(device.sizeBytes), countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(device.mounted ? "已挂载" : (device.authorized ? "已授权" : "未授权"),
                      systemImage: device.mounted ? "externaldrive.fill.badge.checkmark" : (device.authorized ? "key.fill" : "lock"))
                    .font(.callout)
            }

            Text("设备：\(device.bsdName) · \(device.deviceID)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if device.authorized {
                HStack {
                    if !device.mounted {
                        Button("挂载交换区") {
                            model.mountPartition(
                                deviceID: device.deviceID,
                                partitionType: EDPPartitionKind.exchange.rawValue
                            )
                        }
                            .disabled(model.isBusy)
                    }
                    Button("安全弹出") { model.eject(deviceID: device.deviceID) }
                        .disabled(!device.mounted || model.isBusy)
                    Button("删除交换区密码", role: .destructive) {
                        model.deleteCredential(
                            deviceID: device.deviceID,
                            partitionType: EDPPartitionKind.exchange.rawValue
                        )
                    }
                        .disabled(model.isBusy)
                    Spacer()
                    if !device.partitionTypes.isEmpty {
                        Text("分区 \(device.partitionTypes.map(String.init).joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack {
                    SecureField("EDP 密码", text: $password)
                        .textFieldStyle(.roundedBorder)
                    Button("记住并挂载") {
                        model.saveCredential(
                            deviceID: device.deviceID,
                            partitionType: EDPPartitionKind.exchange.rawValue,
                            password: password
                        )
                        password = ""
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || model.isBusy)
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ContentView: View {
    @StateObject private var model = EDPVaultViewModel()
    @State private var showingDiagnostics = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("EDP Drive").font(.title2.bold())
                    Text("后台服务：\(model.serviceStatus) · v\(model.snapshot.serviceVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.serviceStatus == "需要系统批准" {
                    Button("打开系统设置") { model.openServiceSettings() }
                }
                Button { model.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }
            }

            if model.transportRuntimeReady == false {
                HStack {
                    Label("macFUSE Local 运行组件未安装或不完整，挂载操作已暂停", systemImage: "puzzlepiece.extension")
                        .foregroundStyle(.orange)
                    Spacer()
                }
            }

            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if model.snapshot.devices.isEmpty {
                VStack(spacing: 14) {
                    ContentUnavailableView(
                        "未发现 EDP U 盘",
                        systemImage: "externaldrive",
                        description: Text("插入 EDP U 盘后会自动识别。")
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.snapshot.devices) { device in
                            EDPDeviceCard(device: device, model: model)
                        }
                    }
                }
            }

            Divider()
            HStack {
                Button("诊断信息") {
                    model.loadDiagnostics()
                    showingDiagnostics = true
                }
                Spacer()
                Text("无需 Terminal · FSKit backend")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 440)
        .sheet(isPresented: $showingDiagnostics) {
            VStack(alignment: .leading, spacing: 12) {
                Text("诊断信息").font(.headline)
                ScrollView {
                    Text(model.diagnostics.isEmpty ? "正在读取…" : model.diagnostics)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button("关闭") { showingDiagnostics = false }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(20)
            .frame(width: 620, height: 420)
        }
    }
}

private enum EDPMainSection: String, CaseIterable, Identifiable {
    case devices = "设备"
    case activity = "活动"
    case settings = "设置"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .devices: return "externaldrive"
        case .activity: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

struct EDPCredentialTarget: Identifiable {
    let deviceID: String
    let partitionType: UInt32
    let partitionName: String
    var id: String { "\(deviceID):\(partitionType)" }
}

struct EDPMainView: View {
    @ObservedObject var model: EDPVaultViewModel
    @State private var section: EDPMainSection? = .devices

    var body: some View {
        NavigationSplitView {
            List(EDPMainSection.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationTitle("EDP Drive")
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            switch section ?? .devices {
            case .devices: EDPDevicesView(model: model)
            case .activity: EDPActivityView(model: model)
            case .settings: EDPSettingsView(model: model)
            }
        }
        .frame(minWidth: 900, minHeight: 620)
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

struct EDPDevicesView: View {
    @ObservedObject var model: EDPVaultViewModel
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
                HStack(spacing: 12) {
                    Label(
                        "EDP U 盘已识别。请为“EDP Drive 磁盘访问”开启一次完全磁盘访问。",
                        systemImage: "externaldrive.badge.exclamationmark"
                    )
                    Spacer()
                    Button("显示组件") { model.revealRawAccessHelper() }
                    Button("打开完全磁盘访问") { model.openFullDiskAccessSettings() }
                        .buttonStyle(.borderedProminent)
                    Button("重新检测") { model.refreshRawAccess() }
                        .disabled(model.isBusy)
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.10))
                Divider()
            }

            HSplitView {
                List(selection: $selectedDeviceID) {
                    Section("已连接") {
                        ForEach(model.snapshot.devices.filter(\.connected)) { device in
                            deviceLabel(device).tag(device.deviceID)
                        }
                    }
                    let offline = model.snapshot.devices.filter { !$0.connected }
                    if !offline.isEmpty {
                        Section("已保存") {
                            ForEach(offline) { device in
                                deviceLabel(device).tag(device.deviceID)
                            }
                        }
                    }
                }
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 300)

                Group {
                    if let selectedDevice {
                        EDPDeviceDetailView(device: selectedDevice, model: model)
                            .id(selectedDevice.deviceID)
                    } else {
                        VStack(spacing: 14) {
                            ContentUnavailableView(
                                "未发现 EDP U 盘",
                                systemImage: "externaldrive",
                                description: Text("插入设备后会自动识别，也可以查看此前保存的设备。")
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("设备")
        .toolbar {
            ToolbarItem {
                Button { model.refresh() } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
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

    private func deviceLabel(_ device: EDPXPCDevice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: device.connected ? "externaldrive.fill" : "externaldrive")
                .foregroundStyle(device.connected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).lineLimit(1)
                Text(device.connected ? "已连接" : "未连接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct EDPDeviceDetailView: View {
    let device: EDPXPCDevice
    @ObservedObject var model: EDPVaultViewModel
    @State private var credentialTarget: EDPCredentialTarget?
    @State private var displayName = ""
    @State private var confirmingRecordDeletion = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        TextField("设备名称", text: $displayName)
                            .font(.title2.bold())
                            .textFieldStyle(.plain)
                            .onSubmit {
                                model.rename(deviceID: device.deviceID, displayName: displayName)
                            }
                        Text("\(device.vidPID) · \(ByteCountFormatter.string(fromByteCount: Int64(device.sizeBytes), countStyle: .file))")
                            .foregroundStyle(.secondary)
                        Text(device.deviceID)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Label(device.connected ? "已连接" : "未连接",
                          systemImage: device.connected ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(device.connected ? .green : .secondary)
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

                HStack {
                    Button("安全推出整盘") { model.eject(deviceID: device.deviceID) }
                        .disabled(!device.connected || model.isBusy)
                    if !device.connected {
                        Button("删除设备记录", role: .destructive) {
                            confirmingRecordDeletion = true
                        }
                        .disabled(model.isBusy)
                    }
                    Spacer()
                    Text("关闭窗口不会停止自动挂载服务")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 30)
                    .foregroundStyle(mounted ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(partition.displayName).font(.headline)
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
            }

            Divider()

            HStack {
                Toggle("插入后自动挂载", isOn: Binding(
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
                .disabled(!device.connected && partition.partitionType == EDPPartitionKind.boot.rawValue)
                Spacer()
                if let filesystem = partition.filesystem {
                    Text(filesystem).font(.caption).foregroundStyle(.secondary)
                }
            }

            if let error = partition.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                if partition.encrypted {
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
                }
                Spacer()
                if mounted {
                    if partition.mountPoint != nil {
                        Button("在 Finder 中显示") { model.openInFinder(partition) }
                    }
                    Button("卸载") {
                        model.unmountPartition(
                            deviceID: device.deviceID,
                            partitionType: partition.partitionType
                        )
                    }
                } else {
                    Button("挂载") {
                        model.mountPartition(
                            deviceID: device.deviceID,
                            partitionType: partition.partitionType
                        )
                    }
                    .disabled(
                        !device.connected || model.isBusy
                            || (partition.encrypted && partition.credentialStatus != .saved)
                    )
                }
            }

            if partition.encrypted && mounted {
                Text("该分区以可写磁盘介质发布，可使用 Finder 自带的“抹掉”功能格式化为 ExFAT。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.35)))
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
        case .exchange: return "用于受控交换的加密分区"
        case .secure: return "用于保密资料的加密分区"
        case nil: return "EDP 分区"
        }
    }

    @ViewBuilder private var statusBadge: some View {
        let title = mounted ? (partition.readOnly == true ? "只读" : "已挂载")
            : (partition.credentialStatus == .saved ? "密码已保存" : "未挂载")
        Text(title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background((mounted ? Color.green : Color.secondary).opacity(0.13), in: Capsule())
            .foregroundStyle(mounted ? .green : .secondary)
    }
}

struct EDPCredentialSheet: View {
    let target: EDPCredentialTarget
    @ObservedObject var model: EDPVaultViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("设置\(target.partitionName)密码").font(.title3.bold())
            Text("密码会先在当前 U 盘上验证，成功后才保存到系统钥匙串。应用不会修改盘上的密码。")
                .foregroundStyle(.secondary)
            SecureField("现有分区密码", text: $password)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("验证并保存") {
                    model.saveCredential(
                        deviceID: target.deviceID,
                        partitionType: target.partitionType,
                        password: password
                    )
                    password = ""
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || model.isBusy)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

struct EDPActivityView: View {
    @ObservedObject var model: EDPVaultViewModel

    var body: some View {
        Group {
            if model.snapshot.activities.isEmpty {
                ContentUnavailableView(
                    "暂无活动记录",
                    systemImage: "clock",
                    description: Text("设备插入、挂载和凭据变更会显示在这里。")
                )
            } else {
                List(model.snapshot.activities) { activity in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: activity.level == "error"
                              ? "exclamationmark.triangle.fill" : "checkmark.circle")
                            .foregroundStyle(activity.level == "error" ? .red : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(activity.message)
                            HStack {
                                Text(activity.timestamp)
                                if let type = activity.partitionType,
                                   let kind = EDPPartitionKind(rawValue: type) {
                                    Text("· \(kind.displayName)")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("活动")
    }
}

struct EDPSettingsView: View {
    @ObservedObject var model: EDPVaultViewModel
    @State private var showingDiagnostics = false
    @State private var loginItemEnabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("首次设置") {
                LabeledContent {
                    Label(
                        model.serviceStatus,
                        systemImage: model.serviceStatus == "已启用"
                            ? "checkmark.circle.fill" : "exclamationmark.circle"
                    )
                    .foregroundStyle(model.serviceStatus == "已启用" ? .green : .orange)
                } label: {
                    Text("特权后台服务")
                }
                LabeledContent {
                    Label(
                        model.transportRuntimeReady == true ? "已就绪" : "需要重新安装",
                        systemImage: model.transportRuntimeReady == true
                            ? "checkmark.circle.fill" : "exclamationmark.circle"
                    )
                    .foregroundStyle(model.transportRuntimeReady == true ? .green : .orange)
                } label: {
                    Text("macFUSE Local")
                }
                LabeledContent("完全磁盘访问", value: model.rawAccessStatusText)
                Text(model.setupReady
                     ? "首次设置已完成。后台服务会按需打开经校验的 EDP 整盘并把文件描述符交给降权桥进程；重启或重新插盘不再请求管理员密码。"
                     : (model.needsFullDiskAccess
                        ? "请为“EDP Drive 磁盘访问”开启一次完全磁盘访问，然后点击重新检测。"
                        : "请完成后台服务、macFUSE Local 和磁盘访问组件设置；完全磁盘访问会在连接 EDP U 盘后进行验证。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if model.serviceStatus != "已启用" {
                    Button("打开登录项与扩展设置") { model.openServiceSettings() }
                }
            }
            Section("自动挂载") {
                Toggle("启用全局自动挂载", isOn: Binding(
                    get: { model.snapshot.globalAutoMountEnabled },
                    set: { model.setGlobalAutoMount($0) }
                ))
                Toggle("登录时启动菜单栏应用", isOn: Binding(
                    get: { loginItemEnabled },
                    set: { updateLoginItem($0) }
                ))
            }
            Section("后台服务") {
                LabeledContent("状态", value: model.serviceStatus)
                LabeledContent("版本", value: model.snapshot.serviceVersion)
                LabeledContent("磁盘访问", value: model.rawAccessStatusText)
                LabeledContent(
                    "文件系统运行组件",
                    value: model.transportRuntimeReady == true ? "已就绪" : "需要重新安装"
                )
                if model.serviceStatus == "需要系统批准" {
                    Button("打开登录项与扩展设置") { model.openServiceSettings() }
                }
            }
            Section("诊断") {
                Button("查看诊断信息") {
                    model.loadDiagnostics()
                    showingDiagnostics = true
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        .sheet(isPresented: $showingDiagnostics) {
            VStack(alignment: .leading, spacing: 12) {
                Text("诊断信息").font(.headline)
                ScrollView {
                    Text(model.diagnostics.isEmpty ? "正在读取…" : model.diagnostics)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack { Spacer(); Button("关闭") { showingDiagnostics = false } }
            }
            .padding(20)
            .frame(width: 680, height: 460)
        }
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

    var body: some View {
        Button("打开 EDP Drive") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")

        Divider()
        Label(model.serviceStatus, systemImage: "gearshape.2")
        Button(model.snapshot.globalAutoMountEnabled ? "暂停自动挂载" : "恢复自动挂载") {
            model.setGlobalAutoMount(!model.snapshot.globalAutoMountEnabled)
        }

        ForEach(model.snapshot.devices.filter(\.connected)) { device in
            Menu(device.displayName) {
                ForEach(device.partitions) { partition in
                    Menu(partition.displayName) {
                        if partition.mountState == .mounted {
                            if partition.mountPoint != nil {
                                Button("在 Finder 中显示") { model.openInFinder(partition) }
                            }
                            Button("卸载") {
                                model.unmountPartition(
                                    deviceID: device.deviceID,
                                    partitionType: partition.partitionType
                                )
                            }
                        } else {
                            Button("挂载") {
                                model.mountPartition(
                                    deviceID: device.deviceID,
                                    partitionType: partition.partitionType
                                )
                            }
                            .disabled(partition.encrypted && partition.credentialStatus != .saved)
                        }
                    }
                }
                Divider()
                Button("安全推出整盘") { model.eject(deviceID: device.deviceID) }
            }
        }

        if model.snapshot.devices.filter(\.connected).isEmpty {
            Text("未连接 EDP U 盘").foregroundStyle(.secondary)
        } else if model.needsFullDiskAccess {
            Text("加密分区需要为“EDP Drive 磁盘访问”开启一次完全磁盘访问。")
                .foregroundStyle(.secondary)
            Button("显示磁盘访问组件") { model.revealRawAccessHelper() }
            Button("打开完全磁盘访问") { model.openFullDiskAccessSettings() }
            Button("重新检测权限") { model.refreshRawAccess() }
                .disabled(model.isBusy)
        }

        Divider()
        Button("刷新") { model.refresh() }
        Button("退出菜单栏应用") { NSApplication.shared.terminate(nil) }
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
        proxy.snapshot { data in
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
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
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
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                result.set(passed: false, detail: error.localizedDescription)
                semaphore.signal()
            }) as? EDPVaultXPCProtocol else {
                print("RESULT=RAW_ACCESS_XPC_PROXY_UNAVAILABLE")
                exit(1)
            }
            connection.resume()
            proxy.refreshRawAccess { errorMessage in
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
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
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
            ) { errorMessage in
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
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
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
            ) { errorMessage in
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
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                fputs("XPC_EJECT_SMOKE_ERROR=\(error.localizedDescription)\n", stderr)
            }) as? EDPVaultXPCProtocol else {
                print("RESULT=XPC_EJECT_SMOKE_PROXY_UNAVAILABLE")
                exit(1)
            }
            let ejectResult = EDPXPCSmokeResult()
            let ejectSemaphore = DispatchSemaphore(value: 0)
            proxy.eject(deviceID: deviceID) { errorMessage in
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
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                result.set(error: error.localizedDescription)
                semaphore.signal()
            }) as? EDPVaultXPCProtocol else {
                print("RESULT=XPC_DIAGNOSTICS_PROXY_UNAVAILABLE")
                exit(1)
            }
            connection.resume()
            proxy.diagnostics { data in
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
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                result.set(error: error.localizedDescription)
                semaphore.signal()
            }) as? EDPVaultXPCProtocol else {
                print("RESULT=XPC_SNAPSHOT_PROXY_UNAVAILABLE")
                exit(1)
            }
            connection.resume()
            proxy.snapshot { data in
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
                print("SNAPSHOT_DEVICE=\(device.bsdName)|\(device.deviceID)|\(device.vidPID)|\(device.sizeBytes)|authorized=\(device.authorized)|mounted=\(device.mounted)|privilegedAccessReady=\(device.privilegedAccessReady)|partitions=\(device.partitionTypes.map(String.init).joined(separator: ","))")
                for partition in device.partitions.sorted(by: { $0.partitionType < $1.partitionType }) {
                    print("SNAPSHOT_PARTITION=\(device.deviceID)|type=\(partition.partitionType)|autoMount=\(partition.autoMount)|credential=\(partition.credentialStatus.rawValue)|mount=\(partition.mountState.rawValue)|filesystem=\(partition.filesystem ?? "-")|readOnly=\(partition.readOnly.map(String.init) ?? "-")|mountPoint=\(partition.mountPoint ?? "-")")
                }
            }
            print("SNAPSHOT_GLOBAL_AUTOMOUNT=\(snapshot.globalAutoMountEnabled)")
            print("RESULT=PRIVILEGED_XPC_SNAPSHOT_OK")
            exit(0)
        }

        if CommandLine.arguments.contains("--xpc-smoke") {
            let result = EDPXPCSmokeResult()
            let semaphore = DispatchSemaphore(value: 0)
            let connection = NSXPCConnection(machServiceName: edpVaultMachServiceName, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                result.set(passed: false, detail: error.localizedDescription)
                semaphore.signal()
            }) as? EDPVaultXPCProtocol else {
                print("RESULT=XPC_SMOKE_PROXY_UNAVAILABLE")
                exit(1)
            }
            connection.resume()
            proxy.diagnostics { data in
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
        .menuBarExtraStyle(.menu)
    }
}
