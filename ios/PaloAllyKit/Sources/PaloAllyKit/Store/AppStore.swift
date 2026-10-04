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
    }

    // MARK: observable state

    public private(set) var connection: Connection = .idle
    public private(set) var hostName: String = ""
    public private(set) var hostVersion: String = ""
    public private(set) var messages: [ChatMessage] = []
    public private(set) var tasks: [AllyTask] = []
    public private(set) var approvals: [Approval] = []
    public private(set) var watches: [Watch] = []
    public private(set) var artifacts: [Artifact] = []
    public private(set) var settings: HostSettings?
    public private(set) var status: HostStatus?
    /// Highest contiguous chat seq we hold — the `sync{sinceSeq}` cursor.
    public private(set) var lastSeq: Int64 = 0
    /// True between a send and the first sign of a reply (drives the
    /// "收到了" feedback indicator).
    public private(set) var awaitingReply = false
    public private(set) var hasOlderMessages = false
    public private(set) var isLoadingOlder = false
    /// Number of completed sync rounds (each page counts). Mostly for tests.
    public private(set) var syncRounds = 0
    public private(set) var hasSynced = false
    public var lastError: String?

    // MARK: config

    public let rpc: RPCClient
    public let clientKind: String
    public let clientVersion: String
    public var initialHistoryLimit = 100

    private var started = false
    private var syncing = false
    private var resyncRequested = false
    private var pushRegistration: PushRegisterParams?
    private var inboundTask: Task<Void, Never>?

    public init(transport: any HostTransport, clientKind: String = "ios", clientVersion: String = "1.0") {
        self.rpc = RPCClient(transport: transport)
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

    public func stop() {
        inboundTask?.cancel()
        let rpc = rpc
        Task { await rpc.stop() }
        started = false
        connection = .idle
    }

    /// Call when the app returns to the foreground.
    public func reconnectNow() {
        let transport = rpc.transport
        Task { await transport.reconnectNow() }
    }

    private func handle(_ item: RPCInbound) {
        switch item {
        case .connected:
            connection = .syncing
            Task { await self.onConnected() }
        case .disconnected(let reason):
            switch reason {
            case .closed: connection = .offline(nil)
            case .network(let m): connection = .offline(m)
            case .rejected(let m): connection = .rejected(m)
            }
        case .event(let name, let data):
            apply(event: name, data: data)
        }
    }

    private func onConnected() async {
        do {
            let hello: HelloResult = try await rpc.call(RPCMethod.hello,
                                                        params: HelloParams(client: clientKind, version: clientVersion))
            hostName = hello.hostName
            hostVersion = hello.version
            if let s = hello.status { status = s }
            try await performSync()
            connection = .online
            if let push = pushRegistration {
                _ = try? await rpc.call(RPCMethod.pushRegister, params: push, as: OKResult.self)
            }
        } catch {
            // The transport will emit .disconnected if the link died; if it
            // was just a slow host, try again shortly.
            lastError = error.localizedDescription
            if case .syncing = connection { connection = .offline(error.localizedDescription) }
        }
    }

    // MARK: sync

    /// Catches up via `sync{sinceSeq}`, paging until we hold everything.
    /// Concurrent requests coalesce into one extra round.
    public func performSync() async throws {
        if syncing { resyncRequested = true; return }
        syncing = true
        defer { syncing = false }
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
        if let w = r.watches { watches = w }
        if let a = r.artifacts { artifacts = a }
        if let s = r.settings { settings = s }
        if let s = r.status { status = s }

        let maxSeq = r.messages.map(\.seq).max() ?? 0
        if since == nil {
            // Fresh snapshot: server messages replace ours; keep unsent echoes.
            let local = messages.filter { $0.seq == 0 && $0.delivery != .sent }
            let streaming = messages.filter { $0.isStreaming && !r.messages.map(\.id).contains($0.id) }
            messages = r.messages
            for m in streaming + local { messages.append(m) }
            sortMessages()
            lastSeq = max(r.seq, maxSeq)
            hasOlderMessages = (r.messages.map(\.seq).min() ?? 1) > 1
            hasSynced = true
            return false
        }
        for m in r.messages { upsert(m) }
        hasSynced = true
        if r.messages.count >= SyncResult.pageLimit && maxSeq > lastSeq {
            lastSeq = maxSeq
            return maxSeq < r.seq
        }
        lastSeq = max(lastSeq, r.seq, maxSeq)
        return false
    }

    private func requestResync() {
        guard hasSynced, connection == .online || connection == .syncing else { return }
        Task { try? await self.performSync() }
    }

    // MARK: events

    public func apply(event name: String, data: JSONValue) {
        switch name {
        case RPCEventName.chatMessage:
            if let m = try? data.decode(ChatMessage.self) { receive(m) }
        case RPCEventName.chatDelta:
            if let d = try? data.decode(ChatDelta.self), !d.id.isEmpty { applyDelta(d) }
        case RPCEventName.taskUpdated:
            if let t = try? data.decode(AllyTask.self) { upsert(task: t) }
        case RPCEventName.approvalUpdated:
            if let a = try? data.decode(Approval.self) { upsert(approval: a) }
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
        case RPCEventName.status:
            if let s = try? (data["status"] ?? data).decode(HostStatus.self) {
                status = s
                if s.busy == false, !messages.contains(where: \.isStreaming) { awaitingReply = false }
            }
        default:
            break // unknown events are ignored
        }
    }

    /// A finished `chat.message`.
    func receive(_ m: ChatMessage) {
        if m.role != .user { awaitingReply = false }
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
        if let i = messages.firstIndex(where: { $0.id == d.id }) {
            // A late delta after the final message is ignored.
            guard messages[i].isStreaming || messages[i].seq == 0 else { return }
            messages[i].text += d.text
            messages[i].isStreaming = true
        } else {
            var m = ChatMessage(seq: 0, id: d.id, role: .assistant, kind: .text, text: d.text, channel: .app,
                                ts: Date().epochMillis)
            m.isStreaming = true
            messages.append(m)
            sortMessages()
        }
    }

    func upsert(_ incoming: ChatMessage) {
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

    private func sortMessages() {
        let indexed = messages.enumerated().map { ($0.offset, $0.element) }
        messages = indexed.sorted { a, b in
            let ka = a.1.seq == 0 ? Int64.max : a.1.seq
            let kb = b.1.seq == 0 ? Int64.max : b.1.seq
            return ka != kb ? ka < kb : a.0 < b.0
        }.map(\.1)
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

    func upsert(watch w: Watch) {
        if let i = watches.firstIndex(where: { $0.id == w.id }) { watches[i] = w } else { watches.append(w) }
    }

    func upsert(artifact a: Artifact) {
        if let i = artifacts.firstIndex(where: { $0.id == a.id }) { artifacts[i] = a } else { artifacts.append(a) }
    }

    // MARK: derived

    public var pendingApprovals: [Approval] { approvals.filter(\.isPending) }

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

    public var isKilled: Bool { status?.killed ?? false }
    public var isBusy: Bool { awaitingReply || (status?.busy ?? false) || messages.contains(where: \.isStreaming) }

    // MARK: chat

    /// Sends a chat message with an optimistic local echo.
    public func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let cid = UUID().uuidString.lowercased()
        var echo = ChatMessage(seq: 0, id: "local-\(cid)", role: .user, kind: .text, text: text, channel: .app,
                               ts: Date().epochMillis, clientMsgId: cid)
        echo.delivery = .sending
        messages.append(echo)
        sortMessages()
        awaitingReply = true
        Task { await self.deliver(clientMsgId: cid, text: text) }
    }

    /// Re-sends a failed echo.
    public func retry(_ message: ChatMessage) {
        guard message.delivery == .failed, let cid = message.clientMsgId,
              let i = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[i].delivery = .sending
        awaitingReply = true
        Task { await self.deliver(clientMsgId: cid, text: message.text) }
    }

    private func deliver(clientMsgId cid: String, text: String) async {
        do {
            let r: ChatSendResult = try await rpc.call(RPCMethod.chatSend, params: ChatSendParams(text: text, clientMsgId: cid))
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
            if let i = messages.firstIndex(where: { $0.clientMsgId == cid && $0.seq == 0 }) {
                messages[i].delivery = .failed
            }
            awaitingReply = false
            lastError = error.localizedDescription
        }
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
    public func readArtifact(id: String, path: String? = nil, maxBytes: Int64 = 64 * 1024 * 1024) async throws -> (data: Data, mime: String) {
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
            if chunk.eof || chunk.data.isEmpty || (chunk.size > 0 && offset >= chunk.size) || offset >= maxBytes { break }
        }
        return (out, mime)
    }

    // MARK: memory

    public func memoryFiles() async throws -> [MemoryFile] {
        let r: MemoryFilesResult = try await rpc.call(RPCMethod.memoryList, params: EmptyParams())
        return r.files
    }

    public func readMemory(path: String) async throws -> String {
        let r: MemoryContentResult = try await rpc.call(RPCMethod.memoryRead, params: PathParams(path: path))
        return r.content
    }

    public func writeMemory(path: String, content: String) async throws {
        _ = try await rpc.call(RPCMethod.memoryWrite, params: MemoryWriteParams(path: path, content: content), as: OKResult.self)
    }

    // MARK: settings / safety

    public func updateSettings(patch: JSONValue) async throws {
        let r: SettingsResult = try await rpc.call(RPCMethod.settingsUpdate, params: PatchParams(patch: patch))
        if let s = r.settings { settings = s }
    }

    public func kill() async throws {
        let r: KillResult = try await rpc.call(RPCMethod.kill, params: EmptyParams())
        if let s = r.status { status = s } else { status?.killed = true }
    }

    public func resume() async throws {
        let r: KillResult = try await rpc.call(RPCMethod.resume, params: EmptyParams())
        if let s = r.status { status = s } else { status?.killed = false }
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
