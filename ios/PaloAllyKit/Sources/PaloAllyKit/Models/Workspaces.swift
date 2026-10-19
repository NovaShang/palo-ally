import Foundation

// The workbench (docs/workbench-rpc.md): workspaces that group sessions,
// what 以前的 holds, folders to start a session in, one session's details,
// and the browser pane's tabs. A session is a `Pal` on the wire.

// MARK: - the dot

/// The one status dot every list, row and title shows (workbench-prd §3).
public enum StatusDotKind: Sendable, Hashable {
    /// Cyan, with a soft halo.
    case working
    /// Orange: it asked something and waits on the owner.
    case waiting
    /// Green: it finished something the owner hasn't looked at yet.
    case done
    /// Gray: nothing to see. Asleep, starting and stopped look like this too.
    case idle

    public init(_ a: PalAttention) {
        switch a {
        case .working: self = .working
        case .waiting: self = .waiting
        case .done: self = .done
        case .idle, .unknown: self = .idle
        }
    }

    /// One of the computer's other sessions.
    public init(_ s: CCSessionStatus) {
        switch s {
        case .busy: self = .working
        case .waiting: self = .waiting
        case .idle, .stopped, .unknown: self = .idle
        }
    }
}

extension Pal {
    public var dot: StatusDotKind { StatusDotKind(attention) }
}

// MARK: - workspaces

/// A set of sessions the owner tiles together (workbench-prd §2).
public struct Workspace: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// Empty: not named yet; the members' names stand in.
    public var name: String
    /// Session ids, in the sidebar's order.
    public var memberIds: [String]
    /// The tiling, kept as the host sends it (`LayoutNode`); nil = not laid out yet.
    public var layout: JSONValue?
    public var createdAt: Int64
    public var updatedAt: Int64

    public init(id: String, name: String = "", memberIds: [String] = [], layout: JSONValue? = nil,
                createdAt: Int64 = 0, updatedAt: Int64 = 0) {
        self.id = id; self.name = name; self.memberIds = memberIds; self.layout = layout
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        id = l.string("id", or: UUID().uuidString)
        name = l.string("name", or: "")
        memberIds = l.decode([String].self, "memberIds", or: [])
        if let v = l.decode(JSONValue.self, "layout"), v != .null { layout = v } else { layout = nil }
        createdAt = l.millis("createdAt", or: 0)
        updatedAt = l.millis("updatedAt", or: 0)
    }

    /// What it's called: its name, else its members' names put together.
    public func title(pals: [Pal]) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { return n }
        let names = memberIds.compactMap { id in pals.first { $0.id == id }?.displayName }
        return names.prefix(3).joined(separator: " · ")
    }
}

/// `workspaces.list → {workspaces}`, and the `workspaces.updated` event.
public struct WorkspacesResult: Decodable, Sendable {
    public var workspaces: [Workspace]
    public init(workspaces: [Workspace]) { self.workspaces = workspaces }
    public init(from decoder: Decoder) throws {
        workspaces = try Lenient(decoder).array(Workspace.self, "workspaces", or: [])
    }
}

/// `workspaces.create → {workspace}`, `workspaces.update → {workspace}`.
public struct WorkspaceResult: Decodable, Sendable {
    public var workspace: Workspace?
    public init(workspace: Workspace?) { self.workspace = workspace }
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        workspace = l.expect("workspace", l.decode(Workspace.self, "workspace"))
    }
}

public struct WorkspaceCreateParams: Codable, Sendable {
    public var name: String?
    public var memberIds: [String]
    public init(name: String? = nil, memberIds: [String]) { self.name = name; self.memberIds = memberIds }
}

/// Only what is given changes. `layout: .null` clears the tiling.
public struct WorkspaceUpdateParams: Codable, Sendable {
    public var id: String
    public var name: String?
    public var layout: JSONValue?
    public init(id: String, name: String? = nil, layout: JSONValue? = nil) { self.id = id; self.name = name; self.layout = layout }
}

/// No `workspaceId`: out of its workspace, an ordinary session again.
public struct WorkspaceMoveParams: Codable, Sendable {
    public var palId: String
    public var workspaceId: String?
    public init(palId: String, workspaceId: String? = nil) { self.palId = palId; self.workspaceId = workspaceId }
}

// MARK: - what the sidebar lists

