import Foundation

/// A complete in-memory host speaking design.md §5.3 over an
/// `InMemoryTransport`. Powers demo mode, SwiftUI previews, and store tests.
public actor DemoHost {
    public nonisolated let transport: InMemoryTransport

    /// Multiplier for artificial delays (0 = instant, for tests).
    public var speed: Double
    public internal(set) var seq: Int64 = 0
    public internal(set) var messages: [ChatMessage] = []
    public private(set) var tasks: [AllyTask] = []
    public internal(set) var approvals: [Approval] = []
    public internal(set) var questions: [Question] = []
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
    /// The reply being streamed right now (sync's `streaming`).
    private var writing: SyncResult.Streaming?
    /// Allies (allies-prd §7.5): two made-up people with a few exchanges each.
    public private(set) var allies: [AllyInfo] = []
    public private(set) var allyLogs: [String: [AllyEntry]] = [:]
    /// Sessions (sessions-prd §7): the computer's Claude Code sessions and
    /// their conversations (with `sessions: true`; otherwise none).
    public private(set) var sessions: [CCSession] = []
    public private(set) var sessionLogs: [String: [CCMessage]] = [:]
    public private(set) var hooksEnabled = true
    /// Pals (pals-prd §8): the Claude Code sessions it hosts, each one's
    /// conversation, and the computer's other live sessions to adopt (with
    /// `pals: true`; otherwise none).
    public internal(set) var pals: [Pal] = []
    public internal(set) var palLogs: [String: [ChatMessage]] = [:]
    public internal(set) var otherSessions: [CCSession] = []
    /// Conversations that ended lately (pals-prd §10), to adopt.
    public internal(set) var recentSessions: [RecentSession] = []
    /// A Pal's turn being written, to stop (`pals.stop`).
    var palTurns: [String: Task<Void, Never>] = [:]
    /// Sessions asked to be adopted that wait to be quit in their terminal.
    var waitingAdoptions: Set<String> = []
    /// Each Pal's reply being written (`pals.history`'s `streaming`).
    var palWriting: [String: SyncResult.Streaming] = [:]
    /// 回到这里重来: what each rewind took out, under the seq it took (sync tells a client that missed it).
    var rewoundLog: [(seq: Int64, ids: [String])] = []
    /// A Pal's highest message number ever (its ids aren't used again after a rewind).
    var palSeqFloor: [String: Int64] = [:]
    /// The computer's sessions looked at without taking them over (§14), and
    /// the live one that's still going (a line now and then).
    var viewedLogs: [String: [CCMessage]] = [:]
    var viewedTails: Set<String> = []
    /// Images and files sent from the app (media.upload / uploadChunk), by id;
    /// uploads still coming in, by upload id.
    var media: [String: DemoMedia] = [:]
    var uploads: [String: DemoMedia] = [:]
    /// The owner's other devices paired with this computer (device.list);
    /// the one asking is added from what its hello said.
    var otherDevices: [PairedDevice] = DemoHost.demoDevices()
    var helloClient = "ios"
    /// Folders the owner opened from the preview pane (files.folders.*).
    var ownerFolders: [OwnerFolder] = []
    /// Asleep Pals being woken (§12), for words that come meanwhile to wait on.
    var palWakes: [String: Task<Void, Never>] = [:]
    /// Seeded with Pals: an accepted proposal opens a Pal, not a helper.
    let palsMode: Bool
    /// Seeded with sessions: a host from before Pals, which doesn't know `pals.*`.
    let sessionsMode: Bool

    /// The computer name the demo host reports (a second demo host shows the
    /// assistant switcher).
    public nonisolated let hostName: String

    /// `sessions`: the computer has Claude Code sessions (two helpers, one in
    /// a terminal, one in the background), two of them waiting on the owner
    /// with a card each, and the assistant proposes a helper in the chat.
    /// `pals`: instead, two Pals (one waiting on a card), a session in a
    /// terminal and one in the background to adopt (the background one
    /// asking a question), and the assistant proposes opening a Pal.
    public init(speed: Double = 1, seeded: Bool = true, autoConnect: Bool = true, hostName: String = "我的 MacBook",
                assistantName: String = "Palo", color: String = "magenta", sessions withSessions: Bool = false,
                pals withPals: Bool = false) {
        self.speed = speed
        self.hostName = hostName
        self.palsMode = withPals
        self.sessionsMode = withSessions && !withPals
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
            self.questions = s.questions
            self.watches = s.watches
            self.artifacts = s.artifacts
            self.files = s.files
            self.memory = s.memory
            (self.allies, self.allyLogs) = DemoHost.seedAllies(now: Date().epochMillis)
            if withSessions {
                let ss = DemoHost.seedSessions(now: Date().epochMillis, nextSeq: seq + 1)
                self.sessions = ss.sessions
                self.sessionLogs = ss.logs
                self.approvals += ss.approvals
                self.questions += ss.questions
                self.messages.append(ss.proposal)
                self.seq = ss.proposal.seq
            } else if withPals {
                let ps = DemoHost.seedPals(now: Date().epochMillis, nextSeq: seq + 1)
                self.pals = ps.pals
                self.palLogs = ps.logs
                self.otherSessions = ps.others
                self.recentSessions = ps.recent
                self.approvals += ps.approvals
                self.questions += ps.questions
                self.messages.append(ps.proposal)
                self.seq = ps.proposal.seq
            }
        }
        // The owner's words in the assistant's conversation carry the uuid
        // the host keeps them under (回到这里重来 is offered on them).
        messages = messages.map { m in
            var m = m
            if m.role == .user, m.kind == .text, m.pal == nil, m.uuid == nil { m.uuid = "u-\(m.id)" }
            return m
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
        var m = ChatMessage(seq: seq, id: "m\(seq)", role: role, kind: kind, text: text, channel: channel,
                            ts: Date().epochMillis, proactive: proactive, taskId: taskId, approvalId: approvalId)
        // The owner's words carry the uuid the host keeps them under (回到这里重来).
        if role == .user, kind == .text { m.uuid = "u-\(m.id)" }
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

    /// Screenshot states for the title capsule (`-demoState idle | busy | tasks | fresh | answered | tables`):
    /// nothing waiting on the owner, then the main turn working, or several
    /// background tasks running.
    public func applyScenario(_ name: String) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        // Sessions' cards: kept for the sessions' own states; otherwise
        // settled at the computer (they leave the conversation). The helper
        // proposal stays on offer only for those and `helper`, so nothing
        // else waits on the owner.
        if !name.hasPrefix("session") { settleSessionCards() }
        if !name.hasPrefix("session") && !name.hasPrefix("pal") { settlePalCards() }
        if !name.hasPrefix("session") && name != "helper" { withdrawProposals() }
        for i in approvals.indices where approvals[i].isPending && approvals[i].source == nil {
            approvals[i].status = .allowed
            emit(RPCEventName.approvalUpdated, approvals[i])
        }
        for i in questions.indices where questions[i].isPending && questions[i].source == nil {
            if name == "answered" {
                // `-demoState answered`: the question card after the owner chose.
                var answers: [String: String] = [:]
                for item in questions[i].items {
                    answers[item.question] = item.multiSelect
                        ? item.options.prefix(2).map(\.label).joined(separator: ", ") : item.options.first?.label ?? ""
                }
                questions[i].status = .answered
                questions[i].answers = answers
                questions[i].answeredAt = now
                questions[i].answeredBy = "app"
            } else {
                questions[i].status = .expired
            }
            emit(RPCEventName.questionUpdated, questions[i])
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
        case "fresh":
            // A first-time owner: nothing said yet.
            messages.removeAll()
        case "allies":
            // `-demoState allies`: an Ally's message in the conversation, then
            // a draft back to them with two times to choose from.
            receiveAllyMessage(from: "al-family", text: "周六下午带孩子去公园，你那边几点方便？")
            post("家人的助理问周六下午几点去公园。我看了你的日历，这两个时间都空着，回复拟好了，你看一下。")
            makeDraft(to: "al-family", text: "周六下午都可以，这两个时间你看哪个合适？", slots: DemoHost.saturdaySlots())
        case "alliesSent":
            // `-demoState alliesSent`: the same, and the owner has sent it; a
            // short one to 小林 waits in the queue (offline).
            receiveAllyMessage(from: "al-family", text: "周六下午带孩子去公园，你那边几点方便？")
            makeDraft(to: "al-family", text: "周六下午都可以，这两个时间你看哪个合适？", slots: DemoHost.saturdaySlots())
            makeDraft(to: "al-lin", text: "资料我晚上再发你。")
            for e in allyLogs.values.joined() where e.status == .draft {
                var sent = e
                sent.status = e.allyId == "al-lin" ? .queued : .seen
                updateEntry(sent)
            }
        case "sessionExpired":
            // `-demoState sessionExpired`: 网站帮手's card waited past the
            // hook's limit; the session now asks at the computer.
            if let i = approvals.firstIndex(where: { $0.source?.id == "cc-site" }) {
                approvals[i].status = .expired
                approvals[i].decidedAt = now
                approvals[i].decidedBy = "timeout"
                approvals[i].note = "在电脑上等你"
                emit(RPCEventName.approvalUpdated, approvals[i])
            }
        case "sessionSettle":
            // `-demoState sessionSettle`: 网站帮手's card is answered at the
            // computer a few seconds in, and leaves the conversation.
            Task {
                await pause(6)
                if let i = approvals.firstIndex(where: { $0.source?.id == "cc-site" && $0.isPending }) {
                    approvals[i].status = .expired
                    approvals[i].decidedAt = Date().epochMillis
                    approvals[i].decidedBy = "computer"
                    approvals[i].note = "已在电脑上处理"
                    emit(RPCEventName.approvalUpdated, approvals[i])
                    setSession("cc-site") { $0.status = .busy; $0.waitingFor = nil }
                }
            }
        case "adopt":
            // `-demoState adopt`: the owner asked for a conversation that
            // ended; the assistant found it and asks with a card (§10).
            post("把 site 里改首页的那个对话接过来", role: .user)
            if let found = recentMatch("site 首页") {
                post("找到了，是 \(CCSession.shortPath(found.cwd)) 里那个。")
                proposeAdopting(found)
            }
        case "tables":
            // Wide tables in a reply: they scroll sideways instead of squeezing.
            post("MacBook Air 和 dev 哪台更适合常驻跑助理？", role: .user)
            post("""
            两台我都看了一下，差别主要在这几项：

            | 项目 | MacBook Air | dev（云主机） |
            |:---|:---|:---|
            | 一直在线 | 合盖或断网就停，出门时最容易掉线 | 7×24 在线，不受你带不带电脑影响 |
            | 能用的工具 | 本机的浏览器、日历、微信、文件都直接能用 | 只有命令行和网页接口，碰不到本机应用 |
            | 速度和费用 | 不额外花钱，跑重活时风扇会响 | 每月约 ¥140，编译和批量任务快很多 |

            按月算一下两边的开销：

            | 月份 | 电费 | 云主机 | 模型用量 | 合计 |
            |:---|---:|---:|---:|---:|
            | 7 月 | ¥6 | ¥140 | ¥212 | ¥358 |
            | 8 月 | ¥7 | ¥140 | ¥236 | ¥383 |
            | 9 月 | ¥6 | ¥140 | ¥198 | **¥344** |

            建议：日常放在 **dev** 上，需要碰本机应用的事再交给 Air。
            """)
        case "streamfinal":
            // Two real replies streamed in small pieces and then finalized, one
            // after the other: the rows must end up as tall as the final text
            // (they once kept the streaming height and cut the end off).
            Task {
                await pause(2)
                post("他 13 个月就会自己拿遥控器找 Ms Rachel 了", role: .user)
                await streamReply(DemoHost.truncationSampleA)
                await pause(0.5)
                post("他还会玩马里奥赛车", role: .user)
                await streamReply(DemoHost.truncationSampleB)
            }
        case "streamshapes":
            // The three shapes that once kept a stale height until reopening:
            // a tool call first and then a short reply with an emoji and a
            // paragraph break; a plain short streamed reply; a long one.
            Task {
                await pause(2)
                post("这一条也验一下", role: .user)
                var s = status
                s.busy = true
                s.activity = "在给维护那边发消息"
                setStatus(s)
                await pause(1.2)
                await streamReply("哈哈，那这一条也算验收过了 👍\n\nTestFlight 那三件事不急，你有空再弄。")
                await pause(0.5)
                post("再来一条普通的", role: .user)
                await streamReply("好的。这条没有调用任何工具，只是一段普通的流式回复，中间有一个空行。\n\n第二段在这里，结尾也有个表情 🙂")
                await pause(0.5)
                post("长一点的呢", role: .user)
                await streamReply(DemoHost.truncationSampleA)
            }
        case "long":
            // A long conversation full of tables and long answers (like a real
            // owner's after a few weeks), then a long table answer streaming in:
            // the shape that once froze the Mac for 34 s.
            for i in 0..<90 {
                post("第 \(i + 1) 个问题：帮我比较一下这几个方案，顺便把要点列成表。", role: .user)
                post(i % 3 == 0 ? DemoHost.longTableAnswer(i) : DemoHost.longProseAnswer(i))
            }
            // `-demoStreamDelay <s>`: start streaming later (after a scroll tour).
            let delay = UserDefaults.standard.double(forKey: "demoStreamDelay")
            Task {
                await pause(delay > 0 ? delay : 4)
                await streamLongReply()
            }
        case "stress":
            // The iPhone freeze (2026-10-07): a long conversation; replies
            // streaming for half a minute; and every few seconds the link
            // drops and the catch-up inserts what came in meanwhile (WeChat
            // messages), above the reply still streaming. For a minute; the
            // UI test ScrollStressUITests flings the list all through it.
            for i in 0..<90 {
                post("第 \(i + 1) 个问题：帮我比较一下这几个方案，顺便把要点列成表。", role: .user)
                post(i % 3 == 0 ? DemoHost.longTableAnswer(i) : DemoHost.longProseAnswer(i))
            }
            Task {
                await pause(3)
                for _ in 0..<6 {
                    await streamLongReply()
                    await pause(0.3)
                }
            }
            Task {
                await pause(5)
                for round in 0..<11 {
                    missWhileAway(round)
                    await transport.forceReconnect()
                    await pause(5)
                }
            }
        case "burst":
            // a tester's 3.2 s freeze (17:49): while she held to talk, a reply's
            // 110 deltas, its final message (~1 KB) and the host going idle
            // all arrived at once. The long conversation, then that burst at
            // `-demoBurstAt <s>` (default 9; pair with `-voiceDrill`).
            for i in 0..<90 {
                post("第 \(i + 1) 个问题：帮我比较一下这几个方案，顺便把要点列成表。", role: .user)
                post(i % 3 == 0 ? DemoHost.longTableAnswer(i) : DemoHost.longProseAnswer(i))
            }
            let at = UserDefaults.standard.double(forKey: "demoBurstAt")
            Task {
                await pause(at > 0 ? at : 9)
                await burstReply()
            }
        case "bigtable":
            // The long conversation, plus an answer with a 500-row table;
            // then the link drops and comes back (sync, full reload) while
            // another long answer streams in.
            for i in 0..<60 {
                post("第 \(i + 1) 个问题：帮我比较一下这几个方案，顺便把要点列成表。", role: .user)
                post(i % 3 == 0 ? DemoHost.longTableAnswer(i) : DemoHost.longProseAnswer(i))
            }
            post("把这半年的每一笔开销都列出来", role: .user)
            post(DemoHost.hugeTableAnswer(rows: 500))
            Task {
                await pause(5)
                await transport.forceReconnect()
                await pause(2)
                await streamLongReply()
            }
        default:
            break
        }
        setStatus(s)
    }

    /// Four WeChat messages the app didn't hear (the link was down), shaped
    /// like the ones in the freeze: the next catch-up inserts them.
    private func missWhileAway(_ round: Int) {
        let line = "第 \(round + 1) 轮：断线时从微信进来的消息，重连后补上。"
        post(String(repeating: line, count: 6), role: .user, channel: .wechat, broadcast: false)
        post("好的，收到。", channel: .wechat, broadcast: false)
        post(String(repeating: line, count: 3), role: .user, channel: .wechat, broadcast: false)
        post(DemoHost.longProseAnswer(500 + round), channel: .wechat, broadcast: false)
    }

    /// An answer with one very long table (`-demoState bigtable`).
    static func hugeTableAnswer(rows: Int) -> String {
        let body = (0..<rows).map { r in
            "| \(r + 1) | 2026-\(String(format: "%02d", r % 12 + 1))-\(String(format: "%02d", r % 28 + 1)) | 第 \(r + 1) 笔：超市、外卖或者交通 | ¥\(10 + (r * 37) % 900) | \(r % 4 == 0 ? "报销" : "自付") |"
        }.joined(separator: "\n")
        return """
        一共 \(rows) 笔，按时间排好了：

        | # | 日期 | 内容 | 金额 | 备注 |
        |---:|:---|:---|---:|:---|
        \(body)

        合计和分类我放在下面。
        """
    }

    /// Streams a long answer with two tables in small pieces, like a real
    /// turn, then finalizes it (DEBUG stress scenario `-demoState long`).
    public func streamLongReply() async {
        var s = status
        s.busy = true
        s.activity = "在写回复"
        setStatus(s)
        let rid = nextID("r")
        let reply = DemoHost.longTableAnswer(999) + "\n\n" + DemoHost.longProseAnswer(999)
        var acc = ""
        for piece in DemoHost.chunks(reply) {
            acc += piece
            writing = SyncResult.Streaming(id: rid, text: acc)
            emit(RPCEventName.chatDelta, ChatDelta(id: rid, text: piece))
            await pause(0.02)
        }
        writing = nil
        seq += 1
        let final = ChatMessage(seq: seq, id: rid, role: .assistant, kind: .text, text: acc,
                                channel: .app, ts: Date().epochMillis)
        messages.append(final)
        emit(RPCEventName.chatMessage, final)
        s.busy = false
        s.activity = nil
        setStatus(s)
    }

    /// A whole reply at once: busy, 110 deltas back to back, the final
    /// message and idle, with no pause anywhere (`-demoState burst`).
    public func burstReply() async {
        var s = status
        s.busy = true
        s.activity = "在写回复"
        setStatus(s)
        let rid = nextID("r")
        let line = "好的，这件事我已经办好了，结果和下一步都写在下面，你看一下有没有要改的地方。"
        let reply = String(repeating: line, count: 9)
        var pieces = DemoHost.chunks(reply)
        while pieces.count > 110 { pieces[pieces.count - 2] += pieces.removeLast() }
        for piece in pieces { emit(RPCEventName.chatDelta, ChatDelta(id: rid, text: piece)) }
        seq += 1
        let final = ChatMessage(seq: seq, id: rid, role: .assistant, kind: .text, text: reply,
                                channel: .app, ts: Date().epochMillis)
        messages.append(final)
        emit(RPCEventName.chatMessage, final)
        s.busy = false
        s.activity = nil
        setStatus(s)
        debugLog("[demo] burst: \(pieces.count) deltas, \(reply.utf8.count) bytes, final and idle")
    }

    /// Streams `reply` in small pieces, then finalizes it.
    public func streamReply(_ reply: String) async {
        var s = status
        s.busy = true
        s.activity = "在写回复"
        setStatus(s)
        let rid = nextID("r")
        var acc = ""
        for piece in DemoHost.chunks(reply) {
            acc += piece
            writing = SyncResult.Streaming(id: rid, text: acc)
            emit(RPCEventName.chatDelta, ChatDelta(id: rid, text: piece))
            await pause(0.02)
        }
        writing = nil
        seq += 1
        let final = ChatMessage(seq: seq, id: rid, role: .assistant, kind: .text, text: acc,
                                channel: .app, ts: Date().epochMillis)
        messages.append(final)
        emit(RPCEventName.chatMessage, final)
        s.busy = false
        s.activity = nil
        setStatus(s)
    }

    static let truncationSampleA = """
    哈哈，13 个月就会自己拿遥控器找节目，挺厉害的。他能找到也不奇怪：Ms Rachel 是 YouTube 上最火的幼儿频道之一，推荐里很容易刷到，而且整个节目就是按照能抓住这么大宝宝的注意力来设计的。

    **她是谁**
    - 本名 Rachel Griffin Accurso，美国人，以前在纽约当幼儿园音乐老师，有 NYU 音乐教育硕士学位，后来又读了幼儿教育。
    - 2019 年开始做 YouTube 频道 Songs for Littles，起因是她儿子有语言发育迟缓，她找不到能帮孩子学说话的好视频，就自己做。
    - 她丈夫 Aron Accurso 是百老汇的作曲和音乐总监，节目里的歌大多是他写的，他也会出镜，就是 Mr. Aron。
    - 内容会请语言治疗师参与设计。频道订阅过千万，后来 Netflix 也上了她的节目。

    **为什么宝宝一眼就会被吸引**
    - 永远穿亮粉色上衣、背带裤，戴发带，在一堆画面里特别显眼。
    - 脸离镜头很近，直视镜头说话，宝宝会觉得「她在跟我说话」。
    - 说得慢、重复多，还会停下来等孩子回应。

    他既然会自己找了，可以顺手把电视上的自动播放关掉。不然看完一集会一直接着放下去。
    """

    static let truncationSampleB = """
    哈哈，有智能转向和自动加速，他拿着手柄随便按，车也不会掉下赛道，看起来就像真在开。对他来说最好玩的大概是「我一动，屏幕里就有反应」。这么大的孩子正是对因果关系最着迷的时候，跟扔东西、按开关是一个乐趣。

    马里奥赛车画面快、刺激强，跟 Ms Rachel 那种慢节奏是两回事。当成和爸爸一起玩的小游戏挺好，时间短一点就行。

    将来他发现关掉辅助会撞墙，估计就要哭着来找你了 😄
    """

    static func longTableAnswer(_ i: Int) -> String {
        var rows = ""
        for r in 0..<8 {
            rows += "| 方案 \(r + 1) | 适合长期常驻、需要一直在线的场景，出门时也不会掉线 | 每月约 ¥\(100 + r * 17) | 速度快，但碰不到本机应用和文件 |\n"
        }
        return """
        第 \(i) 次对比，结论先说：日常放在 **dev** 上，需要碰本机应用的事再交给 Air。

        | 方案 | 适用场景 | 费用 | 备注 |
        |:---|:---|---:|:---|
        \(rows)
        细节如下：每一项我都按你平时的用法估了一下，数字是过去三个月的平均值，仅供参考。
        """
    }

    static func longProseAnswer(_ i: Int) -> String {
        let para = "这一段是比较长的说明文字，用来模拟真实对话里那种一大段一大段的回复：先讲背景，再讲为什么这么建议，最后列出下一步要做的事情和需要你确认的地方。"
        return "第 \(i) 条回复。\n\n" + (0..<6).map { "- \(para)（\($0 + 1)）" }.joined(separator: "\n") + "\n\n" + para + para
    }

    // MARK: request handling

    func nextID(_ prefix: String) -> String {
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
            if let c = p["client"]?.stringValue { helloClient = c }
            return ["hostName": .string(hostName), "version": .string(status.version), "status": try .from(status)]
        case RPCMethod.sync:
            let since = p["sinceSeq"]?.doubleValue.map { Int64($0) }
            let msgs: [ChatMessage]
            if let since {
                msgs = Array(messages.filter { $0.seq > since }.prefix(SyncResult.pageLimit))
            } else {
                msgs = Array(messages.suffix(100))
            }
            let rewound = since.map { s in rewoundLog.filter { $0.seq > s }.flatMap(\.ids) } ?? []
            return try .from(SyncResult(seq: seq, messages: msgs, tasks: tasks, approvals: approvals, questions: questions,
                                        watches: watches,
                                        artifacts: artifacts, settings: settings, status: status,
                                        streaming: writing, rewound: rewound.isEmpty ? nil : rewound))
        case RPCMethod.chatSend:
            let text = p["text"]?.stringValue ?? ""
            let cid = p["clientMsgId"]?.stringValue
            seq += 1
            var m = ChatMessage(seq: seq, id: "m\(seq)", role: .user, kind: .text, text: text, channel: .app,
                                ts: Date().epochMillis, clientMsgId: cid)
            if let r = p["replyTo"], let reply = try? r.decode(ReplyTo.self) { m.replyTo = reply }
            if let atts = try attachments(p["attachments"]) { m.attachments = atts }
            if !text.hasPrefix("/") { m.uuid = "u-\(m.id)" }
            messages.append(m)
            emit(RPCEventName.chatMessage, m)
            if let sid = p["suggestionId"]?.stringValue {
                demoSuggestions.removeAll { $0.id == sid }
                emit(RPCEventName.suggestionsUpdated, ["suggestions": demoSuggestions])
            }
            Task { await self.respond(to: text) }
            return ["id": .string(m.id), "seq": .number(Double(m.seq))]
        case RPCMethod.chatRewind:
            // As the host's (docs/rewind-prd.md): back to just before one of
            // the owner's messages; it and what came after leave.
            let mid = p["messageId"]?.stringValue ?? ""
            guard let i = messages.firstIndex(where: { $0.id == mid }), messages[i].role == .user, messages[i].uuid != nil else {
                throw DemoError(message: "这一条不能回到这里")
            }
            guard !status.busy else { throw DemoError(message: "它还在忙，先停下再重来") }
            let text = messages[i].text
            let gone = messages[i...].map(\.id)
            messages.removeSubrange(i...)
            seq += 1
            rewoundLog.append((seq, gone))
            await pause(0.3) // the host ends its process and forks the session
            emit(RPCEventName.chatRewound, ChatRewound(id: mid, ids: gone))
            return ["text": .string(text)]
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
        case RPCMethod.questionAnswer:
            let qid = p["id"]?.stringValue ?? ""
            guard let i = questions.firstIndex(where: { $0.id == qid }) else { throw DemoError(message: "没有这个问题") }
            guard questions[i].isPending else { return ["question": try .from(questions[i])] }
            var answers: [String: String] = [:]
            if case .object(let o)? = p["answers"] { for (k, v) in o { answers[k] = v.stringValue ?? "" } }
            guard questions[i].items.allSatisfy({ !(answers[$0.question] ?? "").isEmpty }) else {
                throw DemoError(message: "每个问题都要选一下")
            }
            questions[i].status = .answered
            questions[i].answers = answers
            questions[i].answeredAt = Date().epochMillis
            questions[i].answeredBy = "app"
            emit(RPCEventName.questionUpdated, questions[i])
            if let source = questions[i].source {
                if source.isPal {
                    palCardAnswered(source.id, allowed: true)
                } else {
                    setSession(source.id) { $0.status = .busy; $0.waitingFor = nil }
                    setOther(source.id) { $0.status = .busy; $0.waitingFor = nil }
                }
            }
            return ["question": try .from(questions[i])]
        case RPCMethod.approvalAnswer:
            let aid = p["id"]?.stringValue ?? ""
            let allow = p["allow"]?.boolValue ?? false
            guard let i = approvals.firstIndex(where: { $0.id == aid }) else { throw DemoError(message: "没有这个审批") }
            guard approvals[i].status == .pending else { return ["status": .string(approvals[i].status.rawValue)] }
            approvals[i].status = allow ? .allowed : .denied
            approvals[i].decidedAt = Date().epochMillis
            approvals[i].decidedBy = "app"
            emit(RPCEventName.approvalUpdated, approvals[i])
            if let source = approvals[i].source {
                if source.isPal {
                    palCardAnswered(source.id, allowed: allow)
                } else {
                    setSession(source.id) { $0.status = .busy; $0.waitingFor = nil }
                    setOther(source.id) { $0.status = .busy; $0.waitingFor = nil }
                }
            }
            return ["status": .string(approvals[i].status.rawValue)]
        case RPCMethod.watchAdd:
            let draft = try p.decode(WatchDraft.self)
            let w = Watch(id: nextID("w"), title: draft.title, kind: draft.kind, instruction: draft.instruction,
                          intervalMinutes: draft.intervalMinutes, at: draft.at, dayOfMonth: draft.dayOfMonth,
                          enabled: draft.enabled, createdBy: .user,
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
        case RPCMethod.hostUpdate:
            return ["status": .string("latest"), "current": .string("0.1.3"), "detail": .string("已经是最新版")]
        case RPCMethod.allyList:
            return ["allies": try .from(allies)]
        case RPCMethod.allyInvite:
            let exp = Date().epochMillis + 10 * 60_000
            // `-demoInviteScanned YES`: someone scans it a few seconds later.
            if UserDefaults.standard.bool(forKey: "demoInviteScanned") {
                Task {
                    await self.pause(4)
                    self.addAlly(AllyInfo(id: self.nextID("al"), kind: .family, ownerName: "小周", assistantName: "Palo",
                                          online: true, lastSeen: Date().epochMillis, trust: .review))
                }
            }
            return ["link": .string(DemoHost.inviteLink(expiresAt: exp)), "expiresAt": .number(Double(exp))]
        case RPCMethod.pairInvite:
            let exp = Date().epochMillis + 5 * 60_000
            let link = PairingLink(relay: URL(string: "https://relay.example.com")!, daemonID: "demo-daemon", code: "482913",
                                   hostKey: Data((0..<32).map { UInt8($0 * 7 % 256) }))
            return ["link": .string(link.url.absoluteString), "expiresAt": .number(Double(exp))]
        case RPCMethod.allyAccept:
            guard let invite = AllyInviteLink.parse(p["link"]?.stringValue ?? "") else {
                throw DemoError(message: "这个链接不完整，请对方重新生成二维码")
            }
            guard !invite.isExpired() else { throw DemoError(message: "二维码过期了，请对方重新生成一个") }
            await pause(1.5) // both halves of the pairing
            let asked = (try? p["kind"]?.decode(AllyKind.self)) ?? .family
            let trust = p["trust"]?.stringValue.flatMap(AllyTrust.init(rawValue:)) ?? .review
            let a = AllyInfo(id: nextID("al"), kind: asked == .unknown ? .family : asked,
                             ownerName: invite.name.isEmpty ? "新朋友" : invite.name, assistantName: "Palo",
                             online: true, lastSeen: Date().epochMillis, trust: trust == .unknown ? .review : trust,
                             theirTrust: .review)
            allies.append(a)
            allyLogs[a.id] = []
            emitAllies()
            return ["ally": try .from(a)]
        case RPCMethod.allyRemove:
            let id = p["id"]?.stringValue ?? ""
            guard allies.contains(where: { $0.id == id }) else { throw DemoError(message: "没有这个 Ally") }
            allies.removeAll { $0.id == id }
            emitAllies()
            return ["ok": true]
        case RPCMethod.allyLog:
            let id = p["id"]?.stringValue ?? ""
            let before = p["beforeTs"]?.doubleValue.map { Int64($0) } ?? Int64.max
            let limit = Int(p["limit"]?.doubleValue ?? 50)
            return ["entries": try .from(Array((allyLogs[id] ?? []).filter { $0.ts < before }.suffix(limit)))]
        case RPCMethod.allyDraftDecide:
            let id = p["id"]?.stringValue ?? ""
            guard var e = allyLogs.values.joined().first(where: { $0.id == id }) else {
                throw DemoError(message: "这条草稿已经没有了")
            }
            // Already decided: as it is, never sent twice (§7.6).
            guard e.status == .draft else { return ["entry": try .from(e)] }
            let words = p["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch p["action"]?.stringValue {
            case "send":
                // With text: the owner's changed words go out.
                if let words, !words.isEmpty { e.text = words }
                e.status = .queued
            case "discard":
                e.status = .rejected
                e.note = "没发"
            case "edit":
                guard let words, !words.isEmpty else { throw DemoError(message: "要发的话不能是空的") }
                e.text = words
            default:
                throw DemoError(message: "看不懂这个操作")
            }
            updateEntry(e)
            if e.status == .queued { Task { await self.deliver(e.id) } }
            return ["entry": try .from(e)]
        case RPCMethod.allySay:
            let id = p["id"]?.stringValue ?? ""
            let text = (p["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let ally = allies.first(where: { $0.id == id }) else { throw DemoError(message: "没有这个 Ally") }
            guard !text.isEmpty else { throw DemoError(message: "要说的话不能是空的") }
            let e = AllyEntry(id: nextID("ae"), allyId: id, dir: .outgoing, ts: Date().epochMillis, text: text,
                              status: ally.online ? .sent : .queued, author: .owner)
            updateEntry(e)
            postAlly(e, name: ally.displayName)
            if ally.online {
                Task {
                    await self.deliver(e.id)
                    // Their side answers a little later.
                    await self.pause(1.5)
                    self.receiveAllyMessage(from: id, text: "好的，收到。", author: .owner)
                }
            }
            return ["entry": try .from(e)]
        case RPCMethod.allyTrust:
            let id = p["id"]?.stringValue ?? ""
            guard let i = allies.firstIndex(where: { $0.id == id }) else { throw DemoError(message: "没有这个 Ally") }
            guard let t = p["trust"]?.stringValue.flatMap(AllyTrust.init(rawValue:)), t != .unknown else {
                throw DemoError(message: "看不懂这个档位")
            }
            allies[i].trust = t
            emitAllies()
            return ["ally": try .from(allies[i])]
        case RPCMethod.sessionsList:
            return ["sessions": try .from(sessions), "hooks": .bool(hooksEnabled)]
        case RPCMethod.sessionsHistory:
            let id = p["id"]?.stringValue ?? ""
            guard let log = sessionLogs[id] ?? (palsMode ? viewedSessionLog(id) : nil) else { throw DemoError(message: "没有这个会话") }
            let limit = Int(p["limit"]?.doubleValue ?? 50)
            var upTo = log.endIndex
            if let before = p["before"]?.stringValue, let i = log.firstIndex(where: { $0.id == before }) { upTo = i }
            return ["messages": try .from(Array(log[..<upTo].suffix(limit)))]
        case RPCMethod.sessionsHooks:
            hooksEnabled = p["enabled"]?.boolValue ?? hooksEnabled
            return ["enabled": .bool(hooksEnabled)]
        case RPCMethod.helperDecide:
            let pid = p["proposalId"]?.stringValue ?? ""
            if palsMode, let r = try await decideAdoptCard(pid, action: p["action"]?.stringValue) { return r }
            guard let i = messages.firstIndex(where: { $0.proposal?.id == pid }), var proposal = messages[i].proposal else {
                throw DemoError(message: "这个提议已经没有了")
            }
            guard proposal.isPending else {
                return proposal.sessionId.flatMap { sid in sessions.first { $0.id == sid } }
                    .map { ["session": (try? JSONValue.from($0)) ?? .null] } ?? [:]
            }
            var result: JSONValue = [:]
            switch p["action"]?.stringValue {
            case "create" where palsMode:
                await pause(1.2) // the host starts it, the assistant's handover as its first words
                let sid = UUID().uuidString.lowercased()
                let pal = Pal(id: "pal-\(nextID("p"))", name: proposal.name, cwd: proposal.cwd, sessionId: sid, status: .busy,
                              lastLine: "在看交接说明…", model: "claude-sonnet-4-5", createdBy: .palo)
                pals.append(pal)
                palLogs[pal.id] = []
                appendPal(palMessage(pal.id, role: .user, text: "你好，我是 \(settings.assistantName)。\(proposal.duty)",
                                     channel: .system, from: settings.assistantName))
                emitPals()
                proposal.status = .created
                proposal.sessionId = sid
                proposal.palId = pal.id
                result = ["session": try .from(CCSession(id: sid, name: pal.name, cwd: pal.cwd, kind: .helper, status: .busy,
                                                         lastLine: pal.lastLine, updatedAt: Date().epochMillis)),
                          "pal": try .from(pal)]
                palTurns[pal.id] = Task { await self.streamPal(pal.id, "收到。我先看一下报销文件夹，把这周的发票列出来。") }
            case "create":
                await pause(1.2) // a background session starts
                let s = CCSession(id: nextID("cc"), name: proposal.name, cwd: proposal.cwd, kind: .helper, status: .busy,
                                  lastLine: "在看交接说明…", contextTokens: 12_000, updatedAt: Date().epochMillis)
                sessions.append(s)
                sessionLogs[s.id] = [CCMessage(id: nextID("cm"), ts: Date().epochMillis, role: .palo,
                                               text: "你好，我是 \(settings.assistantName)。\(proposal.duty)", from: settings.assistantName)]
                emitSessions()
                proposal.status = .created
                proposal.sessionId = s.id
                result = ["session": try .from(s)]
            case "discard":
                proposal.status = .discarded
            default:
                throw DemoError(message: "看不懂这个操作")
            }
            messages[i].proposal = proposal
            emit(RPCEventName.chatMessage, messages[i])
            return result
        default:
            if let r = try dispatchMedia(method, p) { return r }
            if let r = try dispatchDevices(method, p) { return r }
            if let r = try dispatchFiles(method, p) { return r }
            if !sessionsMode, let r = try await dispatchPals(method, p) { return r }
            throw DemoError(message: "unknown method \(method)")
        }
    }

    // MARK: sessions

    /// The whole list (`sessions.updated {sessions}`).
    private func emitSessions() {
        emit(RPCEventName.sessionsUpdated, ["sessions": sessions])
    }

    private func setSession(_ id: String, _ change: (inout CCSession) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[i])
        sessions[i].updatedAt = Date().epochMillis
        emitSessions()
    }

    /// Proposals still on offer are no longer (`expired`), as the host
    /// re-sends them: the same message.
    private func withdrawProposals() {
        for i in messages.indices where messages[i].proposal?.isPending == true {
            messages[i].proposal?.status = .expired
            emit(RPCEventName.chatMessage, messages[i])
        }
    }

    /// Every session card still waiting is answered at the computer, and
    /// those sessions carry on.
    private func settleSessionCards() {
        let now = Date().epochMillis
        // As the host marks them: ended without an answer here, handled there.
        for i in approvals.indices where approvals[i].source?.isSession == true && approvals[i].isPending {
            approvals[i].status = .expired
            approvals[i].decidedAt = now
            approvals[i].decidedBy = "computer"
            approvals[i].note = "已在电脑上处理"
            emit(RPCEventName.approvalUpdated, approvals[i])
        }
        for i in questions.indices where questions[i].source?.isSession == true && questions[i].isPending {
            questions[i].status = .expired
            questions[i].answeredAt = now
            questions[i].answeredBy = "computer"
            questions[i].note = "已在电脑上处理"
            emit(RPCEventName.questionUpdated, questions[i])
        }
        for s in sessions where s.status == .waiting { setSession(s.id) { $0.status = .busy; $0.waitingFor = nil } }
        for s in otherSessions where s.status == .waiting { setOther(s.id) { $0.status = .busy; $0.waitingFor = nil } }
    }

    /// Every Pal's card still waiting is answered in the app, and those Pals
    /// go back to idle (so nothing waits on the owner in a screenshot).
    private func settlePalCards() {
        let now = Date().epochMillis
        for i in approvals.indices where approvals[i].source?.isPal == true && approvals[i].isPending {
            approvals[i].status = .allowed
            approvals[i].decidedAt = now
            approvals[i].decidedBy = "app"
            emit(RPCEventName.approvalUpdated, approvals[i])
        }
        for p in pals where p.status == .waiting { setPal(p.id) { $0.status = .idle } }
    }

    // MARK: allies

    private func addAlly(_ a: AllyInfo) {
        allies.append(a)
        allyLogs[a.id] = []
        emitAllies()
    }

    /// The whole list (`ally.updated`, §7.6).
    private func emitAllies() {
        emit(RPCEventName.allyUpdated, ["allies": allies])
    }

    /// An exchange changed: its log, its Ally's last line (the newest, in
    /// any state), and `ally.entry {entry}`.
    private func updateEntry(_ e: AllyEntry) {
        guard let allyId = e.allyId else { return }
        var log = allyLogs[allyId] ?? []
        if let i = log.firstIndex(where: { $0.id == e.id }) { log[i] = e } else { log.append(e) }
        allyLogs[allyId] = log
        emit(RPCEventName.allyEntry, ["entry": (try? JSONValue.from(e)) ?? .null] as JSONValue)
        if let i = allies.firstIndex(where: { $0.id == allyId }),
           allies[i].lastEntry?.id == e.id || e.ts >= (allies[i].lastEntry?.ts ?? 0) {
            allies[i].lastEntry = e
            emitAllies()
        }
    }

    /// Sent: on its way at once when they're online, seen a little later.
    private func deliver(_ id: String) async {
        for next in [AllyEntryStatus.delivered, .seen] {
            await pause(next == .delivered ? 1.2 : 3)
            guard var e = allyLogs.values.joined().first(where: { $0.id == id }),
                  let allyId = e.allyId, allies.first(where: { $0.id == allyId })?.online == true else { return }
            e.status = next
            updateEntry(e)
        }
    }

    /// Their assistant passed something on: into the log and the conversation.
    public func receiveAllyMessage(from allyId: String, text: String, urgent: Bool = false, author: AllyAuthor = .assistant) {
        guard let ally = allies.first(where: { $0.id == allyId }) else { return }
        let e = AllyEntry(id: nextID("ae"), allyId: allyId, dir: .incoming, ts: Date().epochMillis, text: text,
                          urgent: urgent, status: .delivered, author: author)
        updateEntry(e)
        postAlly(e, name: ally.displayName)
    }

    /// The assistant drafted a message to an Ally: a card for the owner.
    public func makeDraft(to allyId: String, text: String, slots: [AllySlot]? = nil) {
        guard let ally = allies.first(where: { $0.id == allyId }) else { return }
        let e = AllyEntry(id: nextID("ae"), allyId: allyId, dir: .outgoing, ts: Date().epochMillis, text: text,
                          slots: slots, status: .draft, author: .assistant)
        updateEntry(e)
        postAlly(e, name: ally.displayName)
    }

    /// Into the conversation as the host does it (§7.6): their words as a
    /// system message, a draft as the assistant's card.
    private func postAlly(_ e: AllyEntry, name: String) {
        seq += 1
        let incoming = e.dir == .incoming
        // The owner's own words (ally.say) are theirs: role "user" (§11.4).
        let role: ChatRole = incoming ? .system : (e.author == .owner ? .user : .assistant)
        var m = ChatMessage(seq: seq, id: "m\(seq)", role: role, kind: .ally, text: e.text,
                            channel: .system, ts: e.ts, proactive: incoming ? true : nil)
        m.author = e.author
        m.allyId = e.allyId
        m.allyName = name
        m.dir = e.dir
        m.entryId = e.id
        messages.append(m)
        emit(RPCEventName.chatMessage, m)
    }

    /// Next Saturday afternoon, two hours each, in this time zone.
    static func saturdaySlots(now: Date = Date()) -> [AllySlot] {
        let cal = Calendar.current
        let day = cal.nextDate(after: now, matching: DateComponents(weekday: 7), matchingPolicy: .nextTime) ?? now
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return [(14, 16), (16, 18)].compactMap { a, b in
            guard let s = cal.date(bySettingHour: a, minute: 0, second: 0, of: day),
                  let e = cal.date(bySettingHour: b, minute: 0, second: 0, of: day) else { return nil }
            return AllySlot(start: f.string(from: s), end: f.string(from: e))
        }
    }

    /// The demo computer's invite (§7.2); nothing answers at that relay.
    static func inviteLink(expiresAt: Int64) -> String {
        var c = URLComponents()
        c.scheme = "paloally"
        c.host = "ally"
        c.queryItems = [
            URLQueryItem(name: "relay", value: "https://relay.example.com"),
            URLQueryItem(name: "daemon", value: "demo-daemon"),
            URLQueryItem(name: "code", value: "482913"),
            URLQueryItem(name: "hostkey", value: Data((0..<32).map { UInt8($0 * 7 % 256) }).base64URLEncodedString()),
            URLQueryItem(name: "name", value: "小明"),
            URLQueryItem(name: "exp", value: String(expiresAt)),
        ]
        return c.url?.absoluteString ?? "paloally://ally"
    }

    static func seedAllies(now: Int64) -> ([AllyInfo], [String: [AllyEntry]]) {
        let min: Int64 = 60_000
        let hour = 60 * min
        let day = 24 * hour
        // Both ways, said by the people themselves or by an assistant for them (§11.2).
        let family = [
            AllyEntry(id: "seed-1", allyId: "al-family", dir: .incoming, ts: now - 2 * day, text: "周末要不要带孩子去公园？",
                      status: .seen, author: .owner),
            AllyEntry(id: "seed-2", allyId: "al-family", dir: .outgoing, ts: now - 2 * day + 6 * min, text: "好呀，周六下午怎么样？",
                      status: .seen, author: .owner),
            AllyEntry(id: "seed-3", allyId: "al-family", dir: .incoming, ts: now - 3 * hour, text: "今晚我晚点回，大概九点。",
                      status: .seen, author: .assistant),
            AllyEntry(id: "seed-4", allyId: "al-family", dir: .outgoing, ts: now - 3 * hour + 4 * min, text: "收到，路上小心。",
                      status: .delivered, author: .assistant),
        ]
        let lin = [
            AllyEntry(id: "seed-5", allyId: "al-lin", dir: .outgoing, ts: now - day - 2 * hour, text: "周四的读书会改到晚上八点了。",
                      status: .seen, author: .assistant),
            AllyEntry(id: "seed-6", allyId: "al-lin", dir: .incoming, ts: now - day - hour, text: "好的，我准时到。",
                      status: .seen, author: .owner),
            AllyEntry(id: "seed-7", allyId: "al-lin", dir: .outgoing, ts: now - 40 * min, text: "明天的资料发你邮箱了，记得看一下。",
                      status: .queued, author: .assistant),
        ]
        let allies = [
            AllyInfo(id: "al-family", kind: .family, ownerName: "家人", assistantName: "小橘", online: true,
                     lastSeen: now - 2 * min, lastEntry: family.last, trust: .converse, theirTrust: .converse),
            AllyInfo(id: "al-lin", kind: .family, ownerName: "小林", assistantName: "阿福", online: false,
                     lastSeen: now - 5 * hour, lastEntry: lin.last, trust: .review),
        ]
        return (allies, ["al-family": family, "al-lin": lin])
    }

    struct SessionSeed {
        var sessions: [CCSession]
        var logs: [String: [CCMessage]]
        var approvals: [Approval]
        var questions: [Question]
        /// The assistant's helper proposal in the conversation.
        var proposal: ChatMessage
    }

    /// Two helpers, a session in a terminal and one in the background;
    /// 网站帮手 waits to run a long command, 数据清洗 asks a question.
    static func seedSessions(now: Int64, nextSeq: Int64) -> SessionSeed {
        let min: Int64 = 60_000
        let hour = 60 * min
        let sessions = [
            CCSession(id: "cc-site", name: "网站帮手", cwd: "/Users/demo/code/site", kind: .helper, status: .waiting,
                      waitingFor: "想运行 npm run build", lastLine: "列表页做完了，跑一下构建看看有没有报错。",
                      contextTokens: 182_000, updatedAt: now - min),
            CCSession(id: "cc-notes", name: "笔记整理", cwd: "/Users/demo/Documents/notes", kind: .helper, status: .idle,
                      lastLine: "这周的 12 篇笔记都归好类了，标签也补上了。", contextTokens: 46_000, updatedAt: now - 40 * min),
            CCSession(id: "cc-login", name: "修登录跳转", cwd: "/Users/demo/code/app", kind: .terminal, status: .busy,
                      lastLine: "在跑登录相关的测试，还剩 3 个文件。", contextTokens: 95_000, updatedAt: now - 2 * min),
            CCSession(id: "cc-data", name: "问卷数据清洗", cwd: "/Users/demo/code/survey", kind: .background, status: .waiting,
                      waitingFor: "问你缺的数据怎么处理", lastLine: "1,200 份问卷里有 37 份没填收入。",
                      contextTokens: 310_000, updatedAt: now - 5 * min),
        ]
        var n = 0
        func line(_ role: CCMessageRole, _ text: String, ago: Int64, from: String? = nil) -> CCMessage {
            n += 1
            // Not the shape of nextID's ("cm-1"), so later lines never share an id.
            return CCMessage(id: "seed-cm\(n)", ts: now - ago, role: role, text: text, from: from)
        }
        // 网站帮手: a day of work before today's, so there is an older page.
        var site: [CCMessage] = [
            line(.palo, "你好，我是 Palo。主人的网站在 ~/code/site，接下来由你专门负责：先做列表页，再做详情页。每天花费不超过 5 美元。",
                 ago: 26 * hour, from: "Palo"),
            line(.assistant, "收到。我先看一下项目结构和现有的页面。", ago: 26 * hour - min),
        ]
        for i in 1...30 {
            site.append(line(.assistant, "第 \(i) 处样式调好了：间距统一成 8 的倍数，字号跟设计稿对齐。", ago: 25 * hour - Int64(i) * 2 * min))
        }
        site += [
            line(.assistant, "看完了：列表页还是空的，路由已经配好。我从数据接口开始接。", ago: 3 * hour),
            line(.owner, "列表要能按日期排序", ago: 2 * hour + 30 * min),
            line(.assistant, "好的，加上了按日期排序，默认最新的在前。", ago: 2 * hour + 28 * min),
            line(.peer, "网站帮手你好，主人的笔记里有一份列表页的设计稿，在 notes/设计/列表页.md。", ago: 2 * hour, from: "笔记整理"),
            line(.assistant, "谢谢，我按那份设计稿调一下间距和字号。", ago: 2 * hour - min),
            line(.palo, "先别管登录页，把列表页做完", ago: 40 * min, from: "主人"),
            line(.assistant, "明白，登录页先放着。列表页做完了，跑一下构建看看有没有报错。", ago: min),
        ]
        let notes = [
            line(.palo, "你好，我是 Palo。主人的笔记在 ~/Documents/notes，请每周把新笔记归类、补上标签。", ago: 5 * 24 * hour, from: "Palo"),
            line(.assistant, "好的，我先把现有的分类看一遍。", ago: 5 * 24 * hour - min),
            line(.assistant, "这周的 12 篇笔记都归好类了，标签也补上了。", ago: 40 * min),
        ]
        let login = [
            line(.owner, "登录以后会跳回首页，应该回到原来那一页", ago: 30 * min),
            line(.assistant, "找到了：跳转时把原来的地址丢了。我改成登录前先记下来。", ago: 25 * min),
            line(.assistant, "在跑登录相关的测试，还剩 3 个文件。", ago: 2 * min),
        ]
        let data = [
            line(.owner, "把问卷数据清洗一下，输出一份干净的表", ago: hour),
            line(.assistant, "1,200 份问卷里有 37 份没填收入。", ago: 6 * min),
        ]
        let approvals = [
            Approval(id: "sa1", tool: "Bash", title: "在电脑上运行一条命令",
                     detail: """
                     npm run build && \\
                       npm run test -- --coverage --reporter=dot && \\
                       npx playwright test tests/list-page.spec.ts --project=chromium --workers=2 && \\
                       rsync -av --delete dist/ ~/code/site-preview/ && \\
                       echo "构建、测试和预览都好了"
                     """,
                     careful: false, status: .pending, createdAt: now - min,
                     source: CardSource(id: "cc-site", name: "网站帮手")),
        ]
        let questions = [
            Question(id: "sq1", items: [
                QuestionItem(question: "没填收入的 37 份问卷怎么处理？", header: "缺的数据", options: [
                    QuestionOption(label: "A 直接删掉", description: "剩 1,163 份"),
                    QuestionOption(label: "B 用中位数补上", description: "1,200 份都保留"),
                ]),
            ], status: .pending, createdAt: now - 5 * min, source: CardSource(id: "cc-data", name: "问卷数据清洗")),
        ]
        var proposal = ChatMessage(seq: nextSeq, id: "m\(nextSeq)", role: .assistant, kind: .helper,
                                   text: "报销单每周都要理一遍，要不要开一个帮手专门管？", channel: .app, ts: now - 3 * min)
        proposal.proposal = HelperProposal(id: "hp1", name: "报销帮手", cwd: "/Users/demo/Documents/报销",
                                           duty: "每周把下载文件夹里的发票整理进报销表，缺的告诉你。", dailyUsd: 3)
        return SessionSeed(sessions: sessions, logs: ["cc-site": site, "cc-notes": notes, "cc-login": login, "cc-data": data],
                           approvals: approvals, questions: questions, proposal: proposal)
    }

    // MARK: canned replies

    func pause(_ seconds: Double) async {
        guard speed > 0 else { return }
        try? await Task.sleep(for: .seconds(seconds * speed))
    }

    private func respond(to text: String) async {
        status.busy = true
        emit(RPCEventName.status, status)
        await pause(0.6)

        var taskToRun: AllyTask?
        var draft: (to: String, text: String, slots: [AllySlot]?)?
        var adoptCard: RecentSession?
        let reply: String
        if text.contains("跟"), text.contains("说") || text.contains("约"),
           let to = allies.first(where: { text.contains($0.ownerName) }) ?? allies.first {
            // 「跟家人说今晚我晚点回」: a draft card, sent only when the owner says so.
            if text.contains("约") {
                draft = (to.id, "周六下午带孩子去公园，这两个时间你看哪个合适？", DemoHost.saturdaySlots())
            } else {
                let said = text.range(of: "说").map { String(text[$0.upperBound...]) } ?? text
                let words = said.trimmingCharacters(in: CharacterSet(charactersIn: "：:，, ").union(.whitespaces))
                draft = (to.id, words.isEmpty ? text : words, nil)
            }
            reply = "拟好了，你看一下，点发送就发给\(to.displayName)。"
        } else if text.contains("提醒") {
            reply = "好嘞，到点我叫你 ⏰\n\n已经加进 **目标** 里了，随时可以改。"
            let w = Watch(id: nextID("w"), title: String(text.prefix(18)), kind: .schedule, instruction: text,
                          at: ["10:00"], enabled: true, createdBy: .agent)
            watches.append(w)
            emit(RPCEventName.watchUpdated, ["watch": (try? JSONValue.from(w)) ?? .null] as JSONValue)
        } else if palsMode, text.contains("接过来") || text.contains("接管"), let found = recentMatch(text) {
            // 「把 site 里那个对话接过来」: found, and a card to say yes to (pals-prd §10).
            adoptCard = found
            reply = "找到了，是 \(CCSession.shortPath(found.cwd)) 里那个。"
        } else if ["帮我", "查", "整理", "比较", "找"].contains(where: text.contains) {
            let now = Date().epochMillis
            let t = AllyTask(id: nextID("t"), title: String(text.replacingOccurrences(of: "帮我", with: "").prefix(16)),
                             summary: "正在办…", status: .running, source: .report, createdAt: now, updatedAt: now)
            upsertTask(t)
            taskToRun = t
            reply = "收到，我在后台办，好了告诉你。"
        } else if text.contains("详细") {
            // A reply longer than the screen (the push-to-top UI tests).
            reply = DemoHost.longProseAnswer(1) + "\n\n" + DemoHost.longProseAnswer(2)
        } else if text.contains("晨报") {
            reply = "今天的晨报在资料库里置顶着：\n\n- **3 件待办**，最急的是周四的会\n- 1 封邮件等你回\n- 下午有雨，记得带伞 ☔️"
        } else {
            reply = "好的，我记下了 🙂\n\n还有什么想让我做的，随时说。"
        }

        // Stream the reply in small pieces, then finalize with chat.message
        // (a long one faster, about as fast as a real one comes).
        let rid = nextID("r")
        var acc = ""
        for piece in DemoHost.chunks(reply) {
            acc += piece
            writing = SyncResult.Streaming(id: rid, text: acc)
            emit(RPCEventName.chatDelta, ChatDelta(id: rid, text: piece))
            await pause(reply.count > 400 ? 0.02 : 0.05)
        }
        writing = nil
        seq += 1
        let final = ChatMessage(seq: seq, id: rid, role: .assistant, kind: taskToRun == nil ? .text : .task, text: acc,
                                channel: .app, ts: Date().epochMillis, taskId: taskToRun?.id)
        messages.append(final)
        emit(RPCEventName.chatMessage, final)
        status.busy = false
        emit(RPCEventName.status, status)

        if let draft { makeDraft(to: draft.to, text: draft.text, slots: draft.slots) }
        if let adoptCard { proposeAdopting(adoptCard) }

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
        var questions: [Question]
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
            { var m = msg(.assistant, "想问你：周五晚上几个人？（共 2 个问题）", kind: .question, ago: 15 * min, taskId: "t3")
              m.questionId = "q1"
              return m }(),
        ]
        let questions = [
            Question(id: "q1", items: [
                QuestionItem(question: "周五晚上几个人？", header: "人数", options: [
                    QuestionOption(label: "两个人", description: "就我们俩"),
                    QuestionOption(label: "四个人", description: "带上爸妈"),
                    QuestionOption(label: "六个人以上", description: "叫上朋友"),
                ]),
                QuestionItem(question: "想吃什么？", header: "口味", options: [
                    QuestionOption(label: "日料"),
                    QuestionOption(label: "粤菜"),
                    QuestionOption(label: "西餐", description: "安静一点的"),
                ], multiSelect: true),
            ], taskId: "t3", status: .pending, createdAt: now - 15 * min),
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
        return Seed(messages: messages, tasks: tasks, approvals: approvals, questions: questions, watches: watches,
                    artifacts: artifacts,
                    files: files, memory: memory)
    }
}
