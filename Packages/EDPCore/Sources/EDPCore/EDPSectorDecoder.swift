import CoreFoundation
import Foundation

public enum EDPCoreVersion {
    public static let current = "0.2.0"
}

public struct EDPSectorIdentity: Hashable, Sendable {
    public let crc: UInt32
    public let k0: UInt16

    public init(crc: UInt32, k0: UInt16) {
        self.crc = crc
        self.k0 = k0
    }
}

public struct EDPSectorField: Hashable, Sendable {
    public let off: Int
    public let len: Int
    public let name: String
    public let desc: String
    public let value: String
    public let color: String

    public init(off: Int, len: Int, name: String, desc: String, value: String, color: String) {
        self.off = off
        self.len = len
        self.name = name
        self.desc = desc
        self.value = value
        self.color = color
    }
}

public struct EDPSectorDecodeContext: Sendable {
    public let identity: EDPSectorIdentity?
    public let vid: String?
    public let pid: String?
    public let sizeBytes: UInt64?

    public init(
        identity: EDPSectorIdentity? = nil,
        vid: String? = nil,
        pid: String? = nil,
        sizeBytes: UInt64? = nil
    ) {
        self.identity = identity
        self.vid = vid
        self.pid = pid
        self.sizeBytes = sizeBytes
    }
}

public struct EDPSectorDecoded: Sendable {
    public let lba: UInt64
    public let decoded: [UInt8]?
    public let method: String?
    public let fields: [EDPSectorField]

    public init(lba: UInt64, decoded: [UInt8]?, method: String?, fields: [EDPSectorField]) {
        self.lba = lba
        self.decoded = decoded
        self.method = method
        self.fields = fields
    }
}

public enum EDPSectorDecoder {
    public static let sectorSize = 512

    public static func decode(
        lba: UInt64,
        raw: [UInt8],
        context: EDPSectorDecodeContext = .init()
    ) throws -> EDPSectorDecoded {
        guard raw.count == sectorSize else {
            throw EDPCoreError.invalidInput("sector must be exactly 512 bytes")
        }

        switch lba {
        case 0:
            return EDPSectorDecoded(lba: lba, decoded: nil, method: nil, fields: EDPSectorFields.lba0(raw))
        case 4:
            guard let result = EDPLBA4.decode(raw) else {
                return EDPSectorDecoded(lba: lba, decoded: nil, method: nil, fields: [])
            }
            return EDPSectorDecoded(
                lba: lba,
                decoded: result.bytes,
                method: String(format: "XOR K0=0x%04X($$$serial=%llu)", EDPLBA4.k0(serial: result.serial), result.serial),
                fields: EDPSectorFields.lba4(result.bytes)
            )
        case 6:
            let decoded = try EDPLBA6.decode(raw)
            return EDPSectorDecoded(
                lba: lba,
                decoded: decoded,
                method: "XOR K0=0x4DAA(SAFE6)",
                fields: EDPSectorFields.lba6(decoded, expectedCRC: context.identity?.crc ?? 0)
            )
        case 7:
            guard let identity = context.identity else {
                return EDPSectorDecoded(lba: lba, decoded: nil, method: nil, fields: [])
            }
            let decoded = EDPRollingXOR.apply(raw, k0: identity.k0)
            guard decoded.starts(with: Array("EDPF".utf8)) else {
                return EDPSectorDecoded(lba: lba, decoded: nil, method: nil, fields: [])
            }
            return EDPSectorDecoded(
                lba: lba,
                decoded: decoded,
                method: String(format: "XOR K0=0x%04X(CRC32(device_id))", identity.k0),
                fields: EDPSectorFields.lba7(decoded)
            )
        case 8:
            guard let identity = context.identity else {
                return EDPSectorDecoded(lba: lba, decoded: nil, method: nil, fields: [])
            }
            var decoded = try EDPA6B0.decrypt(
                Array(raw[0..<0x170]),
                keyRaw: EDPCrypto.littleEndianBytes(identity.crc)
            )
            decoded.append(contentsOf: raw[0x170..<0x200])
            return EDPSectorDecoded(
                lba: lba,
                decoded: decoded,
                method: "A6B0(368B) key=CRC32(device_id); 尾144B raw",
                fields: EDPSectorFields.lba8(decoded)
            )
        case 9:
            if raw.allSatisfy({ $0 == 0 }) {
                return EDPSectorDecoded(
                    lba: lba,
                    decoded: raw,
                    method: "全零扇区(raw)",
                    fields: EDPSectorFields.lba9(raw)
                )
            }
            guard let identity = context.identity else {
                return EDPSectorDecoded(lba: lba, decoded: nil, method: nil, fields: [])
            }
            var decoded = try EDPA6B0.decrypt(
                Array(raw[0..<0x80]),
                keyRaw: EDPCrypto.littleEndianBytes(identity.crc)
            )
            decoded.append(contentsOf: raw[0x80..<0x100])
            decoded.append(contentsOf: raw[0x100..<0x120].map { $0 ^ 0x88 })
            decoded.append(contentsOf: raw[0x120..<0x200])
            return EDPSectorDecoded(
                lba: lba,
                decoded: decoded,
                method: "A6B0(128B)+raw(128B)+XOR0x88(32B)+raw(224B)",
                fields: EDPSectorFields.lba9(decoded)
            )
        case 11:
            guard let vid = context.vid,
                  let pid = context.pid,
                  let size = context.sizeBytes,
                  let result = try decodeLBA11(raw, vid: vid, pid: pid, sizeBytes: size) else {
                return EDPSectorDecoded(lba: lba, decoded: nil, method: nil, fields: [])
            }
            return EDPSectorDecoded(
                lba: lba,
                decoded: result.bytes,
                method: "A6B0 key=crc32(rand+VID+PID+\(result.capacityLabel))",
                fields: EDPSectorFields.lba11(result.bytes)
            )
        case 12:
            guard let identity = context.identity else {
                return EDPSectorDecoded(lba: lba, decoded: nil, method: nil, fields: [])
            }
            var decoded = try EDPA6B0.decrypt(
                Array(raw[0..<0x170]),
                keyRaw: EDPCrypto.littleEndianBytes(identity.crc)
            )
            decoded.append(contentsOf: raw[0x170..<0x200])
            guard decoded.starts(with: Array("EDPF".utf8)) else {
                return EDPSectorDecoded(lba: lba, decoded: nil, method: nil, fields: [])
            }
            return EDPSectorDecoded(
                lba: lba,
                decoded: decoded,
                method: "A6B0(368B) key=CRC32(device_id); 尾144B raw",
                fields: EDPSectorFields.lba12(decoded)
            )
        default:
            return EDPSectorDecoded(lba: lba, decoded: nil, method: nil, fields: [])
        }
    }

