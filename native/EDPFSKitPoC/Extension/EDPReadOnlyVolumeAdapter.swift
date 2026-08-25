import Darwin
import Foundation
import FSKit

/// Thin FSKit adapter over `EDPReadOnlyFilesystemBackend`.
///
/// This type deliberately contains no EDP metadata, crypto, or filesystem
/// parsing logic. It is not yet returned from `EDPFileSystem.loadResource`;
/// runtime activation remains gated on a user-approved macOS 26 machine.
final class EDPReadOnlyVolumeAdapter: FSVolume {
    private static let nonRootIdentifierOffset: UInt64 = 0x1000
    private static let enumerationBatchSize = 256

    private let backend: any EDPReadOnlyFilesystemBackend
    private let rootItem: EDPReadOnlyVolumeItem

    init(
        backend: any EDPReadOnlyFilesystemBackend,
        volumeID: UUID = UUID(uuidString: "3DFA8D69-1DBB-4D3C-A004-ED0000000001")!
    ) throws {
        let rootAttributes = try backend.attributes(for: backend.rootNodeID)
        guard rootAttributes.kind == .directory, rootAttributes.parentID == nil else {
            throw POSIXError(.EIO)
        }

        self.backend = backend
        self.rootItem = try EDPReadOnlyVolumeItem(
            nodeAttributes: rootAttributes,
            rootNodeID: backend.rootNodeID
        )

        super.init(
            volumeID: FSVolume.Identifier(uuid: volumeID),
            volumeName: FSFileName(string: backend.volumeName)
        )
    }

    private func item(for nodeID: EDPReadOnlyNodeID) throws -> EDPReadOnlyVolumeItem {
        if nodeID == backend.rootNodeID {
            return rootItem
        }
        do {
            return try EDPReadOnlyVolumeItem(
                nodeAttributes: backend.attributes(for: nodeID),
                rootNodeID: backend.rootNodeID
            )
        } catch {
            throw Self.posixError(for: error)
        }
    }

    private static func identifier(
        for nodeID: EDPReadOnlyNodeID,
        rootNodeID: EDPReadOnlyNodeID
    ) throws -> FSItem.Identifier {
        if nodeID == rootNodeID {
            return .rootDirectory
        }

        let (rawValue, overflow) = nodeID.rawValue.addingReportingOverflow(nonRootIdentifierOffset)
        guard !overflow,
              let identifier = FSItem.Identifier(rawValue: rawValue),
              identifier != .invalid,
              identifier != .rootDirectory,
              identifier != .parentOfRoot else {
            throw POSIXError(.EOVERFLOW)
        }
        return identifier
    }

    private static func posixError(for error: Error) -> Error {
        guard let backendError = error as? EDPReadOnlyFilesystemError else {
            return error
        }

        switch backendError {
        case .notFound:
            return POSIXError(.ENOENT)
        case .notDirectory:
            return POSIXError(.ENOTDIR)
        case .isDirectory:
            return POSIXError(.EISDIR)
        case .invalidOffset, .invalidLength, .invalidName, .invalidDirectoryCursor:
            return POSIXError(.EINVAL)
        case .invalidModel:
            return POSIXError(.EIO)
        }
    }
}

private final class EDPReadOnlyVolumeItem: FSItem {
    let nodeID: EDPReadOnlyNodeID
    let attributes: FSItem.Attributes

    init(
        nodeAttributes: EDPReadOnlyNodeAttributes,
        rootNodeID: EDPReadOnlyNodeID
    ) throws {
        nodeID = nodeAttributes.nodeID

        let attributes = FSItem.Attributes()
        attributes.uid = 0
        attributes.gid = 0
        attributes.linkCount = 1
        attributes.type = nodeAttributes.kind == .directory ? .directory : .file
        attributes.mode = UInt32(
            (nodeAttributes.kind == .directory ? S_IFDIR : S_IFREG)
                | UInt32(nodeAttributes.permissions)
        )
        attributes.size = nodeAttributes.size
        attributes.allocSize = nodeAttributes.allocatedSize
        attributes.fileID = try EDPReadOnlyVolumeAdapter.identifier(
            for: nodeAttributes.nodeID,
            rootNodeID: rootNodeID
        )

        if let parentID = nodeAttributes.parentID {
            attributes.parentID = try EDPReadOnlyVolumeAdapter.identifier(
                for: parentID,
                rootNodeID: rootNodeID
            )
        } else {
            attributes.parentID = .parentOfRoot
        }

        self.attributes = attributes
        super.init()
    }
}

