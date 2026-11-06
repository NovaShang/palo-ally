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
    /// `version`: the file's when its first chunk was read (nil from an
    /// older host): changed while read, a save over it is a conflict.
    public func readFile(_ scope: FileScope, path: String,
                         progress: ((Int64, Int64) -> Void)? = nil)
        async throws -> (data: Data, mime: String, size: Int64, tooLarge: Bool, version: String?) {
        var out = Data()
        var offset: Int64 = 0
        var version: String?
        while true {
            let chunk: FileChunk = try await rpc.call(
                RPCMethod.filesRead,
                params: FilesReadParams(scope: scope, path: path, offset: offset),
                timeout: 60)
            if offset == 0 { version = chunk.version }
            if chunk.tooLarge { return (Data(), chunk.mime, chunk.size, true, version) }
            out.append(chunk.data)
            offset += Int64(chunk.data.count)
            progress?(offset, max(chunk.size, offset))
            if chunk.eof || chunk.data.isEmpty || offset >= chunk.size || offset > FileChunk.maxFile {
                return (out, chunk.mime, chunk.size, false, version)
            }
        }
    }

    /// A text file edited in the app, saved back whole over `baseVersion`
    /// (the version it was read at); its new version. Changed on the
    /// computer meanwhile: nothing is written, `FileWriteConflict` says the
    /// version there now.
    public func writeFile(_ scope: FileScope, path: String, text: String, baseVersion: String) async throws -> String {
        let r: FilesWriteResult = try await rpc.call(
            RPCMethod.filesWrite,
            params: FilesWriteParams(scope: scope, path: path, content: text, baseVersion: baseVersion),
            timeout: 60)
        if r.conflict { throw FileWriteConflict(version: r.version) }
        return r.version
    }

    // MARK: following a file on screen

    /// Follow one file for as long as the calling task runs (a preview on
    /// screen): `changed` is called each time it changed on disk. The host
    /// watches it (`files.watch`, renewed at a third of its lease, so a
    /// restarted host picks it up again) and says so with `files.changed`; a
    /// host from before that is asked every `pollInterval` for the file's
    /// size and time (its folder's `files.list`). Never throws: offline it
    /// waits and tries again.
    public func followFile(_ scope: FileScope, path: String, pollInterval: Duration = .milliseconds(1500),
                           changed: @escaping @MainActor () async -> Void) async {
        let params = FilesWatchParams(scope: scope, path: path)
        let name = (path as NSString).lastPathComponent
        let feed = FileChangeFeed.shared(for: self)
        let (stream, token) = feed.subscribe()
        defer { feed.unsubscribe(token) }
        var lease = Duration.seconds(30)
        while !Task.isCancelled {
            do {
                let r: FilesWatchResult = try await rpc.call(RPCMethod.filesWatch, params: params)
                lease = .milliseconds(max(5_000, r.lease / 3))
                break
            } catch {
                if Self.unknownMethod(error) {
                    debugLog("files: follow \(name) by polling (host has no files.watch)")
                    await pollFile(scope, path: path, every: pollInterval, changed: changed)
                    return
                }
                // Offline, or not there (yet): try again in a while.
                try? await Task.sleep(for: .seconds(5))
            }
        }
        guard !Task.isCancelled else { return }
        debugLog("files: watching \(name)")
        let rpc = rpc
        let renew = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: lease)
                guard !Task.isCancelled else { return }
                _ = try? await rpc.call(RPCMethod.filesWatch, params: params, as: FilesWatchResult.self)
            }
        }
        for await c in stream where c.scope == scope && c.path == path && !c.gone {
            debugLog("files: \(name) changed on disk (\(c.size) bytes)")
            await changed()
        }
        renew.cancel()
        Task { _ = try? await rpc.call(RPCMethod.filesUnwatch, params: params, as: OKResult.self) }
    }

    /// An older host: the file's size and time from its folder's listing, compared.
    private func pollFile(_ scope: FileScope, path: String, every interval: Duration,
                          changed: @escaping @MainActor () async -> Void) async {
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        var last: (Int64, Int64)?
        while !Task.isCancelled {
            if let list = try? await listFiles(scope, path: dir, showHidden: true),
               let e = list.entries.first(where: { $0.name == name && !$0.isDir }) {
                let now = (e.size, e.mtime)
                if let before = last, before != now {
                    debugLog("files: \(name) changed on disk (polled, \(e.size) bytes)")
                    last = now
                    await changed()
                } else {
                    last = now
                }
            }
            try? await Task.sleep(for: interval)
        }
    }

    nonisolated static func unknownMethod(_ error: Error) -> Bool {
        if case .remote(let m)? = error as? RPCError { return m.lowercased().contains("unknown method") }
        return "\(error)".lowercased().contains("unknown method")
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

/// `files.changed` events, to the previews following their files (one feed
/// per computer: a Pal's or session's store shares its computer's).
@MainActor
public final class FileChangeFeed {
    private static let table = NSMapTable<AppStore, FileChangeFeed>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private var subscribers: [UUID: AsyncStream<FileChanged>.Continuation] = [:]

    public static func shared(for store: AppStore) -> FileChangeFeed {
        let root = store.parent ?? store
        if let f = table.object(forKey: root) { return f }
        let f = FileChangeFeed()
        table.setObject(f, forKey: root)
        return f
    }

    public func subscribe() -> (AsyncStream<FileChanged>, UUID) {
        let id = UUID()
        let (stream, continuation) = AsyncStream<FileChanged>.makeStream(bufferingPolicy: .bufferingNewest(8))
        subscribers[id] = continuation
        return (stream, id)
    }

    public func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)?.finish()
    }

    public func publish(_ change: FileChanged) {
        for c in subscribers.values { c.yield(change) }
    }
}
