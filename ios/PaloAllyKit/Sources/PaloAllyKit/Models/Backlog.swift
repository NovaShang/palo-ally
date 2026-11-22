import Foundation

// MARK: - 待办 (host/src/backlog.ts; docs/workbench-design/backlog.html)

public enum BacklogState: String, TolerantStringEnum {
    /// In line, the queue's order is the owner's.
    case queued
    /// Being done now (`pal`: by which agent).
    case doing
    case done
    case unknown
    public static let fallback = BacklogState.unknown
}

/// One thing the owner wants done and hasn't got to yet.
public struct BacklogItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// One line: what to do.
    public var text: String
    /// A few lines more.
    public var note: String?
    public var state: BacklogState
    /// Who is doing it (doing), or who it's meant for (queued).
    public var pal: String?
    /// That agent's name now.
    public var palName: String?
    public var addedAt: Int64?
    public var doneAt: Int64?

    public init(id: String, text: String, note: String? = nil, state: BacklogState = .queued, pal: String? = nil,
                palName: String? = nil, addedAt: Int64? = nil, doneAt: Int64? = nil) {
        self.id = id; self.text = text; self.note = note; self.state = state; self.pal = pal
        self.palName = palName; self.addedAt = addedAt; self.doneAt = doneAt
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        id = l.string("id", or: UUID().uuidString)
        text = l.string("text", or: "")
        note = l.string("note")
        state = l.decode(BacklogState.self, "state", or: .unknown)
        pal = l.string("pal")
        palName = l.string("palName")
        addedAt = l.millis("addedAt")
        doneAt = l.millis("doneAt")
    }
}

/// A folder's list, shared by the agents working in it: being done first,
/// then the queue (top first), then the done ones.
public struct Backlog: Codable, Sendable, Hashable {
    /// The folder, absolute.
    public var folder: String
    /// The folder's name.
    public var name: String
    /// The assistant's own folder.
    public var assistant: Bool?
    public var items: [BacklogItem]

    public init(folder: String, name: String, assistant: Bool? = nil, items: [BacklogItem]) {
        self.folder = folder; self.name = name; self.assistant = assistant; self.items = items
    }

    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        folder = l.string("folder", or: "")
        name = l.string("name", or: "")
        assistant = l.bool("assistant")
        items = l.array(BacklogItem.self, "items", or: [])
    }

    public var doing: [BacklogItem] { items.filter { $0.state == .doing } }
    public var queued: [BacklogItem] { items.filter { $0.state == .queued } }
    /// The latest first.
    public var done: [BacklogItem] { items.filter { $0.state == .done }.reversed() }

    /// The list once an item has moved to place `to` (0 = top) of the queue,
    /// as the host will have it (a done or started one is in line again).
    public func moving(_ id: String, to: Int) -> Backlog {
        var b = self
        guard let at = b.items.firstIndex(where: { $0.id == id }) else { return b }
        var item = b.items.remove(at: at)
        if item.state != .queued {
            if item.state == .doing { item.pal = nil; item.palName = nil }
            item.state = .queued
            item.doneAt = nil
        }
        let queue = b.items.indices.filter { b.items[$0].state == .queued }
        let place = max(0, min(to, queue.count))
        let index = place < queue.count ? queue[place] : (b.items.firstIndex { $0.state == .done } ?? b.items.count)
        b.items.insert(item, at: index)
        return b
    }

    /// The next item an agent is offered (下一件): the first in line that is
    /// meant for it or for anyone; `skip` steps past that many (换一件).
    public func next(for pal: String, skip: Int = 0) -> BacklogItem? {
        let open = queued.filter { $0.pal == nil || $0.pal == pal }
        guard !open.isEmpty else { return nil }
        return open[skip % open.count]
    }
}

public struct BacklogResult: Decodable, Sendable {
    public var backlog: Backlog?
    public var item: BacklogItem?
    public init(from decoder: Decoder) throws {
        let l = try Lenient(decoder)
        backlog = l.expect("backlog", l.decode(Backlog.self, "backlog"))
        item = l.decode(BacklogItem.self, "item")
    }
}

/// Whose list: an agent's (its folder's), or with neither the assistant's.
public struct BacklogParams: Codable, Sendable {
    public var pal: String?
    public var folder: String?
    public var id: String?
    public var text: String?
    public var note: String?
    public var top: Bool?
    /// backlog.move: the place in the queue, 0 at the top.
    public var to: Int?
    /// backlog.assign / start: the agent; assign with nil: anyone's.
    public var agent: String?
    /// backlog.done: false puts it back in the queue.
    public var done: Bool?

    public init(pal: String? = nil, folder: String? = nil, id: String? = nil, text: String? = nil, note: String? = nil,
                top: Bool? = nil, to: Int? = nil, agent: String? = nil, done: Bool? = nil) {
        self.pal = pal; self.folder = folder; self.id = id; self.text = text; self.note = note; self.top = top
        self.to = to; self.agent = agent; self.done = done
    }

    /// backlog.assign sends `agent: null` to make it anyone's again.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(pal, forKey: .pal)
        try c.encodeIfPresent(folder, forKey: .folder)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(top, forKey: .top)
        try c.encodeIfPresent(to, forKey: .to)
        try c.encode(agent, forKey: .agent)
        try c.encodeIfPresent(done, forKey: .done)
    }
}
