import Foundation

struct EDPReadOnlyNodeID: RawRepresentable, Hashable, Comparable, Sendable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    static func < (lhs: EDPReadOnlyNodeID, rhs: EDPReadOnlyNodeID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum EDPReadOnlyNodeKind: Sendable {
    case directory
    case regularFile
}

struct EDPReadOnlyNodeAttributes: Equatable, Sendable {
    let nodeID: EDPReadOnlyNodeID
    let parentID: EDPReadOnlyNodeID?
    let kind: EDPReadOnlyNodeKind
    let size: UInt64
    let allocatedSize: UInt64
    let permissions: UInt16
}

struct EDPReadOnlyDirectoryEntry: Equatable, Sendable {
    let name: String
    let nodeID: EDPReadOnlyNodeID
    let kind: EDPReadOnlyNodeKind

    /// Opaque backend cursor to resume enumeration after this entry.
    let nextCursor: UInt64
}

enum EDPReadOnlyFilesystemError: Error, Equatable, CustomStringConvertible {
    case notFound
    case notDirectory
    case isDirectory
    case invalidOffset
    case invalidLength
    case invalidName
    case invalidDirectoryCursor
    case invalidModel(String)

    var description: String {
        switch self {
        case .notFound:
            return "filesystem item not found"
        case .notDirectory:
            return "filesystem item is not a directory"
        case .isDirectory:
            return "filesystem item is a directory"
        case .invalidOffset:
            return "invalid read offset"
        case .invalidLength:
            return "invalid read length"
        case .invalidName:
            return "invalid filesystem name"
        case .invalidDirectoryCursor:
            return "invalid directory cursor"
        case let .invalidModel(message):
            return "invalid filesystem model: \(message)"
        }
    }
}

/// FSKit-independent read-only filesystem semantics.
///
/// Implementations own filesystem parsing and data access. They must not
/// import FSKit or know about `FSItem`, directory packers, or FSKit resources.
/// The FSKit layer is intentionally a thin adapter over this boundary.
protocol EDPReadOnlyFilesystemBackend: AnyObject {
    var volumeName: String { get }
    var rootNodeID: EDPReadOnlyNodeID { get }

    func attributes(for nodeID: EDPReadOnlyNodeID) throws -> EDPReadOnlyNodeAttributes

    func lookup(
        name: String,
        inDirectory directoryID: EDPReadOnlyNodeID
    ) throws -> EDPReadOnlyDirectoryEntry

    /// Returns at most `limit` entries beginning at an opaque backend cursor.
    /// Each returned entry carries the cursor that resumes immediately after it.
    func enumerate(
        directory directoryID: EDPReadOnlyNodeID,
        startingAt cursor: UInt64,
        limit: Int
    ) throws -> [EDPReadOnlyDirectoryEntry]

    /// Returns up to `length` bytes. Reading exactly at EOF returns empty data.
    func read(
        file nodeID: EDPReadOnlyNodeID,
        at offset: UInt64,
        length: Int
    ) throws -> Data
}

/// Small immutable reference implementation used to validate the backend
/// contract without FSKit. The live EDP filesystem implementation should
/// conform to `EDPReadOnlyFilesystemBackend` directly rather than materializing
/// a whole large volume into this snapshot.
final class EDPReadOnlyFilesystemSnapshot: EDPReadOnlyFilesystemBackend {
    struct Node: Sendable {
        let nodeID: EDPReadOnlyNodeID
        let parentID: EDPReadOnlyNodeID?
        let name: String
        let kind: EDPReadOnlyNodeKind
        let contents: Data?

        static func directory(
            id: UInt64,
            parentID: UInt64?,
            name: String
        ) -> Node {
            Node(
                nodeID: EDPReadOnlyNodeID(rawValue: id),
                parentID: parentID.map(EDPReadOnlyNodeID.init(rawValue:)),
                name: name,
                kind: .directory,
                contents: nil
            )
        }

        static func file(
            id: UInt64,
            parentID: UInt64,
            name: String,
            contents: Data
        ) -> Node {
            Node(
                nodeID: EDPReadOnlyNodeID(rawValue: id),
                parentID: EDPReadOnlyNodeID(rawValue: parentID),
                name: name,
                kind: .regularFile,
                contents: contents
            )
        }
    }

    let volumeName: String
    let rootNodeID: EDPReadOnlyNodeID

    private let nodesByID: [EDPReadOnlyNodeID: Node]
    private let childrenByParent: [EDPReadOnlyNodeID: [Node]]
    private let childByName: [EDPReadOnlyNodeID: [String: Node]]
    private let allocationUnit: UInt64

    init(
        volumeName: String,
        nodes: [Node],
        allocationUnit: UInt64 = 512
    ) throws {
        guard !volumeName.isEmpty else {
            throw EDPReadOnlyFilesystemError.invalidModel("empty volume name")
        }
        guard allocationUnit > 0 else {
            throw EDPReadOnlyFilesystemError.invalidModel("zero allocation unit")
        }

        var nodesByID: [EDPReadOnlyNodeID: Node] = [:]
        for node in nodes {
            guard nodesByID[node.nodeID] == nil else {
                throw EDPReadOnlyFilesystemError.invalidModel(
                    "duplicate node id \(node.nodeID.rawValue)"
                )
            }
            nodesByID[node.nodeID] = node
        }

        let roots = nodes.filter { $0.parentID == nil }
        guard roots.count == 1, let root = roots.first else {
            throw EDPReadOnlyFilesystemError.invalidModel("expected exactly one root")
        }
        guard root.kind == .directory else {
            throw EDPReadOnlyFilesystemError.invalidModel("root must be a directory")
        }

        var childrenByParent: [EDPReadOnlyNodeID: [Node]] = [:]
        var childByName: [EDPReadOnlyNodeID: [String: Node]] = [:]

        for node in nodes where node.parentID != nil {
            guard let parentID = node.parentID,
                  let parent = nodesByID[parentID] else {
                throw EDPReadOnlyFilesystemError.invalidModel(
                    "missing parent for node \(node.nodeID.rawValue)"
                )
            }
            guard parent.kind == .directory else {
                throw EDPReadOnlyFilesystemError.invalidModel(
                    "parent \(parentID.rawValue) is not a directory"
                )
            }
            guard Self.isValidChildName(node.name) else {
                throw EDPReadOnlyFilesystemError.invalidModel(
                    "invalid child name \(node.name.debugDescription)"
                )
            }
            if node.kind == .directory, node.contents != nil {
                throw EDPReadOnlyFilesystemError.invalidModel(
                    "directory \(node.nodeID.rawValue) carries file contents"
                )
            }
            if node.kind == .regularFile, node.contents == nil {
                throw EDPReadOnlyFilesystemError.invalidModel(
                    "file \(node.nodeID.rawValue) has no contents"
                )
            }

            var byName = childByName[parentID, default: [:]]
            guard byName[node.name] == nil else {
                throw EDPReadOnlyFilesystemError.invalidModel(
                    "duplicate child name \(node.name.debugDescription)"
                )
            }
            byName[node.name] = node
            childByName[parentID] = byName
            childrenByParent[parentID, default: []].append(node)
        }

        for parentID in childrenByParent.keys {
            childrenByParent[parentID]?.sort {
                if $0.name == $1.name {
                    return $0.nodeID < $1.nodeID
                }
                return $0.name < $1.name
            }
        }

        self.volumeName = volumeName
        self.rootNodeID = root.nodeID
        self.nodesByID = nodesByID
        self.childrenByParent = childrenByParent
        self.childByName = childByName
        self.allocationUnit = allocationUnit
    }

    func attributes(for nodeID: EDPReadOnlyNodeID) throws -> EDPReadOnlyNodeAttributes {
        guard let node = nodesByID[nodeID] else {
            throw EDPReadOnlyFilesystemError.notFound
        }

        let size = UInt64(node.contents?.count ?? 0)
        let allocatedSize: UInt64
        if size == 0 {
            allocatedSize = 0
        } else {
            let (padded, overflow) = size.addingReportingOverflow(allocationUnit - 1)
            guard !overflow else {
                throw EDPReadOnlyFilesystemError.invalidModel("allocated-size overflow")
            }
            allocatedSize = (padded / allocationUnit) * allocationUnit
        }

        return EDPReadOnlyNodeAttributes(
            nodeID: node.nodeID,
            parentID: node.parentID,
            kind: node.kind,
            size: size,
            allocatedSize: allocatedSize,
            permissions: node.kind == .directory ? 0o555 : 0o444
        )
    }

    func lookup(
        name: String,
        inDirectory directoryID: EDPReadOnlyNodeID
    ) throws -> EDPReadOnlyDirectoryEntry {
        guard Self.isValidChildName(name) else {
            throw EDPReadOnlyFilesystemError.invalidName
        }
        let directory = try node(directoryID)
        guard directory.kind == .directory else {
            throw EDPReadOnlyFilesystemError.notDirectory
        }
        guard let child = childByName[directoryID]?[name] else {
            throw EDPReadOnlyFilesystemError.notFound
        }

        let siblings = childrenByParent[directoryID] ?? []
        guard let index = siblings.firstIndex(where: { $0.nodeID == child.nodeID }) else {
            throw EDPReadOnlyFilesystemError.invalidModel("child index missing")
        }

        return EDPReadOnlyDirectoryEntry(
            name: child.name,
            nodeID: child.nodeID,
            kind: child.kind,
            nextCursor: UInt64(index + 1)
        )
    }

    func enumerate(
        directory directoryID: EDPReadOnlyNodeID,
        startingAt cursor: UInt64,
        limit: Int
    ) throws -> [EDPReadOnlyDirectoryEntry] {
        guard limit > 0 else {
            throw EDPReadOnlyFilesystemError.invalidLength
        }
        let directory = try node(directoryID)
        guard directory.kind == .directory else {
            throw EDPReadOnlyFilesystemError.notDirectory
        }

        let children = childrenByParent[directoryID] ?? []
        guard cursor <= UInt64(children.count), cursor <= UInt64(Int.max) else {
            throw EDPReadOnlyFilesystemError.invalidDirectoryCursor
        }

        let start = Int(cursor)
        guard start < children.count else { return [] }
        let end = min(children.count, start + limit)

        return children[start..<end].enumerated().map { relativeIndex, node in
            EDPReadOnlyDirectoryEntry(
                name: node.name,
                nodeID: node.nodeID,
                kind: node.kind,
                nextCursor: UInt64(start + relativeIndex + 1)
            )
        }
    }

    func read(
        file nodeID: EDPReadOnlyNodeID,
        at offset: UInt64,
        length: Int
    ) throws -> Data {
        guard length >= 0 else {
            throw EDPReadOnlyFilesystemError.invalidLength
        }
        let file = try node(nodeID)
        guard file.kind == .regularFile else {
            throw EDPReadOnlyFilesystemError.isDirectory
        }
        guard let contents = file.contents else {
            throw EDPReadOnlyFilesystemError.invalidModel("file contents missing")
        }
        guard offset <= UInt64(contents.count), offset <= UInt64(Int.max) else {
            throw EDPReadOnlyFilesystemError.invalidOffset
        }

        let start = Int(offset)
        guard start < contents.count, length > 0 else { return Data() }
        let available = contents.count - start
        let count = min(available, length)
        return contents.subdata(in: start..<(start + count))
    }

    private func node(_ nodeID: EDPReadOnlyNodeID) throws -> Node {
        guard let node = nodesByID[nodeID] else {
            throw EDPReadOnlyFilesystemError.notFound
        }
        return node
    }

    private static func isValidChildName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}
