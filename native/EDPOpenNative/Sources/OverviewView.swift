import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                identityGrid
                layoutCard
                metadataCard
            }
            .padding(24)
            .frame(maxWidth: 1180, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.tint.opacity(0.12))
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.tint)
            }
            .frame(width: 68, height: 68)

            VStack(alignment: .leading, spacing: 5) {
                Text("Lexar USB Flash Drive")
                    .font(.title2.weight(.semibold))
                Text("\(model.disk.diskName) · \(model.disk.capacityText) · USB \(model.disk.vid):\(model.disk.pid)")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label(model.disk.state.label, systemImage: model.disk.state.symbol)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular.tint(.blue.opacity(0.16)).interactive(), in: .capsule)
        }
    }

    private var identityGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
            MetricCard(title: "设备标识", value: model.disk.deviceID, icon: "fingerprint", monospaced: true)
            MetricCard(title: "CRC32", value: "0x\(model.disk.crc32)", icon: "number", monospaced: true)
            MetricCard(title: "LBA7 K0", value: "0x\(model.disk.k0)", icon: "key.horizontal", monospaced: true)
            MetricCard(title: "Label Only ID", value: model.disk.labelOnlyID, icon: "tag", monospaced: true)
        }
    }

    private var layoutCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("EDP 布局", systemImage: "rectangle.split.3x1")
                    .font(.headline)
                Spacer()
                Button("打开磁盘地图") {
                    model.selection = .map
                }
                .buttonStyle(.glass)
            }

            CompactDiskStrip(regions: model.disk.regions)
                .frame(height: 82)

            HStack(spacing: 18) {
                LayoutFact(title: "LBA12", value: "\(model.disk.lba12Entries) entries")
                LayoutFact(title: "LBA9", value: model.disk.hasEETU ? "EETU present" : "zero")
                LayoutFact(title: "总扇区", value: model.disk.totalSectors.formatted())
            }
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 0.5)
        }
    }

    private var metadataCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("当前迁移状态", systemImage: "checkmark.seal")
                .font(.headline)

            MigrationRow(icon: "macwindow", title: "原生 UI", detail: "SwiftUI + AppKit · macOS 26 Liquid Glass", done: true)
            MigrationRow(icon: "externaldrive.badge.checkmark", title: "FDA Raw Broker", detail: "独立 PoC 已验证，正式 Swift broker 尚未接入", done: false)
            MigrationRow(icon: "shippingbox", title: "Rust EDP Core", detail: "保留现有 crypto / parser / convert / editor golden", done: true)
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 0.5)
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let icon: String
    let monospaced: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
        .padding(16)
        .glassEffect(.clear, in: .rect(cornerRadius: 18))
    }
}

private struct LayoutFact: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced).weight(.medium))
        }
    }
}

private struct MigrationRow: View {
    let icon: String
    let title: String
    let detail: String
    let done: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(done ? .green : .orange)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(done ? .green : .orange)
        }
        .padding(.vertical, 3)
    }
}

struct CompactDiskStrip: View {
    let regions: [DiskRegion]

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let total = Double(regions.map(\.sectorCount).reduce(0, +))

            HStack(spacing: 3) {
                ForEach(regions) { region in
                    let ratio = Double(region.sectorCount) / max(total, 1)
                    let visualWidth = max(width * ratio, region.kind == .metadata ? 22 : 8)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(region.kind.gradient)
                        .frame(width: visualWidth)
                        .overlay(alignment: .leading) {
                            if visualWidth > 92 {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(region.name)
                                        .font(.caption.weight(.semibold))
                                    Text(region.subtitle)
                                        .font(.caption2)
                                        .opacity(0.72)
                                }
                                .padding(.horizontal, 10)
                                .foregroundStyle(.white)
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

extension DiskRegion.Kind {
    var gradient: LinearGradient {
        switch self {
        case .metadata:
            LinearGradient(colors: [.gray.opacity(0.85), .gray.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .boot:
            LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .share:
            LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .encrypted:
            LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .free:
            LinearGradient(colors: [.secondary.opacity(0.3), .secondary.opacity(0.15)], startPoint: .top, endPoint: .bottom)
        case .tail:
            LinearGradient(colors: [.orange, .yellow], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
