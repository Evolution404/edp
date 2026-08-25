import Foundation
import FSKit

/// Compile-time contract for the read-only FSVolume surface we intend to use
/// once the approved macOS 26 runtime gate has been crossed.
///
/// This type is deliberately not instantiated by `EDPFileSystem.loadResource`.
/// Its job is to keep the project pinned to the current handler-style FSKit
/// API and to encode the product invariant that every mutating operation is
/// rejected as read-only before any filesystem semantics are implemented.
final class EDPReadOnlyVolumeContract: FSVolume, FSVolume.Handler, FSVolume.ReadWriteHandler {
    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        fatalError("compile-time contract only")
    }

    var volumeStatistics: FSStatFSResult {
        fatalError("compile-time contract only")
    }

    func activateVolume(
        options: FSTaskOptions,
        replyHandler reply: @escaping @Sendable (FSActivateResult?, (any Error)?) -> Void
    ) {
        reply(nil, POSIXError(.ENOTSUP))
    }

    func deactivateVolume(
        options: FSDeactivateOptions,
        replyHandler reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        reply(nil)
    }

    func mount(
        options: FSTaskOptions,
        replyHandler reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        reply(nil)
    }

    func unmount(replyHandler reply: @escaping @Sendable () -> Void) {
        reply()
    }

    func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        in directory: FSItem,
        attributes: FSItem.SetAttributesRequest,
        context: FSContext,
        replyHandler reply: @escaping @Sendable (FSCreateItemResult?, (any Error)?) -> Void
    ) {
        reply(nil, POSIXError(.EROFS))
    }

    func lookupItem(
        named name: FSFileName,
        in directory: FSItem,
        context: FSContext,
        replyHandler reply: @escaping @Sendable (FSLookupItemResult?, (any Error)?) -> Void
    ) {
        reply(nil, POSIXError(.ENOTSUP))
    }

    func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        from directory: FSItem,
        context: FSContext,
        replyHandler reply: @escaping @Sendable (FSRemoveItemResult?, (any Error)?) -> Void
    ) {
        reply(nil, POSIXError(.EROFS))
    }

    func renameItem(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?,
        context: FSContext,
        replyHandler reply: @escaping @Sendable (FSRenameItemResult?, (any Error)?) -> Void
    ) {
        reply(nil, POSIXError(.EROFS))
    }

    func reclaimItem(
        _ item: FSItem,
        replyHandler reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        reply(nil)
    }

    func createLink(
        to item: FSItem,
        named name: FSFileName,
        in directory: FSItem,
        context: FSContext,
        replyHandler reply: @escaping @Sendable (FSCreateLinkResult?, (any Error)?) -> Void
    ) {
        reply(nil, POSIXError(.EROFS))
    }

    func createSymbolicLink(
        named name: FSFileName,
        in directory: FSItem,
        attributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName,
        context: FSContext,
        replyHandler reply: @escaping @Sendable (FSCreateSymlinkResult?, (any Error)?) -> Void
    ) {
        reply(nil, POSIXError(.EROFS))
    }

    func readSymbolicLink(
        _ item: FSItem,
        context: FSContext,
        replyHandler reply: @escaping @Sendable (FSReadSymlinkResult?, (any Error)?) -> Void
    ) {
        reply(nil, POSIXError(.ENOTSUP))
    }

    func getAttributes(
        _ request: FSItem.GetAttributesRequest,
        of item: FSItem,
        context: FSContext,
        replyHandler reply: @escaping @Sendable (FSGetAttributesResult?, (any Error)?) -> Void
    ) {
        reply(nil, POSIXError(.ENOTSUP))
    }

    func setAttributes(
        _ request: FSItem.SetAttributesRequest,
        on item: FSItem,
        context: FSContext,
        replyHandler reply: @escaping @Sendable (FSSetAttributesResult?, (any Error)?) -> Void
    ) {
        reply(nil, POSIXError(.EROFS))
    }

    func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker,
        context: FSContext,
        replyHandler reply: @escaping @Sendable (FSEnumerateDirectoryResult?, (any Error)?) -> Void
    ) {
        reply(nil, POSIXError(.ENOTSUP))
    }

    func synchronize(
        flags: FSSyncFlags,
        replyHandler reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        reply(nil)
    }

    func read(
        from item: FSItem,
        at offset: off_t,
        length: Int,
        into buffer: FSMutableFileDataBuffer,
        replyHandler reply: @escaping @Sendable (FSReadFileResult?, (any Error)?) -> Void
    ) {
        reply(nil, POSIXError(.ENOTSUP))
    }

    func write(
        contents: Data,
        to item: FSItem,
        at offset: off_t,
        replyHandler reply: @escaping @Sendable (FSWriteFileResult?, (any Error)?) -> Void
    ) {
        reply(nil, POSIXError(.EROFS))
    }
}
