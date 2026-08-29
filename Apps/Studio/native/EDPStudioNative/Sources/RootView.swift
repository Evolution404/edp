import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(SidebarDestination.allCases, selection: $model.selection) { item in
                Label(item.title, systemImage: item.systemImage)
                    .tag(item)
            }
            .navigationTitle("EDP Studio")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
        } detail: {
            detailWithInspector
                .navigationTitle(model.selection.title)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        DiskIdentityPill(disk: model.selectedDetectedDisk)
                    }

                    ToolbarItemGroup {
                        Button {
                            model.inspectorVisible.toggle()
                        } label: {
                            Label("检查器", systemImage: "sidebar.trailing")
                        }
                        .buttonStyle(.glass)
                        .help("显示或隐藏检查器")
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var detailWithInspector: some View {
        if model.inspectorVisible {
            HSplitView {
                detailView
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

                InspectorView()
                    .environment(model)
                    .padding(8)
                    .frame(minWidth: 256, idealWidth: 306, maxWidth: 376)
            }
        } else {
            detailView
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch model.selection {
        case .overview:
            OverviewView()
        case .map:
            DiskMapView()
        case .sector:
            SectorView()
        case .editor:
            NativePlaceholderView(
                icon: "pencil.and.outline",
                title: "原生扇区编辑器",
                message: "下一阶段接入现有 Rust 重加密核心；视觉与交互沿用扇区页。"
            )
        case .conversion:
            NativePlaceholderView(
                icon: "wand.and.sparkles",
                title: "免密改造",
                message: "待 Swift FDA broker 接入后复用现有 Rust convert/golden 逻辑。"
            )
        case .backups:
            NativePlaceholderView(
                icon: "clock.arrow.circlepath",
                title: "备份与还原",
                message: "保留 7168B + MD5 + LBA4 ID 安全模型，迁移为原生列表与时间线。"
            )
        }
    }
}

private struct DiskIdentityPill: View {
    let disk: RawBrokerDisk?

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: disk == nil ? "externaldrive.badge.questionmark" : "externaldrive.fill")
                    .foregroundStyle(disk == nil ? Color.secondary : Color.accentColor)
                VStack(alignment: .leading, spacing: 0) {
                    if let disk {
                        Text("\(disk.diskName) · \(disk.displayName)")
                            .font(.system(size: 12, weight: .semibold))
                        Text("\(disk.capacityText) · external physical USB")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("未检测到外置 USB")
                            .font(.system(size: 12, weight: .semibold))
                        Text("由 Raw Broker 实时枚举")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
    }
}

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                inspectorHeader
                Divider()
                diskSection

                if model.selection == .sector || model.selection == .editor {
                    Divider()
                    byteSection
                }

                Divider()
                legendSection
            }
            .padding(18)
        }
        // Keep the inspector as a real HSplitView column so it never overlays scrollable
        // content, but render the column itself as a floating macOS 26 glass sidebar.
        // The outer padding is applied by RootView so the rounded glass surface has the
        // same detached-from-window-edge character as NavigationSplitView's sidebar.
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.separator.opacity(0.34), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("检查器")
                .font(.headline)
            Text("当前设备与字段上下文")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var diskSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectorLabel(title: "状态", value: model.disk.state.label)
            InspectorLabel(title: "LBA12 Entries", value: "\(model.disk.lba12Entries)")
            InspectorLabel(title: "LBA9 EETU", value: model.disk.hasEETU ? "存在" : "无")
            InspectorLabel(title: "Label ID", value: model.disk.labelOnlyID)
            InspectorLabel(title: "CRC32", value: "0x\(model.disk.crc32)")
            InspectorLabel(title: "K0", value: "0x\(model.disk.k0)")
            InspectorLabel(title: "Core", value: model.coreVersion)
        }
    }

    @ViewBuilder
    private var byteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选中字节")
                .font(.subheadline.weight(.semibold))

            if let index = model.selectedByteIndex,
               let value = model.selectedByte,
               let semantic = model.selectedSemantic {
                InspectorLabel(title: "Offset", value: String(format: "0x%03X", index))
                InspectorLabel(title: "Hex", value: String(format: "%02X", value))
                InspectorLabel(title: "Decimal", value: "\(value)")
                InspectorLabel(title: "语义", value: semantic.title)
                if let field = model.selectedField {
                    InspectorLabel(title: "字段", value: field.name)
                    if !field.value.isEmpty {
                        InspectorLabel(title: "值", value: field.value)
                    }
                    if !field.desc.isEmpty {
                        Text(field.desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("点击 Hex Viewer 中任意字节查看字段信息。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var legendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("语义图例")
                .font(.subheadline.weight(.semibold))
            ForEach([
                ByteSemantic.magic,
                .partition,
                .keyMaterial,
                .label,
                .ciphertext,
                .checksum,
                .warning
            ], id: \.rawValue) { semantic in
                HStack(spacing: 8) {
                    Circle()
                        .fill(semantic.swiftUIColor)
                        .frame(width: 8, height: 8)
                    Text(semantic.title)
                        .font(.caption)
                    Spacer()
                }
            }
        }
    }
}

private struct InspectorLabel: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }
}

struct NativePlaceholderView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            .padding(34)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
    }
}

extension ByteSemantic {
    var swiftUIColor: Color {
        switch self {
        case .normal: .secondary
        case .magic: .red
        case .partition: .blue
        case .keyMaterial: .purple
        case .label: .green
        case .ciphertext: .gray
        case .checksum: .orange
        case .warning: .pink
        case .zero: .secondary.opacity(0.35)
        }
    }
}
