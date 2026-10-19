import Foundation
import Observation

// The right pane's tabs (docs/workbench-rpc.md, `workbench.tabs.*`; PRD §7).
// The host keeps one `TabsState` per key; this file is the pure rules on it
// and the hub that loads, edits and writes it.

/// Where a pane's tabs are kept: `palo`, `pal:<id>` or `ws:<id>`.
public enum PaneTabsKey {
    public static let palo = "palo"
    public static func session(_ id: String) -> String { "pal:" + id }
    public static func workspace(_ id: String) -> String { "ws:" + id }

    /// The tab at the head that can't be closed: 成果 beside the assistant, the files elsewhere.
    public static func pinnedKind(_ key: String) -> String { key == palo ? PaneTab.library : PaneTab.files }
}

extension PaneTab {
    public static let library = "library"
    public static let files = "files"
    public static let preview = "preview"
    public static let web = "web"

    public static func previewTab(_ path: String) -> PaneTab { PaneTab(kind: preview, path: path) }
    public static func webTab(_ url: String) -> PaneTab { PaneTab(kind: web, url: url) }
}

extension TabsState {
    /// The first tab is the pinned one, there is at most one of its kind,
    /// and `active` points at a tab.
    public func normalized(key: String) -> TabsState {
        let pinned = PaneTabsKey.pinnedKind(key)
        var list = tabs
        let before = tabs.first
        if before?.kind != pinned {
            list.removeAll { $0.kind == pinned }
            list.insert(PaneTab(kind: pinned), at: 0)
        }
        // Only one pinned tab.
        var seenPinned = false
        list = list.filter { t in
            guard t.kind == pinned else { return true }
            defer { seenPinned = true }
            return !seenPinned
        }
        var s = self
        s.tabs = list
        s.active = min(max(0, active), list.count - 1)
        return s
    }

    /// The tab the pane shows.
    public var activeTab: PaneTab? { tabs.indices.contains(active) ? tabs[active] : nil }

    /// A tab on this key's pane is wanted: open it, and show it.
    private func showing(_ index: Int) -> TabsState {
        var s = self
        s.active = index
        s.open = true
        return s
    }

    private func opening(_ tab: PaneTab, key: String, same: (PaneTab) -> Bool) -> TabsState {
        var s = normalized(key: key)
        if let i = s.tabs.firstIndex(where: same) { return s.showing(i) }
        s.tabs.append(tab)
        return s.showing(s.tabs.count - 1)
    }

    /// The files tab (the pinned one for a session or workspace).
    public func openingFiles(key: String) -> TabsState {
        opening(PaneTab(kind: PaneTab.files), key: key) { $0.kind == PaneTab.files }
    }

    /// 成果 (the pinned one beside the assistant).
    public func openingLibrary(key: String) -> TabsState {
        opening(PaneTab(kind: PaneTab.library), key: key) { $0.kind == PaneTab.library }
    }

    /// A file as a tab; the same path reuses its tab.
    public func openingPreview(path: String, key: String) -> TabsState {
        opening(.previewTab(path), key: key) { $0.kind == PaneTab.preview && $0.path == path }
    }

    /// A page as a tab; the same address reuses its tab.
    public func openingWeb(url: String, key: String) -> TabsState {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return opening(.webTab(u), key: key) { $0.kind == PaneTab.web && $0.url == u }
    }

    /// Closes a tab. The pinned one stays. The tab beside it takes over when
    /// the active one goes.
    public func closing(at index: Int, key: String) -> TabsState {
        var s = normalized(key: key)
        guard index > 0, s.tabs.indices.contains(index) else { return s }
        s.tabs.remove(at: index)
        if index < s.active { s.active -= 1 }
        s.active = min(max(0, s.active), s.tabs.count - 1)
        return s
    }

    /// The page in a web tab went somewhere else (an address typed in it).
    public func retargetingWeb(at index: Int, to url: String, key: String) -> TabsState {
        var s = normalized(key: key)
        guard s.tabs.indices.contains(index), s.tabs[index].kind == PaneTab.web else { return s }
        s.tabs[index].url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return s
    }

    public func activating(_ index: Int, key: String) -> TabsState {
        var s = normalized(key: key)
        guard s.tabs.indices.contains(index) else { return s }
        s.active = index
        return s
    }

    public func settingOpen(_ open: Bool, key: String) -> TabsState {
        var s = normalized(key: key)
        s.open = open
        return s
    }

    /// Whether the tab at `index` has a close button.
    public func canClose(at index: Int, key: String) -> Bool {
        let s = normalized(key: key)
        return index > 0 && s.tabs.indices.contains(index)
    }

