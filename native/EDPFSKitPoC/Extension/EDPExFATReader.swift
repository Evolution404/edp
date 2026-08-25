import Foundation

/// Minimal read-only exFAT reader used by the native FSKit path.
///
/// This layer deliberately knows nothing about FSKit. It consumes any
/// `EDPRawReadable`, which means the same parser works on a plain image or on
/// top of `EDPEncryptedPartitionReader`.
struct EDPExFATBootSector: Sendable {
    let partitionOffset: UInt64
    let volumeLength: UInt64
    let fatOffset: UInt32
    let fatLength: UInt32
    let clusterHeapOffset: UInt32
    let clusterCount: UInt32
    let firstClusterOfRootDirectory: UInt32
    let volumeSerialNumber: UInt32
    let fileSystemRevision: UInt16
    let volumeFlags: UInt16
    let bytesPerSectorShift: UInt8
    let sectorsPerClusterShift: UInt8
    let numberOfFats: UInt8
    let percentInUse: UInt8

    var bytesPerSector: UInt64 { UInt64(1) << bytesPerSectorShift }
    var sectorsPerCluster: UInt64 { UInt64(1) << sectorsPerClusterShift }
    var bytesPerCluster: UInt64 { bytesPerSector * sectorsPerCluster }
    var volumeSizeBytes: UInt64 { volumeLength * bytesPerSector }

    init(bytes: Data, availableBytes: UInt64?) throws {
        guard bytes.count >= 512 else {
            throw EDPNativeCoreError.parse("exFAT boot sector shorter than 512 bytes")
        }
        let raw = [UInt8](bytes)
        guard Array(raw[3..<11]) == Array("EXFAT   ".utf8) else {
            throw EDPNativeCoreError.parse("exFAT filesystem name is missing")
        }
        guard raw[510] == 0x55, raw[511] == 0xaa else {
            throw EDPNativeCoreError.parse("exFAT boot signature is invalid")
        }

        partitionOffset = Self.u64(raw, 64)
        volumeLength = Self.u64(raw, 72)
        fatOffset = Self.u32(raw, 80)
        fatLength = Self.u32(raw, 84)
        clusterHeapOffset = Self.u32(raw, 88)
        clusterCount = Self.u32(raw, 92)
        firstClusterOfRootDirectory = Self.u32(raw, 96)
        volumeSerialNumber = Self.u32(raw, 100)
        fileSystemRevision = Self.u16(raw, 104)
        volumeFlags = Self.u16(raw, 106)
        bytesPerSectorShift = raw[108]
        sectorsPerClusterShift = raw[109]
        numberOfFats = raw[110]
        percentInUse = raw[112]

        guard (9...12).contains(bytesPerSectorShift) else {
            throw EDPNativeCoreError.parse("exFAT bytes-per-sector shift is invalid")
        }
        guard sectorsPerClusterShift <= 25 - bytesPerSectorShift else {
            throw EDPNativeCoreError.parse("exFAT sectors-per-cluster shift is invalid")
        }
        guard numberOfFats == 1 || numberOfFats == 2 else {
            throw EDPNativeCoreError.parse("exFAT NumberOfFats must be 1 or 2")
        }
        guard volumeLength >= (UInt64(1) << 20) / bytesPerSector else {
            throw EDPNativeCoreError.parse("exFAT volume is smaller than 1 MiB")
        }
        guard volumeLength <= UInt64.max / bytesPerSector else {
            throw EDPNativeCoreError.parse("exFAT volume byte length overflows UInt64")
        }
        guard fatOffset >= 24, fatLength > 0 else {
            throw EDPNativeCoreError.parse("exFAT FAT geometry is invalid")
        }

        let fatEnd = UInt64(fatOffset) + UInt64(fatLength) * UInt64(numberOfFats)
        guard UInt64(clusterHeapOffset) >= fatEnd else {
            throw EDPNativeCoreError.parse("exFAT cluster heap overlaps FAT")
        }
        guard clusterCount > 0, clusterCount <= 0xffff_fff5,
              firstClusterOfRootDirectory >= 2,
              firstClusterOfRootDirectory <= clusterCount + 1 else {
            throw EDPNativeCoreError.parse("exFAT root-directory cluster is invalid")
        }

        let heapSectors = UInt64(clusterCount) * sectorsPerCluster
        guard UInt64(clusterHeapOffset) + heapSectors <= volumeLength else {
            throw EDPNativeCoreError.parse("exFAT cluster heap exceeds volume length")
        }
        if let availableBytes, volumeSizeBytes > availableBytes {
            throw EDPNativeCoreError.parse("exFAT volume length exceeds backing partition")
        }
    }

