import Foundation
import Observation

/// The app's single source of truth: mirrors host state, applies events,
/// re-syncs on (re)connect, and does optimistic chat sends.
@MainActor
@Observable
public final class AppStore {
    public enum Connection: Equatable, Sendable {
        case idle
        case connecting
        /// Transport up, catching up (`hello` + `sync`).
        case syncing
        case online
        case offline(String?)
        /// Host refused this device; the user must pair again.
        case rejected(String)

        public var isOnline: Bool { self == .online }
        public var isRejected: Bool { if case .rejected = self { return true } else { return false } }
    }

    // MARK: observable state

    /// The link as it really is — for logic (sending, sync, what's enabled).
    /// What the owner is shown is `displayedConnection`.
    public private(set) var connection: Connection = .idle {
        didSet {
            guard connection != oldValue else { return }
            debugLog("connection: \(connection)")
            connectionChanged()
        }
    }
    /// The link as the owner sees it. iOS closes the socket whenever the app
    /// is suspended, so every return to the app starts with a drop and a
    /// quick reconnect — not news. A drop only shows once it has lasted
    /// `troubleGrace` seconds, counted from the drop or from the app becoming
    /// active, whichever is later; until then this stays calm (still online,
    /// or connecting). Being refused (pair again) shows at once.
    public private(set) var displayedConnection: Connection = .idle
    /// A drop (or a refusal) the owner is being shown: it outlasted the grace
    /// period. Banners, captions and the avatar's offline look follow this.
    public private(set) var connectionTrouble = false
    /// How long a drop stays silent.
    public var troubleGrace: Double = 8
    /// When the current stretch without a link began (or the app became active).
    private var troubleSince: Date?
    private var troubleTimer: Task<Void, Never>?
    /// Between didEnterBackground and didBecomeActive.
    private var inBackground = false
    public private(set) var hostName: String = ""
    public private(set) var hostVersion: String = ""
    public private(set) var messages: [ChatMessage] = []
    public private(set) var tasks: [AllyTask] = []
    public private(set) var approvals: [Approval] = []
    /// Choice cards (AskUserQuestion), newest first.
    public private(set) var questions: [Question] = []
    public private(set) var watches: [Watch] = []
    public private(set) var artifacts: [Artifact] = []
    public private(set) var settings: HostSettings? {
        didSet { if let settings, settings != oldValue { onSettings?(settings) } }
    }
    public private(set) var status: HostStatus?
    /// Slash commands, fetched the first time the user types "/".
    public private(set) var commands: [SlashCommand] = []
    public private(set) var modelInfo: ModelInfo?
    /// Highest contiguous chat seq we hold — the `sync{sinceSeq}` cursor.
    public private(set) var lastSeq: Int64 = 0
    /// True between a send and the first sign of a reply (drives the
    /// "收到了" feedback indicator).
    public private(set) var awaitingReply = false
    public private(set) var hasOlderMessages = false
    /// The list shows an older stretch of the conversation (a search jump far
    /// back), not the live end. Live messages wait until `returnToLatest()`.
    public private(set) var viewingPast = false
    public private(set) var isLoadingOlder = false
    /// Number of completed sync rounds (each page counts). Mostly for tests.
    public private(set) var syncRounds = 0
    public private(set) var hasSynced = false
    public var lastError: String?
    /// Puts text on the system pasteboard when a clipboard message arrives
    /// live; returns false when it can't right now (e.g. app not active).
    /// Set by the app; tests inject their own.
    @ObservationIgnored public var clipboardWriter: (@MainActor (String) -> Bool)?
    /// Called with `lastSeq` after every completed sync (the app uses it to
    /// baseline what the owner has seen on hosts they aren't looking at).
    @ObservationIgnored public var onSynced: (@MainActor (Int64) -> Void)?
    /// Called whenever the host's settings arrive or change (the app takes
    /// the assistant's color from them).
    @ObservationIgnored public var onSettings: (@MainActor (HostSettings) -> Void)?
    /// Clipboard messages already copied on this device (local state).
    public private(set) var copiedClipboardIDs: Set<String> = []

    public func markCopied(_ id: String) { copiedClipboardIDs.insert(id) }

    // MARK: config

    public let rpc: RPCClient
    public let clientKind: String
    public let clientVersion: String
    public var initialHistoryLimit = 100

    /// Streamed text not yet applied (from bento's MessageItem): appends are
    /// coalesced (~30 ms) so markdown re-parsing, row diffing and autoscroll
    /// don't run per token.
    private var pendingDeltas: [String: String] = [:]
    private var deltaFlushScheduled = false
    /// Deltas received (breadcrumbs note every 20th).
    @ObservationIgnored private var deltaCount = 0
    private var started = false
    private var syncing = false
    private var resyncRequested = false
    private var pushRegistration: PushRegisterParams?
    private var inboundTask: Task<Void, Never>?
    /// Bumped on every connect / disconnect; stale catch-up loops stop.
    private var connectGeneration = 0
    private var backgroundedAt: Date?
    /// First retry delay when `hello` / `sync` fails on a live link.
    public var syncRetryBase: Double = 1
    /// After this many failed catch-up attempts, drop the link and reconnect.
    public var syncRetryLimit = 3

    public init(transport: any HostTransport, clientKind: String = "ios", clientVersion: String = "1.0",
                rpcTimeout: Double = 20) {
        self.rpc = RPCClient(transport: transport, defaultTimeout: rpcTimeout)
        self.clientKind = clientKind
        self.clientVersion = clientVersion
    }

    // MARK: lifecycle

    public func start() {
        guard !started else { return }
        started = true
        connection = .connecting
        let rpc = rpc
        let stream = rpc.inbound
        inboundTask = Task { [weak self] in
            for await item in stream {
                guard let self else { return }
                self.handle(item)
            }
        }
        Task { await rpc.start() }
    }