    /// What a pane edit changed, without the host's stamp.
    func sameContent(as other: TabsState) -> Bool {
        tabs == other.tabs && active == other.active && open == other.open
    }
}

// MARK: - the hub

/// Every pane's tabs for one computer: loaded once, edited at once, written
/// to the host at most every 500 ms (the last write wins), and kept current
/// from `workbench.updated` (the echo of our own write is dropped by `updatedAt`).
@MainActor @Observable
public final class PaneTabsHub {
    public private(set) var states: [String: TabsState] = [:]
    public private(set) var loaded = false

    /// How long edits gather before one write.
    public static var throttle: Duration = .milliseconds(500)

    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var pending: Set<String> = []
    @ObservationIgnored private var timers: [String: Task<Void, Never>] = [:]
    /// Writes sent, for tests.
    @ObservationIgnored public private(set) var writes = 0

    private static let table = NSMapTable<AppStore, PaneTabsHub>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    /// The computer's hub (a session's scoped store shares its computer's).
    public static func shared(for store: AppStore) -> PaneTabsHub {
        let root = store.parent ?? store
        if let h = table.object(forKey: root) { return h }
        let h = PaneTabsHub(store: root)
        table.setObject(h, forKey: root)
        return h
    }

    init(store: AppStore) { self.store = store }

    /// What the key shows: its state, or the default (closed, the pinned tab).
    public func state(for key: String) -> TabsState {
        (states[key] ?? TabsState()).normalized(key: key)
    }

    // MARK: editing

    public func update(_ key: String, _ edit: (TabsState) -> TabsState) {
        let before = state(for: key)
        var after = edit(before)
        after.updatedAt = states[key]?.updatedAt ?? 0
        guard !after.sameContent(as: before) else { return }
        states[key] = after
        pending.insert(key)
        schedule(key)
    }

    public func openFiles(_ key: String) { update(key) { $0.openingFiles(key: key) } }
    public func openLibrary(_ key: String) { update(key) { $0.openingLibrary(key: key) } }
    public func openPreview(_ key: String, path: String) { update(key) { $0.openingPreview(path: path, key: key) } }
    public func openWeb(_ key: String, url: String) { update(key) { $0.openingWeb(url: url, key: key) } }
    public func retargetWeb(_ key: String, at index: Int, url: String) { update(key) { $0.retargetingWeb(at: index, to: url, key: key) } }
    public func close(_ key: String, at index: Int) { update(key) { $0.closing(at: index, key: key) } }
    public func activate(_ key: String, at index: Int) { update(key) { $0.activating(index, key: key) } }
    public func setOpen(_ key: String, _ open: Bool) { update(key) { $0.settingOpen(open, key: key) } }

    // MARK: the host

    /// `workbench.tabs.get`: every key's state. A key being edited here keeps ours.
    public func load() async {
        guard let store else { return }
        guard let r = try? await store.rpc.call(RPCMethod.workbenchTabsGet, params: TabsGetParams(), as: TabsGetResult.self) else { return }
        for (k, v) in r.states where !pending.contains(k) { states[k] = v }
        loaded = true
    }

    /// `workbench.updated {key, state}`.
    func apply(update json: JSONValue) {
        guard store?.scope == .palo, let u = WorkbenchTabsUpdate(json: json) else { return }
        // Edits not written yet win: they are written next and replace this.
        guard !pending.contains(u.key) else { return }
        guard let s = u.state else { states[u.key] = nil; return }
        // Our own echo, or an older one.
        if let mine = states[u.key], s.updatedAt <= mine.updatedAt { return }
        states[u.key] = s
    }

    private func schedule(_ key: String) {
        guard timers[key] == nil else { return }
        timers[key] = Task { [weak self] in
            try? await Task.sleep(for: Self.throttle)
            await self?.flush(key)
        }
    }

    /// Writes the key now (the throttle's end).
    public func flush(_ key: String) async {
        timers[key] = nil
        guard pending.remove(key) != nil, let store, let s = states[key] else { return }
        let params = TabsSetParams(key: key, tabs: s.tabs, active: s.active, open: s.open)
        writes += 1
        do {
            let r: TabsSetResult = try await store.rpc.call(RPCMethod.workbenchTabsSet, params: params, as: TabsSetResult.self)
            // Stamped by the host; edits made meanwhile stay as they are.
            if let fresh = r.state {
                if pending.contains(key) { states[key]?.updatedAt = fresh.updatedAt } else { states[key] = fresh }
            }
        } catch {
            // Offline or refused: the next edit or load puts it right.
        }
    }
}