    func clusterByteOffset(_ cluster: UInt32) throws -> UInt64 {
        guard cluster >= 2, cluster <= clusterCount + 1 else {
            throw EDPNativeCoreError.parse("exFAT cluster index out of range: \(cluster)")
        }
        let clusterIndex = UInt64(cluster - 2)
        return (UInt64(clusterHeapOffset) + clusterIndex * sectorsPerCluster) * bytesPerSector
    }

    func fatEntryByteOffset(_ cluster: UInt32) throws -> UInt64 {
        guard cluster <= clusterCount + 1 else {
            throw EDPNativeCoreError.parse("exFAT FAT cluster index out of range: \(cluster)")
        }
        return UInt64(fatOffset) * bytesPerSector + UInt64(cluster) * 4
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
        (0..<8).reduce(UInt64(0)) { partial, index in
            partial | (UInt64(bytes[offset + index]) << UInt64(index * 8))
        }
    }
}

struct EDPExFATNode: Sendable, Equatable {
    let name: String
    let isDirectory: Bool
    let attributes: UInt16
    let firstCluster: UInt32
    let dataLength: UInt64
    let validDataLength: UInt64
    let noFatChain: Bool

    /// Stable enough for the read-only FSKit item cache: identifies the
    /// directory that owns this entry and the byte offset of the primary entry
    /// within that directory stream.
    let parentDirectoryFirstCluster: UInt32
    let directoryEntryOffset: UInt64
}

/// Read-only exFAT semantics over an arbitrary byte source.
final class EDPExFATReader {
    static let fileEntryType: UInt8 = 0x85
    static let streamExtensionEntryType: UInt8 = 0xc0
    static let fileNameEntryType: UInt8 = 0xc1
    static let volumeLabelEntryType: UInt8 = 0x83
    static let endOfDirectoryEntryType: UInt8 = 0x00

    let raw: any EDPRawReadable
    let boot: EDPExFATBootSector

    init(raw: any EDPRawReadable) throws {
        self.raw = raw
        let bootBytes = try raw.readExact(at: 0, length: 512)
        boot = try EDPExFATBootSector(bytes: bootBytes, availableBytes: raw.sizeBytes)
    }

    func volumeLabel() throws -> String? {
        let data = try directoryData(firstCluster: boot.firstClusterOfRootDirectory, dataLength: nil, noFatChain: false)
        let bytes = [UInt8](data)
        var offset = 0
        while offset + 32 <= bytes.count {
            let type = bytes[offset]
            if type == Self.endOfDirectoryEntryType {
                return nil
            }
            if type == Self.volumeLabelEntryType {
                let count = min(Int(bytes[offset + 1]), 11)
                return Self.decodeUTF16LE(bytes, start: offset + 2, codeUnitCount: count)
            }
            offset += 32
        }
        return nil
    }

    func listRootDirectory() throws -> [EDPExFATNode] {
        try listDirectory(firstCluster: boot.firstClusterOfRootDirectory, dataLength: nil, noFatChain: false)
    }

    func listDirectory(_ directory: EDPExFATNode) throws -> [EDPExFATNode] {
        guard directory.isDirectory else {
            throw EDPNativeCoreError.invalidInput("exFAT item is not a directory")
        }
        return try listDirectory(
            firstCluster: directory.firstCluster,
            dataLength: directory.dataLength,
            noFatChain: directory.noFatChain
        )
    }

