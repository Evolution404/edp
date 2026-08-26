import AppKit
import Darwin
import Foundation
import ServiceManagement
import Security
import SwiftUI

private func createAuthorizationRef() throws -> AuthorizationRef {
    var created: AuthorizationRef?
    let status = AuthorizationCreate(nil, nil, [], &created)
    guard status == errAuthorizationSuccess, let created else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    return created
}

private func authorizationData(
    for rightName: String,
    using authorization: AuthorizationRef
) throws -> Data {
    let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
    let status = rightName.withCString { name in
        var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
        return withUnsafeMutablePointer(to: &item) { itemPointer in
            var rights = AuthorizationRights(count: 1, items: itemPointer)
            return AuthorizationCopyRights(authorization, &rights, nil, flags, nil)
        }
    }
    guard status == errAuthorizationSuccess else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }

    var external = AuthorizationExternalForm()
    let externalStatus = AuthorizationMakeExternalForm(authorization, &external)
    guard externalStatus == errAuthorizationSuccess else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(externalStatus))
    }
    return withUnsafeBytes(of: external) { Data($0) }
}

private func makeRawDeviceAuthorization() throws -> (AuthorizationRef, Data) {
    let authorization = try createAuthorizationRef()
    do {
        let data = try authorizationData(for: "system.privilege.admin", using: authorization)
        return (authorization, data)
    } catch {
        AuthorizationFree(authorization, [])
        throw error
    }
}

@MainActor
final class EDPVaultViewModel: ObservableObject {
    @Published var snapshot = EDPXPCSnapshot(devices: [], serviceVersion: "-", timestamp: "-")
    @Published var serviceStatus = "检查中…"
    @Published var lastError: String?
    @Published var diagnostics = ""
    @Published var isBusy = false
    @Published var macFUSEFSKitReady: Bool?

    private let serviceMode: String
    private let daemonService: SMAppService?
    private var rawAuthorizationRef: AuthorizationRef?
    private let legacyPlistURL = URL(fileURLWithPath: "/Library/LaunchDaemons/com.edp.usbvault.mountd.plist")
    private var connection: NSXPCConnection?

