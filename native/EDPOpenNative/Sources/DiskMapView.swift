import SwiftUI

struct DiskMapView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedRegionID: UUID?

    var body: some View {
        @Bindable var model = model

        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 20) {
                mapHeader
                fullDiskMap
                    .frame(width: 960 * model.zoom, height: 170)
                    .animation(.smooth(duration: 0.28), value: model.zoom)
                metadataGrid
                regionDetails
            }
            .padding(24)
            .frame(minWidth: 980, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .bottom) {
            zoomBar
                .padding(.bottom, 8)
        }
    }

    private var mapHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("全盘布局")
                .font(.title2.weight(.semibold))
            Text("\(model.disk.totalSectors.formatted()) 扇区 · \(model.disk.capacityText) · 点击区域查看 LBA 范围")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var fullDiskMap: some View {
        GeometryReader { proxy in
            let total = Double(model.disk.regions.map(\.sectorCount).reduce(0, +))
            let available = max(proxy.size.width, 1)

            HStack(spacing: 4) {
                ForEach(model.disk.regions) { region in
                    let ratio = Double(region.sectorCount) / max(total, 1)
                    let width = max(available * ratio, minimumWidth(for: region.kind))
                    regionBlock(region, width: width)
                }
            }
            .padding(10)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.separator.opacity(0.45), lineWidth: 0.5)
            }
        }
    }

    private func regionBlock(_ region: DiskRegion, width: CGFloat) -> some View {
        let selected = selectedRegionID == region.id

        return Button {
            selectedRegionID = region.id
        } label: {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(region.kind.gradient)
                    .overlay {
                        if region.kind == .encrypted {
                            DiagonalPattern()
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .opacity(0.18)
                        }
                    }

                if width > 92 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(region.name)
                            .font(.subheadline.weight(.semibold))
                        Text(region.subtitle)
                            .font(.caption2)
                            .opacity(0.78)
                            .lineLimit(2)
                    }
                    .padding(12)
                    .foregroundStyle(.white)
                }
            }
            .frame(width: width, height: 148)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? Color.white.opacity(0.95) : Color.white.opacity(0.14), lineWidth: selected ? 2 : 0.5)
            }
            .shadow(color: selected ? .accentColor.opacity(0.22) : .clear, radius: 14)
        }
        .buttonStyle(.plain)
        .help("\(region.name) · LBA \(region.startLBA.formatted()) – \(region.endLBA.formatted())")
    }

    private var metadataGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LBA 0–13 元数据")
                .font(.headline)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 8) {
                ForEach(0..<14, id: \.self) { lba in
                    Button {
                        model.selectedLBA = UInt64(lba)
                        model.selection = .sector
                    } label: {
                        VStack(spacing: 4) {
                            Text("\(lba)")
                                .font(.system(.headline, design: .rounded).weight(.semibold))
                            Text(metadataName(lba))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var regionDetails: some View {
        if let region = model.disk.regions.first(where: { $0.id == selectedRegionID }) ?? model.disk.regions.first(where: { $0.kind == .share }) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 16) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(region.kind.gradient)
                        .frame(width: 10, height: 52)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(region.name)
                            .font(.headline)
                        Text(region.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                        Text("LBA \(region.startLBA.formatted()) – \(region.endLBA.formatted())")
                            .font(.system(.caption, design: .monospaced))
                        Text("\(region.sectorCount.formatted()) sectors")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
            }
        }
    }

    private var zoomBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "minus.magnifyingglass")
            Slider(value: Binding(
                get: { model.zoom },
                set: { model.zoom = $0 }
            ), in: 0.8...1.6)
                .frame(width: 180)
            Image(systemName: "plus.magnifyingglass")
            Text("\(Int(model.zoom * 100))%")
                .font(.system(.caption, design: .monospaced))
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func minimumWidth(for kind: DiskRegion.Kind) -> CGFloat {
        switch kind {
        case .metadata: 30
        case .boot: 58
        case .free: 20
        default: 94
        }
    }

    private func metadataName(_ lba: Int) -> String {
        switch lba {
        case 0: "MBR"
        case 4: "Label"
        case 6: "SAFE6"
        case 7: "EDPF"
        case 8: "LLGB"
        case 9: "EETU"
        case 11: "PDKB"
        case 12: "EDPF"
        default: "Metadata"
        }
    }
}

private struct DiagonalPattern: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let spacing: CGFloat = 10
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing
            }
            context.stroke(path, with: .color(.white), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}