    func lookup(name: String, in directory: EDPExFATNode? = nil) throws -> EDPExFATNode? {
        let children: [EDPExFATNode]
        if let directory {
            children = try listDirectory(directory)
        } else {
            children = try listRootDirectory()
        }
        return children.first {
            $0.name.compare(name, options: [.caseInsensitive, .literal]) == .orderedSame
        }
    }

    func readFile(_ node: EDPExFATNode, at offset: UInt64, length: Int) throws -> Data {
        guard !node.isDirectory else {
            throw EDPNativeCoreError.invalidInput("cannot read directory as a regular file")
        }
        guard length >= 0 else {
            throw EDPNativeCoreError.invalidInput("negative exFAT read length")
        }
        guard offset <= node.dataLength else {
            throw EDPNativeCoreError.invalidInput("exFAT read starts beyond end of file")
        }
        guard length > 0, offset < node.dataLength else { return Data() }

        let requested = min(UInt64(length), node.dataLength - offset)
        let readable = offset < node.validDataLength
            ? min(requested, node.validDataLength - offset)
            : 0

        var result = Data()
        if readable > 0 {
            result = try readAllocatedRange(
                firstCluster: node.firstCluster,
                dataLength: node.dataLength,
                noFatChain: node.noFatChain,
                offset: offset,
                length: Int(readable)
            )
        }
        if requested > readable {
            result.append(Data(count: Int(requested - readable)))
        }
        return result
    }

    private func listDirectory(
        firstCluster: UInt32,
        dataLength: UInt64?,
        noFatChain: Bool
    ) throws -> [EDPExFATNode] {
        let data = try directoryData(firstCluster: firstCluster, dataLength: dataLength, noFatChain: noFatChain)
        let bytes = [UInt8](data)
        var nodes = [EDPExFATNode]()
        var offset = 0

        while offset + 32 <= bytes.count {
            let entryType = bytes[offset]
            if entryType == Self.endOfDirectoryEntryType {
                break
            }

            if entryType != Self.fileEntryType {
                offset += 32
                continue
            }

            let secondaryCount = Int(bytes[offset + 1])
            let setByteLength = (secondaryCount + 1) * 32
            guard secondaryCount >= 2, offset + setByteLength <= bytes.count else {
                throw EDPNativeCoreError.parse("truncated exFAT file directory-entry set")
            }
            let set = Array(bytes[offset..<(offset + setByteLength)])
            guard Self.verifySetChecksum(set) else {
                throw EDPNativeCoreError.verify("exFAT directory-entry set checksum mismatch")
            }

            let streamOffset = offset + 32
            guard bytes[streamOffset] == Self.streamExtensionEntryType else {
                throw EDPNativeCoreError.parse("exFAT file entry is missing stream extension")
            }
            let nameLength = Int(bytes[streamOffset + 3])
            guard nameLength > 0 else {
                throw EDPNativeCoreError.parse("exFAT file name is empty")
            }
            let fileNameEntryCount = (nameLength + 14) / 15
            guard secondaryCount >= 1 + fileNameEntryCount else {
                throw EDPNativeCoreError.parse("exFAT file entry has too few name entries")
            }

            var nameUnits = [UInt16]()
            nameUnits.reserveCapacity(fileNameEntryCount * 15)
            for nameIndex in 0..<fileNameEntryCount {
                let nameEntryOffset = offset + (2 + nameIndex) * 32
                guard bytes[nameEntryOffset] == Self.fileNameEntryType else {
                    throw EDPNativeCoreError.parse("exFAT file-name entry is missing")
                }
                for unitIndex in 0..<15 {
                    let p = nameEntryOffset + 2 + unitIndex * 2
                    nameUnits.append(UInt16(bytes[p]) | (UInt16(bytes[p + 1]) << 8))
                }
            }
            let name = String(decoding: nameUnits.prefix(nameLength), as: Unicode.UTF16.self)

            let attributes = Self.u16(bytes, offset + 4)
            let flags = bytes[streamOffset + 1]
            let validDataLength = Self.u64(bytes, streamOffset + 8)
            let childFirstCluster = Self.u32(bytes, streamOffset + 20)
            let childDataLength = Self.u64(bytes, streamOffset + 24)
            guard validDataLength <= childDataLength else {
                throw EDPNativeCoreError.parse("exFAT ValidDataLength exceeds DataLength")
            }
            if childDataLength > 0 {
                guard childFirstCluster >= 2, childFirstCluster <= boot.clusterCount + 1 else {
                    throw EDPNativeCoreError.parse("exFAT stream first cluster is invalid")
                }
            }

            nodes.append(
                EDPExFATNode(
                    name: name,
                    isDirectory: (attributes & 0x10) != 0,
                    attributes: attributes,
                    firstCluster: childFirstCluster,
                    dataLength: childDataLength,
                    validDataLength: validDataLength,
                    noFatChain: (flags & 0x02) != 0,
                    parentDirectoryFirstCluster: firstCluster,
                    directoryEntryOffset: UInt64(offset)
                )
            )
            offset += setByteLength
        }
        return nodes
    }

