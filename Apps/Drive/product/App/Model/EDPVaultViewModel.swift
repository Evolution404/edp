import AppKit
import Foundation
import ServiceManagement
import SwiftUI

private enum EDPServiceLifecycleState {
    case stopped
    case starting(id: UUID)
    case running
    case stopping(id: UUID, restartAfterStop: Bool, completion: (() -> Void)?)
    case failed(message: String)

    var operationID: UUID? {
        switch self {
        case .starting(let id), .stopping(let id, _, _): return id
        case .stopped, .running, .failed: return nil
        }
    }

    var restartAfterStop: Bool {
        if case .stopping(_, let restartAfterStop, _) = self { return restartAfterStop }
        return false
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
#if EDP_UI_PREVIEW
    private let previewConfiguration: EDPPreviewConfiguration
#endif
    private let daemonPlistName = "com.edp.drive.service.plist"
    private let legacyPlistURL = URL(fileURLWithPath: "/Library/LaunchDaemons/com.edp.drive.service.plist")
    private let servicePreferenceKey = "com.edp.drive.service.desired-running"
    private var connection: NSXPCConnection?
    private var connectionGeneration: UUID?
    private var serviceLifecycle: EDPServiceLifecycleState = .running

    func rawAccessState(for device: EDPXPCDevice) -> EDPRawAccessState {
        if let state = device.rawAccessState { return state }
        return device.privilegedAccessReady ? .ready : .pending
    }

    var needsFullDiskAccess: Bool {
        snapshot.devices.contains {
            $0.connected && rawAccessState(for: $0) == .permissionRequired
        }
    }

    var hasRawAccessBusyDevice: Bool {
        snapshot.devices.contains {
            $0.connected && rawAccessState(for: $0) == .busy
        }
    }

    var rawAccessReady: Bool {
        let connected = snapshot.devices.filter(\.connected)
        return !connected.isEmpty && connected.allSatisfy {
            rawAccessState(for: $0) == .ready
        }
    }

    var fullDiskAccessVerified: Bool {
        snapshot.devices.contains {
            guard $0.connected else { return false }
            let state = rawAccessState(for: $0)
            return state == .ready || state == .busy
        }
    }

    var fullDiskAccessStatusText: String {
        if needsFullDiskAccess { return "需要授权" }
        if fullDiskAccessVerified { return "已授权" }
        return "连接设备后验证"
    }

    var rawAccessHelperInstalled: Bool {
#if EDP_UI_PREVIEW
        previewConfiguration.rawAccessHelperInstalled
#else
        FileManager.default.isExecutableFile(atPath: edpDriveServicePath)
#endif
    }

    var rawAccessStatusText: String {
        guard rawAccessHelperInstalled else { return "组件未安装" }
        let connected = snapshot.devices.filter(\.connected)
        if connected.isEmpty {
            if snapshot.devices.contains(where: { rawAccessState(for: $0) == .logicallyEjected }) {
                return "已安全推出"
            }
            return "待连接 EDP U 盘验证"
        }
        if needsFullDiskAccess { return "需要完全磁盘访问" }
        if hasRawAccessBusyDevice { return "设备被系统占用" }
        if connected.contains(where: { rawAccessState(for: $0) == .unavailable }) {
            return "Raw Access 不可用"
        }
        if connected.allSatisfy({ rawAccessState(for: $0) == .ready }) {
            return "已验证"
        }
        return "正在验证"
    }

    var setupReady: Bool {
        serviceStatus == "运行中"
            && transportRuntimeReady == true
            && rawAccessHelperInstalled
            && rawAccessReady
    }

    init() {
#if EDP_UI_PREVIEW
        let configuration = EDPPreviewScenarioFactory.configuration(
            for: EDPPreviewScenario.fromCommandLine()
        )
        previewConfiguration = configuration
        serviceMode = "preview"
        daemonService = nil
        snapshot = configuration.snapshot
        serviceStatus = configuration.serviceStatus
        transportRuntimeReady = configuration.transportRuntimeReady
        serviceDesiredRunning = configuration.serviceDesiredRunning
        return
#else
        serviceMode = Bundle.main.object(forInfoDictionaryKey: "EDPServiceMode") as? String ?? "legacy"
        daemonService = serviceMode == "smappservice"
            ? SMAppService.daemon(plistName: daemonPlistName)
            : nil
        // Explicitly opening EDP Drive always restores the discovery daemon.
        // A prior in-app Stop/Complete Quit applies to that running UI session;
        // it must not leave the next app launch looking healthy while the
        // Disk Arbitration/IOKit discovery service remains intentionally off.
        serviceDesiredRunning = true
        persistServicePreference()
        ensureServiceRegistration()
        refreshTransportRuntimeState()
        refresh()
        resumeRuntimeForAppLaunch()
        Task { [weak self] in
            let enablement = await Task.detached(priority: .utility) { () async -> (restartedAgents: Bool, error: String?) in
                do {
                    let restartedAgents = try await ensureMacFUSELocalEnablement()
                    guard macFUSELocalEnablementReady() else {
                        return (restartedAgents, "macFUSE FSKit 启用状态尚未就绪")
                    }
                    return (restartedAgents, nil)
                } catch {
                    return (false, error.localizedDescription)
                }
            }.value
            guard let self else { return }
            if let error = enablement.error {
                self.lastError = "macFUSE Local 启用失败：\(error)"
            }
            // Registration commands and settings writes above are completion
            // authorities. Do not add a fixed post-registration sleep: the
            // FSKit agent is demand-launched when the next mount is requested.
            self.refreshTransportRuntimeState()
            if self.transportRuntimeReady == true {
                self.retryTransientAutomaticMounts()
            }
            self.refresh()
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
    init(previewConfiguration configuration: EDPPreviewConfiguration) {
        previewConfiguration = configuration
        serviceMode = "preview"
        daemonService = nil
        snapshot = configuration.snapshot
        serviceStatus = configuration.serviceStatus
        transportRuntimeReady = configuration.transportRuntimeReady
        serviceDesiredRunning = configuration.serviceDesiredRunning
    }
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
            switch serviceLifecycle {
            case .stopping(_, let restartAfterStop, _):
                serviceStatus = restartAfterStop ? "正在重启…" : "正在停止…"
            case .starting:
                serviceStatus = "正在启动…"
            case .running:
                if !serviceDesiredRunning {
                    serviceStatus = "已停止"
                } else if connection != nil {
                    serviceStatus = "运行中"
                } else {
                    serviceStatus = "等待按需启动"
                }
            case .stopped:
                serviceStatus = serviceDesiredRunning ? "等待按需启动" : "已停止"
            case .failed:
                serviceStatus = serviceDesiredRunning ? "状态异常" : "已停止"
            }
        case .requiresApproval: serviceStatus = "需要系统批准"
        case .notRegistered: serviceStatus = "未注册"
        case .notFound: serviceStatus = "未安装"
        @unknown default: serviceStatus = "未知"
        }
    }

    private func persistServicePreference() {
        UserDefaults.standard.set(serviceDesiredRunning, forKey: servicePreferenceKey)
    }

    private func armServiceTimeout(id: UUID, operation: String, seconds: Double = 12) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.serviceLifecycle.operationID == id else { return }
            self.serviceLifecycle = .failed(message: "后台服务\(operation)超时")
            self.serviceDesiredRunning = true
            self.persistServicePreference()
            self.isBusy = false
            self.lastError = "后台服务\(operation)超时"
            self.serviceStatus = "状态未知（\(operation)超时）"
        }
    }

    private func serviceConnectionEnded() {
        connection = nil
        connectionGeneration = nil
        let priorState = serviceLifecycle

        switch priorState {
        case .stopping(_, let restartAfterStop, let completion):
            serviceLifecycle = .stopped
            serviceDesiredRunning = false
            persistServicePreference()
            isBusy = false
            serviceStatus = "已停止"
            if restartAfterStop {
                startService()
            } else {
                completion?()
            }
        case .starting:
            serviceLifecycle = .failed(message: "后台服务启动期间连接中断")
            isBusy = false
            serviceStatus = "启动失败"
            lastError = "后台服务启动期间连接中断"
        case .running:
            serviceLifecycle = .failed(message: "后台服务连接已中断")
            isBusy = false
            serviceStatus = "连接已中断"
        case .stopped, .failed:
            isBusy = false
            serviceStatus = "已停止"
        }
    }

    func startService() {
        switch serviceLifecycle {
        case .running:
            if !serviceDesiredRunning {
                resumePausedRuntime()
                return
            }
            serviceDesiredRunning = true
            persistServicePreference()
            return
        case .starting:
            serviceDesiredRunning = true
            persistServicePreference()
            return
        case .stopping(let id, _, _):
            serviceLifecycle = .stopping(id: id, restartAfterStop: true, completion: nil)
            return
        case .stopped:
            if connection != nil {
                resumePausedRuntime()
                return
            }
        case .failed:
            break
        }

        serviceDesiredRunning = true
        persistServicePreference()
        ensureServiceRegistration()
        guard currentServiceStatus() == .enabled else {
            let message = "后台服务尚未注册、启用或批准"
            serviceLifecycle = .failed(message: message)
            lastError = message
            return
        }

        connection?.invalidate()
        connection = nil
        connectionGeneration = nil
        isBusy = true
        serviceStatus = "正在启动…"
        lastError = nil
        let operationID = UUID()
        serviceLifecycle = .starting(id: operationID)
        armServiceTimeout(id: operationID, operation: "启动")

        guard let connection = connectIfNeeded(),
              let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable [weak self] error in
                  Task { @MainActor in
                      guard let self,
                            case .starting(let currentID) = self.serviceLifecycle,
                            currentID == operationID else { return }
                      let message = "后台服务启动失败：\(error.localizedDescription)"
                      self.serviceLifecycle = .failed(message: message)
                      self.isBusy = false
                      self.lastError = message
                      self.refreshServiceStatus()
                  }
              }) as? EDPVaultXPCProtocol else {
            let message = "无法建立后台服务连接"
            serviceLifecycle = .failed(message: message)
            isBusy = false
            lastError = message
            return
        }

        proxy.healthCheck { @Sendable [weak self] response in
            Task { @MainActor in
                guard let self,
                      case .starting(let currentID) = self.serviceLifecycle,
                      currentID == operationID else { return }
                guard response == "com.edp.drive.service:running" else {
                    let message = "后台服务返回了无效健康状态"
                    self.serviceLifecycle = .failed(message: message)
                    self.lastError = message
                    self.isBusy = false
                    return
                }
                self.serviceLifecycle = .running
                self.isBusy = false
                self.serviceStatus = "运行中"
                self.retryTransientAutomaticMounts()
                self.refresh()
            }
        }
    }

    private func resumeRuntimeForAppLaunch() {
        guard let activeConnection = connection ?? connectIfNeeded(),
              let proxy = activeConnection.remoteObjectProxyWithErrorHandler({ @Sendable [weak self] error in
                  Task { @MainActor in
                      self?.lastError = "后台运行时恢复失败：\(error.localizedDescription)"
                  }
              }) as? EDPVaultXPCProtocol else { return }
        proxy.requestRuntimeResume { @Sendable [weak self] errorMessage in
            Task { @MainActor in
                guard let self else { return }
                if let errorMessage {
                    self.lastError = "后台运行时恢复失败：\(errorMessage)"
                } else {
                    self.refresh()
                }
            }
        }
    }

    private func resumePausedRuntime() {
        serviceDesiredRunning = true
        persistServicePreference()
        isBusy = true
        serviceStatus = "正在启动…"
        lastError = nil
        let operationID = UUID()
        serviceLifecycle = .starting(id: operationID)
        armServiceTimeout(id: operationID, operation: "启动")

        guard let activeConnection = connection ?? connectIfNeeded(),
              let proxy = activeConnection.remoteObjectProxyWithErrorHandler({ @Sendable [weak self] error in
                  Task { @MainActor in
                      guard let self,
                            case .starting(let currentID) = self.serviceLifecycle,
                            currentID == operationID else { return }
                      let message = "后台服务启动失败：\(error.localizedDescription)"
                      self.serviceLifecycle = .failed(message: message)
                      self.serviceDesiredRunning = false
                      self.persistServicePreference()
                      self.isBusy = false
                      self.lastError = message
                      self.serviceStatus = "启动失败"
                  }
              }) as? EDPVaultXPCProtocol else {
            let message = "后台服务已暂停，但无法建立安全 XPC 连接"
            serviceLifecycle = .failed(message: message)
            serviceDesiredRunning = false
            persistServicePreference()
            isBusy = false
            lastError = message
            serviceStatus = "启动失败"
            return
        }

        proxy.requestRuntimeResume { @Sendable [weak self] errorMessage in
            Task { @MainActor in
                guard let self,
                      case .starting(let currentID) = self.serviceLifecycle,
                      currentID == operationID else { return }
                if let errorMessage {
                    let message = "后台服务启动失败：\(errorMessage)"
                    self.serviceLifecycle = .failed(message: message)
                    self.serviceDesiredRunning = false
                    self.persistServicePreference()
                    self.isBusy = false
                    self.lastError = message
                    self.serviceStatus = "启动失败"
                    return
                }
                self.serviceLifecycle = .running
                self.serviceDesiredRunning = true
                self.persistServicePreference()
                self.isBusy = false
                self.serviceStatus = "运行中"
                self.refresh()
            }
        }
    }

    func stopService(completion: (() -> Void)? = nil) {
        switch serviceLifecycle {
        case .stopped:
            serviceDesiredRunning = false
            persistServicePreference()
            completion?()
            return
        case .stopping:
            return
        case .running, .starting, .failed:
            break
        }

        guard let activeConnection = connection ?? connectIfNeeded(),
              let proxy = activeConnection.remoteObjectProxyWithErrorHandler({ @Sendable [weak self] error in
                  Task { @MainActor in
                      guard let self,
                            case .stopping = self.serviceLifecycle else { return }
                      let message = "后台服务停止失败：\(error.localizedDescription)"
                      self.serviceLifecycle = .failed(message: message)
                      self.serviceDesiredRunning = true
                      self.persistServicePreference()
                      self.isBusy = false
                      self.lastError = message
                      self.serviceStatus = "状态异常"
                  }
              }) as? EDPVaultXPCProtocol else {
            let message = "无法建立安全 XPC 连接，未暂停后台运行时"
            serviceLifecycle = .failed(message: message)
            serviceDesiredRunning = true
            persistServicePreference()
            serviceStatus = "状态异常"
            lastError = message
            return
        }

        serviceDesiredRunning = false
        persistServicePreference()
        isBusy = true
        serviceStatus = "正在停止…"
        lastError = nil
        let operationID = UUID()
        serviceLifecycle = .stopping(
            id: operationID,
            restartAfterStop: false,
            completion: completion
        )
        armServiceTimeout(id: operationID, operation: "停止")

        proxy.requestRuntimePause { @Sendable [weak self] errorMessage in
            Task { @MainActor in
                guard let self,
                      case .stopping(let currentID, _, let completion) = self.serviceLifecycle,
                      currentID == operationID else { return }
                if let errorMessage {
                    let message = "后台服务停止失败：\(errorMessage)"
                    self.serviceLifecycle = .failed(message: message)
                    self.serviceDesiredRunning = true
                    self.persistServicePreference()
                    self.isBusy = false
                    self.lastError = message
                    self.serviceStatus = "状态异常"
                    return
                }
                self.serviceLifecycle = .stopped
                self.serviceDesiredRunning = false
                self.persistServicePreference()
                self.isBusy = false
                self.serviceStatus = "已停止"
                self.refresh()
                completion?()
            }
        }
    }

    func restartService() {
        guard case .running = serviceLifecycle else {
            if case .stopped = serviceLifecycle { startService() }
            return
        }
        guard let activeConnection = connection ?? connectIfNeeded(),
              let proxy = activeConnection.remoteObjectProxyWithErrorHandler({ @Sendable [weak self] error in
                  Task { @MainActor in
                      guard let self else { return }
                      let message = "后台服务重启失败：\(error.localizedDescription)"
                      self.serviceLifecycle = .failed(message: message)
                      self.isBusy = false
                      self.lastError = message
                      self.serviceStatus = "状态异常"
                  }
              }) as? EDPVaultXPCProtocol else {
            let message = "无法建立安全 XPC 连接，未执行后台运行时重启"
            serviceLifecycle = .failed(message: message)
            lastError = message
            serviceStatus = "状态异常"
            return
        }

        serviceDesiredRunning = true
        persistServicePreference()
        isBusy = true
        serviceStatus = "正在重启…"
        lastError = nil
        let operationID = UUID()
        serviceLifecycle = .starting(id: operationID)
        armServiceTimeout(id: operationID, operation: "重启")
        proxy.requestRuntimeRestart { @Sendable [weak self] errorMessage in
            Task { @MainActor in
                guard let self,
                      case .starting(let currentID) = self.serviceLifecycle,
                      currentID == operationID else { return }
                if let errorMessage {
                    let message = "后台服务重启失败：\(errorMessage)"
                    self.serviceLifecycle = .failed(message: message)
                    self.isBusy = false
                    self.lastError = message
                    self.serviceStatus = "状态异常"
                    return
                }
                self.serviceLifecycle = .running
                self.isBusy = false
                self.serviceStatus = "运行中"
                self.refresh()
            }
        }
    }

    func shutdownService(completion: (() -> Void)? = nil) {
        guard let activeConnection = connection ?? connectIfNeeded(),
              let proxy = activeConnection.remoteObjectProxyWithErrorHandler({ @Sendable [weak self] error in
                  Task { @MainActor in
                      guard let self else { return }
                      self.isBusy = false
                      self.lastError = "后台服务退出失败：\(error.localizedDescription)"
                  }
              }) as? EDPVaultXPCProtocol else {
            completion?()
            return
        }
        isBusy = true
        serviceStatus = "正在安全推出设备并完全退出…"
        lastError = nil
        let operationID = UUID()
        serviceLifecycle = .stopping(
            id: operationID,
            restartAfterStop: false,
            completion: completion
        )
        armServiceTimeout(id: operationID, operation: "完全退出", seconds: 90)

        // A true process exit releases the Disk Arbitration session and every
        // physical claim. Resume first (idempotent) so a paused runtime refreshes
        // the current physical-generation list, then safe-eject every connected
        // EDP device before asking launchd to terminate the privileged process.
        proxy.requestRuntimeResume { @Sendable [weak self] errorMessage in
            Task { @MainActor in
                guard let self,
                      case .stopping(let currentID, _, _) = self.serviceLifecycle,
                      currentID == operationID else { return }
                if let errorMessage {
                    self.failFullExit(operationID: operationID, detail: errorMessage)
                    return
                }
                self.loadFullExitDeviceIDs(operationID: operationID)
            }
        }
    }

    private func loadFullExitDeviceIDs(operationID: UUID) {
        guard let proxy = proxy() else {
            failFullExit(operationID: operationID, detail: "无法读取安全推出设备列表")
            return
        }
        proxy.snapshot { @Sendable [weak self] data in
            Task { @MainActor in
                guard let self,
                      case .stopping(let currentID, _, _) = self.serviceLifecycle,
                      currentID == operationID else { return }
                do {
                    let current = try JSONDecoder().decode(EDPXPCSnapshot.self, from: data)
                    let deviceIDs = current.devices.filter(\.connected).map(\.deviceID)
                    self.ejectNextForFullExit(
                        deviceIDs: deviceIDs,
                        index: 0,
                        operationID: operationID
                    )
                } catch {
                    self.failFullExit(
                        operationID: operationID,
                        detail: "无法解析安全推出设备列表：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func ejectNextForFullExit(
        deviceIDs: [String],
        index: Int,
        operationID: UUID
    ) {
        guard case .stopping(let currentID, _, _) = serviceLifecycle,
              currentID == operationID else { return }
        guard index < deviceIDs.count else {
            requestProcessShutdownForFullExit(operationID: operationID)
            return
        }
        guard let proxy = proxy() else {
            failFullExit(operationID: operationID, detail: "安全推出期间 XPC 连接不可用")
            return
        }
        proxy.eject(deviceID: deviceIDs[index]) { @Sendable [weak self] errorMessage in
            Task { @MainActor in
                guard let self,
                      case .stopping(let currentID, _, _) = self.serviceLifecycle,
                      currentID == operationID else { return }
                if let errorMessage {
                    self.failFullExit(
                        operationID: operationID,
                        detail: "设备安全推出失败：\(errorMessage)"
                    )
                    return
                }
                self.ejectNextForFullExit(
                    deviceIDs: deviceIDs,
                    index: index + 1,
                    operationID: operationID
                )
            }
        }
    }

    private func requestProcessShutdownForFullExit(operationID: UUID) {
        guard let proxy = proxy() else {
            failFullExit(operationID: operationID, detail: "完全退出期间 XPC 连接不可用")
            return
        }
        proxy.requestGracefulShutdown { @Sendable [weak self] errorMessage in
            Task { @MainActor in
                guard let self,
                      case .stopping(let currentID, _, _) = self.serviceLifecycle,
                      currentID == operationID else { return }
                if let errorMessage {
                    self.failFullExit(operationID: operationID, detail: errorMessage)
                    return
                }
                // Receipt of this reply is the authoritative drain event. ACK it
                // explicitly so the service can exit without a fixed delay.
                guard let acknowledgementProxy = self.proxy() else {
                    self.failFullExit(operationID: operationID, detail: "完全退出确认期间 XPC 连接不可用")
                    return
                }
                acknowledgementProxy.acknowledgeGracefulShutdownReply()
                // Success is completed by serviceConnectionEnded(), after the
                // privileged process actually exits and the XPC connection ends.
            }
        }
    }

    private func failFullExit(operationID: UUID, detail: String) {
        guard case .stopping(let currentID, _, _) = serviceLifecycle,
              currentID == operationID else { return }
        serviceLifecycle = .failed(message: detail)
        serviceDesiredRunning = true
        persistServicePreference()
        isBusy = false
        lastError = "后台服务退出失败：\(detail)"
        serviceStatus = "状态异常"
    }

    func openServiceSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func refreshTransportRuntimeState() {
        transportRuntimeReady = macFUSELocalEnablementReady()
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

    func setDefaultAutoMount(partitionType: UInt32, enabled: Bool) {
        guard let proxy = proxy() else { return }
        proxy.setDefaultPartitionAutoMount(
            partitionType: partitionType,
            enabled: enabled
        ) { @Sendable [weak self] errorMessage in
            Task { @MainActor in
                self?.lastError = errorMessage
                self?.refresh()
            }
        }
    }

    func setDefaultAutoProbePassword(partitionType: UInt32, enabled: Bool) {
        guard let proxy = proxy() else { return }
        proxy.setDefaultPartitionAutoProbePassword(
            partitionType: partitionType,
            enabled: enabled
        ) { @Sendable [weak self] errorMessage in
            Task { @MainActor in
                self?.lastError = errorMessage
                self?.refresh()
            }
        }
    }

    func setDefaultProbePassword(partitionType: UInt32, password: String) {
        guard !password.isEmpty, let proxy = proxy() else { return }
        isBusy = true
        proxy.setDefaultProbePassword(
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

    func resetDefaultProbePassword(partitionType: UInt32) {
        guard let proxy = proxy() else { return }
        isBusy = true
        proxy.resetDefaultProbePassword(partitionType: partitionType) { @Sendable [weak self] errorMessage in
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                self.lastError = errorMessage
                self.refresh()
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
