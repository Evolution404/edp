import Foundation
import SwiftUI

struct EDPOverviewView: View {
    @ObservedObject var model: EDPVaultViewModel

    private var overviewDevices: [EDPXPCDevice] {
        model.snapshot.devices.sorted { lhs, rhs in
            if lhs.connected != rhs.connected { return lhs.connected && !rhs.connected }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    private var showsMultipleDevices: Bool {
        overviewDevices.count > 1
    }

    private var rawAccessReady: Bool {
        let connectedDevices = overviewDevices.filter(\.connected)
        guard !connectedDevices.isEmpty else { return !model.needsFullDiskAccess }
        return connectedDevices.allSatisfy(\.privilegedAccessReady)
    }

    private func firstFinderPartition(for device: EDPXPCDevice) -> EDPXPCPartition? {
        device.partitions.first { $0.mountState == .mounted && $0.mountPoint != nil }
    }

    private func mountablePartitionCount(for device: EDPXPCDevice) -> Int {
        device.partitions.filter {
            $0.mountState != .mounted && (!$0.encrypted || $0.credentialStatus == .saved)
        }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EDPTheme.Spacing.lg) {
                if overviewDevices.isEmpty {
                    deviceEmptyState
                } else {
                    ForEach(overviewDevices) { device in
                        deviceHero(device)
                    }
                }

                systemStatusStrip

                ForEach(overviewDevices) { device in
                    partitionStructure(device)
                }

                if overviewDevices.count == 1, let device = overviewDevices.first {
                    HStack(alignment: .top, spacing: EDPTheme.Spacing.lg) {
                        quickActions(device)
                            .frame(maxWidth: .infinity, alignment: .top)
                        recentActivity
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                } else {
                    ForEach(overviewDevices) { device in
                        quickActions(device)
                    }
                    recentActivity
                }
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

    private func deviceHero(_ device: EDPXPCDevice) -> some View {
        EDPContentCard {
            HStack(spacing: EDPTheme.Spacing.md) {
                Image(systemName: device.connected ? "externaldrive.fill" : "externaldrive")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(device.connected ? Color.accentColor : .secondary)
                    .frame(width: 62, height: 62)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .accessibilityHidden(true)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(device.displayName)，\(device.connected ? "已连接" : "已保存")，\(device.mediaName)，\(device.vidPID)")
    }

    private var deviceEmptyState: some View {
        EDPEmptyState(
            "未发现 EDP U 盘",
            message: "插入标准 EDP 加密盘后会自动识别；普通 U 盘和免密改造盘继续由 macOS 接管。",
            systemImage: "externaldrive.badge.questionmark"
        )
    }

    private var systemStatusStrip: some View {
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
                    ready: rawAccessReady
                )
                Divider().frame(height: 42)
                EDPOverviewStatusCell(
                    title: "macFUSE",
                    value: model.transportRuntimeReady == true ? "就绪" : "需安装",
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

    private func partitionStructure(_ device: EDPXPCDevice) -> some View {
        VStack(alignment: .leading, spacing: EDPTheme.Spacing.sm) {
            EDPSectionHeader(
                showsMultipleDevices ? "\(device.displayName) · 分区结构" : "分区结构",
                subtitle: nil,
                systemImage: "rectangle.split.3x1"
            ) {
                Text("\(device.partitions.count) 个分区")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            EDPContentCard(padding: 0) {
                HStack(spacing: 1) {
                    ForEach(device.partitions) { partition in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: partitionIcon(partition))
                                    .foregroundStyle(partitionTint(partition))
                                Text(partition.displayName)
                                    .font(.headline)
                                    .lineLimit(1)
                            }
                            Text(partition.filesystem ?? (partition.encrypted ? "加密分区" : "文件系统待检测"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(partitionStatus(partition))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(partition.mountState == .failed ? .red : partitionTint(partition))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(partitionTint(partition).opacity(0.10))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: EDPTheme.Radius.row, style: .continuous))
            }
        }
    }

    private func quickActions(_ device: EDPXPCDevice) -> some View {
        VStack(alignment: .leading, spacing: EDPTheme.Spacing.sm) {
            EDPSectionHeader(
                showsMultipleDevices ? "\(device.displayName) · 快捷操作" : "快捷操作",
                subtitle: "\(device.partitions.filter { $0.mountState == .mounted }.count) / \(device.partitions.count) 分区已挂载",
                systemImage: "bolt"
            )
            EDPContentCard {
                HStack(spacing: EDPTheme.Spacing.sm) {
                    if let partition = firstFinderPartition(for: device) {
                        overviewActionButton("在 Finder 中显示", systemImage: "folder") {
                            model.openInFinder(partition)
                        }
                    }
                    overviewActionButton("挂载全部", systemImage: "externaldrive.badge.plus") {
                        model.mountAllAvailablePartitions(device)
                    }
                    .disabled(!device.connected || model.isBusy || mountablePartitionCount(for: device) == 0)
                    overviewActionButton("安全推出整盘", systemImage: "eject") {
                        model.eject(deviceID: device.deviceID)
                    }
                    .disabled(!device.connected || model.isBusy)
                }
            }
        }
    }

    private func overviewActionButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .medium))
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 62)
        }
        .buttonStyle(.glass)
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: EDPTheme.Spacing.sm) {
            EDPSectionHeader(
                "最近活动",
                subtitle: "最新的设备与挂载事件",
                systemImage: "clock.arrow.circlepath"
            )
            EDPContentCard {
                if model.snapshot.activities.isEmpty {
                    Text("暂无活动记录")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.snapshot.activities.prefix(5)).indices, id: \.self) { index in
                            let activity = model.snapshot.activities[index]
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: activity.level == "error" ? "exclamationmark.triangle.fill" : "circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(activity.level == "error" ? .red : .secondary)
                                    .accessibilityHidden(true)
                                Text(activity.message)
                                    .lineLimit(2)
                                Spacer()
                                Text(activity.timestamp)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                            if index < min(4, model.snapshot.activities.count - 1) {
                                Divider().padding(.leading, 20)
                            }
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

    private func partitionTint(_ partition: EDPXPCPartition) -> Color {
        switch EDPPartitionKind(rawValue: partition.partitionType) {
        case .boot: return .blue
        case .exchange: return .green
        case .secure: return .purple
        case nil: return .accentColor
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)：\(value)")
    }
}