    private func directoryData(
        firstCluster: UInt32,
        dataLength: UInt64?,
        noFatChain: Bool
    ) throws -> Data {
        if let dataLength {
            guard dataLength <= 256 * 1024 * 1024 else {
                throw EDPNativeCoreError.parse("exFAT directory exceeds 256 MiB")
            }
            guard dataLength <= UInt64(Int.max) else {
                throw EDPNativeCoreError.parse("exFAT directory is too large")
            }
            return try readAllocatedRange(
                firstCluster: firstCluster,
                dataLength: dataLength,
                noFatChain: noFatChain,
                offset: 0,
                length: Int(dataLength)
            )
        }

        let chain = try fatChain(firstCluster: firstCluster)
        guard UInt64(chain.count) <= UInt64(Int.max) / boot.bytesPerCluster else {
            throw EDPNativeCoreError.parse("exFAT root directory is too large")
        }
        var result = Data()
        for cluster in chain {
            let clusterBytes = try readCluster(cluster)
            result.append(clusterBytes)
            guard result.count <= 256 * 1024 * 1024 else {
                throw EDPNativeCoreError.parse("exFAT root directory exceeds 256 MiB")
            }
            if Self.containsEndOfDirectory(clusterBytes) {
                break
            }
        }
        return result
    }

    private func readAllocatedRange(
        firstCluster: UInt32,
        dataLength: UInt64,
        noFatChain: Bool,
        offset: UInt64,
        length: Int
    ) throws -> Data {
        guard length >= 0 else {
            throw EDPNativeCoreError.invalidInput("negative allocated-range length")
        }
        guard length > 0 else { return Data() }
        let (end, overflow) = offset.addingReportingOverflow(UInt64(length))
        guard !overflow, end <= dataLength else {
            throw EDPNativeCoreError.invalidInput("allocated-range read exceeds stream")
        }

        let clusterSize = boot.bytesPerCluster
        let firstLogicalCluster = offset / clusterSize
        let lastLogicalCluster = (end - 1) / clusterSize
        let clusterCountNeeded = lastLogicalCluster - firstLogicalCluster + 1

        var physicalClusters = [UInt32]()
        if noFatChain {
            guard firstCluster >= 2 else {
                throw EDPNativeCoreError.parse("contiguous exFAT stream has no first cluster")
            }
            for delta in 0..<clusterCountNeeded {
                let candidate = UInt64(firstCluster) + firstLogicalCluster + delta
                guard candidate <= UInt64(boot.clusterCount) + 1 else {
                    throw EDPNativeCoreError.parse("contiguous exFAT stream exceeds cluster heap")
                }
                physicalClusters.append(UInt32(candidate))
            }
        } else {
            let chain = try fatChain(firstCluster: firstCluster)
            guard lastLogicalCluster < UInt64(chain.count) else {
                throw EDPNativeCoreError.parse("exFAT FAT chain is shorter than stream length")
            }
            let startIndex = Int(firstLogicalCluster)
            let endIndex = Int(lastLogicalCluster)
            physicalClusters = Array(chain[startIndex...endIndex])
        }

        var remaining = length
        var logicalOffset = offset
        var result = Data()
        result.reserveCapacity(length)

        for cluster in physicalClusters {
            let offsetWithinCluster = logicalOffset % clusterSize
            let available = clusterSize - offsetWithinCluster
            let take = min(UInt64(remaining), available)
            let clusterBase = try boot.clusterByteOffset(cluster)
            let absolute = clusterBase + offsetWithinCluster
            result.append(try raw.readExact(at: absolute, length: Int(take)))
            remaining -= Int(take)
            logicalOffset += take
            if remaining == 0 { break }
        }

        guard remaining == 0 else {
            throw EDPNativeCoreError.parse("exFAT allocated-range read ended early")
        }
        return result
    }

