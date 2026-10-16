import Foundation

/// Files on the computer, read-only (docs/files-prd.md): a Pal's project
/// folder (its ⋯ menu → 文件), the paths in replies, the composer's
/// 电脑上的文件, and folders opened from the preview pane.
extension AppStore {
    /// One folder's children (`path` relative to the scope's folder; "" is the folder itself).
    public func listFiles(_ scope: FileScope, path: String = "", showHidden: Bool = false) async throws -> FilesListResult {
        try await rpc.call(RPCMethod.filesList, params: FilesListParams(scope: scope, path: path, showHidden: showHidden ? true : nil))
    }

    /// A whole file, in chunks. `tooLarge`: over 5 MB, nothing was read.
    public func readFile(_ scope: FileScope, path: String,
                         progress: ((Int64, Int64) -> Void)? = nil) async throws -> (data: Data, mime: String, size: Int64, tooLarge: Bool) {
        var out = Data()
        var offset: Int64 = 0
        while true {
            let chunk: FileChunk = try await rpc.call(
                RPCMethod.filesRead,
                params: FilesReadParams(scope: scope, path: path, offset: offset),
                timeout: 60)
            if chunk.tooLarge { return (Data(), chunk.mime, chunk.size, true) }
            out.append(chunk.data)
            offset += Int64(chunk.data.count)
            progress?(offset, max(chunk.size, offset))
            if chunk.eof || chunk.data.isEmpty || offset >= chunk.size || offset > FileChunk.maxFile {
                return (out, chunk.mime, chunk.size, false)
            }
        }
    }

    /// File and folder names under the scope's folder, best first.
    public func searchFiles(_ scope: FileScope, query: String, limit: Int = 50) async throws -> FilesSearchResult {
        try await rpc.call(RPCMethod.filesSearch, params: FilesSearchParams(scope: scope, query: query, limit: limit))
    }

    /// Which of the paths found in a reply are files the owner can open.
    public func resolveFiles(_ scope: FileScope, paths: [String]) async throws -> [ResolvedFile] {
        guard !paths.isEmpty else { return [] }
        let r: FilesResolveResult = try await rpc.call(RPCMethod.filesResolve, params: FilesResolveParams(scope: scope, paths: paths))
        return r.files
    }

    // MARK: the owner's folders

    public func ownerFolders() async throws -> [OwnerFolder] {
        let r: OwnerFoldersResult = try await rpc.call(RPCMethod.filesFoldersList, params: EmptyParams())
        return r.folders
    }

    /// One level of the computer's folders (nil: the home folder).
    public func browseFolders(path: String? = nil, showHidden: Bool = false) async throws -> FolderBrowseResult {
        try await rpc.call(RPCMethod.filesFoldersBrowse, params: FolderBrowseParams(path: path, showHidden: showHidden ? true : nil))
    }

    public func addOwnerFolder(path: String) async throws -> OwnerFolder {
        let r: OwnerFolderResult = try await rpc.call(RPCMethod.filesFoldersAdd, params: FolderAddParams(path: path))
        return r.folder
    }

    public func removeOwnerFolder(id: String) async throws {
        let _: OKResult = try await rpc.call(RPCMethod.filesFoldersRemove, params: FolderRemoveParams(id: id))
    }
}
