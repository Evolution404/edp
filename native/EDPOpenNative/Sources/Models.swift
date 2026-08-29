import SwiftUI
import Observation
import AppKit

enum SidebarDestination: String, CaseIterable, Identifiable, Hashable {
    case overview
    case map
    case sector
    case editor
    case conversion
    case backups

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "概览"
        case .map: "磁盘地图"
        case .sector: "扇区"
        case .editor: "编辑器"
        case .conversion: "免密改造"
        case .backups: "备份与还原"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "externaldrive"
        case .map: "rectangle.split.3x1"
        case .sector: "square.grid.3x3"
        case .editor: "pencil.and.outline"
        case .conversion: "wand.and.sparkles"
        case .backups: "clock.arrow.circlepath"
        }
    }
}

enum BrokerState: Equatable {
    case checking
    case unavailable(String)
    case connected
    case ready(String)
    case denied(String)

    var title: String {
        switch self {
        case .checking: "正在检测 Raw Broker"
        case .unavailable: "Raw Broker 未连接"
        case .connected: "Raw Broker 已连接"
        case .ready: "完全磁盘访问已就绪"
        case .denied: "完全磁盘访问未就绪"
        }
    }

    var detail: String {
        switch self {
        case .checking: "仅检查 XPC 服务，不访问 raw disk"
        case .unavailable(let message), .denied(let message), .ready(let message): message
        case .connected: "XPC 与代码签名校验通过；尚未执行 raw 权限探针"
        }
    }

    var systemImage: String {
        switch self {
        case .checking: "ellipsis.circle"
        case .unavailable: "xmark.shield"
        case .connected: "checkmark.shield"
        case .ready: "checkmark.shield.fill"
        case .denied: "exclamationmark.shield"
        }
    }
}

enum DiskState: String {
    case encrypted
    case noPassword
    case unavailable

    var label: String {
        switch self {
        case .encrypted: "标准加密盘"
        case .noPassword: "免密盘"
        case .unavailable: "未识别"
        }
    }

    var symbol: String {
        switch self {
        case .encrypted: "lock.fill"
        case .noPassword: "lock.open.fill"
        case .unavailable: "questionmark.circle"
        }
    }
}

struct DiskRegion: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let startLBA: UInt64
    let endLBA: UInt64
    let subtitle: String
    let kind: Kind

    enum Kind: Hashable {
        case metadata
        case boot
        case share
        case encrypted
        case free
        case tail
    }

    var sectorCount: UInt64 { max(endLBA &- startLBA &+ 1, 1) }
}

struct DiskSnapshot: Hashable {
    let diskName: String
    let capacityText: String
    let totalSectors: UInt64
    let vid: String
    let pid: String
    let deviceID: String
    let crc32: String
    let k0: String
    let state: DiskState
    let lba12Entries: Int
    let hasEETU: Bool
    let labelOnlyID: String
    let regions: [DiskRegion]
}

enum ByteSemantic: Int, Hashable {
    case normal
    case magic
    case partition
    case keyMaterial
    case label
    case ciphertext
    case checksum
    case warning
    case zero

    var title: String {
        switch self {
        case .normal: "普通字节"
        case .magic: "Magic / 结构标识"
        case .partition: "分区布局"
        case .keyMaterial: "密钥材料"
        case .label: "标签 / 文本"
        case .ciphertext: "密文"
        case .checksum: "校验值"
        case .warning: "敏感字段"
        case .zero: "零填充"
        }
    }
}

struct SectorSnapshot: Hashable {
    let lba: UInt64
    let title: String
    let method: String
    let bytes: [UInt8]
    let semantics: [ByteSemantic]
    let fields: [CoreField]
}

@MainActor
@Observable
final class AppModel {
    var selection: SidebarDestination = .overview
    var selectedLBA: UInt64 = 12
    var selectedByteIndex: Int? = 0
    var inspectorVisible = true
    var showDecoded = true
    var zoom: Double = 1.0
    var brokerState: BrokerState = .checking
    var detectedDisks: [RawBrokerDisk] = []
    var selectedDiskNumber: UInt32?

