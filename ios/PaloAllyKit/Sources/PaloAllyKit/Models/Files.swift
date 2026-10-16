import Foundation

// Files on the computer, read-only (docs/files-prd.md): a Pal's project
// folder, the assistant's home (its working folder and artifacts), and
// folders the owner opened from the preview pane.

/// Whose files: `{kind:"pal", id}`, `{kind:"palo"}` or `{kind:"folder", id}`.
public struct FileScope: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case pal, palo, folder }
    public var kind: Kind
    public var id: String?

    public init(kind: Kind, id: String? = nil) { self.kind = kind; self.id = kind == .palo ? nil : id }
    public static let palo = FileScope(kind: .palo)
    public static func pal(_ id: String) -> FileScope { FileScope(kind: .pal, id: id) }
    public static func folder(_ id: String) -> FileScope { FileScope(kind: .folder, id: id) }
}

/// One child of a folder.
public struct FileEntry: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case file, dir }
    public var name: String
    public var kind: Kind
    public var size: Int64
    public var mtime: Int64
    public var id: String { name }
    public var isDir: Bool { kind == .dir }

    public init(name: String, kind: Kind, size: Int64 = 0, mtime: Int64 = 0) {
        self.name = name; self.kind = kind; self.size = size; self.mtime = mtime
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        name = l.string("name", or: "")
        kind = Kind(rawValue: l.string("kind", or: "file")) ?? .file
        size = l.int64("size", or: 0)
        mtime = l.millis("mtime", or: 0)
    }
}

/// `files.list {scope, path?, showHidden?}`.
public struct FilesListParams: Codable, Sendable {
    public var scope: FileScope
    public var path: String
    public var showHidden: Bool?
    public init(scope: FileScope, path: String = "", showHidden: Bool? = nil) {
        self.scope = scope; self.path = path; self.showHidden = showHidden
    }
}

/// `files.list → {root, path, entries, truncated}`: `root` is the scope's
/// folder on the computer, `path` the listed folder relative to it.
public struct FilesListResult: Codable, Sendable {
    public var root: String
    public var path: String
    public var entries: [FileEntry]
    public var truncated: Bool

    public init(root: String, path: String, entries: [FileEntry], truncated: Bool = false) {
        self.root = root; self.path = path; self.entries = entries; self.truncated = truncated
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        root = l.string("root", or: "")
        path = l.string("path", or: "")
        entries = l.array(FileEntry.self, "entries", or: [])
        truncated = l.bool("truncated", or: false)
    }
}

/// `files.read {scope, path, offset?, length?}`.
public struct FilesReadParams: Codable, Sendable {
    public var scope: FileScope
    public var path: String
    public var offset: Int64
    public var length: Int64
    public init(scope: FileScope, path: String, offset: Int64 = 0, length: Int64 = ArtifactChunk.maxChunk) {
        self.scope = scope; self.path = path; self.offset = offset; self.length = length
    }
}

/// `files.read → {data, size, mime, eof, tooLarge?}`: a chunk like
/// `artifact.read`'s; over 5 MB only the size (`tooLarge`).
public struct FileChunk: Decodable, Sendable {
    public var data: Data
    public var size: Int64
    public var mime: String
    public var eof: Bool
    public var tooLarge: Bool
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        data = Data(base64Encoded: l.string("data", or: ""), options: .ignoreUnknownCharacters) ?? Data()
        size = l.int64("size", or: 0)
        mime = l.string("mime", or: "application/octet-stream")
        eof = l.bool("eof", or: true)
        tooLarge = l.bool("tooLarge") ?? false
    }
    /// What the host sends whole (docs/files-prd.md: 5 MB).
    public static let maxFile: Int64 = 5 * 1024 * 1024
}

/// `files.search {scope, query, limit?}`.
public struct FilesSearchParams: Codable, Sendable {
    public var scope: FileScope
    public var query: String
    public var limit: Int?
    public init(scope: FileScope, query: String, limit: Int? = nil) { self.scope = scope; self.query = query; self.limit = limit }
}

