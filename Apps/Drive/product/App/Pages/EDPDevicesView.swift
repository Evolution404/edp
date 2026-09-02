import Foundation
import SwiftUI

enum EDPDeviceSection: String, CaseIterable, Identifiable {
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
    @State private var deviceSection: EDPDeviceSection

    init(device: EDPXPCDevice, model: EDPVaultViewModel) {
        self.device = device
        _model = ObservedObject(wrappedValue: model)
        _deviceSection = State(initialValue: .overview)
    }

#if EDP_UI_PREVIEW
    init(device: EDPXPCDevice, model: EDPVaultViewModel, previewSection: EDPDeviceSection) {
        self.device = device
        _model = ObservedObject(wrappedValue: model)
        _deviceSection = State(initialValue: previewSection)
    }
#endif

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
                            .accessibilityHidden(true)
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