/// The sidebar's sections, worked out from the sessions and workspaces
/// (workbench-prd §4). Pure: the same input, the same tree.
public struct SidebarTree: Sendable, Equatable {
    public struct WorkspaceNode: Sendable, Equatable, Identifiable {
        public var workspace: Workspace
        /// Its name, else the members'.
        public var title: String
        /// The sessions in it, in its order.
        public var members: [Pal]
        /// How many of them wait on the owner.
        public var waiting: Int
        public var id: String { workspace.id }
    }

    /// Oldest first, so rows keep their places as layouts change.
    public var workspaces: [WorkspaceNode]
    /// Ordinary sessions (in no workspace, not folded), the latest activity first.
    public var sessions: [Pal]
    /// Sessions put away for lack of use: 以前的 holds them.
    public var foldedCount: Int
    /// Sessions waiting on the owner, anywhere.
    public var waitingCount: Int

    public init(workspaces: [WorkspaceNode] = [], sessions: [Pal] = [], foldedCount: Int = 0, waitingCount: Int = 0) {
        self.workspaces = workspaces; self.sessions = sessions; self.foldedCount = foldedCount; self.waitingCount = waitingCount
    }

    public static func build(pals: [Pal], workspaces: [Workspace]) -> SidebarTree {
        let byID = Dictionary(pals.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var inWorkspace = Set<String>()
        var nodes: [WorkspaceNode] = []
        for w in workspaces.sorted(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }) {
            var ids = w.memberIds
            // A session that says it is in this workspace, listed or not.
            for p in pals where p.workspaceId == w.id && !ids.contains(p.id) { ids.append(p.id) }
            var seen = Set<String>()
            let members = ids.compactMap { id -> Pal? in
                guard !inWorkspace.contains(id), seen.insert(id).inserted, let p = byID[id] else { return nil }
                return p
            }
            members.forEach { inWorkspace.insert($0.id) }
            nodes.append(WorkspaceNode(workspace: w, title: w.title(pals: pals), members: members,
                                       waiting: members.filter { $0.attention == .waiting }.count))
        }
        let loose = pals.enumerated().filter { !inWorkspace.contains($0.element.id) }
        let ordinary = loose.filter { !$0.element.folded }
            .sorted { a, b in
                let (x, y) = (a.element.updatedAt ?? 0, b.element.updatedAt ?? 0)
                return x != y ? x > y : a.offset < b.offset
            }
            .map(\.element)
        return SidebarTree(workspaces: nodes, sessions: ordinary,
                           foldedCount: loose.filter { $0.element.folded }.count,
                           waitingCount: pals.filter { $0.attention == .waiting }.count)
    }

    /// 以前的 N: what the earlier list holds when it has been read, else the
    /// sessions already folded.
    public func earlierCount(loaded: [EarlierItem]?) -> Int { loaded?.count ?? foldedCount }
}

// MARK: - 以前的

/// One line of 以前的 (`pals.earlier`): a session that ended, one put away
/// for lack of use, or a conversation from the computer's terminal.
public struct EarlierItem: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, TolerantStringEnum {
        case ended, folded, recent, unknown
        public static let fallback = Kind.unknown
    }
    public var kind: Kind
    /// Stable: `ended:<sessionId>`, `folded:<palId>`, `recent:<sessionId>`.
    public var key: String
    /// Folded only: the session's id.
    public var palId: String?
    public var sessionId: String
    public var name: String
    public var cwd: String
    /// Ended: when it ended. Folded: when last used. Recent: last changed.
    public var at: Int64
    /// Ended only: the workspace it was in.
    public var workspaceId: String?

    public var id: String { key }

    enum CodingKeys: String, CodingKey { case kind, key, palId = "id", sessionId, name, cwd, at, workspaceId }

    public init(kind: Kind, key: String, palId: String? = nil, sessionId: String, name: String, cwd: String, at: Int64,
                workspaceId: String? = nil) {
        self.kind = kind; self.key = key; self.palId = palId; self.sessionId = sessionId; self.name = name
        self.cwd = cwd; self.at = at; self.workspaceId = workspaceId
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        kind = l.decode(Kind.self, "kind", or: .unknown)
        sessionId = l.string("sessionId", or: "")
        key = l.string("key", or: "\(kind.rawValue):\(sessionId)")
        palId = l.string("id")
        name = l.string("name", or: "")
        cwd = l.string("cwd", or: "")
        at = l.millis("at", or: 0)
        workspaceId = l.string("workspaceId")
    }

    /// What it's called: its name on one line, else its folder's.
    public var displayTitle: String {
        let t = name.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? EarlierGroup.name(of: cwd) : t
    }
}

