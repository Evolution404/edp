import AppKit
import SwiftUI

struct EDPMenuBarView: View {
    @ObservedObject var model: EDPVaultViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var credentialTarget: EDPCredentialTarget?

    private var connectedDevices: [EDPXPCDevice] {
        model.snapshot.devices.filter(\.connected)
    }

    private var serviceIsRunning: Bool {
        model.serviceStatus == "运行中"
    }

    private var serviceIsStopped: Bool {
        model.serviceStatus == "已停止"
    }

    private var serviceStatusIcon: String {
        if serviceIsRunning { return "checkmark.circle.fill" }
        if serviceIsStopped { return "stop.circle.fill" }
        if model.serviceStatus == "需要系统批准" { return "exclamationmark.triangle.fill" }
        if model.serviceStatus.contains("正在") || model.serviceStatus.contains("检查") {
            return "clock.fill"
        }
        return "circle.fill"
    }

    private var serviceStatusColor: Color {
        if serviceIsRunning { return .green }
        if serviceIsStopped { return .secondary }
        if model.serviceStatus == "需要系统批准" { return .orange }
        return .secondary
    }

    private var bodyHeight: CGFloat {
        let partitionCount = connectedDevices.reduce(0) { $0 + $1.partitions.count }
        let estimated = 150 + connectedDevices.count * 60 + partitionCount * 48
        return min(500, max(260, CGFloat(estimated)))
    }

    var body: some View {
        VStack(spacing: 0) {
            menuHeader

            ScrollView {
                VStack(spacing: 0) {
                    devicesSection

                    Divider().padding(.horizontal, 12)
                    autoMountRow

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
        .sheet(item: $credentialTarget) { target in
            EDPCredentialSheet(target: target, model: model)
        }
    }

    private var menuHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("EDP Drive")
                        .font(.system(size: 14, weight: .semibold))
                    Text("后台服务\(model.serviceStatus)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("打开主窗口") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .keyboardShortcut("o")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 7)

            HStack(spacing: 8) {
                Label("后台服务", systemImage: "gearshape.2")
                    .font(.caption.weight(.semibold))

                Image(systemName: serviceStatusIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(serviceStatusColor)
                    .help(model.serviceStatus)
                    .accessibilityLabel("后台服务状态：\(model.serviceStatus)")

                Spacer()

                serviceIconButton(
                    "启动",
                    systemImage: "play.fill",
                    enabled: !model.isBusy && !serviceIsRunning
                ) {
                    model.startService()
                }
                serviceIconButton(
                    "停止",
                    systemImage: "stop.fill",
                    enabled: !model.isBusy && !serviceIsStopped
                ) {
                    model.stopService()
                }
                serviceIconButton(
                    "重启",
                    systemImage: "arrow.clockwise",
                    enabled: !model.isBusy && serviceIsRunning
                ) {
                    model.restartService()
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(Color.primary.opacity(0.025))
    }

    private func serviceIconButton(
        _ title: String,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 23, height: 23)
        }
        .buttonStyle(.glass)
        .controlSize(.mini)
        .disabled(!enabled)
        .help(title)
        .accessibilityLabel(title)
    }

    private var autoMountRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("自动挂载")
                    .font(.system(size: 13, weight: .medium))
                Text(model.snapshot.globalAutoMountEnabled ? "已开启" : "已暂停")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("自动挂载", isOn: Binding(
                get: { model.snapshot.globalAutoMountEnabled },
                set: { model.setGlobalAutoMount($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(model.isBusy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(device.sizeBytes), countStyle: .file)) · 已连接")
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
                Text(mountAvailabilityText(partition) ?? partitionSummary(partition))
                    .font(.caption2)
                    .foregroundStyle(partition.mountState == .failed ? Color.red : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if partition.encrypted {
                Button {
                    credentialTarget = EDPCredentialTarget(
                        deviceID: device.deviceID,
                        partitionType: partition.partitionType,
                        partitionName: partition.displayName
                    )
                } label: {
                    Image(systemName: partition.credentialStatus == .saved ? "key.fill" : "key")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
                .disabled(model.isBusy || !device.connected)
                .help(partition.credentialStatus == .saved ? "更新密码" : "设置密码")
                .accessibilityLabel(partition.credentialStatus == .saved ? "更新\(partition.displayName)密码" : "设置\(partition.displayName)密码")
            }

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
                model.shutdownService {
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
            return "点击钥匙设置密码"
        }
        if partition.mountState == .failed {
            return partition.lastError ?? "上次挂载失败"
        }
        return nil
    }

    private func partitionSummary(_ partition: EDPXPCPartition) -> String {
        let status: String
        switch partition.mountState {
        case .unavailable: status = "不可用"
        case .unmounted: status = "未挂载"
        case .mounting: status = "正在挂载"
        case .mounted: status = partition.readOnly == true ? "只读" : "已挂载"
        case .failed: status = "挂载失败"
        }
        if let filesystem = partition.filesystem, !filesystem.isEmpty {
            return "\(filesystem) · \(status)"
        }
        return status
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