    private static func decodeLBA11(
        _ raw: [UInt8],
        vid: String,
        pid: String,
        sizeBytes: UInt64
    ) throws -> (bytes: [UInt8], capacityLabel: String)? {
        let random = Array(raw[0..<0x100])
        let cylinderBytes: UInt64 = 255 * 63 * 512
        let chs = (sizeBytes / cylinderBytes) * cylinderBytes
        var candidates: [(UInt64, String)] = [(sizeBytes, "DiskSize")]
        if chs != 0, chs != sizeBytes { candidates.append((chs, "CHS")) }

        for (candidate, label) in candidates {
            var seed = random
            seed.append(contentsOf: vid.utf8)
            seed.append(contentsOf: pid.utf8)
            seed.append(contentsOf: EDPCrypto.littleEndianBytes(candidate))
            let key = EDPCrypto.littleEndianBytes(EDPCrypto.crc32Bare(seed))
            let plaintext = try EDPA6B0.decrypt(Array(raw[0x100..<0x200]), keyRaw: key)
            guard plaintext.starts(with: Array("PDKB".utf8)) else { continue }
            var output = random
            output.append(contentsOf: plaintext)
            return (output, label)
        }
        return nil
    }
}

private enum EDPSectorFields {
    private static let gbkEncoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0631))
    )

    static func lba0(_ raw: [UInt8]) -> [EDPSectorField] {
        var fields = [field(0, 0x1be, "引导代码", "MBR 引导区(与改造无关)", "", "cipher")]
        for index in 0..<4 {
            let offset = 0x1be + index * 16
            let type = raw[offset + 4]
            guard type != 0 else { continue }
            let start = UInt64(u32(raw, offset + 8))
            let sectors = UInt64(u32(raw, offset + 12))
            fields.append(
                field(
                    offset,
                    16,
                    "分区表项\(index)",
                    "MBR 分区项(boot/type/CHS/起始LBA/扇数)",
                    "\(dosTypeName(type)) @LBA\(start) ×\(sectors)扇 (\(formatGB(sectors * 512)))",
                    "part"
                )
            )
        }
        fields.append(field(0x1fe, 2, "55AA", "MBR 签名", "55 AA", "magic"))
        return fields
    }

    static func lba4(_ decoded: [UInt8]) -> [EDPSectorField] {
        var fields: [EDPSectorField] = []
        if let serial = EDPLBA4.parseSerial(decoded) {
            let low = UInt32(truncatingIfNeeded: serial)
            fields.append(field(0, 16, "$$$ 标签头", "labelOnlyId(盘唯一 ID, 明文)", String(format: "$$$ %llu $$$ (0x%08X)", serial, low), "magic"))
            fields.append(field(0x18, 4, "onlyIdXor8", "= labelOnlyId ^ 0x88888888(上传服务器)", String(format: "0x%08X", u32(decoded, 0x18)), "key"))
            fields.append(field(0x1c, 4, "onlyID2Nd", "独立盘唯一 ID(sectorInfo AES key 种子)", String(format: "0x%08X", u32(decoded, 0x1c)), "key"))
            fields.append(field(0x20, 8, "device-unique", "设备唯一块", hex(decoded[0x20..<0x28]), "key"))
        } else {
            fields.append(field(0, 64, "标签头", "未找到 $$$<数字>$$$ 头", "", "cipher"))
        }
        if Array(decoded[0x39..<0x3d]) == Array("LLGB".utf8) {
            fields.append(field(0x39, 4, "LLGB 锚点", "LLGB 关联段起点(与 LBA8 呼应)", "LLGB", "magic"))
        }
        return fields
    }

    static func lba6(_ decoded: [UInt8], expectedCRC: UInt32) -> [EDPSectorField] {
        let crc = u32(decoded, 0x100)
        var fields = [
            field(0x00, 64, "标签名", "GBK 标签文本(覆盖模板)", "\"\(gbkZ(decoded[0x00..<0x40]))\"", "label"),
            field(0x50, 32, "用户", "GBK 责任人", "\"\(gbkZ(decoded[0x50..<0x70]))\"", "label"),
            field(0x70, 16, "序列号", "ASCII", "\"\(gbkZ(decoded[0x70..<0x80]))\"", "label"),
            field(0x100, 4, "CRC32(device_id)", "盘身份绑定", String(format: "0x%08X %@", crc, crc == expectedCRC ? "✓" : "✗"), "key"),
            field(0x104, 4, "CRC32<<1", "上字段的移位副本", String(format: "0x%08X %@", u32(decoded, 0x104), u32(decoded, 0x104) == crc &<< 1 ? "✓" : "✗"), "key"),
        ]
        if let position = find(Array("!SAFE6".utf8), in: decoded, range: 0x188..<0x1c0) {
            fields.append(field(0x188, position - 0x188 + 6, "GBK+!SAFE6", "部门名+签名", "\"\(gbkZ(decoded[0x188..<position]))!SAFE6\"", "label"))
        }
        fields.append(field(0x1c0, 8, "GLAB 前缀", "标签编号前缀", "\"\(String(decoding: decoded[0x1c0..<0x1c8], as: UTF8.self))\"", "label"))
        fields.append(field(0x1ca, 2, "0x1CA", "模板默认/Boot 扇区数(语义未定案, 非数据区大小)", "\(u16(decoded, 0x1ca))", "cipher"))
        fields.append(field(0x1d4, 25, "旧分区描述", "加密盘分区描述符(改造时清零区)", "", "cipher"))
        fields.append(field(0x1f0, 1, "注册标志", "已注册=1", "\(decoded[0x1f0])", "key"))
        fields.append(field(0x1fc, 4, "校验和", "对密文 CRC32 的 ROL1×10 变换", String(format: "0x%08X", u32(decoded, 0x1fc)), "checksum"))
        return fields
    }

    static func lba7(_ decoded: [UInt8]) -> [EDPSectorField] {
        var fields: [EDPSectorField] = []
        for index in 0..<3 { appendEDPFFields(&fields, decoded: decoded, stride: 0x40, index: index) }
        if decoded[0xc0..<0xc8].contains(where: { $0 != 0 }) {
            fields.append(field(0xc0, 8, "表尾终止符", "EDPF 表结束标记(不清零铁律)", hex(decoded[0xc0..<0xc8]), "warn"))
        }
        return fields
    }

    static func lba8(_ decoded: [UInt8]) -> [EDPSectorField] {
        var fields: [EDPSectorField] = []
        if decoded.starts(with: Array("LLGB".utf8)) {
            fields.append(field(0, 4, "LLGB magic", "标签分区(LLGB)标识", "LLGB", "magic"))
            fields.append(field(4, 4, "长度", "结构长度", "\(u32(decoded, 4))", "cipher"))
        }
        for tag in parseElabel(decoded) {
            fields.append(field(tag.off, tag.len, "<\(tag.tag)>", "ELABEL 标签键值", tag.values.joined(separator: "  ||  "), "label"))
        }
        return fields
    }

    static func lba9(_ decoded: [UInt8]) -> [EDPSectorField] {
        if decoded.allSatisfy({ $0 == 0 }) {
            return [field(0, 512, "全零", "无 EETU(免密盘特征)", "", "zero")]
        }
        return [
            field(0, 128, "EETU", "临时使用区(A6B0 加密)", "", "cipher"),
            field(0x100, 32, "XOR0x88 区", "0x88 混淆段", "", "cipher"),
        ]
    }

    static func lba11(_ decoded: [UInt8]) -> [EDPSectorField] {
        var fields = [field(0, 256, "rand", "DRKB 头+随机明文(key 组成部分)", "", "key")]
        if Array(decoded[0x100..<0x104]) == Array("PDKB".utf8) {
            let tail = decoded[0x104..<0x200]
            let count = tail.firstIndex(of: 0).map { tail.distance(from: tail.startIndex, to: $0) } ?? 108
            fields.append(field(0x100, 4, "PDKB magic", "设备备份块标识", "PDKB", "magic"))
            fields.append(field(0x104, count, "device_id", "盘身份(解 LBA7/8/12 的 key 源)", gbk(decoded[0x104..<(0x104 + count)]), "label"))
        } else {
            fields.append(field(0x100, 256, "PDKB 密文", "未解出(需正确 VID/PID/DiskSize)", "", "cipher"))
        }
        return fields
    }

    static func lba12(_ decoded: [UInt8]) -> [EDPSectorField] {
        var fields: [EDPSectorField] = []
        for index in 0..<3 { appendEDPFFields(&fields, decoded: decoded, stride: 0x60, index: index) }
        if decoded[0x120..<0x128].contains(where: { $0 != 0 }) {
            fields.append(field(0x120, 8, "表尾终止符", "EDPF 表结束标记(不清零铁律)", hex(decoded[0x120..<0x128]), "warn"))
        }
        return fields
    }

    private static func appendEDPFFields(
        _ fields: inout [EDPSectorField],
        decoded: [UInt8],
        stride: Int,
        index: Int
    ) {
        let base = index * stride
        guard base + stride <= decoded.count,
              Array(decoded[base..<(base + 4)]) == Array("EDPF".utf8) else { return }
        let type = u32(decoded, base + 0x0c)
        let name = "entry\(index)·\(edpfTypeName(type))"
        fields.append(field(base, 4, "\(name) magic", "EDPF 标识", "EDPF", "magic"))
        fields.append(field(base + 0x08, 4, "\(name) 版本", "结构版本(读端透传)", "\(u32(decoded, base + 0x08))", "cipher"))
        fields.append(field(base + 0x0c, 4, "\(name) 类型", "1=Boot 2=Share 4=Encrypt/IIR指针", "\(type)", "part"))
        fields.append(field(base + 0x10, 4, "\(name) 激活", "激活标志", "\(u32(decoded, base + 0x10))", "part"))
        fields.append(field(base + 0x14, 4, "\(name) 加密使能", "+0x14=加密使能(非只读)", "\(u32(decoded, base + 0x14))", "part"))
        fields.append(field(base + 0x18, 8, "\(name) 起始", "起始 LBA", "\(u64(decoded, base + 0x18))", "part"))
        fields.append(field(base + 0x20, 8, "\(name) bps", "每扇字节数", "\(u64(decoded, base + 0x20))", "cipher"))
        let size = u64(decoded, base + 0x28)
        fields.append(field(base + 0x28, 8, "\(name) 大小", "字节(Encrypt 在 LBA7 为 3072B IIR 指针)", "\(size) (\(formatGB(size)))", "part"))
        fields.append(field(base + 0x30, 4, "\(name) pwdCRC", "CRC32(密码)", String(format: "0x%08X", u32(decoded, base + 0x30)), "key"))
        if stride == 0x40 {
            fields.append(field(base + 0x38, 8, "\(name) key8", "密钥材料(Region A 上级)", hex(decoded[(base + 0x38)..<(base + 0x40)]), "key"))
        } else if base + 0x60 <= decoded.count {
            fields.append(field(base + 0x34, 4, "\(name) keyCRC", "CRC32(file_key) 闭合校验", String(format: "0x%08X", u32(decoded, base + 0x34)), "key"))
            fields.append(field(base + 0x38, 16, "\(name) salt", "file_key 的 wrapped salt", hex(decoded[(base + 0x38)..<(base + 0x48)]), "key"))
            fields.append(field(base + 0x58, 4, "\(name) algo", "加密算法: 2=SM4 1=AES", "\(u32(decoded, base + 0x58))", "key"))
        }
    }

    private struct ElabelTag {
        let off: Int
        let len: Int
        let tag: String
        let values: [String]
    }

    private static func parseElabel(_ decoded: [UInt8]) -> [ElabelTag] {
        guard decoded.count > 0x80,
              let first = decoded[0x80...].firstIndex(of: UInt8(ascii: "<")) else { return [] }
        var index = first
        var result: [ElabelTag] = []
        while index < decoded.count {
            guard decoded[index] == UInt8(ascii: "<") else { index += 1; continue }
            if index + 1 < decoded.count, decoded[index + 1] == UInt8(ascii: "/") {
                guard let end = decoded[index...].firstIndex(of: UInt8(ascii: ">")) else { break }
                index = end + 1
                continue
            }
            guard let end = decoded[index...].firstIndex(of: UInt8(ascii: ">")) else { break }
            let tag = gbk(decoded[(index + 1)..<end])
            let start = end + 1
            let close = find(Array("</".utf8), in: decoded, range: start..<decoded.count)
            let zeros = find([0, 0], in: decoded, range: start..<decoded.count)
            let contentEnd = min(close ?? decoded.count, zeros ?? decoded.count)
            var content = Array(decoded[start..<contentEnd])
            while content.last == 0 { content.removeLast() }
            var values: [String] = []
            var segmentStart = 0
            var cursor = 0
            while cursor + 1 < content.count {
                if content[cursor] == UInt8(ascii: "|"), content[cursor + 1] == UInt8(ascii: "|") {
                    if cursor > segmentStart { values.append(gbk(content[segmentStart..<cursor])) }
                    cursor += 2
                    segmentStart = cursor
                } else {
                    cursor += 1
                }
            }
            if segmentStart < content.count { values.append(gbk(content[segmentStart..<content.count])) }
            result.append(ElabelTag(off: index, len: contentEnd - index, tag: tag, values: values))
            index = max(contentEnd, index + 1)
        }
        return result
    }

    private static func field(_ off: Int, _ len: Int, _ name: String, _ desc: String, _ value: String, _ color: String) -> EDPSectorField {
        EDPSectorField(off: off, len: len, name: name, desc: desc, value: value, color: color)
    }

    private static func dosTypeName(_ type: UInt8) -> String {
        switch type {
        case 0x01: "FAT12"
        case 0x04: "FAT16"
        case 0x05: "Extended"
        case 0x06: "FAT16B"
        case 0x07: "NTFS/exFAT"
        case 0x0b: "FAT32(CHS)"
        case 0x0c: "FAT32(LBA)"
        case 0x0e: "FAT16(LBA)"
        case 0x0f: "Extended(LBA)"
        case 0x27: "Hidden NTFS"
        case 0x82: "Linux swap"
        case 0x83: "Linux"
        case 0xee: "GPT Protective"
        case 0xef: "EFI System"
        default: String(format: "0x%02X", type)
        }
    }

    private static func edpfTypeName(_ type: UInt32) -> String {
        switch type {
        case 1: "Boot"
        case 2: "Share"
        case 4: "Encrypt/IIR指针"
        default: "type\(type)"
        }
    }

    private static func formatGB(_ bytes: UInt64) -> String {
        String(format: "%.2fGB", Double((bytes + 5_000_000) / 10_000_000) / 100.0)
    }

    private static func gbk<S: Collection>(_ bytes: S) -> String where S.Element == UInt8 {
        String(data: Data(bytes), encoding: gbkEncoding) ?? String(decoding: bytes, as: UTF8.self)
    }

    private static func gbkZ<S: Collection>(_ bytes: S) -> String where S.Element == UInt8 {
        let array = Array(bytes)
        let end = array.firstIndex(of: 0) ?? array.count
        return gbk(array[0..<end])
    }

    private static func hex<S: Collection>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func u64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<8 { result |= UInt64(bytes[offset + index]) << UInt64(index * 8) }
        return result
    }

    private static func find(_ pattern: [UInt8], in bytes: [UInt8], range: Range<Int>) -> Int? {
        guard !pattern.isEmpty, range.lowerBound >= 0, range.upperBound <= bytes.count else { return nil }
        guard pattern.count <= range.count else { return nil }
        let last = range.upperBound - pattern.count
        guard range.lowerBound <= last else { return nil }
        for start in range.lowerBound...last where Array(bytes[start..<(start + pattern.count)]) == pattern {
            return start
        }
        return nil
    }
}