    let disk = SampleData.disk
    let coreVersion = EDPCore.version
    private var brokerClient: RawBrokerClient?

    init() {
        refreshBrokerConnection()
    }

    var sector: SectorSnapshot {
        SampleData.sector(lba: selectedLBA)
    }

    var selectedByte: UInt8? {
        guard let selectedByteIndex, sector.bytes.indices.contains(selectedByteIndex) else { return nil }
        return sector.bytes[selectedByteIndex]
    }

    var selectedSemantic: ByteSemantic? {
        guard let selectedByteIndex, sector.semantics.indices.contains(selectedByteIndex) else { return nil }
        return sector.semantics[selectedByteIndex]
    }

    var selectedField: CoreField? {
        guard let selectedByteIndex else { return nil }
        return sector.fields.first { selectedByteIndex >= $0.off && selectedByteIndex < $0.off + $0.len }
    }

    var selectedDetectedDisk: RawBrokerDisk? {
        guard let selectedDiskNumber else { return detectedDisks.first }
        return detectedDisks.first { $0.diskNumber == selectedDiskNumber }
    }

    func refreshBrokerConnection() {
        brokerState = .checking
        let client = RawBrokerClient()
        brokerClient = client
        client.ping { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let reply) where reply.ok:
                self.brokerState = .connected
                self.refreshDetectedDisks()
            case .success(let reply):
                self.detectedDisks = []
                self.selectedDiskNumber = nil
                self.brokerState = .unavailable(reply.message)
            case .failure(let error):
                self.detectedDisks = []
                self.selectedDiskNumber = nil
                self.brokerState = .unavailable(error.localizedDescription)
            }
        }
    }

    func refreshDetectedDisks() {
        guard let client = brokerClient else { return }
        client.listUSBDisks { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let reply) where reply.ok:
                let previous = self.selectedDiskNumber
                self.detectedDisks = reply.disks
                if let previous, reply.disks.contains(where: { $0.diskNumber == previous }) {
                    self.selectedDiskNumber = previous
                } else {
                    self.selectedDiskNumber = reply.disks.first?.diskNumber
                }
            case .success(let reply):
                self.detectedDisks = []
                self.selectedDiskNumber = nil
                self.brokerState = .unavailable(reply.message)
            case .failure(let error):
                self.detectedDisks = []
                self.selectedDiskNumber = nil
                self.brokerState = .unavailable(error.localizedDescription)
            }
        }
    }

    func probeFullDiskAccess() {
        guard let diskNumber = selectedDiskNumber,
              detectedDisks.contains(where: { $0.diskNumber == diskNumber }) else {
            brokerState = .denied("没有由 broker 实时枚举确认的 external physical USB whole disk")
            return
        }
        let client = brokerClient ?? RawBrokerClient()
        brokerClient = client
        brokerState = .checking
        client.probeReadAccess(diskNumber: diskNumber) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let reply) where reply.ok:
                self.brokerState = .ready(reply.message)
            case .success(let reply):
                self.brokerState = .denied(reply.message)
            case .failure(let error):
                self.brokerState = .unavailable(error.localizedDescription)
            }
        }
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}

extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        var value = self.littleEndian
        return Swift.withUnsafeBytes(of: &value) { Array($0) }
    }
}

enum SampleData {
    static let disk = DiskSnapshot(
        diskName: "disk9",
        capacityText: "124.74 GB",
        totalSectors: 243_601_664,
        vid: "21c4",
        pid: "0cd1",
        deviceID: "disk&ven_lexar&prod_usb_flash_drive",
        crc32: "6BBAEEFB",
        k0: "8541",
        state: .encrypted,
        lba12Entries: 3,
        hasEETU: true,
        labelOnlyID: "1625940067",
        regions: [
            DiskRegion(name: "Metadata", startLBA: 0, endLBA: 13, subtitle: "EDP 元数据", kind: .metadata),
            DiskRegion(name: "Boot", startLBA: 63, endLBA: 20_479, subtitle: "启动区 · FAT16", kind: .boot),
            DiskRegion(name: "Share", startLBA: 20_480, endLBA: 231_422_207, subtitle: "明文数据区 · 118.48 GB", kind: .share),
            DiskRegion(name: "Gap", startLBA: 231_422_208, endLBA: 231_423_999, subtitle: "布局间隔", kind: .free),
            DiskRegion(name: "Encrypt / IIR", startLBA: 231_424_000, endLBA: 243_601_663, subtitle: "加密区 · 6.23 GB", kind: .encrypted)
        ]
    )

