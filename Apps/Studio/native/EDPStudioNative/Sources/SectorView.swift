import SwiftUI
import AppKit

struct SectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let sector = model.sector

        VStack(spacing: 0) {
            controlBar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(sector.title)
                                .font(.headline)
                            Text(sector.method)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("512 bytes")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    SectorHexRepresentable(
                        bytes: sector.bytes,
                        semantics: sector.semantics,
                        selectedIndex: $model.selectedByteIndex
                    )
                    .frame(width: 790, height: 760)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(.separator.opacity(0.55), lineWidth: 0.5)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background { EDPWindowBackdrop() }

            Divider()
            statusBar
        }
    }

    private var controlBar: some View {
        @Bindable var model = model

        return EDPGlassToolbar {
            HStack(spacing: 10) {
                Button {
                    model.selectedLBA = model.selectedLBA > 0 ? model.selectedLBA - 1 : 0
                    model.selectedByteIndex = 0
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .padding(7)

                HStack(spacing: 6) {
                    Text("LBA")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("LBA", value: $model.selectedLBA, format: .number.grouping(.never))
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 84)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(EDPTheme.quietFill, in: Capsule())

                Button {
                    model.selectedLBA += 1
                    model.selectedByteIndex = 0
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .padding(7)

                Divider()
                    .frame(height: 20)

                Picker("视图", selection: $model.showDecoded) {
                    Text("解密").tag(true)
                    Text("Raw").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 132)

                Spacer()

                Menu {
                    ForEach([0, 4, 6, 7, 8, 9, 11, 12], id: \.self) { lba in
                        Button("LBA \(lba)") {
                            model.selectedLBA = UInt64(lba)
                            model.selectedByteIndex = 0
                        }
                    }
                } label: {
                    Label("元数据", systemImage: "square.grid.3x3")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Label("离线视觉 PoC", systemImage: "circle.fill")
                .foregroundStyle(.secondary)
            Spacer()
            if let index = model.selectedByteIndex, let byte = model.selectedByte {
                Text("offset \(String(format: "0x%03X", index))")
                Text("hex \(String(format: "%02X", byte))")
                Text(model.selectedSemantic?.title ?? "")
            } else {
                Text("点击任意字节查看详情")
            }
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: 30)
        .background(EDPTheme.quietFill)
    }
}

struct SectorHexRepresentable: NSViewRepresentable {
    let bytes: [UInt8]
    let semantics: [ByteSemantic]
    @Binding var selectedIndex: Int?

    func makeNSView(context: Context) -> HexGridNSView {
        let view = HexGridNSView()
        view.onSelect = { index in
            selectedIndex = index
        }
        return view
    }

    func updateNSView(_ nsView: HexGridNSView, context: Context) {
        nsView.bytes = bytes
        nsView.semantics = semantics
        nsView.selectedIndex = selectedIndex
        nsView.needsDisplay = true
    }
}

final class HexGridNSView: NSView {
    var bytes: [UInt8] = []
    var semantics: [ByteSemantic] = []
    var selectedIndex: Int?
    var hoveredIndex: Int?
    var onSelect: ((Int?) -> Void)?

    private let topInset: CGFloat = 34
    private let leftInset: CGFloat = 16
    private let offsetWidth: CGFloat = 72
    private let cellWidth: CGFloat = 27
    private let rowHeight: CGFloat = 22
    private let asciiGap: CGFloat = 18

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let headerColor = NSColor.secondaryLabelColor
        let textColor = NSColor.labelColor

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: boldFont,
            .foregroundColor: headerColor
        ]

        drawString("OFFSET", at: CGPoint(x: leftInset, y: 10), attributes: headerAttributes)
        for col in 0..<16 {
            drawString(String(format: "%02X", col), at: CGPoint(x: byteStartX + CGFloat(col) * cellWidth + 5, y: 10), attributes: headerAttributes)
        }
        drawString("ASCII", at: CGPoint(x: asciiStartX + 4, y: 10), attributes: headerAttributes)

        let rows = max((bytes.count + 15) / 16, 1)
        for row in 0..<rows {
            let y = topInset + CGFloat(row) * rowHeight
            drawString(String(format: "%08X", row * 16), at: CGPoint(x: leftInset, y: y + 3), attributes: headerAttributes)

            var ascii = ""
            for col in 0..<16 {
                let index = row * 16 + col
                guard bytes.indices.contains(index) else {
                    ascii.append(" ")
                    continue
                }

                let x = byteStartX + CGFloat(col) * cellWidth
                let cellRect = NSRect(x: x + 1, y: y + 1, width: cellWidth - 3, height: rowHeight - 2)
                drawCellBackground(index: index, rect: cellRect)
                drawString(String(format: "%02X", bytes[index]), at: CGPoint(x: x + 5, y: y + 3), attributes: baseAttributes)

                let scalar = bytes[index]
                if scalar >= 0x20 && scalar <= 0x7e {
                    ascii.append(Character(UnicodeScalar(scalar)))
                } else {
                    ascii.append("·")
                }
            }

            drawString(ascii, at: CGPoint(x: asciiStartX + 4, y: y + 3), attributes: baseAttributes)
        }

        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        let separator = NSBezierPath()
        separator.move(to: CGPoint(x: byteStartX - 8, y: 4))
        separator.line(to: CGPoint(x: byteStartX - 8, y: topInset + CGFloat(rows) * rowHeight))
        separator.move(to: CGPoint(x: asciiStartX - 8, y: 4))
        separator.line(to: CGPoint(x: asciiStartX - 8, y: topInset + CGFloat(rows) * rowHeight))
        separator.lineWidth = 0.5
        separator.stroke()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let next = byteIndex(at: point)
        if next != hoveredIndex {
            hoveredIndex = next
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        selectedIndex = byteIndex(at: point)
        onSelect?(selectedIndex)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard let current = selectedIndex else {
            super.keyDown(with: event)
            return
        }

        let next: Int?
        switch event.keyCode {
        case 123: next = max(current - 1, 0)
        case 124: next = min(current + 1, max(bytes.count - 1, 0))
        case 125: next = min(current + 16, max(bytes.count - 1, 0))
        case 126: next = max(current - 16, 0)
        default:
            super.keyDown(with: event)
            return
        }
        selectedIndex = next
        onSelect?(next)
        needsDisplay = true
    }

    private var byteStartX: CGFloat { leftInset + offsetWidth }
    private var asciiStartX: CGFloat { byteStartX + cellWidth * 16 + asciiGap }

    private func byteIndex(at point: CGPoint) -> Int? {
        guard point.y >= topInset else { return nil }
        let row = Int((point.y - topInset) / rowHeight)
        let relativeX = point.x - byteStartX
        guard relativeX >= 0 else { return nil }
        let col = Int(relativeX / cellWidth)
        guard (0..<16).contains(col) else { return nil }
        let index = row * 16 + col
        return bytes.indices.contains(index) ? index : nil
    }

    private func drawCellBackground(index: Int, rect: NSRect) {
        let semantic = semantics.indices.contains(index) ? semantics[index] : .normal
        var color = semantic.nsColor.withAlphaComponent(0.14)

        if hoveredIndex == index {
            color = NSColor.controlAccentColor.withAlphaComponent(0.14)
        }
        if selectedIndex == index {
            color = NSColor.controlAccentColor.withAlphaComponent(0.28)
        }

        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()

        if selectedIndex == index {
            NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            border.lineWidth = 1
            border.stroke()
        }
    }

    private func drawString(_ string: String, at point: CGPoint, attributes: [NSAttributedString.Key: Any]) {
        (string as NSString).draw(at: point, withAttributes: attributes)
    }
}

private extension ByteSemantic {
    var nsColor: NSColor {
        switch self {
        case .normal: .secondaryLabelColor
        case .magic: .systemRed
        case .partition: .systemBlue
        case .keyMaterial: .systemPurple
        case .label: .systemGreen
        case .ciphertext: .systemGray
        case .checksum: .systemOrange
        case .warning: .systemPink
        case .zero: .tertiaryLabelColor
        }
    }
}