/// One folder's earlier sessions, newest first.
public struct EarlierGroup: Sendable, Hashable, Identifiable {
    public var cwd: String
    public var items: [EarlierItem]
    public var id: String { cwd }
    public var name: String { Self.name(of: cwd) }
    public var path: String { CCSession.shortPath(cwd) }

    static func name(of cwd: String) -> String {
        let short = CCSession.shortPath(cwd)
        let last = (short as NSString).lastPathComponent
        return last.isEmpty ? short : last
    }

    /// By folder: the folder used most lately first. With a query, only
    /// those whose title or folder has it (any case).
    public static func group(_ items: [EarlierItem], matching query: String = "") -> [EarlierGroup] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let shown = q.isEmpty ? items : items.filter {
            $0.displayTitle.lowercased().contains(q) || CCSession.shortPath($0.cwd).lowercased().contains(q)
        }
        var byFolder: [String: [EarlierItem]] = [:]
        for i in shown { byFolder[i.cwd, default: []].append(i) }
        return byFolder.map { cwd, list in
            EarlierGroup(cwd: cwd, items: list.sorted { ($0.at, $0.key) > ($1.at, $1.key) })
        }
        .sorted { a, b in
            let (x, y) = (a.items.first?.at ?? 0, b.items.first?.at ?? 0)
            return x != y ? x > y : a.cwd < b.cwd
        }
    }
}

public struct EarlierParams: Codable, Sendable {
    public var limit: Int?
    public var folder: String?
    public init(limit: Int? = nil, folder: String? = nil) { self.limit = limit; self.folder = folder }
}

/// `pals.earlier → {items}`.
public struct EarlierResult: Decodable, Sendable {
    public var items: [EarlierItem]
    public init(items: [EarlierItem]) { self.items = items }
    public init(from decoder: Decoder) throws {
        items = try Lenient(decoder).array(EarlierItem.self, "items", or: [])
    }
}

/// `pals.end → {earlier}`.
public struct PalEndResult: Decodable, Sendable {
    public var earlier: EarlierItem?
    public init(earlier: EarlierItem?) { self.earlier = earlier }
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        earlier = l.expect("earlier", l.decode(EarlierItem.self, "earlier"))
    }
}

/// `pals.resume {key}` (→ `{pal}`, as `pals.wake` answers).
public struct PalResumeParams: Codable, Sendable {
    public var key: String
    public init(key: String) { self.key = key }
}

// MARK: - starting a session

/// `pals.create {cwd, name?, text?, workspaceId?}` (→ `{pal}`).
public struct PalCreateParams: Codable, Sendable {
    public var cwd: String
    public var name: String?
    public var text: String?
    public var workspaceId: String?
    public init(cwd: String, name: String? = nil, text: String? = nil, workspaceId: String? = nil) {
        self.cwd = cwd; self.name = name; self.text = text; self.workspaceId = workspaceId
    }
}

/// A folder to start a session in.
public struct SessionFolder: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var name: String
    public var lastUsedAt: Int64
    public var id: String { path }
    enum CodingKeys: String, CodingKey { case path, name, lastUsedAt }

    public init(path: String, name: String, lastUsedAt: Int64) { self.path = path; self.name = name; self.lastUsedAt = lastUsedAt }
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        path = l.string("path", or: "")
        name = l.string("name", or: (path as NSString).lastPathComponent)
        lastUsedAt = l.millis("lastUsedAt", or: 0)
    }
}

public struct FoldersParams: Codable, Sendable {
    public var limit: Int?
    public init(limit: Int? = nil) { self.limit = limit }
}

/// `pals.folders → {folders}`.
public struct FoldersResult: Decodable, Sendable {
    public var folders: [SessionFolder]
    public init(folders: [SessionFolder]) { self.folders = folders }
    public init(from decoder: Decoder) throws {
        folders = try Lenient(decoder).array(SessionFolder.self, "folders", or: [])
    }
}

// MARK: - one session's details

/// A model the session can use, and the thinking depths it allows (none: no choice).
public struct PalModelOption: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var efforts: [String]
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        id = l.string("id", or: "")
        name = l.string("name", or: id)
        efforts = l.decode([String].self, "efforts", or: [])
    }
}