/// One search hit, relative to the scope's folder.
public struct FileMatch: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var kind: FileEntry.Kind
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public init(path: String, kind: FileEntry.Kind) { self.path = path; self.kind = kind }
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        path = l.string("path", or: "")
        kind = FileEntry.Kind(rawValue: l.string("kind", or: "file")) ?? .file
    }
}

/// `files.search → {matches, partial}`.
public struct FilesSearchResult: Codable, Sendable {
    public var matches: [FileMatch]
    public var partial: Bool
    public init(matches: [FileMatch], partial: Bool = false) { self.matches = matches; self.partial = partial }
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        matches = l.array(FileMatch.self, "matches", or: [])
        partial = l.bool("partial", or: false)
    }
}

/// `files.resolve {scope, paths}`: the paths found in a reply.
public struct FilesResolveParams: Codable, Sendable {
    public var scope: FileScope
    public var paths: [String]
    public init(scope: FileScope, paths: [String]) { self.scope = scope; self.paths = paths }
}

/// A path from a reply that is a file the owner can open.
public struct ResolvedFile: Codable, Sendable, Hashable {
    /// As written in the reply.
    public var text: String
    /// Relative to the scope's folder.
    public var path: String
    public var size: Int64
    public init(text: String, path: String, size: Int64) { self.text = text; self.path = path; self.size = size }
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        text = l.string("text", or: "")
        path = l.string("path", or: "")
        size = l.int64("size", or: 0)
    }
}

/// `files.resolve → {files}`: only the ones that resolved.
public struct FilesResolveResult: Codable, Sendable {
    public var files: [ResolvedFile]
    public init(files: [ResolvedFile]) { self.files = files }
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        files = l.array(ResolvedFile.self, "files", or: [])
    }
}

/// A folder the owner opened from the preview pane (「打开文件夹…」).
public struct OwnerFolder: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var path: String
    public var name: String
    public var addedAt: Int64
    public init(id: String, path: String, name: String, addedAt: Int64) {
        self.id = id; self.path = path; self.name = name; self.addedAt = addedAt
    }
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        id = l.string("id", or: "")
        path = l.string("path", or: "")
        name = l.string("name", or: "")
        addedAt = l.millis("addedAt", or: 0)
    }
}

/// `files.folders.list → {folders}`.
public struct OwnerFoldersResult: Codable, Sendable {
    public var folders: [OwnerFolder]
    public init(folders: [OwnerFolder]) { self.folders = folders }
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        folders = l.array(OwnerFolder.self, "folders", or: [])
    }
}

/// `files.folders.add → {folder}`.
public struct OwnerFolderResult: Codable, Sendable {
    public var folder: OwnerFolder
    public init(folder: OwnerFolder) { self.folder = folder }
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        folder = l.decode(OwnerFolder.self, "folder", or: OwnerFolder(id: "", path: "", name: "", addedAt: 0))
    }
}

/// `files.folders.browse {path?, showHidden?}`: one level of the computer's
/// folders, to pick one (starts at the home folder).
public struct FolderBrowseParams: Codable, Sendable {
    public var path: String?
    public var showHidden: Bool?
    public init(path: String? = nil, showHidden: Bool? = nil) { self.path = path; self.showHidden = showHidden }
}

/// `files.folders.browse → {path, parent, entries, truncated}` (folders only;
/// `parent` nil at `/`).
public struct FolderBrowseResult: Codable, Sendable {
    public var path: String
    public var parent: String?
    public var entries: [FileEntry]
    public var truncated: Bool
    public init(path: String, parent: String?, entries: [FileEntry], truncated: Bool = false) {
        self.path = path; self.parent = parent; self.entries = entries; self.truncated = truncated
    }
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        path = l.string("path", or: "")
        parent = l.string("parent")
        entries = l.array(FileEntry.self, "entries", or: [])
        truncated = l.bool("truncated", or: false)
    }
}

/// `files.folders.add {path}`.
public struct FolderAddParams: Codable, Sendable {
    public var path: String
    public init(path: String) { self.path = path }
}

/// `files.folders.remove {id}`.
public struct FolderRemoveParams: Codable, Sendable {
    public var id: String
    public init(id: String) { self.id = id }
}