    /// Disconnects and stops listening (the store's lifecycle, not the
    /// assistant's stop button — that is `stop()`).
    public func shutdown() {
        inboundTask?.cancel()
        let rpc = rpc
        Task { await rpc.stop() }
        started = false
        connection = .idle
    }

    /// Skip any pending backoff and try right away.
    public func reconnectNow() {
        let transport = rpc.transport
        Task { await transport.reconnectNow() }
    }

    /// Drop the current link (it may be stale) and reconnect immediately.
    public func forceReconnect() {
        let transport = rpc.transport
        Task { await transport.forceReconnect() }
    }

    public func didEnterBackground(at date: Date = Date()) {
        backgroundedAt = date
        // Time away doesn't count toward showing a drop (iOS closes the
        // socket while the app is suspended); the grace starts over on return.
        inBackground = true
        troubleTimer?.cancel()
        troubleTimer = nil
    }

    /// Call when the app returns to the foreground. After a long stay in the
    /// background the socket is usually dead even if it looks open, so we
    /// force a fresh connection instead of trusting it.
    public func didBecomeActive(at date: Date = Date(), staleAfter: TimeInterval = 30) {
        let away = backgroundedAt.map { date.timeIntervalSince($0) } ?? 0
        backgroundedAt = nil
        // Whatever dropped while it was away gets the full grace period from
        // now: the reconnect below usually lands well within it.
        inBackground = false
        if !connection.isOnline, !connectionTrouble, connection != .idle { startGrace() }
        if away > staleAfter && started { forceReconnect() } else { reconnectNow() }
    }

    // MARK: displayed connection

    private func connectionChanged() {
        switch connection {
        case .online, .idle:
            endGrace()
            connectionTrouble = false
            displayedConnection = connection
        case .rejected:
            endGrace()
            connectionTrouble = true
            displayedConnection = connection
        case .connecting, .syncing, .offline:
            if connectionTrouble {
                // Already showing the drop: follow along (offline → connecting → …).
                displayedConnection = connection
                return
            }
            // Within the grace period: nothing alarming. A link that was up
            // still looks up; otherwise it's just connecting.
            if displayedConnection != .online {
                if case .offline = connection { displayedConnection = .connecting } else { displayedConnection = connection }
            }
            if troubleSince == nil {
                if inBackground { troubleSince = Date() } else { startGrace() }
            }
        }
    }