    static func sector(lba: UInt64) -> SectorSnapshot {
        if lba == 0 {
            var raw = [UInt8](repeating: 0, count: 512)
            let part = 0x1BE
            raw[part + 4] = 0x0E
            raw.replaceSubrange(part + 8..<part + 12, with: UInt32(63).littleEndianBytes)
            raw.replaceSubrange(part + 12..<part + 16, with: UInt32(20_417).littleEndianBytes)
            raw[0x1FE] = 0x55
            raw[0x1FF] = 0xAA

            if let decoded = try? EDPCore.decodeSector(lba: 0, raw: raw) {
                let view = decoded.decodedHex?.decodedHexBytes ?? raw
                var semantics = view.map { $0 == 0 ? ByteSemantic.zero : .normal }
                for field in decoded.fields {
                    let lower = max(0, field.off)
                    let upper = min(view.count, field.off + field.len)
                    guard lower < upper else { continue }
                    for index in lower..<upper { semantics[index] = field.semantic }
                }
                return SectorSnapshot(
                    lba: 0,
                    title: "LBA0 · MBR 分区表",
                    method: decoded.method ?? "Rust Core · raw MBR",
                    bytes: view,
                    semantics: semantics,
                    fields: decoded.fields
                )
            }
        }

        var bytes = [UInt8](repeating: 0, count: 512)
        var semantics = [ByteSemantic](repeating: .zero, count: 512)

        func write(_ offset: Int, _ values: [UInt8], semantic: ByteSemantic) {
            for (i, value) in values.enumerated() where bytes.indices.contains(offset + i) {
                bytes[offset + i] = value
                semantics[offset + i] = semantic
            }
        }

        if lba == 12 {
            write(0x00, Array("EDPF".utf8), semantic: .magic)
            write(0x04, [0x03, 0x00, 0x00, 0x00], semantic: .partition)
            write(0x08, [0x60, 0x00, 0x00, 0x00], semantic: .partition)

            write(0x20, Array("Share".utf8), semantic: .label)
            write(0x30, [0x3f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], semantic: .partition)
            write(0x38, [0x00, 0xd0, 0xcb, 0x1b, 0x00, 0x00, 0x00, 0x00], semantic: .partition)

            write(0x80, Array("Encrypt".utf8), semantic: .label)
            write(0x90, [0x00, 0x40, 0xcb, 0x0d, 0x00, 0x00, 0x00, 0x00], semantic: .warning)
            write(0xa0, [0xfb, 0xee, 0xba, 0x6b, 0x41, 0x85, 0xa7, 0xf0], semantic: .keyMaterial)

            for i in 0xb0..<0x170 {
                if bytes[i] == 0 {
                    bytes[i] = UInt8(truncatingIfNeeded: (i &* 37) ^ 0xa6)
                    semantics[i] = .ciphertext
                }
            }
            for i in 0x170..<0x200 {
                bytes[i] = UInt8(truncatingIfNeeded: (i &* 11) ^ 0x5a)
                semantics[i] = .ciphertext
            }

            return SectorSnapshot(
                lba: lba,
                title: "LBA12 · EDPF 分区表",
                method: "视觉样例 · 实盘接入后由 Rust Core 解密",
                bytes: bytes,
                semantics: semantics,
                fields: []
            )
        }

        let seed = UInt8(truncatingIfNeeded: lba &* 17)
        for i in bytes.indices {
            bytes[i] = seed &+ UInt8(truncatingIfNeeded: i &* 13)
            semantics[i] = i < 64 ? .partition : .ciphertext
        }
        return SectorSnapshot(
            lba: lba,
            title: "LBA\(lba)",
            method: "离线视觉样例",
            bytes: bytes,
            semantics: semantics,
            fields: []
        )
    }
}
