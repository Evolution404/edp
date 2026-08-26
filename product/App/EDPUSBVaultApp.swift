import AppKit
import Darwin
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class EDPVaultViewModel: ObservableObject {
    @Published var snapshot = EDPXPCSnapshot(devices: [], serviceVersion: "-", timestamp: "-")
    @Published var serviceStatus = "检查中…"
    @Published var lastError: String?
    @Published var diagnostics = ""
    @Published var isBusy = false

    private let daemonService = SMAppService.daemon(plistName: "com.edp.usbvault.mountd.plist")
    private var connection: NSXPCConnection?

    init() {
        ensureServiceRegistration()
        refresh()
    }

    private func connectIfNeeded() -> NSXPCConnection? {
        guard daemonService.status == .enabled else { return nil }
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
        if daemonService.status == .notRegistered {
            do {
                try daemonService.register()
            } catch {
                lastError = "后台服务注册失败：\(error.localizedDescription)"
            }
        }
        refreshServiceStatus()
    }

    func refreshServiceStatus() {
        switch daemonService.status {
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

    func refresh() {
        refreshServiceStatus()
        guard let proxy = proxy() else {
            if daemonService.status == .requiresApproval {
                lastError = "请在系统设置中批准 EDP USB Vault 后台服务"
            } else if daemonService.status != .enabled {
                lastError = "后台服务尚未启用"
            }
            return
        }
        proxy.snapshot { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                do {
                    self.snapshot = try JSONDecoder().decode(EDPXPCSnapshot.self, from: data)
                    self.lastError = nil
                } catch {
                    self.lastError = String(data: data, encoding: .utf8) ?? error.localizedDescription
                }
                self.refreshServiceStatus()
            }
        }
    }

    func authorize(deviceID: String, password: String) {
        guard !password.isEmpty, let proxy = proxy() else { return }
        isBusy = true
        proxy.authorize(deviceID: deviceID, password: Data(password.utf8)) { [weak self] errorMessage in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                self.lastError = errorMessage
                self.refresh()
            }
        }
    }

    func revoke(deviceID: String) {
        guard let proxy = proxy() else { return }
        isBusy = true
        proxy.revoke(deviceID: deviceID) { [weak self] errorMessage in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                self.lastError = errorMessage
                self.refresh()
            }
        }
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
                    Button("安全弹出") { model.eject(deviceID: device.deviceID) }
                        .disabled(!device.mounted || model.isBusy)
                    Button("撤销授权", role: .destructive) { model.revoke(deviceID: device.deviceID) }
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
                        model.authorize(deviceID: device.deviceID, password: password)
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
                    Text("EDP USB Vault").font(.title2.bold())
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

            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if model.snapshot.devices.isEmpty {
                ContentUnavailableView(
                    "未发现 EDP U 盘",
                    systemImage: "externaldrive",
                    description: Text("插入 EDP U 盘后会自动识别。")
                )
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

@main
struct EDPUSBVaultApp: App {
    init() {
        if CommandLine.arguments.contains("--register-service") {
            let service = SMAppService.daemon(plistName: "com.edp.usbvault.mountd.plist")
            do {
                if service.status == .notRegistered {
                    try service.register()
                }
                switch service.status {
                case .enabled:
                    print("SMAPP_SERVICE_STATUS=enabled")
                    exit(0)
                case .requiresApproval:
                    print("SMAPP_SERVICE_STATUS=requiresApproval")
                    exit(0)
                case .notRegistered:
                    print("SMAPP_SERVICE_STATUS=notRegistered")
                    exit(1)
                case .notFound:
                    print("SMAPP_SERVICE_STATUS=notFound")
                    exit(1)
                @unknown default:
                    print("SMAPP_SERVICE_STATUS=unknown")
                    exit(1)
                }
            } catch {
                FileHandle.standardError.write(Data("SMAPP_SERVICE_ERROR=\(error)\n".utf8))
                exit(1)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