/// A background task or sub-agent running in a session.
public struct PalTask: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, TolerantStringEnum {
        case subagent, bg, unknown
        public static let fallback = Kind.unknown
    }
    public var id: String
    public var title: String
    public var kind: Kind
    public var startedAt: Int64
    public var summary: String?
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        id = l.string("id", or: "")
        title = l.string("title", or: "")
        kind = l.decode(Kind.self, "kind", or: .unknown)
        startedAt = l.millis("startedAt", or: 0)
        summary = l.string("summary")
    }
}

/// `pals.detail → …`: everything the title capsule's details show.
public struct PalDetail: Decodable, Sendable {
    public var pal: Pal?
    public var contextTokens: Int?
    public var contextWindow: Int?
    public var costTotalUsd: Double
    public var spentToday: Double
    public var model: String?
    public var effort: String?
    public var models: [PalModelOption]
    public var tasks: [PalTask]
    public var lastCompactAt: Int64?

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        pal = l.expect("pal", l.decode(Pal.self, "pal"))
        contextTokens = l.int("contextTokens")
        contextWindow = l.int("contextWindow")
        costTotalUsd = l.expect("costTotalUsd", l.double("costTotalUsd")) ?? 0
        spentToday = l.expect("spentToday", l.double("spentToday")) ?? 0
        model = l.string("model")
        effort = l.string("effort")
        models = l.array(PalModelOption.self, "models", or: [])
        tasks = l.array(PalTask.self, "tasks", or: [])
        lastCompactAt = l.millis("lastCompactAt")
    }
}

public struct PalSetModelParams: Codable, Sendable {
    public var id: String
    public var model: String?
    public var effort: String?
    public init(id: String, model: String? = nil, effort: String? = nil) { self.id = id; self.model = model; self.effort = effort }
}

public struct PalStopTaskParams: Codable, Sendable {
    public var id: String
    public var taskId: String
    public init(id: String, taskId: String) { self.id = id; self.taskId = taskId }
}

public struct PalRevealParams: Codable, Sendable {
    public var id: String
    /// `finder` or `terminal`.
    public var kind: String
    public init(id: String, kind: String) { self.id = id; self.kind = kind }
}

/// An answer that is `{}`.
public struct EmptyResult: Decodable, Sendable {
    public init() {}
    public init(from decoder: Decoder) throws {}
}

// MARK: - the browser pane's tabs

/// A tab in the right pane. Unknown kinds (a newer app wrote them) are kept.
public struct PaneTab: Codable, Sendable, Hashable {
    public var kind: String
    public var path: String?
    public var url: String?
    public init(kind: String, path: String? = nil, url: String? = nil) { self.kind = kind; self.path = path; self.url = url }
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        kind = l.string("kind", or: "")
        path = l.string("path")
        url = l.string("url")
    }
}

public struct TabsState: Codable, Sendable, Hashable {
    public var tabs: [PaneTab]
    public var active: Int
    public var open: Bool
    public var updatedAt: Int64
    public init(tabs: [PaneTab] = [], active: Int = 0, open: Bool = false, updatedAt: Int64 = 0) {
        self.tabs = tabs; self.active = active; self.open = open; self.updatedAt = updatedAt
    }
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        tabs = l.array(PaneTab.self, "tabs", or: [])
        active = l.int("active", or: 0)
        open = l.bool("open", or: false)
        updatedAt = l.millis("updatedAt", or: 0)
    }
}

public struct TabsGetParams: Codable, Sendable {
    public var key: String?
    public init(key: String? = nil) { self.key = key }
}

public struct TabsGetResult: Decodable, Sendable {
    public var states: [String: TabsState]
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        states = l.decode([String: TabsState].self, "states", or: [:])
    }
}

public struct TabsSetParams: Codable, Sendable {
    public var key: String
    public var tabs: [PaneTab]
    public var active: Int?
    public var open: Bool
    public init(key: String, tabs: [PaneTab], active: Int? = nil, open: Bool) {
        self.key = key; self.tabs = tabs; self.active = active; self.open = open
    }
}

public struct TabsSetResult: Decodable, Sendable {
    public var state: TabsState?
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        state = l.expect("state", l.decode(TabsState.self, "state"))
    }
}

/// `workbench.updated {key, state}`; `state` nil = the key was dropped.
public struct WorkbenchTabsUpdate: Sendable {
    public var key: String
    public var state: TabsState?
    public init?(json: JSONValue) {
        guard let key = json["key"]?.stringValue else { return nil }
        self.key = key
        state = json["state"].flatMap { try? $0.decode(TabsState.self) }
    }
}
