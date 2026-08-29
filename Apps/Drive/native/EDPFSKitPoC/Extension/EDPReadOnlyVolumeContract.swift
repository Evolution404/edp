import Darwin
import Foundation
import FSKit

/// Compile-time contract for the smallest read-only FSVolume surface supported
/// by the Xcode 26.6 / macOS 26.5 SDK used in CI.
///
/// This type is intentionally NOT returned from `EDPFileSystem.loadResource`.
/// It exists so that volume lifecycle, namespace, attribute, directory, and
/// read/write signatures stay compiler-checked while the real FSKit runtime
/// remains blocked on user approval on a normal macOS 26 installation.
///
/// Apple has documented handler-style replacements for these Operations APIs,
/// but that API is not present in the current stable SDK. CI separately probes
/// the installed FSKit headers so this contract can migrate when the SDK does.
final class EDPReadOnlyVolumeContract: FSVolume {
    private let rootItem = EDPReadOnlyVolumeContractItem()

    init() {
        super.init(
            volumeID: FSVolume.Identifier(uuid: UUID(uuidString: "3DFA8D69-1DBB-4D3C-A004-ED0000000001")!),
            volumeName: FSFileName(string: "EDP Drive")
        )
    }
}

private final class EDPReadOnlyVolumeContractItem: FSItem {
    let attributes: FSItem.Attributes

    override init() {
        let attributes = FSItem.Attributes()
        attributes.parentID = .parentOfRoot
        attributes.fileID = .rootDirectory
        attributes.uid = 0
        attributes.gid = 0
        attributes.linkCount = 1
        attributes.type = .directory
        attributes.mode = UInt32(S_IFDIR | 0o555)
        attributes.size = 0
        attributes.allocSize = 0
        self.attributes = attributes
        super.init()
    }
}

extension EDPReadOnlyVolumeContract: FSVolume.PathConfOperations {
    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumXattrSize: Int { 0 }
    var maximumFileSize: UInt64 { UInt64.max }
}

extension EDPReadOnlyVolumeContract: FSVolume.Operations {
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
        let result = FSStatFSResult(fileSystemTypeName: "edpvault-contract")
        result.blockSize = 512
        result.ioSize = 4096
        result.totalBlocks = 0
        result.availableBlocks = 0
        result.freeBlocks = 0
        result.totalFiles = 1
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
        guard let item = item as? EDPReadOnlyVolumeContractItem else {
            throw POSIXError(.ENOENT)
        }
        return item.attributes
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
        throw POSIXError(.ENOENT)
    }

    func reclaimItem(_ item: FSItem) async throws {}

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        throw POSIXError(.EINVAL)
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
        attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker
    ) async throws -> FSDirectoryVerifier {
        guard directory is EDPReadOnlyVolumeContractItem else {
            throw POSIXError(.ENOTDIR)
        }
        return verifier
    }
}

extension EDPReadOnlyVolumeContract: FSVolume.ReadWriteOperations {
    func read(
        from item: FSItem,
        at offset: off_t,
        length: Int,
        into buffer: FSMutableFileDataBuffer
    ) async throws -> Int {
        throw POSIXError(.ENOTSUP)
    }

    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> Int {
        throw POSIXError(.EROFS)
    }
}
