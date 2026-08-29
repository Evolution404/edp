import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(SidebarDestination.allCases, selection: $model.selection) { item in
                Label(item.title, systemImage: item.systemImage)
                    .padding(.vertical, 3)
                    .tag(item)
            }
            .listStyle(.sidebar)
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
                            withAnimation(reduceMotion ? EDPTheme.Motion.reduced : EDPTheme.Motion.navigation) {
                                model.inspectorVisible.toggle()
                            }
                        } label: {
                            Label("检查器", systemImage: "sidebar.trailing")
                        }
                        .buttonStyle(.glass)
                        .help("显示或隐藏检查器")
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .background { EDPWindowBackdrop() }
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
                    .transition(.opacity)
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
        EDPGlassToolbar {
            HStack(spacing: 9) {
                Image(systemName: disk == nil ? "externaldrive.badge.questionmark" : "externaldrive.fill")
                    .foregroundStyle(disk == nil ? Color.secondary : Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))
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
            }
        }
    }
}

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
        // Match the native NavigationSplitView sidebar instead of stacking a gray
        // SwiftUI material beneath Liquid Glass. NSVisualEffectView(.sidebar) gives the
        // same behind-window blur family as the leading sidebar; the surrounding HSplitView
        // column stays transparent and only this rounded surface floats inside it.
        .background {
            if reduceTransparency {
                Color(nsColor: .controlBackgroundColor)
            } else {
                NativeSidebarMaterial()
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.separator.opacity(0.22), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 18, y: 7)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var inspectorHeader: some View {
        EDPSectionHeader(
            "检查器",
            subtitle: "当前设备与字段上下文",
            systemImage: "sidebar.trailing"
        )
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

private struct NativeSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .sidebar
        nsView.blendingMode = .behindWindow
        nsView.state = .active
        nsView.isEmphasized = false
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
            EDPWindowBackdrop()
            EDPGlassCard {
                EDPEmptyState(title, message: message, systemImage: icon)
            }
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
