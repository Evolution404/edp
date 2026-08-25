import FSKit

@main
struct EDPFSKitExtension: UnaryFileSystemExtension {
    typealias FileSystem = EDPFileSystem

    let fileSystem = EDPFileSystem()
}