extension EDPReadOnlyVolumeAdapter: FSVolume.PathConfOperations {
    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumXattrSize: Int { 0 }
    var maximumFileSize: UInt64 { UInt64.max }
}

extension EDPReadOnlyVolumeAdapter: FSVolume.Operations {
    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsHardLinks = false
        capabilities.supportsSymbolicLinks = false
        capabilities.supportsPersistentObjectIDs = true
        capabilities.doesNotSupportVolumeSizes = true
        capabilities.supportsHiddenFiles = true
        capabilities.supports64BitObjectIDs = true
        capabilities.caseFormat = .insensitiveCasePreserving
        return capabilities
    }

    var volumeStatistics: FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: "edpvault")
        result.blockSize = 512
        result.ioSize = 4096
        result.totalBlocks = 0
        result.availableBlocks = 0
        result.freeBlocks = 0
        result.totalFiles = 0
        result.freeFiles = 0
        return result
    }

    func activate(options: FSTaskOptions) async throws -> FSItem {
        rootItem
    }

    func deactivate(options: FSDeactivateOptions = []) async throws {}

    func mount(options: FSTaskOptions) async throws {}

    func unmount() async {}

    func synchronize(flags: FSSyncFlags) async throws {}

    func attributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem
    ) async throws -> FSItem.Attributes {
        guard let item = item as? EDPReadOnlyVolumeItem else {
            throw POSIXError(.ENOENT)
        }
        do {
            return try EDPReadOnlyVolumeItem(
                nodeAttributes: backend.attributes(for: item.nodeID),
                rootNodeID: backend.rootNodeID
            ).attributes
        } catch {
            throw Self.posixError(for: error)
        }
    }

    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem
    ) async throws -> FSItem.Attributes {
        throw POSIXError(.EROFS)
    }

    func lookupItem(
        named name: FSFileName,
        inDirectory directory: FSItem
    ) async throws -> (FSItem, FSFileName) {
        guard let directory = directory as? EDPReadOnlyVolumeItem else {
            throw POSIXError(.ENOTDIR)
        }
        guard let string = name.string else {
            throw POSIXError(.EINVAL)
        }

        if string == "." {
            return (directory, name)
        }
        if string == ".." {
            let directoryAttributes: EDPReadOnlyNodeAttributes
            do {
                directoryAttributes = try backend.attributes(for: directory.nodeID)
            } catch {
                throw Self.posixError(for: error)
            }
            guard let parentID = directoryAttributes.parentID else {
                return (rootItem, name)
            }
            return (try item(for: parentID), name)
        }

        do {
            let entry = try backend.lookup(name: string, inDirectory: directory.nodeID)
            return (try item(for: entry.nodeID), FSFileName(string: entry.name))
        } catch {
            throw Self.posixError(for: error)
        }
    }

    func reclaimItem(_ item: FSItem) async throws {}

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        throw POSIXError(.ENOTSUP)
    }

    func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest
    ) async throws -> (FSItem, FSFileName) {
        throw POSIXError(.EROFS)
    }

    func createSymbolicLink(
        named name: FSFileName,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName
    ) async throws -> (FSItem, FSFileName) {
        throw POSIXError(.EROFS)
    }

    func createLink(
        to item: FSItem,
        named name: FSFileName,
        inDirectory directory: FSItem
    ) async throws -> FSFileName {
        throw POSIXError(.EROFS)
    }

    func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        fromDirectory directory: FSItem
    ) async throws {
        throw POSIXError(.EROFS)
    }

    func renameItem(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?
    ) async throws -> FSFileName {
        throw POSIXError(.EROFS)
    }

    func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes requestedAttributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker
    ) async throws -> FSDirectoryVerifier {
        guard let directory = directory as? EDPReadOnlyVolumeItem else {
            throw POSIXError(.ENOTDIR)
        }

        var position = UInt64(cookie)
        let prefixCount: UInt64 = requestedAttributes == nil ? 2 : 0
        let currentIdentifier = directory.attributes.fileID

        if requestedAttributes == nil, position < prefixCount {
            if position == 0 {
                let packed = packer.packEntry(
                    name: FSFileName(string: "."),
                    itemType: .directory,
                    itemID: currentIdentifier,
                    nextCookie: FSDirectoryCookie(1),
                    attributes: nil
                )
                guard packed else { return FSDirectoryVerifier(1) }
                position = 1
            }

            if position == 1 {
                let directoryAttributes: EDPReadOnlyNodeAttributes
                do {
                    directoryAttributes = try backend.attributes(for: directory.nodeID)
                } catch {
                    throw Self.posixError(for: error)
                }
                let parentIdentifier: FSItem.Identifier
                if let parentID = directoryAttributes.parentID {
                    parentIdentifier = try Self.identifier(
                        for: parentID,
                        rootNodeID: backend.rootNodeID
                    )
                } else {
                    parentIdentifier = currentIdentifier
                }

                let packed = packer.packEntry(
                    name: FSFileName(string: ".."),
                    itemType: .directory,
                    itemID: parentIdentifier,
                    nextCookie: FSDirectoryCookie(2),
                    attributes: nil
                )
                guard packed else { return FSDirectoryVerifier(1) }
                position = 2
            }
        }

        guard position >= prefixCount else {
            throw POSIXError(.EINVAL)
        }
        let backendCursor = position - prefixCount

        let entries: [EDPReadOnlyDirectoryEntry]
        do {
            entries = try backend.enumerate(
                directory: directory.nodeID,
                startingAt: backendCursor,
                limit: Self.enumerationBatchSize
            )
        } catch {
            throw Self.posixError(for: error)
        }

        for entry in entries {
            let itemIdentifier = try Self.identifier(
                for: entry.nodeID,
                rootNodeID: backend.rootNodeID
            )
            let itemType: FSItem.ItemType = entry.kind == .directory ? .directory : .file
            let itemAttributes: FSItem.Attributes?
            if requestedAttributes != nil {
                itemAttributes = try item(for: entry.nodeID).attributes
            } else {
                itemAttributes = nil
            }

            let packed = packer.packEntry(
                name: FSFileName(string: entry.name),
                itemType: itemType,
                itemID: itemIdentifier,
                nextCookie: FSDirectoryCookie(prefixCount + entry.nextCursor),
                attributes: itemAttributes
            )
            if !packed { break }
        }

        return FSDirectoryVerifier(1)
    }
}

extension EDPReadOnlyVolumeAdapter: FSVolume.ReadWriteOperations {
    func read(
        from item: FSItem,
        at offset: off_t,
        length: Int,
        into buffer: FSMutableFileDataBuffer
    ) async throws -> Int {
        guard let item = item as? EDPReadOnlyVolumeItem else {
            throw POSIXError(.ENOENT)
        }
        guard offset >= 0, length >= 0 else {
            throw POSIXError(.EINVAL)
        }

        let requestedLength = min(length, buffer.length)
        let data: Data
        do {
            data = try backend.read(
                file: item.nodeID,
                at: UInt64(offset),
                length: requestedLength
            )
        } catch {
            throw Self.posixError(for: error)
        }
        guard data.count <= requestedLength else {
            throw POSIXError(.EIO)
        }

        data.withUnsafeBytes { source in
            guard data.count > 0 else { return }
            _ = buffer.withUnsafeMutableBytes { destination in
                memcpy(destination.baseAddress, source.baseAddress, data.count)
            }
        }
        return data.count
    }

    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> Int {
        throw POSIXError(.EROFS)
    }
}