    private func readCluster(_ cluster: UInt32) throws -> Data {
        guard boot.bytesPerCluster <= UInt64(Int.max) else {
            throw EDPNativeCoreError.parse("exFAT cluster size exceeds addressable memory")
        }
        return try raw.readExact(
            at: boot.clusterByteOffset(cluster),
            length: Int(boot.bytesPerCluster)
        )
    }

    private func fatChain(firstCluster: UInt32) throws -> [UInt32] {
        guard firstCluster >= 2, firstCluster <= boot.clusterCount + 1 else {
            throw EDPNativeCoreError.parse("exFAT FAT chain starts outside cluster heap")
        }
        var chain = [UInt32]()
        chain.reserveCapacity(8)
        var visited = Set<UInt32>()
        var current = firstCluster

        while true {
            guard visited.insert(current).inserted else {
                throw EDPNativeCoreError.parse("exFAT FAT chain contains a cycle")
            }
            chain.append(current)
            guard chain.count <= Int(boot.clusterCount) else {
                throw EDPNativeCoreError.parse("exFAT FAT chain exceeds cluster count")
            }

            let bytes = [UInt8](try raw.readExact(at: boot.fatEntryByteOffset(current), length: 4))
            let next = Self.u32(bytes, 0)
            if next == 0xffff_ffff {
                return chain
            }
            guard next >= 2, next <= boot.clusterCount + 1 else {
                throw EDPNativeCoreError.parse("exFAT FAT chain contains invalid next cluster \(next)")
            }
            current = next
        }
    }

    private static func containsEndOfDirectory(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var offset = 0
        while offset + 32 <= bytes.count {
            if bytes[offset] == endOfDirectoryEntryType {
                return true
            }
            offset += 32
        }
        return false
    }

    private static func verifySetChecksum(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 32, bytes.count % 32 == 0 else { return false }
        let expected = u16(bytes, 2)
        var checksum: UInt16 = 0
        for index in bytes.indices {
            if index == 2 || index == 3 { continue }
            checksum = ((checksum & 1) != 0 ? 0x8000 : 0) | (checksum >> 1)
            checksum = checksum &+ UInt16(bytes[index])
        }
        return checksum == expected
    }

    private static func decodeUTF16LE(
        _ bytes: [UInt8],
        start: Int,
        codeUnitCount: Int
    ) -> String {
        var units = [UInt16]()
        units.reserveCapacity(codeUnitCount)
        for index in 0..<codeUnitCount {
            let p = start + index * 2
            units.append(UInt16(bytes[p]) | (UInt16(bytes[p + 1]) << 8))
        }
        return String(decoding: units, as: Unicode.UTF16.self)
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
        (0..<8).reduce(UInt64(0)) { partial, index in
            partial | (UInt64(bytes[offset + index]) << UInt64(index * 8))
        }
    }
}
