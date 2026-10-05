import Foundation

/// A complete in-memory host speaking design.md §5.3 over an
/// `InMemoryTransport`. Powers demo mode, SwiftUI previews, and store tests.
public actor DemoHost {
    public nonisolated let transport: InMemoryTransport

    /// Multiplier for artificial delays (0 = instant, for tests).
    public var speed: Double
    public private(set) var seq: Int64 = 0
    public private(set) var messages: [ChatMessage] = []
    public private(set) var tasks: [AllyTask] = []
    public private(set) var approvals: [Approval] = []
    public private(set) var watches: [Watch] = []
    public private(set) var artifacts: [Artifact] = []
    public private(set) var files: [String: Data] = [:] // "<artifactId>/<path>"
    public private(set) var memory: [String: (scope: MemoryScope, content: String, updatedAt: Int64)] = [:]
    public private(set) var settings = HostSettings(timezone: "Asia/Shanghai", quietHours: QuietHours(start: "23:00", end: "08:00"),
                                                    probeIntervalMinutes: 10, approvalTimeoutMinutes: 30)
    public private(set) var status = HostStatus(online: true, busy: false, model: "glm-4.6",
                                                sessionId: "demo", wechat: .connected, version: "0.1.0-demo")
    public private(set) var pushTokens: [String] = []
    public private(set) var requestLog: [String] = []
    /// Params of the most recent request per method.
    public private(set) var lastParams: [String: JSONValue] = [:]
    private var idCounter = 0

    /// The computer name the demo host reports (a second demo host shows the
    /// assistant switcher).
    public nonisolated let hostName: String

    public init(speed: Double = 1, seeded: Bool = true, autoConnect: Bool = true, hostName: String = "我的 MacBook",
                assistantName: String = "Palo", color: String = "magenta") {
        self.speed = speed
        self.hostName = hostName
        settings.assistantName = assistantName
        settings.color = color
        status.metAt = Date().epochMillis - 41 * 86_400_000
        let t = InMemoryTransport(autoConnect: autoConnect)
        self.transport = t
        if seeded {
            let s = DemoHost.seed(now: Date().epochMillis)
            self.messages = s.messages
            self.seq = s.messages.map(\.seq).max() ?? 0
            self.tasks = s.tasks
            self.approvals = s.approvals
            self.watches = s.watches
            self.artifacts = s.artifacts
            self.files = s.files
            self.memory = s.memory
        }
        // Strong on purpose: the transport keeps its host alive (demo mode and
        // tests often only hold the store/transport).
        t.onSend = { data in await self.handle(data) }
    }

    public func setSpeed(_ s: Double) { speed = s }

    // MARK: event injection (tests / demo)

    /// Appends a message with the next seq and broadcasts it.
    @discardableResult
    public func post(_ text: String, role: ChatRole = .assistant, kind: ChatKind = .text, channel: ChatChannel = .app,
                     proactive: Bool? = nil, taskId: String? = nil, approvalId: String? = nil,
                     broadcast: Bool = true) -> ChatMessage {
        seq += 1
        let m = ChatMessage(seq: seq, id: "m\(seq)", role: role, kind: kind, text: text, channel: channel,
                            ts: Date().epochMillis, proactive: proactive, taskId: taskId, approvalId: approvalId)
        messages.append(m)
        if broadcast { emit(RPCEventName.chatMessage, m) }
        return m
    }

    public func emit<T: Encodable>(_ event: String, _ data: T) {
        guard let v = try? JSONValue.from(data) else { return }
        transport.deliver(json: ["event": .string(event), "data": v])
    }

    public func upsertTask(_ t: AllyTask) {
        if let i = tasks.firstIndex(where: { $0.id == t.id }) { tasks[i] = t } else { tasks.append(t) }
        emit(RPCEventName.taskUpdated, t)
    }

    public func addArtifact(_ a: Artifact, files newFiles: [String: Data]) {
        artifacts.removeAll { $0.id == a.id }
        artifacts.append(a)
        for (path, data) in newFiles { files["\(a.id)/\(path)"] = data }
        emit(RPCEventName.artifactUpdated, a)
    }

    public func setStatus(_ s: HostStatus) {
        status = s
        emit(RPCEventName.status, s)
    }

    public func addApproval(_ a: Approval) {
        approvals.append(a)
        emit(RPCEventName.approvalUpdated, a)
    }

    /// Screenshot states for the title capsule (`-demoState idle | busy | tasks`):
    /// nothing waiting on the owner, then the main turn working, or several
    /// background tasks running.
    public func applyScenario(_ name: String) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for i in approvals.indices where approvals[i].isPending {
            approvals[i].status = .allowed
            emit(RPCEventName.approvalUpdated, approvals[i])
        }
        for t in tasks where t.isActive {
            var done = t
            done.status = .done
            upsertTask(done)
        }
        var s = status
        s.model = "claude-opus-5-5"
        s.effort = "medium"
        s.busy = false
        s.activity = nil
        switch name {
        case "busy":
            s.busy = true
            s.activity = "在看网页"
            upsertTask(AllyTask(id: "t-busy", title: "整理本周报销单", summary: "已经找到 5 张发票，正在核对金额",
                                status: .running, source: .auto, createdAt: now - 300_000, updatedAt: now - 20_000))
        case "tasks":
            upsertTask(AllyTask(id: "t-a", title: "整理本周报销单", summary: "已经找到 5 张发票，正在核对金额",
                                status: .running, source: .auto, createdAt: now - 600_000, updatedAt: now - 90_000))
            upsertTask(AllyTask(id: "t-b", title: "上海出行比价", summary: "在比较东航和春秋的退改规则",
                                status: .running, source: .auto, createdAt: now - 400_000, updatedAt: now - 5_000))
            upsertTask(AllyTask(id: "t-c", title: "汇总这周的会议纪要", summary: "",
                                status: .running, source: .auto, createdAt: now - 60_000, updatedAt: now - 50_000))
        default:
            break
        }
        setStatus(s)
    }

    // MARK: request handling

    private func nextID(_ prefix: String) -> String {
        idCounter += 1
        return "\(prefix)-\(idCounter)"
    }

    private func reply(_ id: Int, _ result: JSONValue) {
        transport.deliver(json: ["id": .number(Double(id)), "result": result])
    }

    private func replyError(_ id: Int, _ message: String) {
        transport.deliver(json: ["id": .number(Double(id)), "error": ["message": .string(message)]])
    }

    private func handle(_ data: Data) async {
        guard case .request(let id, let method, let params)? = WireMessage.parse(data) else { return }
        requestLog.append(method)
        lastParams[method] = params
        do {
            reply(id, try await dispatch(method, params))
        } catch {
            replyError(id, (error as? DemoError)?.message ?? error.localizedDescription)
        }
    }

    struct DemoError: Error { let message: String }
    private var demoModel: String?
    /// 「试试」 the demo assistant offers.
    private var demoSuggestions: [Suggestion] = [
        Suggestion(id: "sg_1", chip: "找出没在用的订阅", prompt: "帮我把信用卡账单和邮箱里的订阅都找出来，标出最近三个月没用过的", category: "省钱"),
        Suggestion(id: "sg_2", chip: "每周日给我做周报", prompt: "以后每周日晚上把我这一周做的事整理成一份周报"),
        Suggestion(id: "sg_3", chip: "盯着十一月回国机票", prompt: "帮我每天看一下十一月从旧金山回上海的机票，低于 5000 告诉我"),
        Suggestion(id: "sg_4", chip: "整理下载文件夹", prompt: "把我电脑上的下载文件夹按类型整理一下，删掉重复的安装包前先问我"),
    ]

    private func dispatch(_ method: String, _ p: JSONValue) async throws -> JSONValue {
        switch method {
        case RPCMethod.hello:
            return ["hostName": .string(hostName), "version": .string(status.version), "status": try .from(status)]
        case RPCMethod.sync:
            let since = p["sinceSeq"]?.doubleValue.map { Int64($0) }
            let msgs: [ChatMessage]
            if let since {
                msgs = Array(messages.filter { $0.seq > since }.prefix(SyncResult.pageLimit))
            } else {
                msgs = Array(messages.suffix(100))
            }
            return try .from(SyncResult(seq: seq, messages: msgs, tasks: tasks, approvals: approvals, watches: watches,
                                        artifacts: artifacts, settings: settings, status: status))
        case RPCMethod.chatSend:
            let text = p["text"]?.stringValue ?? ""
            let cid = p["clientMsgId"]?.stringValue
            seq += 1
            var m = ChatMessage(seq: seq, id: "m\(seq)", role: .user, kind: .text, text: text, channel: .app,
                                ts: Date().epochMillis, clientMsgId: cid)
            if let r = p["replyTo"], let reply = try? r.decode(ReplyTo.self) { m.replyTo = reply }
            messages.append(m)
            emit(RPCEventName.chatMessage, m)
            if let sid = p["suggestionId"]?.stringValue {
                demoSuggestions.removeAll { $0.id == sid }
                emit(RPCEventName.suggestionsUpdated, ["suggestions": demoSuggestions])
            }
            Task { await self.respond(to: text) }
            return ["id": .string(m.id), "seq": .number(Double(m.seq))]
        case RPCMethod.chatHistory:
            let before = Int64(p["beforeSeq"]?.doubleValue ?? Double(Int64.max))
            let limit = Int(p["limit"]?.doubleValue ?? 50)
            return ["messages": try .from(Array(messages.filter { $0.seq < before }.suffix(limit)))]
        case RPCMethod.chatSearch:
            let q = (p["query"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            guard !q.isEmpty else { return ["messages": .array([])] }
            let hits: [JSONValue] = messages.reversed().compactMap { m in
                let text = m.label.map { "\($0) \(m.text)" } ?? m.text
                guard let r = text.lowercased().range(of: q) else { return nil }
                let at = text.distance(from: text.startIndex, to: r.lowerBound)
                let chars = Array(text)
                let start = max(0, at - 40), end = min(chars.count, at + q.count + 40)
                let body = String(chars[start..<end]).replacingOccurrences(of: "\n", with: " ")
                let snippet = (start > 0 ? "…" : "") + body + (end < chars.count ? "…" : "")
                return .object(["seq": .number(Double(m.seq)), "id": .string(m.id), "role": .string(m.role.rawValue),
                                "ts": .number(Double(m.ts)), "channel": .string(m.channel.rawValue), "snippet": .string(snippet)])
            }
            return ["messages": .array(Array(hits.prefix(50)))]
        case RPCMethod.chatAround:
            let seq = Int64(p["seq"]?.doubleValue ?? 0)
            let before = Int(p["before"]?.doubleValue ?? 25), after = Int(p["after"]?.doubleValue ?? 25)
            let i = messages.firstIndex { $0.seq >= seq } ?? messages.count
            return ["messages": try .from(Array(messages[max(0, i - before)..<min(messages.count, i + after + 1)]))]
        case RPCMethod.taskGet:
            let tid = p["id"]?.stringValue ?? ""
            guard let t = tasks.first(where: { $0.id == tid }) else { throw DemoError(message: "没有这个任务") }
            return ["task": try .from(t), "activity": try .from(DemoHost.activity(for: t))]
        case RPCMethod.taskStop:
            let tid = p["id"]?.stringValue ?? ""
            if var t = tasks.first(where: { $0.id == tid }) {
                t.status = .stopped
                t.updatedAt = Date().epochMillis
                upsertTask(t)
            }
            return ["ok": true]
        case RPCMethod.approvalAnswer:
            let aid = p["id"]?.stringValue ?? ""
            let allow = p["allow"]?.boolValue ?? false
            guard let i = approvals.firstIndex(where: { $0.id == aid }) else { throw DemoError(message: "没有这个审批") }
            guard approvals[i].status == .pending else { return ["status": .string(approvals[i].status.rawValue)] }
            approvals[i].status = allow ? .allowed : .denied
            approvals[i].decidedAt = Date().epochMillis
            approvals[i].decidedBy = "app"
            emit(RPCEventName.approvalUpdated, approvals[i])
            return ["status": .string(approvals[i].status.rawValue)]
        case RPCMethod.watchAdd:
            let draft = try p.decode(WatchDraft.self)
            let w = Watch(id: nextID("w"), title: draft.title, kind: draft.kind, instruction: draft.instruction,
                          intervalMinutes: draft.intervalMinutes, at: draft.at, enabled: draft.enabled, createdBy: .user,
                          skipIfActiveMinutes: draft.skipIfActiveMinutes)
            watches.append(w)
            emit(RPCEventName.watchUpdated, ["watch": try JSONValue.from(w)] as JSONValue)
            return ["watch": try .from(w)]
        case RPCMethod.watchUpdate:
            let wid = p["id"]?.stringValue ?? ""
            guard let i = watches.firstIndex(where: { $0.id == wid }), case .object(let patch)? = p["patch"] else {
                throw DemoError(message: "没有这个提醒")
            }
            var obj = try JSONValue.from(watches[i])
            if case .object(var o) = obj {
                for (k, v) in patch { o[k] = v }
                // Like the host: enabled and the goal state move together.
                if case .bool(let on)? = patch["enabled"], patch["state"] == nil {
                    o["state"] = .string(on ? (watches[i].state == .waiting ? "waiting" : "tracking") : "paused")
                }
                obj = .object(o)
            }
            watches[i] = try obj.decode(Watch.self)
            emit(RPCEventName.watchUpdated, ["watch": try JSONValue.from(watches[i])] as JSONValue)
            return ["watch": try .from(watches[i])]
        case RPCMethod.watchRemove:
            let wid = p["id"]?.stringValue ?? ""
            watches.removeAll { $0.id == wid }
            emit(RPCEventName.watchUpdated, ["removed": .string(wid)] as JSONValue)
            return ["ok": true]
        case RPCMethod.artifactList:
            return ["artifacts": try .from(artifacts)]
        case RPCMethod.artifactRead:
            let aid = p["id"]?.stringValue ?? ""
            guard let a = artifacts.first(where: { $0.id == aid }) else { throw DemoError(message: "没有这个资料") }
            let path = p["path"]?.stringValue ?? a.mainFile
            let data = files["\(aid)/\(path)"] ?? Data()
            let offset = Int(p["offset"]?.doubleValue ?? 0)
            let length = min(Int(p["length"]?.doubleValue ?? Double(ArtifactChunk.maxChunk)), Int(ArtifactChunk.maxChunk))
            let start = min(offset, data.count)
            let end = min(start + length, data.count)
            let chunk = data.subdata(in: start..<end)
            return ["data": .string(chunk.base64EncodedString()), "size": .number(Double(data.count)),
                    "mime": .string(DemoHost.mime(for: path)), "eof": .bool(end >= data.count)]
        case RPCMethod.artifactPin:
            let aid = p["id"]?.stringValue ?? ""
            guard let i = artifacts.firstIndex(where: { $0.id == aid }) else { throw DemoError(message: "没有这个资料") }
            artifacts[i].pinned = p["pinned"]?.boolValue ?? false
            emit(RPCEventName.artifactUpdated, artifacts[i])
            return ["artifact": try .from(artifacts[i])]
        case RPCMethod.memoryList:
            let list = memory.map { MemoryFile(path: $0.key, scope: $0.value.scope, size: Int64($0.value.content.utf8.count),
                                               updatedAt: $0.value.updatedAt) }
                .sorted { ($0.scope == .core ? 0 : 1, $0.path) < ($1.scope == .core ? 0 : 1, $1.path) }
            return ["files": try .from(list)]
        case RPCMethod.memoryRead:
            let path = p["path"]?.stringValue ?? ""
            guard let f = memory[path] else { throw DemoError(message: "没有这个文件") }
            return ["content": .string(f.content), "updatedAt": .number(Double(f.updatedAt))]
        case RPCMethod.memoryWrite:
            let path = p["path"]?.stringValue ?? ""
            if let base = p["baseUpdatedAt"]?.doubleValue, let cur = memory[path], cur.updatedAt > Int64(base) {
                throw DemoError(message: "这个文件刚被助理改过，请重新打开再改")
            }
            let scope = memory[path]?.scope ?? .auto
            let now = max(Date().epochMillis, (memory[path]?.updatedAt ?? 0) + 1)
            memory[path] = (scope, p["content"]?.stringValue ?? "", now)
            return ["ok": true, "updatedAt": .number(Double(now))]
        case RPCMethod.settingsUpdate:
            guard case .object(let patch)? = p["patch"] else { throw DemoError(message: "bad patch") }
            var obj = try JSONValue.from(settings)
            if case .object(var o) = obj { for (k, v) in patch { o[k] = v }; obj = .object(o) }
            settings = try obj.decode(HostSettings.self)
            emit(RPCEventName.settingsUpdated, settings)
            return ["settings": try .from(settings)]
        case RPCMethod.stop:
            status.busy = false
            status.activity = nil
            for t in tasks where t.isActive {
                var s = t; s.status = .stopped; s.updatedAt = Date().epochMillis; upsertTask(s)
            }
            emit(RPCEventName.status, status)
            return ["status": try .from(status)]
        case RPCMethod.pushRegister:
            pushTokens.append(p["token"]?.stringValue ?? "")
            return ["ok": true]
        case RPCMethod.pushUnregister:
            let token = p["token"]?.stringValue ?? ""
            pushTokens.removeAll { $0 == token }
            return ["ok": true]
        case RPCMethod.deviceUnpair:
            return ["ok": true]
        case RPCMethod.auditTail:
            return ["entries": []]
        case RPCMethod.commandsList:
            let cmds: [JSONValue] = [
                ["name": "stop", "description": "停下手上的事"],
                ["name": "status", "description": "看看我在忙什么"],
                ["name": "compact", "description": "Clear conversation history but keep a summary"],
                ["name": "context", "description": "Show current context usage"],
                ["name": "cost", "description": "Show usage"],
                ["name": "model", "description": "Set the AI model"],
                ["name": "pdf", "description": "Work with PDF files", "argumentHint": "<file>"],
            ]
            return ["commands": .array(cmds)]
        case RPCMethod.modelGet:
            return [
                "model": .string(status.model.isEmpty ? "claude-opus-5-5[1m]" : status.model),
                "setting": demoModel.map { .string($0) } ?? .null,
                "effort": status.effort.map { .string($0) } ?? .null,
                "models": .array([
                    ["value": "default", "displayName": "默认（推荐）", "description": "Opus 5.5", "efforts": ["low", "medium", "high", "xhigh", "max"]],
                    ["value": "sonnet", "displayName": "Sonnet", "description": "Sonnet 5 · 日常够用", "efforts": ["low", "medium", "high", "xhigh", "max"]],
                    ["value": "haiku", "displayName": "Haiku", "description": "Haiku 4.5 · 最快", "efforts": []],
                ]),
            ]
        case RPCMethod.modelSet:
            if let m = p["model"] {
                demoModel = m.stringValue
                status.model = ["sonnet": "claude-sonnet-5", "haiku": "claude-haiku-4-5"][m.stringValue ?? ""] ?? "claude-opus-5-5[1m]"
            }
            if let e = p["effort"] { status.effort = e.stringValue }
            emit(RPCEventName.status, status)
            return ["status": try .from(status)]
        case RPCMethod.suggestionsList:
            return ["suggestions": try .from(demoSuggestions)]
        case RPCMethod.suggestionsDismiss:
            let id = p["id"]?.stringValue ?? ""
            let had = demoSuggestions.contains { $0.id == id }
            demoSuggestions.removeAll { $0.id == id }
            emit(RPCEventName.suggestionsUpdated, ["suggestions": demoSuggestions])
            return ["ok": .bool(had)]
        default:
            throw DemoError(message: "unknown method \(method)")
        }
    }

    // MARK: canned replies

    private func pause(_ seconds: Double) async {
        guard speed > 0 else { return }
        try? await Task.sleep(for: .seconds(seconds * speed))
    }

    private func respond(to text: String) async {
        status.busy = true
        emit(RPCEventName.status, status)
        await pause(0.6)

        var taskToRun: AllyTask?
        let reply: String
        if text.contains("提醒") {
            reply = "好嘞，到点我叫你 ⏰\n\n已经加进 **目标** 里了，随时可以改。"
            let w = Watch(id: nextID("w"), title: String(text.prefix(18)), kind: .schedule, instruction: text,
                          at: ["10:00"], enabled: true, createdBy: .agent)
            watches.append(w)
            emit(RPCEventName.watchUpdated, ["watch": (try? JSONValue.from(w)) ?? .null] as JSONValue)
        } else if ["帮我", "查", "整理", "比较", "找"].contains(where: text.contains) {
            let now = Date().epochMillis
            let t = AllyTask(id: nextID("t"), title: String(text.replacingOccurrences(of: "帮我", with: "").prefix(16)),
                             summary: "正在办…", status: .running, source: .report, createdAt: now, updatedAt: now)
            upsertTask(t)
            taskToRun = t
            reply = "收到，我在后台办，好了告诉你。"
        } else if text.contains("晨报") {
            reply = "今天的晨报在资料库里置顶着：\n\n- **3 件待办**，最急的是周四的会\n- 1 封邮件等你回\n- 下午有雨，记得带伞 ☔️"
        } else {
            reply = "好的，我记下了 🙂\n\n还有什么想让我做的，随时说。"
        }

        // Stream the reply in small pieces, then finalize with chat.message.
        let rid = nextID("r")
        var acc = ""
        for piece in DemoHost.chunks(reply) {
            acc += piece
            emit(RPCEventName.chatDelta, ChatDelta(id: rid, text: piece))
            await pause(0.05)
        }
        seq += 1
        let final = ChatMessage(seq: seq, id: rid, role: .assistant, kind: taskToRun == nil ? .text : .task, text: acc,
                                channel: .app, ts: Date().epochMillis, taskId: taskToRun?.id)
        messages.append(final)
        emit(RPCEventName.chatMessage, final)
        status.busy = false
        emit(RPCEventName.status, status)

        if var t = taskToRun {
            await pause(3)
            t.status = .done
            t.summary = "办好了，结果整理在资料库里。"
            t.updatedAt = Date().epochMillis
            t.activityCount = 4
            upsertTask(t)
            post("「\(t.title)」办好了 ✅ 结果整理在资料库里，有问题随时问我。", kind: .task, taskId: t.id)
        }
    }

    static func chunks(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in s {
            cur.append(ch)
            if cur.count >= 3 || "，。！？\n".contains(ch) { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func mime(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown": "text/markdown"
        case "html", "htm": "text/html"
        case "csv": "text/csv"
        case "pdf": "application/pdf"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "txt": "text/plain"
        default: "application/octet-stream"
        }
    }

    static func activity(for t: AllyTask) -> [TaskActivity] {
        let base = t.createdAt
        var out = [
            TaskActivity(ts: base + 2_000, kind: .text, text: "先看看要比较哪些选项。"),
            TaskActivity(ts: base + 9_000, kind: .toolUse, tool: "浏览网页", text: "打开 ctrip.com 搜索航班"),
            TaskActivity(ts: base + 25_000, kind: .toolResult, tool: "浏览网页", text: "找到 12 个航班，最低 ¥1,280"),
            TaskActivity(ts: base + 40_000, kind: .toolUse, tool: "写文件", text: "整理结果到资料库"),
        ]
        if t.status == .done { out.append(TaskActivity(ts: t.updatedAt, kind: .text, text: t.summary)) }
        return out
    }

    // MARK: seed data

    struct Seed {
        var messages: [ChatMessage]
        var tasks: [AllyTask]
        var approvals: [Approval]
        var watches: [Watch]
        var artifacts: [Artifact]
        var files: [String: Data]
        var memory: [String: (scope: MemoryScope, content: String, updatedAt: Int64)]
    }

    static func seed(now: Int64) -> Seed {
        let min: Int64 = 60_000
        let hour = 60 * min
        var seq: Int64 = 0
        func msg(_ role: ChatRole, _ text: String, kind: ChatKind = .text, channel: ChatChannel = .app,
                 ago: Int64, proactive: Bool? = nil, taskId: String? = nil, approvalId: String? = nil) -> ChatMessage {
            seq += 1
            return ChatMessage(seq: seq, id: "m\(seq)", role: role, kind: kind, text: text, channel: channel,
                               ts: now - ago, proactive: proactive, taskId: taskId, approvalId: approvalId)
        }
        var brief = msg(.assistant, "- 王老师的邮件等你回，问周四的会能不能参加\n- 十一月回国机票降到 ¥4,860，比昨天低 ¥320\n- 报销单找到 5 张发票，还差核对金额\n- 周五晚上的餐厅等你定几个人、什么口味\n- 本周睡眠 4/6 天做到",
                        channel: .schedule, ago: 5 * hour, proactive: true)
        brief.card = MessageCard(title: "晨报", goalId: "w1")
        var quoted = msg(.user, "帮我回王老师，说周四可以", ago: 4 * hour + 30 * min)
        quoted.replyTo = ReplyTo(messageId: brief.id, excerpt: "王老师的邮件等你回，问周四的会能不能参加")
        let messages = [
            brief,
            quoted,
            msg(.user, "帮我把下周去上海的机票和酒店比较一下", ago: 4 * hour),
            msg(.assistant, "收到，我在后台比价，好了告诉你。", kind: .task, ago: 4 * hour - min, taskId: "t1"),
            msg(.assistant, "比好了 ✈️\n\n- 最划算：周二早上 **东航 MU5100**，¥1,280\n- 酒店推荐静安的全季，两晚 ¥960\n\n详细对比放在《上海出行比价》里。",
                kind: .task, ago: 3 * hour, taskId: "t1"),
            msg(.user, "周末提醒我给妈妈打电话", channel: .wechat, ago: 2 * hour),
            msg(.assistant, "好嘞，周六上午 10 点提醒你 ☎️", channel: .wechat, ago: 2 * hour - min),
            msg(.assistant, "要给王老师回邮件确认周四的会，需要你点个头。", kind: .approval, ago: 20 * min, approvalId: "a1"),
        ]
        let tasks = [
            AllyTask(id: "t2", title: "整理本周报销单", summary: "已经找到 5 张发票，正在核对金额", status: .running,
                     source: .report, createdAt: now - hour, updatedAt: now - 10 * min, activityCount: 6),
            AllyTask(id: "t3", title: "订周五晚上的餐厅", summary: "想确认一下几个人、什么口味", status: .needsInput,
                     source: .report, createdAt: now - 90 * min, updatedAt: now - 30 * min, activityCount: 3),
            AllyTask(id: "t1", title: "上海出行比价", summary: "东航 MU5100 最划算，酒店推荐静安全季", status: .done,
                     source: .report, createdAt: now - 4 * hour, updatedAt: now - 3 * hour, activityCount: 9),
        ]
        let approvals = [
            Approval(id: "a1", tool: "send_email", title: "给王老师回邮件",
                     detail: "收件人：王老师 <wang@example.com>\n内容：王老师好，周四下午 3 点的会我可以参加，谢谢！",
                     taskId: nil, careful: true, status: .pending, createdAt: now - 20 * min),
            Approval(id: "a2", tool: "browser_navigate", title: "打开大众点评查餐厅",
                     detail: "要打开 dianping.com 搜索周五晚上可订位的餐厅", taskId: "t3", careful: false,
                     status: .pending, createdAt: now - 25 * min, suggestedScope: "domain:dianping.com"),
            Approval(id: "a0", tool: "read_file", title: "读取下载文件夹里的发票", detail: "~/Downloads/发票/*.pdf",
                     taskId: "t2", careful: false, status: .allowed, createdAt: now - hour,
                     decidedAt: now - hour + min, decidedBy: "app"),
        ]
        let watches = [
            Watch(id: "w5", title: "邮箱清零", kind: .check, instruction: "每天看收件箱，整理、起草回复，发之前给我看。",
                  intervalMinutes: 60, enabled: true, createdBy: .agent, lastCheckedAt: now - 40 * min,
                  state: .waiting, progress: "等你连上 Gmail", progressAt: now - 40 * min),
            Watch(id: "w6", title: "十一月回国机票", kind: .check, instruction: "每天比价 SFO→PVG 11 月 20 日前后的直飞，低于 ¥4,500 就告诉我。",
                  intervalMinutes: 360, enabled: true, createdBy: .agent, lastCheckedAt: now - 2 * hour,
                  state: .tracking, progress: "每天比价，现在最低 ¥4,860", progressAt: now - 2 * hour,
                  history: [GoalProgress(at: now - 50 * hour, text: "开始比价，最低 ¥5,380"),
                            GoalProgress(at: now - 26 * hour, text: "降到 ¥5,180"),
                            GoalProgress(at: now - 2 * hour, text: "每天比价，现在最低 ¥4,860")]),
            Watch(id: "w7", title: "每天 11 点前睡", kind: .schedule, instruction: "每晚 22:30 提醒我准备睡觉，第二天记一下有没有做到。",
                  at: ["22:30"], enabled: true, createdBy: .user, lastTriggeredAt: now - 12 * hour,
                  state: .tracking, progress: "本周 4/6 天做到", progressAt: now - 12 * hour, ratio: 4.0 / 6.0),
            Watch(id: "w1", title: "晨报", kind: .schedule, instruction: "给主人写今天的晨报：需要主人处理的、目标进展、值得一提的变化。",
                  at: ["07:30"], enabled: true, createdBy: .agent, lastTriggeredAt: now - 5 * hour,
                  progress: "今天 3 件事、2 封要回的邮件", progressAt: now - 5 * hour),
            Watch(id: "w2", title: "盯着王老师的邮件", kind: .check, instruction: "看看有没有王老师的新邮件，有就告诉我。",
                  intervalMinutes: 30, enabled: true, createdBy: .agent, lastCheckedAt: now - 12 * min,
                  progress: "王老师确认了周四的会", progressAt: now - 3 * hour),
            Watch(id: "w3", title: "周六提醒给妈妈打电话", kind: .schedule, instruction: "提醒我给妈妈打电话。",
                  at: ["10:00"], enabled: true, createdBy: .user),
            Watch(id: "w8", title: "退掉没在用的订阅", kind: .check, instruction: "从账单邮件里找订阅，列给我确认后逐个退订。",
                  intervalMinutes: 1440, enabled: false, createdBy: .agent, lastCheckedAt: now - 30 * hour,
                  state: .done, progress: "退了 3 个", progressAt: now - 30 * hour, outcome: "退掉 3 个订阅，每月省 ¥96"),
            Watch(id: "w4", title: "每周财务快照", kind: .schedule, instruction: "更新本周开销表。",
                  at: ["21:00"], enabled: false, createdBy: .user),
        ]
        let briefing = """
        # 今日晨报 · 10 月 4 日

        ## 待办
        1. **周四 15:00** 和王老师开会（邮件待确认）
        2. 提交本周报销单
        3. 订周五晚上的餐厅

        ## 邮件
        - 王老师：周四的会能来吗？
        - 银行：九月账单已出

        ## 天气
        下午有雨，*记得带伞*。

        > 今天也辛苦啦。
        """
        let compare = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <style>body{font-family:-apple-system;padding:16px;line-height:1.5}table{border-collapse:collapse;width:100%}
        td,th{border-bottom:1px solid #ddd;padding:8px;text-align:left}@media(prefers-color-scheme:dark){body{background:#000;color:#eee}}</style>
        </head><body><h2>上海出行比价</h2><table><tr><th>航班</th><th>时间</th><th>价格</th></tr>
        <tr><td>东航 MU5100</td><td>周二 07:30</td><td>¥1,280</td></tr><tr><td>国航 CA1501</td><td>周二 09:00</td><td>¥1,460</td></tr>
        <tr><td>春秋 9C8888</td><td>周二 13:10</td><td>¥980（不含行李）</td></tr></table>
        <h3>酒店</h3><p>静安全季酒店，两晚 ¥960，离会场步行 8 分钟。</p></body></html>
        """
        let csv = "日期,类别,金额\n09-01,餐饮,86\n09-03,交通,32\n09-08,购物,459\n09-15,餐饮,128\n09-22,房租,4500\n"
        let artifacts = [
            Artifact(id: "ar1", title: "每日晨报", type: "markdown", mainFile: "briefing.md", pinned: true,
                     updatedAt: now - 5 * hour, files: [ArtifactFile(path: "briefing.md", size: Int64(briefing.utf8.count))]),
            Artifact(id: "ar2", title: "上海出行比价", type: "html", mainFile: "index.html", pinned: false,
                     updatedAt: now - 3 * hour, files: [ArtifactFile(path: "index.html", size: Int64(compare.utf8.count))]),
            Artifact(id: "ar3", title: "九月开销", type: "table", mainFile: "spending.csv", pinned: false,
                     updatedAt: now - 26 * hour, files: [ArtifactFile(path: "spending.csv", size: Int64(csv.utf8.count))]),
        ]
        let files: [String: Data] = [
            "ar1/briefing.md": Data(briefing.utf8),
            "ar2/index.html": Data(compare.utf8),
            "ar3/spending.csv": Data(csv.utf8),
        ]
        let memory: [String: (scope: MemoryScope, content: String, updatedAt: Int64)] = [
            "user.md": (.core, "# 关于我\n\n- 住在杭州，常去上海出差\n- 喜欢靠窗座位\n- 不吃香菜\n", now - 48 * hour),
            "soul.md": (.core, "# 说话方式\n\n简短、温暖，不啰嗦。重要的事情先说结论。\n", now - 72 * hour),
            "MEMORY.md": (.auto, "- [出行偏好](travel.md)\n- [家人](family.md)\n", now - 3 * hour),
            "travel.md": (.auto, "# 出行偏好\n\n- 航班优先早班\n- 酒店预算一晚 500 以内\n", now - 3 * hour),
            "family.md": (.auto, "# 家人\n\n- 妈妈：每周六上午通电话\n", now - 2 * hour),
        ]
        return Seed(messages: messages, tasks: tasks, approvals: approvals, watches: watches, artifacts: artifacts,
                    files: files, memory: memory)
    }
}