    /// (Re)starts the grace period now.
    private func startGrace() {
        troubleSince = Date()
        troubleTimer?.cancel()
        let grace = troubleGrace
        troubleTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            guard !Task.isCancelled, let self else { return }
            self.graceEnded()
        }
    }

    private func endGrace() {
        troubleTimer?.cancel()
        troubleTimer = nil
        troubleSince = nil
    }

    /// Still no link after the whole grace period: now it's worth showing.
    private func graceEnded() {
        troubleTimer = nil
        switch connection {
        case .online, .idle, .rejected: return
        default:
            connectionTrouble = true
            displayedConnection = connection
        }
    }

    private func handle(_ item: RPCInbound) {
        switch item {
        case .connected:
            breadcrumb("link connected → syncing (\(messages.count) msgs)")
            connectGeneration += 1
            connection = .syncing
            let gen = connectGeneration
            Task { await self.onConnected(generation: gen) }
        case .disconnected(let reason):
            breadcrumb("link disconnected")
            connectGeneration += 1
            switch reason {
            case .closed: connection = .offline(nil)
            case .network(let m): connection = .offline(m)
            case .rejected(let m): connection = .rejected(m)
            }
        case .event(let name, let data):
            apply(event: name, data: data)
        }
    }

    /// Catch-up after every (re)connect: `hello`, `sync`, push re-register,
    /// then resend anything queued while offline. If it fails on a link that
    /// is still up, retry with backoff; after `syncRetryLimit` failures drop
    /// the link and reconnect rather than sitting there half-connected.
    private func onConnected(generation gen: Int) async {
        var failures = 0
        while gen == connectGeneration {
            do {
                let hello: HelloResult = try await rpc.call(RPCMethod.hello,
                                                            params: HelloParams(client: clientKind, version: clientVersion))
                guard gen == connectGeneration else { return }
                hostName = hello.hostName
                hostVersion = hello.version
                if let s = hello.status { applyStatus(s) }
                try await performSync()
                guard gen == connectGeneration else { return }
                connection = .online
                lastError = nil
                if let push = pushRegistration {
                    _ = try? await rpc.call(RPCMethod.pushRegister, params: push, as: OKResult.self)
                }
                resendQueued()
                Task { await self.loadSuggestions() }
                return
            } catch {
                guard gen == connectGeneration else { return }
                debugLog("sync failed: \(error)")
                lastError = Friendly.message(error)
                failures += 1
                if failures >= syncRetryLimit {
                    await rpc.transport.forceReconnect()
                    return
                }
                try? await Task.sleep(for: .seconds(syncRetryBase * pow(2, Double(failures - 1))))
            }
        }
    }

    // MARK: sync

    /// Catches up via `sync{sinceSeq}`, paging until we hold everything.
    /// Concurrent requests coalesce into one extra round.
    public func performSync() async throws {
        if syncing { resyncRequested = true; return }
        syncing = true
        breadcrumb("sync start (since \(hasSynced ? lastSeq : 0))")
        defer {
            syncing = false
            breadcrumb("sync end (\(messages.count) msgs)")
        }
        repeat {
            resyncRequested = false
            var more = true
            while more {
                let since: Int64? = hasSynced ? lastSeq : nil
                let result: SyncResult = try await rpc.call(RPCMethod.sync, params: SyncParams(sinceSeq: since))
                more = applySync(result, since: since)
                syncRounds += 1
            }
        } while resyncRequested
    }

    /// Applies one sync page. Returns true if another page is needed.
    @discardableResult
    public func applySync(_ r: SyncResult, since: Int64?) -> Bool {
        if let t = r.tasks { tasks = t; sortTasks() }
        if let a = r.approvals { approvals = a; sortApprovals() }
        if let q = r.questions { questions = q.sorted { $0.createdAt > $1.createdAt } }
        if let w = r.watches { watches = w }
        if let a = r.artifacts { artifacts = a }
        if let s = r.settings { settings = s }

        let maxSeq = r.messages.map(\.seq).max() ?? 0
        breadcrumb("sync page: \(r.messages.count) msgs, \(r.messages.reduce(0) { $0 + $1.text.utf8.count }) bytes, \(since == nil ? "snapshot" : "since")")
        if since == nil {
            // Fresh snapshot: server messages replace ours; keep unsent echoes.
            let serverIDs = Set(r.messages.map(\.id))
            let serverCIDs = Set(r.messages.compactMap(\.clientMsgId))
            // Unsent echoes the host already has (matched by clientMsgId) are
            // replaced by the server copy.
            let local = messages.filter {
                $0.seq == 0 && $0.delivery != .sent && !($0.clientMsgId.map(serverCIDs.contains) ?? false)
            }
            let streaming = messages.filter { $0.isStreaming && !serverIDs.contains($0.id) }
            messages = r.messages
            for m in streaming + local { messages.append(m) }
            sortMessages()
            lastSeq = max(r.seq, maxSeq)
            hasOlderMessages = (r.messages.map(\.seq).min() ?? 1) > 1
            hasSynced = true
            afterSync(r)
            onSynced?(lastSeq)
            return false
        }
        for m in r.messages { upsert(m) }
        hasSynced = true
        afterSync(r)
        defer { onSynced?(lastSeq) }
        if r.messages.count >= SyncResult.pageLimit && maxSeq > lastSeq {
            lastSeq = maxSeq
            return maxSeq < r.seq
        }
        lastSeq = max(lastSeq, r.seq, maxSeq)
        return false
    }

    /// A reply that landed while we weren't listening still ends the wait.
    private func afterSync(_ r: SyncResult) {
        if let s = r.status { applyStatus(s) }
        guard awaitingReply else { return }
        let lastUser = messages.last(where: { $0.role == .user && $0.seq > 0 })?.seq ?? 0
        let pendingEcho = messages.contains { $0.role == .user && $0.seq == 0 && $0.delivery == .sending }
        if !pendingEcho, messages.contains(where: { $0.role != .user && $0.seq > lastUser }) {
            awaitingReply = false
        }
    }

    /// Applies a status snapshot. `busy == false` means the turn is over:
    /// anything still streaming is finished (a turn can end without a final
    /// `chat.message`, e.g. after an error or a stop) and the wait ends.
    private func applyStatus(_ s: HostStatus) {
        if s.busy != status?.busy { breadcrumb("host \(s.busy ? "busy" : "idle")") }
        status = s
        guard !s.busy else { return }
        flushDeltas()
        for i in messages.indices where messages[i].isStreaming { messages[i].isStreaming = false }
        awaitingReply = false
    }

    private func requestResync() {
        guard hasSynced, connection == .online || connection == .syncing else { return }
        Task { try? await self.performSync() }
    }

    // MARK: events

    public func apply(event name: String, data: JSONValue) {
        switch name {
        case RPCEventName.chatMessage:
            if let m = try? data.decode(ChatMessage.self) {
                let isNew = !messages.contains { $0.id == m.id }
                receive(m)
                // Live only: history and sync never touch the clipboard.
                if isNew, m.kind == .clipboard, m.role == .assistant, clipboardWriter?(m.text) == true {
                    copiedClipboardIDs.insert(m.id)
                }
            }
        case RPCEventName.chatDelta:
            if let d = try? data.decode(ChatDelta.self), !d.id.isEmpty { applyDelta(d) }
        case RPCEventName.taskUpdated:
            if let t = try? data.decode(AllyTask.self) { upsert(task: t) }
        case RPCEventName.approvalUpdated:
            if let a = try? data.decode(Approval.self) { upsert(approval: a) }
        case RPCEventName.questionUpdated:
            if let q = try? data.decode(Question.self) { upsert(question: q) }
        case RPCEventName.watchUpdated:
            switch WatchUpdate(json: data) {
            case .upsert(let w): upsert(watch: w)
            case .removed(let id): watches.removeAll { $0.id == id }
            case .unknown: break
            }
        case RPCEventName.artifactUpdated:
            if let a = try? (data["artifact"] ?? data).decode(Artifact.self) { upsert(artifact: a) }
        case RPCEventName.settingsUpdated:
            if let s = try? (data["settings"] ?? data).decode(HostSettings.self) { settings = s }
        case RPCEventName.commandsUpdated:
            if let r = try? data.decode(CommandsResult.self) { commands = r.commands }
        case RPCEventName.suggestionsUpdated:
            if let r = try? data.decode(SuggestionsResult.self) { suggestions = r.suggestions }
        case RPCEventName.status:
            if let s = try? (data["status"] ?? data).decode(HostStatus.self) { applyStatus(s) }
        default:
            break // unknown events are ignored
        }
    }

    /// A finished `chat.message`.
    func receive(_ m: ChatMessage) {
        if m.role != .user { awaitingReply = false }
        // Looking at an older stretch: don't splice the live end onto it (it
        // would hide the gap in between); it's loaded on the way back.
        if viewingPast, m.seq > 0, !messages.contains(where: { $0.id == m.id || ($0.seq == 0 && $0.clientMsgId != nil && $0.clientMsgId == m.clientMsgId) }) {
            if m.seq > lastSeq { lastSeq = m.seq }
            return
        }
        upsert(m)
        guard m.seq > 0 else { return }
        if m.seq == lastSeq + 1 {
            lastSeq = m.seq
        } else if m.seq > lastSeq + 1 {
            // Gap: something was missed while we weren't looking.
            requestResync()
        }
    }

    func applyDelta(_ d: ChatDelta) {
        awaitingReply = false
        deltaCount += 1
        if deltaCount % 20 == 1 { breadcrumb("delta #\(deltaCount) (+\(d.text.utf8.count) bytes)") }
        if let i = messages.firstIndex(where: { $0.id == d.id }) {
            // A late delta after the final message (or after the turn
            // ended) is ignored.
            guard messages[i].isStreaming else { return }
            pendingDeltas[d.id, default: ""] += d.text
            scheduleDeltaFlush()
        } else {
            // Live text waits while an older stretch is on screen.
            guard !viewingPast else { return }
            // The first words show up at once; the rest is batched.
            var m = ChatMessage(seq: 0, id: d.id, role: .assistant, kind: .text, text: d.text, channel: .app,
                                ts: Date().epochMillis)
            m.isStreaming = true
            messages.append(m)
            sortMessages()
        }
    }

    private func scheduleDeltaFlush() {
        guard !deltaFlushScheduled else { return }
        deltaFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            self?.flushDeltas()
        }
    }

    func flushDeltas() {
        deltaFlushScheduled = false
        guard !pendingDeltas.isEmpty else { return }
        for (id, text) in pendingDeltas {
            if let i = messages.firstIndex(where: { $0.id == id }), messages[i].isStreaming { messages[i].text += text }
        }
        pendingDeltas.removeAll()
    }

    func upsert(_ incoming: ChatMessage) {
        breadcrumb("message \(incoming.role.rawValue) \(incoming.text.utf8.count) bytes (\(messages.count) msgs)")
        // The final text supersedes anything still buffered for it.
        pendingDeltas[incoming.id] = nil
        var m = incoming
        m.isStreaming = false
        m.delivery = .sent
        if let i = messages.firstIndex(where: { $0.id == m.id }) {
            messages[i] = m
        } else if m.role == .user, let i = echoIndex(for: m) {
            messages[i] = m
        } else {
            messages.append(m)
        }
        sortMessages()
    }

    /// Finds the optimistic echo a broadcast user message corresponds to.
    private func echoIndex(for m: ChatMessage) -> Int? {
        if let cid = m.clientMsgId,
           let i = messages.firstIndex(where: { $0.seq == 0 && $0.clientMsgId == cid }) {
            return i
        }
        // Host didn't echo clientMsgId: match the oldest unacked app echo with
        // the same text.
        guard m.channel == .app || m.channel == .unknown else { return nil }
        return messages.firstIndex(where: { $0.seq == 0 && $0.delivery == .sending && $0.role == .user && $0.text == m.text })
    }

    /// Server messages in seq order; local ones (seq 0: echoes, failed or
    /// queued sends, in-flight streams) slotted in by timestamp, so an unsent
    /// message doesn't stay pinned below newer replies.
    private func sortMessages() {
        let indexed = messages.enumerated()
        let real = indexed.filter { $0.element.seq > 0 }
            .sorted { ($0.element.seq, $0.offset) < ($1.element.seq, $1.offset) }.map(\.element)
        let local = indexed.filter { $0.element.seq == 0 }
            .sorted { ($0.element.ts, $0.offset) < ($1.element.ts, $1.offset) }.map(\.element)
        guard !local.isEmpty else { messages = real; return }
        var out: [ChatMessage] = []
        out.reserveCapacity(messages.count)
        var li = 0
        for m in real {
            while li < local.count && local[li].ts < m.ts { out.append(local[li]); li += 1 }
            out.append(m)
        }
        out.append(contentsOf: local[li...])
        messages = out
    }

    func upsert(task t: AllyTask) {
        if let i = tasks.firstIndex(where: { $0.id == t.id }) { tasks[i] = t } else { tasks.append(t) }
        sortTasks()
    }

    private func sortTasks() {
        tasks.sort { ($0.isActive ? 1 : 0, $0.updatedAt) > ($1.isActive ? 1 : 0, $1.updatedAt) }
    }

    func upsert(approval a: Approval) {
        if let i = approvals.firstIndex(where: { $0.id == a.id }) { approvals[i] = a } else { approvals.append(a) }
        sortApprovals()
    }

    private func sortApprovals() {
        approvals.sort { ($0.isPending ? 1 : 0, $0.createdAt) > ($1.isPending ? 1 : 0, $1.createdAt) }
    }

    func upsert(question q: Question) {
        if let i = questions.firstIndex(where: { $0.id == q.id }) { questions[i] = q } else { questions.append(q) }
        questions.sort { $0.createdAt > $1.createdAt }
    }

    func upsert(watch w: Watch) {
        if let i = watches.firstIndex(where: { $0.id == w.id }) { watches[i] = w } else { watches.append(w) }
    }

    func upsert(artifact a: Artifact) {
        if let i = artifacts.firstIndex(where: { $0.id == a.id }) { artifacts[i] = a } else { artifacts.append(a) }
    }

    // MARK: derived

    public var pendingApprovals: [Approval] { approvals.filter(\.isPending) }
    public var pendingQuestions: [Question] { questions.filter(\.isPending) }
    public func question(id: String) -> Question? { questions.first { $0.id == id } }

    /// What the owner hasn't seen: replies, notices and cards newer than `seq`
    /// (their own messages don't count).
    public nonisolated static func unreadCount(_ messages: [ChatMessage], after seq: Int64) -> Int {
        messages.reduce(0) { $0 + ($1.seq > seq && $1.role != .user ? 1 : 0) }
    }

    public func unreadCount(after seq: Int64) -> Int { Self.unreadCount(messages, after: seq) }

    public func approval(id: String) -> Approval? { approvals.first { $0.id == id } }
    public func task(id: String) -> AllyTask? { tasks.first { $0.id == id } }
    public func artifact(id: String) -> Artifact? { artifacts.first { $0.id == id } }

    public var pinnedArtifacts: [Artifact] {
        artifacts.filter(\.pinned).sorted { $0.updatedAt > $1.updatedAt }
    }

    public var recentArtifacts: [Artifact] {
        artifacts.filter { !$0.pinned }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Pending approvals with no chat message to anchor them inline.
    public var unanchoredPendingApprovals: [Approval] {
        let anchored = Set(messages.compactMap(\.approvalId))
        return pendingApprovals.filter { !anchored.contains($0.id) }
    }

    public var isBusy: Bool { awaitingReply || (status?.busy ?? false) || messages.contains(where: \.isStreaming) }

    // MARK: chat

    /// Sends a chat message with an optimistic local echo.
    /// An image picked in the composer, already downsized (see ImagePrep).
    public struct OutgoingImage: Sendable {
        public var data: Data
        public var mediaType: String
        public init(data: Data, mediaType: String) { self.data = data; self.mediaType = mediaType }
    }

    /// Any other file picked in the composer; uploaded in chunks.
    public struct OutgoingFile: Sendable {
        public var data: Data
        public var mediaType: String
        public var name: String
        public init(data: Data, mediaType: String, name: String) { self.data = data; self.mediaType = mediaType; self.name = name }
    }

    // MARK: 「试试」 suggestions

    /// Unused suggestions from the host (chips above the composer; the full
    /// list can also back a 「它能做什么」 page).
    public private(set) var suggestions: [Suggestion] = []
    /// clientMsgId → the suggestion that message came from.
    private var suggestionForMessage: [String: String] = [:]

    public func loadSuggestions() async {
        if let r: SuggestionsResult = try? await rpc.call(RPCMethod.suggestionsList, params: EmptyParams()) {
            suggestions = r.suggestions
        }
    }

    /// Sends the suggestion's full request as the owner's message.
    public func use(_ s: Suggestion) {
        suggestions.removeAll { $0.id == s.id }
        send(s.prompt, suggestionId: s.id)
    }

    /// Settings → 立即更新 (or just look, with `check`): the host updates itself
    /// to the newest release once nothing is in flight.
    public func updateHost(check: Bool) async throws -> HostUpdateResult {
        try await rpc.call(RPCMethod.hostUpdate, params: HostUpdateParams(check: check), as: HostUpdateResult.self)
    }

    /// Never show this one again.
    public func dismiss(_ s: Suggestion) {
        suggestions.removeAll { $0.id == s.id }
        Task { _ = try? await rpc.call(RPCMethod.suggestionsDismiss, params: SuggestionIDParams(id: s.id), as: OKResult.self) }
    }

    /// What the composer is replying to (set by 「回复」 / 「引用回复」 / 「聊聊」);
    /// sent with the next message, then cleared.
    public var replyDraft: ReplyTo?

    /// Starts a reply to (part of) a message: the composer shows the quote.
    public func quote(_ message: ChatMessage, excerpt: String? = nil) {
        let text = (excerpt ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        replyDraft = ReplyTo(messageId: message.id, excerpt: text)
    }

    public func send(_ rawText: String, images picked: [OutgoingImage] = [], files pickedFiles: [OutgoingFile] = [], suggestionId: String? = nil) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !picked.isEmpty || !pickedFiles.isEmpty else { return }
        // Sending always happens at the live end of the conversation.
        if viewingPast { Task { await self.returnToLatest() } }
        let cid = UUID().uuidString.lowercased()
        var echo = ChatMessage(seq: 0, id: "local-\(cid)", role: .user, kind: .text, text: text, channel: .app,
                               ts: Date().epochMillis, clientMsgId: cid)
        // A 「试试」 chip starts fresh; anything typed goes with the open quote.
        if suggestionId == nil, let reply = replyDraft {
            echo.replyTo = reply
            replyDraft = nil
        }
        if let suggestionId { suggestionForMessage[cid] = suggestionId }
        if !picked.isEmpty || !pickedFiles.isEmpty {
            // Shown right away from local bytes; uploaded on delivery (an image
            // per call, files in chunks).
            let imgs = picked.enumerated().map { i, img in
                let id = "\(Self.localImagePrefix)\(cid)-\(i)"
                images[id] = img.data
                return Attachment(id: id, mediaType: img.mediaType)
            }
            let docs = pickedFiles.enumerated().map { i, f in
                let id = "\(Self.localFilePrefix)\(cid)-\(i)"
                localFiles[id] = f.data
                return Attachment(id: id, kind: "file", mediaType: f.mediaType, name: f.name, size: Int64(f.data.count))
            }
            echo.attachments = imgs + docs
        }
        echo.delivery = .sending
        messages.append(echo)
        sortMessages()
        awaitingReply = true
        Task { await self.deliver(clientMsgId: cid, text: text) }
    }

    /// Re-sends a failed or queued echo (same clientMsgId: the host de-dupes).
    public func retry(_ message: ChatMessage) {
        guard message.delivery == .failed || message.delivery == .queued, let cid = message.clientMsgId,
              let i = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[i].delivery = .sending
        awaitingReply = true
        Task { await self.deliver(clientMsgId: cid, text: message.text) }
    }

    private func deliver(clientMsgId cid: String, text: String) async {
        do {
            let ids = try await uploadImages(clientMsgId: cid)
            let replyTo = messages.first(where: { $0.clientMsgId == cid && $0.seq == 0 })?.replyTo
            let r: ChatSendResult = try await rpc.call(RPCMethod.chatSend,
                                                       params: ChatSendParams(text: text, clientMsgId: cid, attachments: ids,
                                                                              suggestionId: suggestionForMessage[cid], replyTo: replyTo))
            suggestionForMessage[cid] = nil
            guard let i = messages.firstIndex(where: { $0.clientMsgId == cid && $0.seq == 0 }) else { return }
            if !r.id.isEmpty, let dup = messages.firstIndex(where: { $0.id == r.id }), dup != i {
                // The broadcast already landed under the server id.
                messages.remove(at: i)
                return
            }
            if !r.id.isEmpty { messages[i].id = r.id }
            messages[i].seq = r.seq
            messages[i].delivery = .sent
            sortMessages()
            if r.seq == lastSeq + 1 { lastSeq = r.seq } else if r.seq > lastSeq + 1 { requestResync() }
        } catch {
            // Offline / dropped / no answer: keep it queued and resend after
            // the next reconnect. Anything else the user retries by hand.
            let offline = [RPCError.notConnected, .disconnected, .timeout].contains(error as? RPCError)
            if let i = messages.firstIndex(where: { $0.clientMsgId == cid && $0.seq == 0 }) {
                messages[i].delivery = offline ? .queued : .failed
            }
            awaitingReply = false
            // A drop still within its grace period isn't an error yet: the
            // message just waits for the reconnect, which resends it.
            if !(offline && !connectionTrouble) { lastError = Friendly.message(error) }
        }
    }

    static let localImagePrefix = "local-img-"
    static let localFilePrefix = "local-file-"
    /// Bytes of files picked here, until (and after) they're uploaded.
    private var localFiles: [String: Data] = [:]

    /// Image bytes by attachment id: sent from this device, or fetched on demand.
    public private(set) var images: [String: Data] = [:]
    private var imageLoads: Set<String> = []

    /// Uploads the echo's not-yet-uploaded images, one per call, swapping in
    /// the host's ids. Returns all ids (nil when there are none). A retry
    /// resumes where it stopped.
    private func uploadImages(clientMsgId cid: String) async throws -> [String]? {
        guard let i = messages.firstIndex(where: { $0.clientMsgId == cid && $0.seq == 0 }),
              let atts = messages[i].attachments, !atts.isEmpty else { return nil }
        var done: [Attachment] = []
        for a in atts {
            let up: Attachment
            if a.id.hasPrefix(Self.localImagePrefix) {
                guard let data = images[a.id] else { continue }
                up = try await rpc.call(RPCMethod.mediaUpload,
                                        params: MediaUploadParams(mediaType: a.mediaType, data: data.base64EncodedString()))
                images[up.id] = data
            } else if a.id.hasPrefix(Self.localFilePrefix) {
                guard let data = localFiles[a.id] else { continue }
                up = try await uploadFile(data, name: a.name ?? "file", mediaType: a.mediaType)
                localFiles[up.id] = data
            } else {
                done.append(a)
                continue
            }
            done.append(up)
            if let j = messages.firstIndex(where: { $0.clientMsgId == cid && $0.seq == 0 }) {
                messages[j].attachments = done + atts.dropFirst(done.count)
            }
        }
        return done.map(\.id)
    }

    private func uploadFile(_ data: Data, name: String, mediaType: String) async throws -> Attachment {
        let chunk = Int(ArtifactChunk.maxChunk)
        var uploadId: String?
        var offset = 0
        repeat {
            let end = min(offset + chunk, data.count)
            let done = end >= data.count
            let r: MediaUploadChunkResult = try await rpc.call(
                RPCMethod.mediaUploadChunk,
                params: MediaUploadChunkParams(uploadId: uploadId, name: name, mediaType: mediaType, offset: Int64(offset),
                                               data: data.subdata(in: offset..<end).base64EncodedString(), done: done),
                timeout: 60)
            if done {
                guard let a = r.attachment else { throw RPCError.badResponse }
                return a
            }
            uploadId = r.uploadId
            offset = end
        } while true
    }

    /// A file sent in the conversation: local bytes if it was picked here, else from the host.
    public func fileData(_ id: String) async throws -> Data {
        if let d = localFiles[id] { return d }
        return try await readMedia(id: id)
    }

    /// A file the assistant sent (media.read, chunked like artifacts).
    public func readMedia(id: String, maxBytes: Int64 = 100 * 1024 * 1024) async throws -> Data {
        var out = Data()
        var offset: Int64 = 0
        while true {
            let chunk: ArtifactChunk = try await rpc.call(
                RPCMethod.mediaRead, params: MediaReadParams(id: id, offset: offset, length: ArtifactChunk.maxChunk), timeout: 60)
            out.append(chunk.data)
            offset += Int64(chunk.data.count)
            if chunk.eof || chunk.data.isEmpty || (chunk.size > 0 && offset >= chunk.size) || offset >= maxBytes { break }
        }
        return out
    }

    /// The picture of an image artifact, for its card in the conversation.
    public func loadArtifactImage(_ id: String) async {
        let key = "artifact:\(id)"
        guard images[key] == nil, !imageLoads.contains(key) else { return }
        imageLoads.insert(key)
        defer { imageLoads.remove(key) }
        if let r = try? await readArtifact(id: id) { images[key] = r.data }
    }

    /// Fetches an attachment's bytes if they aren't here yet (history, other devices).
    public func loadImage(_ id: String) async {
        guard images[id] == nil, !imageLoads.contains(id), !id.hasPrefix(Self.localImagePrefix) else { return }
        imageLoads.insert(id)
        defer { imageLoads.remove(id) }
        if let r: MediaData = try? await rpc.call(RPCMethod.mediaGet, params: MediaGetParams(id: id)),
           let data = Data(base64Encoded: r.data) {
            images[id] = data
        }
    }

    /// Resends everything queued while offline, oldest first.
    private func resendQueued() {
        let queued = messages.filter { $0.seq == 0 && $0.delivery == .queued && $0.clientMsgId != nil }
        for m in queued { retry(m) }
    }

    /// Loads an older page of history (scroll-to-top).
    public func loadOlder(limit: Int = 50) async {
        guard !isLoadingOlder, let first = messages.first(where: { $0.seq > 0 }) else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let r: MessagesResult = try await rpc.call(RPCMethod.chatHistory,
                                                       params: ChatHistoryParams(beforeSeq: first.seq, limit: limit))
            for m in r.messages where !messages.contains(where: { $0.id == m.id }) {
                messages.append(m)
            }
            sortMessages()
            hasOlderMessages = r.messages.count >= limit && (r.messages.map(\.seq).min() ?? 1) > 1
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: search (成果)

    /// Conversation hits for `query`, newest first.
    public func searchConversation(_ query: String, limit: Int = 50) async throws -> [ChatSearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let r: ChatSearchResult = try await rpc.call(RPCMethod.chatSearch, params: ChatSearchParams(query: q, limit: limit))
        return r.messages
    }

    /// Makes sure the message `seq` is in the list and returns its id. Close
    /// by, older pages are loaded so the list stays continuous; far back, the
    /// list switches to a window around it (`viewingPast`) until
    /// `returnToLatest()`.
    public func revealMessage(seq: Int64, maxGap: Int64 = 1000) async -> String? {
        if let m = messages.first(where: { $0.seq == seq }) { return m.id }
        let earliest = messages.first(where: { $0.seq > 0 })?.seq
        if let earliest, earliest > seq, earliest - seq <= maxGap {
            while hasOlderMessages, !(messages.contains { $0.seq == seq }) {
                let before = messages.first(where: { $0.seq > 0 })?.seq
                await loadOlder(limit: 200)
                if messages.first(where: { $0.seq > 0 })?.seq == before { break } // nothing more came
            }
            if let m = messages.first(where: { $0.seq == seq }) { return m.id }
        }
        do {
            let r: MessagesResult = try await rpc.call(RPCMethod.chatAround, params: ChatAroundParams(seq: seq))
            guard !r.messages.isEmpty else { return nil }
            let local = messages.filter { $0.seq == 0 }
            messages = r.messages + local
            sortMessages()
            viewingPast = (r.messages.map(\.seq).max() ?? 0) < lastSeq
            hasOlderMessages = (r.messages.map(\.seq).min() ?? 1) > 1
            return messages.first(where: { $0.seq == seq })?.id
        } catch {
            lastError = Friendly.message(error)
            return nil
        }
    }

    /// Back from an older stretch to the live end of the conversation.
    public func returnToLatest(limit: Int = 100) async {
        guard viewingPast else { return }
        do {
            let r: MessagesResult = try await rpc.call(RPCMethod.chatHistory,
                                                       params: ChatHistoryParams(beforeSeq: lastSeq + 1, limit: limit))
            let local = messages.filter { $0.seq == 0 }
            messages = r.messages + local
            sortMessages()
            viewingPast = false
            hasOlderMessages = (r.messages.map(\.seq).min() ?? 1) > 1
        } catch {
            lastError = Friendly.message(error)
        }
    }

    // MARK: tasks

    public func taskDetail(id: String) async throws -> TaskDetail {
        let d: TaskDetail = try await rpc.call(RPCMethod.taskGet, params: IDParams(id: id))
        if let t = d.task { upsert(task: t) }
        return d
    }

    public func stopTask(id: String) async throws {
        _ = try await rpc.call(RPCMethod.taskStop, params: IDParams(id: id), as: OKResult.self)
    }

    // MARK: approvals

    public func answer(_ approval: Approval, allow: Bool, remember: Bool = false) async throws {
        let rememberFlag: Bool? = (remember && allow && approval.canRemember) ? true : nil
        let before = approvals.first { $0.id == approval.id }
        if var a = before {
            a.status = allow ? .allowed : .denied
            a.decidedAt = Date().epochMillis
            upsert(approval: a)
        }
        do {
            let r: StatusStringResult = try await rpc.call(RPCMethod.approvalAnswer,
                                                           params: ApprovalAnswerParams(id: approval.id, allow: allow, remember: rememberFlag))
            if var a = approvals.first(where: { $0.id == approval.id }),
               let s = ApprovalStatus(rawValue: r.status) {
                a.status = s
                upsert(approval: a)
            }
        } catch {
            if let before { upsert(approval: before) }
            throw error
        }
    }

    // MARK: questions

    /// Sends the owner's choices for a question card. `answers`: question
    /// text → chosen label(s) joined by ", ", or the owner's own words.
    public func answer(_ question: Question, answers: [String: String]) async throws {
        let before = questions.first { $0.id == question.id }
        if var q = before {
            q.status = .answered
            q.answers = answers
            q.answeredAt = Date().epochMillis
            upsert(question: q)
        }
        do {
            let r: QuestionResult = try await rpc.call(RPCMethod.questionAnswer,
                                                       params: QuestionAnswerParams(id: question.id, answers: answers))
            if let q = r.question { upsert(question: q) }
        } catch {
            if let before { upsert(question: before) }
            throw error
        }
    }

    // MARK: watches

    @discardableResult
    public func addWatch(_ draft: WatchDraft) async throws -> Watch? {
        let r: WatchResult = try await rpc.call(RPCMethod.watchAdd, params: draft)
        if let w = r.watch { upsert(watch: w) }
        return r.watch
    }

    @discardableResult
    public func updateWatch(id: String, patch: JSONValue) async throws -> Watch? {
        let r: WatchResult = try await rpc.call(RPCMethod.watchUpdate, params: PatchParams(id: id, patch: patch))
        if let w = r.watch { upsert(watch: w) }
        return r.watch
    }

    public func setWatch(_ watch: Watch, enabled: Bool) async throws {
        if let i = watches.firstIndex(where: { $0.id == watch.id }) { watches[i].enabled = enabled }
        do {
            try await updateWatch(id: watch.id, patch: ["enabled": .bool(enabled)])
        } catch {
            if let i = watches.firstIndex(where: { $0.id == watch.id }) { watches[i].enabled = watch.enabled }
            throw error
        }
    }

    public func removeWatch(id: String) async throws {
        _ = try await rpc.call(RPCMethod.watchRemove, params: IDParams(id: id), as: OKResult.self)
        watches.removeAll { $0.id == id }
    }

    /// Full patch for an edited watch (explicit nulls clear fields).
    public static func watchPatch(from draft: WatchDraft) -> JSONValue {
        var o: [String: JSONValue] = [
            "title": .string(draft.title),
            "kind": .string(draft.kind.rawValue),
            "instruction": .string(draft.instruction),
            "enabled": .bool(draft.enabled),
        ]
        o["intervalMinutes"] = draft.intervalMinutes.map { .number(Double($0)) } ?? .null
        o["at"] = draft.at.map { .array($0.map(JSONValue.string)) } ?? .null
        o["dayOfMonth"] = draft.dayOfMonth.map { .number(Double($0)) } ?? .null
        if let s = draft.skipIfActiveMinutes { o["skipIfActiveMinutes"] = .number(Double(s)) }
        return .object(o)
    }

    // MARK: artifacts

    public func refreshArtifacts() async throws {
        let r: ArtifactsResult = try await rpc.call(RPCMethod.artifactList, params: EmptyParams())
        artifacts = r.artifacts
    }

    public func setPinned(_ artifact: Artifact, _ pinned: Bool) async throws {
        if let i = artifacts.firstIndex(where: { $0.id == artifact.id }) { artifacts[i].pinned = pinned }
        do {
            let r: ArtifactResult = try await rpc.call(RPCMethod.artifactPin, params: ArtifactPinParams(id: artifact.id, pinned: pinned))
            if let a = r.artifact { upsert(artifact: a) }
        } catch {
            if let i = artifacts.firstIndex(where: { $0.id == artifact.id }) { artifacts[i].pinned = artifact.pinned }
            throw error
        }
    }

    /// Reads a whole artifact file, following `artifact.read` chunks.
    /// `progress(received, total)` is called after each chunk.
    public func readArtifact(id: String, path: String? = nil, maxBytes: Int64 = 64 * 1024 * 1024,
                             progress: ((Int64, Int64) -> Void)? = nil) async throws -> (data: Data, mime: String) {
        var out = Data()
        var mime = "application/octet-stream"
        var offset: Int64 = 0
        while true {
            let chunk: ArtifactChunk = try await rpc.call(
                RPCMethod.artifactRead,
                params: ArtifactReadParams(id: id, path: path, offset: offset, length: ArtifactChunk.maxChunk),
                timeout: 60)
            mime = chunk.mime
            out.append(chunk.data)
            offset += Int64(chunk.data.count)
            progress?(offset, max(chunk.size, offset))
            if chunk.eof || chunk.data.isEmpty || (chunk.size > 0 && offset >= chunk.size) || offset >= maxBytes { break }
        }
        return (out, mime)
    }

    // MARK: memory

    public func memoryFiles() async throws -> [MemoryFile] {
        let r: MemoryFilesResult = try await rpc.call(RPCMethod.memoryList, params: EmptyParams())
        return r.files
    }

    public func readMemory(path: String) async throws -> MemoryContentResult {
        try await rpc.call(RPCMethod.memoryRead, params: PathParams(path: path))
    }

    /// Writes a memory file. Pass the `updatedAt` from `readMemory` as
    /// `baseUpdatedAt`; the host refuses the write if the file changed since.
    /// Returns the new `updatedAt`: the base for the next write.
    @discardableResult
    public func writeMemory(path: String, content: String, baseUpdatedAt: Int64?) async throws -> Int64? {
        let r: MemoryWriteResult = try await rpc.call(
            RPCMethod.memoryWrite, params: MemoryWriteParams(path: path, content: content, baseUpdatedAt: baseUpdatedAt))
        return r.updatedAt
    }

    // MARK: settings / model / stop

    public func updateSettings(patch: JSONValue) async throws {
        let r: SettingsResult = try await rpc.call(RPCMethod.settingsUpdate, params: PatchParams(patch: patch))
        if let s = r.settings { settings = s }
    }

    public func loadCommands() async {
        guard commands.isEmpty else { return }
        if let r: CommandsResult = try? await rpc.call(RPCMethod.commandsList, params: EmptyParams()) { commands = r.commands }
    }

    public func loadModels() async throws {
        let info: ModelInfo = try await rpc.call(RPCMethod.modelGet, params: EmptyParams())
        modelInfo = info
    }

    /// Pass `.some(nil)` to go back to the default.
    public func setModel(_ model: String?? = .none, effort: String?? = .none) async throws {
        var params: [String: JSONValue] = [:]
        if case .some(let m) = model { params["model"] = m.map { .string($0) } ?? .null }
        if case .some(let e) = effort { params["effort"] = e.map { .string($0) } ?? .null }
        let r: StatusResult = try await rpc.call(RPCMethod.modelSet, params: JSONValue.object(params))
        if let s = r.status { status = s }
        try? await loadModels()
    }

    /// The stop button: the assistant drops whatever it is doing. Nothing
    /// stays blocked; the next message works as usual.
    public func stop() async throws {
        let r: StatusResult = try await rpc.call(RPCMethod.stop, params: EmptyParams())
        if let s = r.status { applyStatus(s) }
    }

    // MARK: unpair

    /// Best-effort goodbye before forgetting this host: drop our push token
    /// and ask the host to remove this device's pairing. Errors are ignored.
    public func unregisterDevice(pushToken: Data?) async {
        guard connection == .online else { return }
        let token = pushToken?.hexString ?? pushRegistration?.token
        if let token {
            _ = try? await rpc.call(RPCMethod.pushUnregister, params: PushUnregisterParams(token: token), as: OKResult.self,
                                    timeout: 5)
        }
        _ = try? await rpc.call(RPCMethod.deviceUnpair, params: EmptyParams(), as: OKResult.self, timeout: 5)
        pushRegistration = nil
    }

    // MARK: push

    /// Remembers the APNs token and registers it now (if online) and after
    /// every reconnect.
    public func registerPush(token: Data, environment: PushEnvironment) {
        let params = PushRegisterParams(token: token.hexString, env: environment)
        pushRegistration = params
        guard connection == .online else { return }
        let rpc = rpc
        Task { _ = try? await rpc.call(RPCMethod.pushRegister, params: params, as: OKResult.self) }
    }
}
