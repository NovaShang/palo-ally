import Foundation
import SwiftUI

/// One immediate child of a directory, name relative to that directory.
public struct DirectoryEntry: Sendable, Equatable, Hashable {
    public let name: String
    public let isDir: Bool
    public let size: Int64

    public init(name: String, isDir: Bool, size: Int64 = 0) {
        self.name = name
        self.isDir = isDir
        self.size = size
    }
}

/// One directory's listing: `truncated` when the source held some back.
public struct DirectoryListResult: Sendable, Equatable {
    public let entries: [DirectoryEntry]
    public let truncated: Bool

    public init(entries: [DirectoryEntry], truncated: Bool = false) {
        self.entries = entries
        self.truncated = truncated
    }
}

/// Lists one directory, given its path relative to the tree's root ("" is
/// the root itself); `showHidden` asks for what the source hides by default.
public typealias DirectoryLister = @Sendable (_ relPath: String, _ showHidden: Bool) async throws -> DirectoryListResult

/// Expansion state for the lazy file tree: one store per tree (a Pal's
/// 文件, a folder opened from the preview pane). Ported from Bento Term's
/// `LazyDirectoryTreeStore`: one listing per expanded directory, fetched the
/// first time it opens, so depth costs nothing until it's looked at. Here the
/// source is the computer (`files.list`), and it hides `.git`,
/// `node_modules` and the like until `showHidden`, so toggling that lists
/// again rather than filtering.
@MainActor
public final class LazyDirectoryTreeStore: ObservableObject {
    /// One directory's browse state, keyed by relPath ("" = root).
    public struct DirState: Equatable {
        public var entries: [DirectoryEntry]? = nil   // nil = not loaded yet
        public var loading = false
        public var error: String?
        public var truncated = false
        public var expanded = false

        public init() {}
    }

    @Published public private(set) var rootError: String?
    @Published public private(set) var rootLoading = false
    @Published public private(set) var showHidden = false
    @Published private var dirs: [String: DirState] = [:]

    private var lister: DirectoryLister?
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Bumped on every reset, so a listing from before it is dropped.
    private var generation = 0

    public init() {}

    public func state(of dir: String) -> DirState {
        dirs[dir] ?? DirState()
    }

    /// The expanded directories, root first (what a reload lists again).
    public var expandedPaths: [String] {
        [""] + dirs.filter { $0.key != "" && $0.value.expanded }.map(\.key).sorted()
    }

    // MARK: gestures

    /// Expand (fetch children on first expand) / collapse.
    public func toggle(_ dir: String) {
        var st = state(of: dir)
        if st.expanded {
            st.expanded = false
            dirs[dir] = st
            return
        }
        st.expanded = true
        dirs[dir] = st
        if st.entries == nil { fetch(dir) }
    }

    /// Re-fetch a directory that failed.
    public func retry(_ dir: String) {
        fetch(dir, refresh: true)
    }

    /// List again every directory that's open (pull to refresh, the reload button).
    public func reload() {
        for dir in expandedPaths { fetch(dir, refresh: true) }
    }

    /// Show or hide what the source hides by default; every open directory is listed again.
    public func setShowHidden(_ show: Bool) {
        guard show != showHidden else { return }
        showHidden = show
        for (key, var st) in dirs where !st.expanded && key != "" {
            st.entries = nil
            dirs[key] = st
        }
        reload()
    }

    /// Point the store at a new tree. Clears all expansion and cancels
    /// in-flight fetches, then lists the root.
    public func reset(lister: @escaping DirectoryLister) {
        for t in tasks.values { t.cancel() }
        tasks.removeAll()
        dirs.removeAll()
        generation += 1
        self.lister = lister
        rootError = nil
        rootLoading = true
        var root = DirState()
        root.expanded = true
        dirs[""] = root
        fetch("")
    }

    // MARK: fetching

    private func fetch(_ dir: String, refresh: Bool = false) {
        guard let lister else { return }
        var st = state(of: dir)
        guard refresh || !st.loading else { return }
        st.loading = true
        st.error = nil
        dirs[dir] = st
        if dir.isEmpty { rootLoading = true }
        let hidden = showHidden
        let gen = generation
        tasks[dir]?.cancel()
        tasks[dir] = Task { [weak self] in
            let result: DirectoryListResult?
            var err: String?
            do {
                result = try await lister(dir, hidden)
            } catch {
                result = nil
                err = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            self?.apply(result, error: err, to: dir, generation: gen)
        }
    }

    private func apply(_ result: DirectoryListResult?, error: String?, to dir: String, generation gen: Int) {
        guard gen == generation else { return }
        var st = state(of: dir)
        st.loading = false
        st.error = error
        if let result {
            st.entries = result.entries
            st.truncated = result.truncated
        }
        dirs[dir] = st
        tasks[dir] = nil
        if dir.isEmpty {
            rootLoading = false
            rootError = result == nil ? error : nil
        }
    }
}

/// The picker's listing: exactly one directory, replaced on every move
/// (Bento Term's `DirectoryLevelStore`). A slow listing that lands after the
/// picker moved on is dropped rather than shown under the wrong path.
@MainActor
public final class DirectoryLevelStore: ObservableObject {
    @Published public private(set) var path: String?
    @Published public private(set) var entries: [DirectoryEntry] = []
    @Published public private(set) var loading = false
    @Published public private(set) var error: String?
    @Published public private(set) var truncated = false
    @Published public private(set) var showHidden = false

    private var lister: DirectoryLister?
    private var task: Task<Void, Never>?

    public init() {}

    public func bind(lister: @escaping DirectoryLister) {
        self.lister = lister
    }

    public func fail(_ message: String) {
        task?.cancel()
        task = nil
        path = nil
        entries = []
        truncated = false
        loading = false
        error = message
    }

    /// List `path` (whatever the lister takes: relative or absolute).
    public func load(_ path: String) {
        guard let lister else { return }
        task?.cancel()
        if path != self.path {
            entries = []
            truncated = false
        }
        self.path = path
        loading = true
        error = nil
        let hidden = showHidden
        task = Task { [weak self] in
            var result: DirectoryListResult?
            var err: String?
            do {
                result = try await lister(path, hidden)
            } catch {
                err = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            self?.apply(result, error: err, for: path)
        }
    }

    public func reload() {
        guard let path else { return }
        load(path)
    }

    public func setShowHidden(_ show: Bool) {
        guard show != showHidden else { return }
        showHidden = show
        reload()
    }

    private func apply(_ result: DirectoryListResult?, error: String?, for path: String) {
        guard path == self.path else { return }
        loading = false
        self.error = error
        if let result {
            entries = result.entries
            truncated = result.truncated
        }
    }
}
