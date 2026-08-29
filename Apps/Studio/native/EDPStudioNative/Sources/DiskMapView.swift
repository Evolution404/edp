import SwiftUI

struct DiskMapView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedRegionID: UUID?

    var body: some View {
        @Bindable var model = model

        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 20) {
                mapHeader
                fullDiskMap
                metadataGrid
                regionDetails
            }
            .padding(24)
            .frame(minWidth: 980, alignment: .leading)
        }
        .background { EDPWindowBackdrop() }
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
        let layout = diskMapLayout

        return HStack(spacing: layout.spacing) {
            ForEach(Array(model.disk.regions.enumerated()), id: \.element.id) { index, region in
                regionBlock(region, width: layout.regionWidths[index])
            }
        }
        .padding(layout.inset)
        // The ScrollView must own the real rendered extent. The previous GeometryReader
        // reported only the nominal 960×zoom width even after per-region minimum widths
        // pushed Boot/Secret/metadata past that boundary, so the final Secret block was
        // painted outside the scrollable content and could never be reached.
        .frame(width: layout.totalWidth, height: 170, alignment: .leading)
        .background(EDPTheme.quietFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 0.5)
        }
    }

    private var diskMapLayout: DiskMapLayout {
        let regions = model.disk.regions
        let spacing: CGFloat = 4
        let inset: CGFloat = 10
        let chromeWidth = inset * 2 + spacing * CGFloat(max(regions.count - 1, 0))
        let minimums = regions.map { minimumWidth(for: $0.kind) }
        let minimumRegionWidth = minimums.reduce(0, +)
        let nominalTotalWidth = max(960 * model.zoom, chromeWidth + minimumRegionWidth)
        let targetRegionWidth = nominalTotalWidth - chromeWidth

        guard !regions.isEmpty else {
            return DiskMapLayout(regionWidths: [], totalWidth: nominalTotalWidth, spacing: spacing, inset: inset)
        }

        var widths = Array(repeating: CGFloat.zero, count: regions.count)
        var unresolved = Array(regions.indices)
        var remainingWidth = targetRegionWidth

        // Allocate tiny structural regions at their readable minimum first, then
        // distribute the remaining width proportionally. This preserves the full-disk
        // scale without allowing minimum-width clamping to overflow the declared extent.
        while !unresolved.isEmpty {
            let totalWeight = unresolved.reduce(0.0) { partial, index in
                partial + Double(regions[index].sectorCount)
            }
            guard totalWeight > 0 else {
                let equalWidth = remainingWidth / CGFloat(unresolved.count)
                for index in unresolved { widths[index] = max(equalWidth, minimums[index]) }
                break
            }

            let constrained = unresolved.filter { index in
                let proportional = remainingWidth * CGFloat(Double(regions[index].sectorCount) / totalWeight)
                return proportional < minimums[index]
            }

            if constrained.isEmpty {
                for index in unresolved {
                    widths[index] = remainingWidth * CGFloat(Double(regions[index].sectorCount) / totalWeight)
                }
                break
            }

            let constrainedSet = Set(constrained)
            for index in constrained {
                widths[index] = minimums[index]
                remainingWidth -= minimums[index]
            }
            unresolved.removeAll { constrainedSet.contains($0) }
        }

        let renderedWidth = widths.reduce(0, +) + chromeWidth
        return DiskMapLayout(
            regionWidths: widths,
            totalWidth: max(renderedWidth, nominalTotalWidth),
            spacing: spacing,
            inset: inset
        )
    }

    private func regionBlock(_ region: DiskRegion, width: CGFloat) -> some View {
        let selected = selectedRegionID == region.id

        return Button {
            withAnimation(reduceMotion ? EDPTheme.Motion.reduced : EDPTheme.Motion.navigation) {
                selectedRegionID = region.id
            }
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
        EDPContentCard {
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
        }
    }

    @ViewBuilder
    private var regionDetails: some View {
        if let region = model.disk.regions.first(where: { $0.id == selectedRegionID }) ?? model.disk.regions.first(where: { $0.kind == .share }) {
            EDPContentCard(padding: 16) {
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
                            .contentTransition(.numericText())
                    }
                }
            }
        }
    }

    private var zoomBar: some View {
        EDPGlassToolbar {
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
                    .contentTransition(.numericText())
            }
        }
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

private struct DiskMapLayout {
    let regionWidths: [CGFloat]
    let totalWidth: CGFloat
    let spacing: CGFloat
    let inset: CGFloat
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