    init() {
        serviceMode = Bundle.main.object(forInfoDictionaryKey: "EDPServiceMode") as? String ?? "legacy"
        daemonService = serviceMode == "smappservice"
            ? SMAppService.daemon(plistName: "com.edp.usbvault.mountd.plist")
            : nil
        ensureServiceRegistration()
        refreshFSKitState()
        refresh()
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
        if let daemonService, daemonService.status == .notRegistered {
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

    func refreshFSKitState() {
        let appExtension = "/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app/Contents/Extensions/io.macfuse.app.fsmodule.macfuse.appex"
        let framework = "/Library/Filesystems/macfuse.fs/Contents/Frameworks/MFMount.framework"
        macFUSEFSKitReady = FileManager.default.fileExists(atPath: appExtension)
            && FileManager.default.fileExists(atPath: framework)
    }

    private func requireMacFUSEFSKit() -> Bool {
        guard macFUSEFSKitReady == true else {
            lastError = "macFUSE 运行组件未安装完整，请重新安装 macFUSE 后再试。"
            return false
        }
        return true
    }

    func refresh() {
        refreshServiceStatus()
        refreshFSKitState()
        guard let proxy = proxy() else {
            let status = currentServiceStatus()
            if status == .requiresApproval {
                lastError = "请在系统设置中批准 EDP USB Vault 后台服务"
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
                    self.lastError = nil
                } catch {
                    self.lastError = String(data: data, encoding: .utf8) ?? error.localizedDescription
                }
                self.refreshServiceStatus()
            }
        }
    }

    private func rawAuthorizationData(deviceID: String) throws -> Data {
        guard let device = snapshot.devices.first(where: { $0.deviceID == deviceID }) else {
            throw NSError(
                domain: "com.edp.usbvault.authorization",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "EDP 设备已断开或尚未刷新"]
            )
        }
        if rawAuthorizationRef == nil {
            rawAuthorizationRef = try createAuthorizationRef()
        }
        guard let rawAuthorizationRef else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errAuthorizationInvalidRef))
        }
        let rawPath = "/dev/r\(device.bsdName)"
        let rightName = "sys.openfile.readonly.\(rawPath)"
        return try authorizationData(for: rightName, using: rawAuthorizationRef)
    }

    func authorize(deviceID: String, password: String) {
        guard requireMacFUSEFSKit(), !password.isEmpty, let proxy = proxy() else { return }
        let rawAuthorization: Data
        do {
            rawAuthorization = try rawAuthorizationData(deviceID: deviceID)
        } catch {
            lastError = "无法取得磁盘访问授权：\(error.localizedDescription)"
            return
        }
        isBusy = true
        proxy.authorize(
            deviceID: deviceID,
            password: Data(password.utf8),
            rawAuthorization: rawAuthorization
        ) { [weak self] errorMessage in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                self.lastError = errorMessage
                self.refresh()
            }
        }
    }

    func grantRawAccess(deviceID: String) {
        guard requireMacFUSEFSKit(), let proxy = proxy() else { return }
        let authorization: Data
        do {
            authorization = try rawAuthorizationData(deviceID: deviceID)
        } catch {
            lastError = "无法取得磁盘访问授权：\(error.localizedDescription)"
            return
        }
        isBusy = true
        proxy.grantRawAccess(authorization: authorization) { [weak self] grantError in
            guard grantError == nil else {
                Task { @MainActor in
                    guard let self else { return }
                    self.isBusy = false
                    self.lastError = grantError
                    self.refresh()
                }
                return
            }
            proxy.retryMount(deviceID: deviceID) { [weak self] mountError in
                Task { @MainActor in
                    guard let self else { return }
                    self.isBusy = false
                    self.lastError = mountError
                    self.refresh()
                }
            }
        }
    }

    func retryMount(deviceID: String) {
        guard requireMacFUSEFSKit(), let proxy = proxy() else { return }
        let authorization: Data
        do {
            authorization = try rawAuthorizationData(deviceID: deviceID)
        } catch {
            lastError = "无法取得磁盘访问授权：\(error.localizedDescription)"
            return
        }
        isBusy = true
        proxy.grantRawAccess(authorization: authorization) { [weak self] grantError in
            guard grantError == nil else {
                Task { @MainActor in
                    guard let self else { return }
                    self.isBusy = false
                    self.lastError = grantError
                    self.refresh()
                }
                return
            }
            proxy.retryMount(deviceID: deviceID) { [weak self] mountError in
                Task { @MainActor in
                    guard let self else { return }
                    self.isBusy = false
                    self.lastError = mountError
                    self.refresh()
                }
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
                    if !device.rawAccessReady {
                        Button("启用磁盘访问") { model.grantRawAccess(deviceID: device.deviceID) }
                            .disabled(model.isBusy)
                    } else if !device.mounted {
                        Button("挂载交换区") { model.retryMount(deviceID: device.deviceID) }
                            .disabled(model.isBusy)
                    }
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

            if model.macFUSEFSKitReady == false {
                HStack {
                    Label("macFUSE 运行组件未安装完整，挂载操作已暂停", systemImage: "puzzlepiece.extension")
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

@main
struct EDPUSBVaultApp: App {
    init() {
        if let index = CommandLine.arguments.firstIndex(of: "--xpc-mount-smoke"),
           CommandLine.arguments.count > index + 2 {
            let bsdName = CommandLine.arguments[index + 1]
            let deviceID = CommandLine.arguments[index + 2]
            do {
                let authorization = try createAuthorizationRef()
                defer { AuthorizationFree(authorization, []) }
                let rawPath = "/dev/r\(bsdName)"
                let external = try authorizationData(
                    for: "sys.openfile.readonly.\(rawPath)",
                    using: authorization
                )

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

                let grantResult = EDPXPCSmokeResult()
                let grantSemaphore = DispatchSemaphore(value: 0)
                proxy.grantRawAccess(authorization: external) { errorMessage in
                    grantResult.set(passed: errorMessage == nil, detail: errorMessage ?? "raw authorization accepted")
                    grantSemaphore.signal()
                }
                guard grantSemaphore.wait(timeout: .now() + 15) == .success else {
                    print("RESULT=XPC_MOUNT_SMOKE_GRANT_TIMEOUT")
                    exit(1)
                }
                let grant = grantResult.snapshot()
                guard grant.0 else {
                    print("XPC_MOUNT_SMOKE_DETAIL=\(grant.1)")
                    print("RESULT=XPC_MOUNT_SMOKE_GRANT_FAILED")
                    exit(1)
                }

                let mountResult = EDPXPCSmokeResult()
                let mountSemaphore = DispatchSemaphore(value: 0)
                proxy.retryMount(deviceID: deviceID) { errorMessage in
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
            } catch {
                print("XPC_MOUNT_SMOKE_AUTH_ERROR=\(error.localizedDescription)")
                print("RESULT=XPC_MOUNT_SMOKE_FAILED")
                exit(1)
            }
        }

        if CommandLine.arguments.contains("--grant-raw-access-smoke") {
            do {
                let authorization = try makeRawDeviceAuthorization()
                defer { AuthorizationFree(authorization.0, []) }
                let result = EDPXPCSmokeResult()
                let semaphore = DispatchSemaphore(value: 0)
                let connection = NSXPCConnection(machServiceName: edpVaultMachServiceName, options: .privileged)
                connection.remoteObjectInterface = NSXPCInterface(with: EDPVaultXPCProtocol.self)
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    result.set(passed: false, detail: error.localizedDescription)
                    semaphore.signal()
                }) as? EDPVaultXPCProtocol else {
                    print("RESULT=RAW_ACCESS_XPC_PROXY_UNAVAILABLE")
                    exit(1)
                }
                connection.resume()
                proxy.grantRawAccess(authorization: authorization.1) { errorMessage in
                    result.set(
                        passed: errorMessage == nil,
                        detail: errorMessage ?? "raw authorization accepted"
                    )
                    semaphore.signal()
                }
                guard semaphore.wait(timeout: .now() + 10) == .success else {
                    connection.invalidate()
                    print("RESULT=RAW_ACCESS_XPC_TIMEOUT")
                    exit(1)
                }
                connection.invalidate()
                let captured = result.snapshot()
                print("RAW_ACCESS_XPC_DETAIL=\(captured.1)")
                print(captured.0 ? "RESULT=RAW_ACCESS_XPC_OK" : "RESULT=RAW_ACCESS_XPC_FAILED")
                exit(captured.0 ? 0 : 1)
            } catch {
                print("RAW_ACCESS_AUTH_ERROR=\(error.localizedDescription)")
                print("RESULT=RAW_ACCESS_XPC_FAILED")
                exit(1)
            }
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
                print("SNAPSHOT_DEVICE=\(device.bsdName)|\(device.deviceID)|\(device.vidPID)|\(device.sizeBytes)|authorized=\(device.authorized)|mounted=\(device.mounted)|rawAccessReady=\(device.rawAccessReady)|partitions=\(device.partitionTypes.map(String.init).joined(separator: ","))")
            }
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
                let service = SMAppService.daemon(plistName: "com.edp.usbvault.mountd.plist")
                do {
                    if service.status == .notRegistered {
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
                let legacyURL = URL(fileURLWithPath: "/Library/LaunchDaemons/com.edp.usbvault.mountd.plist")
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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
