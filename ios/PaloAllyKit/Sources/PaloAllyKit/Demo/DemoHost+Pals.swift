import Foundation

/// Pals in the demo (pals-prd §8): two Pals with their conversations, one
/// waiting on a card; a terminal session and a background one to adopt.
/// A Pal answers what the owner types by streaming a reply, the way the
/// assistant does; 接管 on the background session takes a moment, on the
/// terminal one it waits to be quit there (`-demoAdoptAfter <s>`, default 6;
/// 0 never). Seven conversations that ended lately, in three folders, adopt
/// in a moment (§10; `-demoAdoptError <why>` makes that fail,
/// `-demoRecentEmpty YES` leaves none); the assistant proposes one with a
/// `pal_adopt` card when asked to 接过来 (`-demoState adopt`). Two more Pals
/// are asleep (§12): words for one wake it first (`-demoWakeAfter <s>`,
/// default 1.5), and `-demoPals <n>` adds n more asleep ones (a long list).
extension DemoHost {
    // MARK: requests

    /// The `pals.*` methods; nil for any other.
    func dispatchPals(_ method: String, _ p: JSONValue) async throws -> JSONValue? {
        switch method {
        case RPCMethod.palsList:
            normalizePals()
            return ["pals": try .from(pals), "others": try .from(otherSessions), "hooks": .bool(hooksEnabled)]
        case RPCMethod.palsHistory:
            let id = p["id"]?.stringValue ?? ""
            guard let log = palLogs[id] else { throw DemoError(message: "没有这个 Pal") }
            let limit = Int(p["limit"]?.doubleValue ?? 50)
            var upTo = log.endIndex
            if let before = p["before"]?.stringValue, let i = log.firstIndex(where: { $0.id == before }) { upTo = i }
            var out: JSONValue = ["messages": try .from(Array(log[..<upTo].suffix(limit)))]
            // The newest page has the reply being written (as the host's does).
            if p["before"] == nil, let w = palWriting[id], case .object(var o) = out {
                o["streaming"] = try .from(w)
                out = .object(o)
            }
            return out
        case RPCMethod.palsSend:
            let id = p["id"]?.stringValue ?? ""
            let text = (p["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let pal = pals.first(where: { $0.id == id }) else { throw DemoError(message: "没有这个 Pal") }
            guard pal.status != .stopped else { throw DemoError(message: "\(pal.displayName)停了") }
            // Images and files go with the words, as Palo takes them (pals-prd §15).
            let atts = try attachments(p["attachments"])
            guard !text.isEmpty || atts != nil else { throw DemoError(message: "要说的话不能是空的") }
            // The first words name a session nobody has named.
            if Pal.isUnnamed(pal.name), !text.isEmpty {
                let first = text.replacingOccurrences(of: "\n", with: " ")
                setPal(id) { $0.name = String(first.prefix(16)) }
            }
            // Asleep: its session resumes first; the words go in once it's up.
            if pal.isAsleep || pal.status == .starting { await wakePal(id) }
            var m = palMessage(id, role: .user, text: text, channel: .app)
            m.clientMsgId = p["clientMsgId"]?.stringValue
            m.attachments = atts
            appendPal(m)
            palTurns[id]?.cancel()
            palTurns[id] = Task { await self.palAnswers(id, to: text) }
            return ["id": .string(m.id), "seq": .number(Double(m.seq))]
        case RPCMethod.palsWake:
            let id = p["id"]?.stringValue ?? ""
            guard pals.contains(where: { $0.id == id }) else { throw DemoError(message: "没有这个 Pal") }
            await wakePal(id)
            return ["pal": try .from(pals.first { $0.id == id })]
        case RPCMethod.palsRename:
            let id = p["id"]?.stringValue ?? ""
            let want = (p["name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard pals.contains(where: { $0.id == id }) else { throw DemoError(message: "没有这个 Pal") }
            guard !want.isEmpty else { throw DemoError(message: "名字不能是空的") }
            guard want.count <= 40 else { throw DemoError(message: "名字太长了（最多 40 个字）") }
            // As the host's: a name another Pal has gets a number.
            let taken = Set(pals.filter { $0.id != id }.map { $0.name.lowercased() })
            var name = want
            var n = 2
            while taken.contains(name.lowercased()) { name = "\(want) \(n)"; n += 1 }
            setPal(id) { $0.name = name }
            return ["pal": try .from(pals.first { $0.id == id })]
        case RPCMethod.palsRewind:
            // As the host's (docs/rewind-prd.md): the owner's own words only;
            // the files can go back for any but its first (from before
            // checkpoints were kept); `-demoNoCheckpoints YES`: never.
            let id = p["id"]?.stringValue ?? ""
            let mid = p["messageId"]?.stringValue ?? ""
            guard let pal = pals.first(where: { $0.id == id }), let log = palLogs[id] else { throw DemoError(message: "没有这个 Pal") }
            guard let i = log.firstIndex(where: { $0.id == mid }) else { throw DemoError(message: "在对话记录里找不到这一条，没法回到这里") }
            guard log[i].role == .user, (log[i].from ?? "").isEmpty else { throw DemoError(message: "这一条不是你说的，不能回到这里") }
            let checkpoint = !UserDefaults.standard.bool(forKey: "demoNoCheckpoints")
                && log[..<i].contains { $0.role == .user && ($0.from ?? "").isEmpty }
            if p["check"]?.boolValue == true { return ["canRestoreFiles": .bool(checkpoint)] }
            guard pal.status != .busy && pal.status != .waiting else { throw DemoError(message: "它还在忙，先停下再重来") }
            let files = p["restoreFiles"]?.boolValue == true
            guard !files || checkpoint else { throw DemoError(message: "这一步之前的代码没法恢复") }
            await pause(files ? 1.2 : 0.6) // its process ends (the files go back), then it's forked
            palTurns[id]?.cancel()
            palTurns[id] = nil
            palWriting[id] = nil
            // Its process ended: its open cards go (answered no), as the host's do.
            for j in approvals.indices where approvals[j].source?.id == id && approvals[j].status == .pending {
                approvals[j].status = .denied
                approvals[j].decidedAt = Date().epochMillis
                approvals[j].decidedBy = "rewind"
                emit(RPCEventName.approvalUpdated, approvals[j])
            }
            setPal(id) { $0.status = .idle; $0.pending = 0 }
            let gone = log[i...].map(\.id)
            palLogs[id] = Array(log[..<i])
            emit(RPCEventName.chatRewound, ChatRewound(id: mid, ids: gone, pal: id))
            return ["text": .string(log[i].text), "filesRestored": .bool(files)]
        case RPCMethod.palsStop:
            let id = p["id"]?.stringValue ?? ""
            guard pals.contains(where: { $0.id == id }) else { throw DemoError(message: "没有这个 Pal") }
            palTurns[id]?.cancel()
            palTurns[id] = nil
            setPal(id) { $0.status = .idle }
            return ["ok": true]
        case RPCMethod.palsAdopt:
            let sid = p["sessionId"]?.stringValue ?? ""
            if p["cancel"]?.boolValue == true {
                // The owner stopped waiting: so does the demo's computer.
                guard waitingAdoptions.remove(sid) != nil else {
                    if let pal = pals.first(where: { $0.sessionId == sid }) { return ["cancelled": false, "pal": try .from(pal)] }
                    return ["cancelled": false]
                }
                setOther(sid) { $0.adopting = nil }
                return ["cancelled": true]
            }
            // Already a Pal: the same one.
            if let pal = pals.first(where: { $0.sessionId == sid }) { return ["pal": try .from(pal)] }
            if recentSessions.contains(where: { $0.sessionId == sid }) {
                await pause(1.5) // nothing to stop: its record is resumed under the host
                if let why = UserDefaults.standard.string(forKey: "demoAdoptError"), !why.isEmpty {
                    throw DemoError(message: why)
                }
                guard let pal = adoptRecent(sid) else { throw DemoError(message: "这个对话已经找不到了") }
                return ["pal": try .from(pal)]
            }
            guard let s = otherSessions.first(where: { $0.id == sid }) else { throw DemoError(message: "这个会话已经没有了") }
            if s.kind == .terminal {
                // Quit in its terminal first; the demo's owner does it a few seconds later.
                waitingAdoptions.insert(sid)
                setOther(sid) { $0.adopting = true }
                let after = UserDefaults.standard.object(forKey: "demoAdoptAfter") != nil
                    ? UserDefaults.standard.double(forKey: "demoAdoptAfter") : 6
                if after > 0 {
                    Task {
                        await self.pause(after)
                        guard self.waitingAdoptions.contains(sid) else { return }
                        self.finishAdoption(sid)
                    }
                }
                return ["waiting": "exit-in-terminal"]
            }
            await pause(1.5) // `claude stop`, then resumed under the host
            guard let pal = finishAdoption(sid) else { throw DemoError(message: "这个会话已经没有了") }
            return ["pal": try .from(pal)]
        case RPCMethod.palsRecent:
            if UserDefaults.standard.bool(forKey: "demoRecentEmpty") { return ["sessions": .array([])] }
            await pause(0.4) // the host reads the records on disk
            var list = recentSessions.sorted { $0.lastModified > $1.lastModified }
            if let folder = p["folder"]?.stringValue, !folder.isEmpty {
                list = list.filter { $0.cwd == folder || $0.cwd.hasSuffix("/" + folder) }
            }
            let limit = Int(p["limit"]?.doubleValue ?? 50)
            return ["sessions": try .from(Array(list.prefix(min(50, max(1, limit)))))]
        case RPCMethod.palsRelease:
            let id = p["id"]?.stringValue ?? ""
            guard let pal = pals.first(where: { $0.id == id }) else { throw DemoError(message: "没有这个 Pal") }
            palTurns[id]?.cancel()
            pals.removeAll { $0.id == id }
            emitPals()
            // As the host gives it: into its folder, then resume its record.
            let folder = pal.cwd.contains(" ") ? "'\(pal.cwd)'" : pal.cwd
            return ["resumeCommand": .string("cd \(folder) && claude --resume \(pal.sessionId)")]
        case RPCMethod.palsRemove:
            let id = p["id"]?.stringValue ?? ""
            guard pals.contains(where: { $0.id == id }) else { throw DemoError(message: "没有这个 Pal") }
            palTurns[id]?.cancel()
            pals.removeAll { $0.id == id }
            emitPals()
            return ["ok": true]
        default:
            return nil
        }
    }

    // MARK: changes

    /// The whole list, as `pals.list` gives it.
    func emitPals() {
        normalizePals()
        emit(RPCEventName.palsUpdated, ["pals": (try? JSONValue.from(pals)) ?? .array([]),
                                        "others": (try? JSONValue.from(otherSessions)) ?? .array([]),
                                        "hooks": .bool(hooksEnabled)] as JSONValue)
    }

    /// What the host works out: the dot's state, and who has been left alone
    /// long enough to be put away (no workspace, untouched for 3 days).
    func normalizePals() {
        let now = Date().epochMillis
        for i in pals.indices {
            pals[i].attention = Pal.derivedAttention(status: pals[i].status, pending: pals[i].pending,
                                              finishedAt: pals[i].finishedAt, seenAt: pals[i].seenAt)
            pals[i].folded = pals[i].workspaceId == nil && now - (pals[i].updatedAt ?? now) > 3 * 24 * 3_600_000
        }
    }

    func emitWorkspaces() {
        emit(RPCEventName.workspacesUpdated, ["workspaces": (try? JSONValue.from(workspaces)) ?? .array([])] as JSONValue)
    }

    func setPal(_ id: String, _ change: (inout Pal) -> Void) {
        guard let i = pals.firstIndex(where: { $0.id == id }) else { return }
        change(&pals[i])
        pals[i].pending = approvals.filter { $0.isPending && $0.source?.isPal == true && $0.source?.id == id }.count
            + questions.filter { $0.isPending && $0.source?.isPal == true && $0.source?.id == id }.count
        emitPals()
    }

    func setOther(_ id: String, _ change: (inout CCSession) -> Void) {
        guard let i = otherSessions.firstIndex(where: { $0.id == id }) else { return }
        change(&otherSessions[i])
        otherSessions[i].updatedAt = Date().epochMillis
        emitPals()
    }

    /// The next message in a Pal's conversation (its own numbering).
    func palMessage(_ id: String, role: ChatRole, text: String, channel: ChatChannel = .app, from: String? = nil) -> ChatMessage {
        let n = max(palLogs[id]?.last?.seq ?? 0, palSeqFloor[id] ?? 0) + 1
        palSeqFloor[id] = n
        var m = ChatMessage(seq: n, id: "\(id)-\(n)", role: role, kind: .text, text: text, channel: channel, ts: Date().epochMillis)
        m.pal = id
        m.from = from
        return m
    }

    /// Into its conversation, and out as `chat.message {pal}`.
    func appendPal(_ m: ChatMessage) {
        guard let id = m.pal else { return }
        palLogs[id, default: []].append(m)
        emit(RPCEventName.chatMessage, m)
    }

    /// It's a Pal now: out of the others, under the same name, its record resumed.
    @discardableResult
    func finishAdoption(_ sid: String) -> Pal? {
        waitingAdoptions.remove(sid)
        guard let s = otherSessions.first(where: { $0.id == sid }) else { return nil }
        otherSessions.removeAll { $0.id == sid }
        let id = "pal-\(nextID("p"))"
        let pal = Pal(id: id, name: s.name, cwd: s.cwd, sessionId: s.id, status: s.status == .waiting ? .waiting : .idle,
                      lastLine: s.lastLine, model: "claude-opus-5-5", createdBy: .owner)
        pals.append(pal)
        // Its record so far, as Claude Code kept it.
        var log: [ChatMessage] = []
        for line in sessionLines(for: s) {
            let n = Int64(log.count + 1)
            var m = ChatMessage(seq: n, id: "\(id)-\(n)", role: line.role, kind: .text, text: line.text,
                                channel: line.role == .user ? .cli : .app, ts: Date().epochMillis - Int64(60_000 * (10 - log.count)))
            m.pal = id
            log.append(m)
        }
        palLogs[id] = log
        // Its waiting card is the Pal's now.
        for i in questions.indices where questions[i].source?.id == sid && questions[i].isPending {
            questions[i].source = CardSource(kind: .pal, id: id, name: pal.name)
            emit(RPCEventName.questionUpdated, questions[i])
        }
        for i in approvals.indices where approvals[i].source?.id == sid && approvals[i].isPending {
            approvals[i].source = CardSource(kind: .pal, id: id, name: pal.name)
            emit(RPCEventName.approvalUpdated, approvals[i])
        }
        setPal(id) { _ in }
        return pals.first { $0.id == id }
    }

    // MARK: recent conversations (§10)

    /// A conversation that ended is a Pal now: its record resumed, under its title.
    @discardableResult
    func adoptRecent(_ sid: String) -> Pal? {
        guard let r = recentSessions.first(where: { $0.sessionId == sid }) else { return nil }
        recentSessions.removeAll { $0.sessionId == sid }
        let id = "pal-\(nextID("p"))"
        let lines = DemoHost.recentLines[sid] ?? [(.user, r.title), (.assistant, "好，我先看一下相关的文件。")]
        let pal = Pal(id: id, name: r.displayTitle, cwd: r.cwd, sessionId: sid, status: .idle, lastLine: lines.last?.1,
                      model: "claude-opus-5-5", createdBy: .owner, updatedAt: Date().epochMillis)
        pals.insert(pal, at: 0)
        palLogs[id] = lines.enumerated().map { i, l in
            var m = ChatMessage(seq: Int64(i + 1), id: "\(id)-\(i + 1)", role: l.0, kind: .text, text: l.1,
                                channel: l.0 == .user ? .cli : .app,
                                ts: r.lastModified - Int64(60_000 * (lines.count - i)))
            m.pal = id
            return m
        }
        setPal(id) { _ in }
        return pals.first { $0.id == id }
    }

    /// The recent conversation a request names (its folder or words in its
    /// title), else the newest.
    func recentMatch(_ text: String) -> RecentSession? {
        let newest = recentSessions.sorted { $0.lastModified > $1.lastModified }
        let words = text.split(whereSeparator: { " ，,。的里那个把接过来管对话".contains($0) }).map(String.init).filter { !$0.isEmpty }
        func score(_ r: RecentSession) -> Int {
            let folder = (r.cwd as NSString).lastPathComponent.lowercased()
            return words.reduce(0) { n, w in
                n + (folder == w.lowercased() ? 2 : 0) + (r.title.contains(w) ? 1 : 0)
            }
        }
        return newest.max { score($0) < score($1) || (score($0) == score($1) && $0.lastModified < $1.lastModified) } ?? newest.first
    }

    /// The assistant asks before adopting it: a `pal_adopt` card.
    func proposeAdopting(_ r: RecentSession) {
        seq += 1
        var m = ChatMessage(seq: seq, id: "m\(seq)", role: .assistant, kind: .palAdopt,
                            text: "接管「\(r.displayTitle)」（\(CCSession.shortPath(r.cwd))）？", channel: .system,
                            ts: Date().epochMillis)
        m.adoption = PalAdoptProposal(id: nextID("pa"), sessionId: r.sessionId, cwd: r.cwd, title: r.title)
        messages.append(m)
        emit(RPCEventName.chatMessage, m)
    }

    /// 接管 / 不用 on a `pal_adopt` card (`helper.decide`); nil when the
    /// proposal isn't one.
    func decideAdoptCard(_ pid: String, action: String?) async throws -> JSONValue? {
        guard let i = messages.firstIndex(where: { $0.adoption?.id == pid }), var card = messages[i].adoption else { return nil }
        // Answered for good; one that failed can be tapped again (as the host's).
        guard card.status != .adopted, card.status != .discarded else {
            return card.palId.flatMap { id in pals.first { $0.id == id } }.map { ["pal": (try? JSONValue.from($0)) ?? .null] } ?? [:]
        }
        var result: JSONValue = [:]
        switch action {
        case "create":
            await pause(1.5)
            if let why = UserDefaults.standard.string(forKey: "demoAdoptError"), !why.isEmpty {
                card.status = .failed
                card.note = why
            } else if let pal = pals.first(where: { $0.sessionId == card.sessionId }) ?? adoptRecent(card.sessionId) {
                card.status = .adopted
                card.palId = pal.id
                card.note = nil
                result = ["pal": try .from(pal)]
            } else {
                card.status = .failed
                card.note = "这个对话已经找不到了"
            }
        case "discard":
            card.status = .discarded
            card.note = nil
        default:
            throw DemoError(message: "看不懂这个操作")
        }
        messages[i].adoption = card
        emit(RPCEventName.chatMessage, messages[i])
        return result
    }

    /// What the demo's other sessions said before they were adopted.
    private func sessionLines(for s: CCSession) -> [(role: ChatRole, text: String)] {
        switch s.name {
        case "修登录跳转":
            return [(.user, "登录以后会跳回首页，应该回到原来那一页"),
                    (.assistant, "找到了：跳转时把原来的地址丢了。我改成登录前先记下来。"),
                    (.assistant, "在跑登录相关的测试，还剩 3 个文件。")]
        case "问卷数据清洗":
            return [(.user, "把问卷数据清洗一下，输出一份干净的表"),
                    (.assistant, "1,200 份问卷里有 37 份没填收入。")]
        default:
            return [(.assistant, s.lastLine ?? "")]
        }
    }

    // MARK: looking without taking over (§14)

    /// A session that isn't a Pal, as `sessions.history` reads it: one of the
    /// others (the busy one adds a line every few seconds while it's looked
    /// at), or a conversation that ended lately.
    func viewedSessionLog(_ id: String) -> [CCMessage]? {
        if let log = viewedLogs[id] { return log }
        let now = Date().epochMillis
        var lines: [(CCMessageRole, String, String?)]
        if let s = otherSessions.first(where: { $0.id == id }) {
            lines = sessionLines(for: s).map { ($0.role == .user ? .owner : .assistant, $0.text, nil) }
            if s.id == "cc-login" {
                lines.insert((.peer, "你好，我是笔记整理。登录页的文案在 notes/产品/登录.md 里，主人上周改过一版：按钮叫「继续」，不叫「下一步」；忘记密码的链接放在输入框下面，不放在按钮旁边；错误提示用一句话说清楚哪里不对，不要只写「出错了」。改完跳转以后，顺手把这几处也对一下。", "笔记整理"), at: 1)
            }
        } else if let r = recentSessions.first(where: { $0.sessionId == id }) {
            lines = (DemoHost.recentLines[id] ?? [(.user, r.title), (.assistant, "好，我先看一下相关的文件。")])
                .map { ($0.0 == .user ? .owner : .assistant, $0.1, nil) }
        } else {
            return nil
        }
        let log = lines.enumerated().map { i, l in
            CCMessage(id: "\(id)-v\(i + 1)", ts: now - Int64(60_000 * (lines.count - i)), role: l.0, text: l.1, from: l.2)
        }
        viewedLogs[id] = log
        if otherSessions.first(where: { $0.id == id })?.status == .busy, !viewedTails.contains(id) {
            viewedTails.insert(id)
            let after = UserDefaults.standard.object(forKey: "demoTailEvery") != nil
                ? UserDefaults.standard.double(forKey: "demoTailEvery") : 4
            Task {
                for n in 1...6 {
                    await self.pause(after)
                    guard self.otherSessions.contains(where: { $0.id == id }) else { return }
                    self.viewedLogs[id, default: []].append(CCMessage(id: "\(id)-t\(n)", ts: Date().epochMillis, role: .assistant,
                                                                      text: "第 \(n) 个测试文件跑完了，都通过。"))
                }
            }
        }
        return log
    }

    // MARK: asleep and awake (§12)

    /// An asleep Pal's session resumes (`starting` meanwhile); one awake is
    /// left as it is. Words that come meanwhile wait for the same wake.
    func wakePal(_ id: String) async {
        if let t = palWakes[id] { return await t.value }
        guard pals.first(where: { $0.id == id })?.isAsleep == true else { return }
        setPal(id) { $0.status = .starting }
        let after = UserDefaults.standard.object(forKey: "demoWakeAfter") != nil
            ? UserDefaults.standard.double(forKey: "demoWakeAfter") : 1.5
        let t = Task {
            await self.pause(after)
            self.setPal(id) { $0.status = .idle; $0.updatedAt = Date().epochMillis }
        }
        palWakes[id] = t
        await t.value
        palWakes[id] = nil
    }

    // MARK: turns

    /// The owner said something: it works on it, streams its answer, and is idle again.
    func palAnswers(_ id: String, to text: String) async {
        setPal(id) { $0.status = .busy; $0.lastLine = text }
        await pause(0.8)
        guard !Task.isCancelled else { return }
        let reply = "好的，按你说的办。我先把要改的地方列出来，再一处一处改，改完跑一遍测试告诉你结果。"
        await streamPal(id, reply)
    }

    /// Its card was answered: it carries on, then says what came of it.
    func palCardAnswered(_ id: String, allowed: Bool) {
        setPal(id) { $0.status = .busy }
        palTurns[id]?.cancel()
        palTurns[id] = Task {
            await self.pause(1.2)
            guard !Task.isCancelled else { return }
            await self.streamPal(id, allowed ? "构建通过了，没有报错。列表页可以看了，接下来做详情页。" : "好的，不跑了。你想先看哪一部分？")
        }
    }

    /// A reply in small pieces (`chat.delta {pal}`), then the whole of it.
    func streamPal(_ id: String, _ reply: String) async {
        setPal(id) { $0.status = .busy }
        var n = (palLogs[id]?.last?.seq ?? 0) + 1
        let rid = "\(id)-r\(n)"
        var acc = ""
        for piece in DemoHost.chunks(reply) {
            guard !Task.isCancelled else { break }
            acc += piece
            palWriting[id] = SyncResult.Streaming(id: rid, text: acc)
            emit(RPCEventName.chatDelta, ChatDelta(id: rid, text: piece, pal: id))
            await pause(0.05)
        }
        palWriting[id] = nil
        n = (palLogs[id]?.last?.seq ?? 0) + 1
        var m = ChatMessage(seq: n, id: rid, role: .assistant, kind: .text, text: acc, channel: .app, ts: Date().epochMillis)
        m.pal = id
        appendPal(m)
        setPal(id) { $0.status = .idle; $0.lastLine = acc; $0.finishedAt = Date().epochMillis; $0.updatedAt = Date().epochMillis }
        palTurns[id] = nil
    }

    // MARK: seed

    struct PalSeed {
        var pals: [Pal]
        var logs: [String: [ChatMessage]]
        var others: [CCSession]
        var approvals: [Approval]
        var questions: [Question]
        /// The assistant proposes opening a Pal in the conversation.
        var proposal: ChatMessage
        /// Conversations that ended lately, in three folders.
        var recent: [RecentSession]
        /// One workspace of two sessions.
        var workspaces: [Workspace]
    }

    /// What the recent conversations said, by session (their records once adopted).
    static let recentLines: [String: [(ChatRole, String)]] = [
        "7c1e9a52-3f0b-4d8e-9a61-0b5c2e7d4f10": [
            (.user, "首页改成两栏布局，左边放文章列表，右边放简介"),
            (.assistant, "好，我先看一下首页现在的结构。"),
            (.assistant, "两栏改好了，窄屏下自动变回一栏。还差简介的头像没换。"),
        ],
        "2b8d4f61-9e3a-4c7b-8d20-6a1f5e9c3b72": [
            (.user, "手机上点菜单没反应"),
            (.assistant, "找到了：菜单按钮被顶部的横幅盖住了。我把横幅的层级调低了，你在手机上再试一下。"),
        ],
        "e4a7c3d9-1b6f-4e2a-b8c5-9d0e7f3a2c61": [
            (.user, "收藏页加上按标签筛选"),
            (.assistant, "加好了：顶部一排标签，点一个只看这类菜谱，再点一次取消。"),
        ],
        "5f2c8e1a-7d4b-4a9c-a3e6-1c8b0d5f7e24": [
            (.user, "整理一下十一月去东京的行程，按天排"),
            (.assistant, "排好了，一共 5 天，第三天下午空着，可以留给购物。"),
        ],
    ]

    /// 网站帮手 waits to run a long command; 笔记整理 is idle; 博客改版 and
    /// 照片整理 are asleep; 修登录跳转 runs in a terminal and 问卷数据清洗 in
    /// the background, asking a question.
    static func seedPals(now: Int64, nextSeq: Int64) -> PalSeed {
        let min: Int64 = 60_000
        let hour = 60 * min
        let pals = [
            Pal(id: "pal-site", name: "网站帮手", cwd: "/Users/demo/code/site", sessionId: "5d821f3c-7a1e-4c55-9b0e-2f6d81a4c901",
                status: .waiting, lastLine: "列表页做完了，跑一下构建看看有没有报错。", pending: 1, model: "claude-opus-5-5",
                createdBy: .palo),
            Pal(id: "pal-notes", name: "笔记整理", cwd: "/Users/demo/Documents/notes", sessionId: "9a40c2e7-1b3d-4e8f-a6c5-77d0e3b2f418",
                status: .idle, lastLine: "这周的 12 篇笔记都归好类了，标签也补上了。", model: "claude-sonnet-4-5", createdBy: .owner),
            // Idle a while, put to sleep (§12).
            Pal(id: "pal-blog", name: "博客改版", cwd: "/Users/demo/code/blog", sessionId: "3e7b9d21-6c4a-4f8e-b2d0-8a1c5e9f7b34",
                status: .asleep, lastLine: "评论区的样式改好了，等你有空看看。", model: "claude-sonnet-4-5", createdBy: .owner,
                updatedAt: now - 2 * 24 * hour, lastWakeUsd: 0.04),
            Pal(id: "pal-photos", name: "照片整理", cwd: "/Users/demo/Pictures/整理", sessionId: "b5c1e8a4-2d7f-4a3b-9e60-4f2d8c1a7e95",
                status: .asleep, lastLine: "去年的照片按月份分好了，重复的挪进了「待删」。", model: "claude-sonnet-4-5", createdBy: .palo,
                updatedAt: now - 6 * 24 * hour),
        ]
        let others = [
            CCSession(id: "cc-login", name: "修登录跳转", cwd: "/Users/demo/code/app", kind: .terminal, status: .busy,
                      lastLine: "在跑登录相关的测试，还剩 3 个文件。", contextTokens: 95_000, updatedAt: now - 2 * min),
            CCSession(id: "cc-data", name: "问卷数据清洗", cwd: "/Users/demo/code/survey", kind: .background, status: .waiting,
                      waitingFor: "问你缺的数据怎么处理", lastLine: "1,200 份问卷里有 37 份没填收入。",
                      contextTokens: 310_000, updatedAt: now - 5 * min),
        ]
        func log(_ id: String, _ lines: [(ChatRole, String, Int64, ChatChannel, String?)]) -> [ChatMessage] {
            lines.enumerated().map { i, l in
                var m = ChatMessage(seq: Int64(i + 1), id: "\(id)-\(i + 1)", role: l.0, kind: .text, text: l.1, channel: l.3,
                                    ts: now - l.2)
                m.pal = id
                m.from = l.4
                return m
            }
        }
        // 网站帮手: a day of work before today's, so there is an older page.
        var site: [(ChatRole, String, Int64, ChatChannel, String?)] = [
            (.user, "你好，我是 Palo。主人的网站在 ~/code/site，接下来由你专门负责：先做列表页，再做详情页。", 26 * hour, .system, "Palo"),
            (.assistant, "收到。我先看一下项目结构和现有的页面。", 26 * hour - min, .app, nil),
        ]
        for i in 1...30 {
            site.append((.assistant, "第 \(i) 处样式调好了：间距统一成 8 的倍数，字号跟设计稿对齐。", 25 * hour - Int64(i) * 2 * min, .app, nil))
        }
        site += [
            (.assistant, "看完了：列表页还是空的，路由已经配好。我从数据接口开始接。", 3 * hour, .app, nil),
            (.user, "列表要能按日期排序", 2 * hour + 30 * min, .cli, nil),
            (.assistant, """
            好的，加上了按日期排序，默认最新的在前。改了这几处：

            - `ListPage.tsx`：表头加了排序按钮
            - `useItems.ts`：按 `updatedAt` 倒序
            - 测试补了两条
            """, 2 * hour + 28 * min, .app, nil),
            (.user, "设计稿在 notes/设计/列表页.md，间距和字号按那份来。", 2 * hour, .system, "Palo"),
            (.assistant, "好，我按那份设计稿调一下间距和字号。", 2 * hour - min, .app, nil),
            (.user, "先别管登录页，把列表页做完", 40 * min, .app, nil),
            (.assistant, "明白，登录页先放着。列表页做完了，跑一下构建看看有没有报错。", min, .app, nil),
        ]
        // 笔记整理: the assistant's long brief and another Pal's long request
        // (both fold on its page).
        let notes: [(ChatRole, String, Int64, ChatChannel, String?)] = [
            (.user, "每周把新笔记归类，补上标签", 5 * 24 * hour, .cli, nil),
            (.assistant, "好的，我先把现有的分类看一遍。", 5 * 24 * hour - min, .app, nil),
            (.user, """
            主人想让这周的笔记整理多做几件事，我把要求列在这里：

            1. 新笔记先按主题归到现有的 8 个分类里，实在放不进去的放到「待定」，不要新建分类。
            2. 每篇补 2 到 4 个标签，优先用已经有的标签。同义的合并，比如「读书」和「阅读」只留「阅读」。
            3. 标题是日期的笔记，按第一段的内容改一个看得懂的标题，原来的日期放到正文开头。
            4. 会议记录里提到的待办，单独抽出来放进「本周待办.md」，每条后面注明出自哪篇。
            5. 重复的笔记不要删，在较新的那篇开头写一句「和某某重复」，主人自己决定留哪篇。

            做完告诉我一共动了多少篇、新加了哪些标签，我再转告主人。
            """, 3 * hour, .system, "Palo"),
            (.assistant, "收到，按这五条来。先从分类开始。", 3 * hour - min, .app, nil),
            (.user, """
            你好，我是网站帮手。网站的「关于」页要用到主人去年写的几篇读书笔记，麻烦帮我找一下：标题里有「设计」或者「排版」的，去年写的，大概五六篇。找到以后把文件路径发给我就行，不用改内容。如果里面有讲字体怎么选的段落，也请标出来，我想直接引用到页面上。
            """, 70 * min, .system, "网站帮手"),
            (.assistant, "找到 6 篇，路径和讲字体的 3 段都发给网站帮手了。", 69 * min, .app, nil),
            (.assistant, "这周的 12 篇笔记都归好类了，标签也补上了。", 40 * min, .app, nil),
        ]
        let approvals = [
            Approval(id: "pa1", tool: "Bash", title: "运行一条命令",
                     detail: """
                     npm run build && \\
                       npm run test -- --coverage --reporter=dot && \\
                       npx playwright test tests/list-page.spec.ts --project=chromium --workers=2
                     """,
                     careful: false, status: .pending, createdAt: now - min,
                     source: CardSource(kind: .pal, id: "pal-site", name: "网站帮手")),
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
                                   text: "报销单每周都要理一遍，要不要开一个 Pal 专门管？", channel: .app, ts: now - 3 * min)
        proposal.proposal = HelperProposal(id: "hp1", name: "报销帮手", cwd: "/Users/demo/Documents/报销",
                                           duty: "每周把下载文件夹里的发票整理进报销表，缺的告诉你。", dailyUsd: 3)
        let day = 24 * hour
        let recent = [
            RecentSession(sessionId: "7c1e9a52-3f0b-4d8e-9a61-0b5c2e7d4f10", cwd: "/Users/demo/code/site",
                          title: "首页改成两栏布局", lastModified: now - 20 * hour, size: 486_000),
            RecentSession(sessionId: "2b8d4f61-9e3a-4c7b-8d20-6a1f5e9c3b72", cwd: "/Users/demo/code/site",
                          title: "修复手机上菜单点不开", lastModified: now - 3 * day, size: 152_000),
            RecentSession(sessionId: "a91d6b30-4c2e-4f7a-9b18-3e5d7c0a8f45", cwd: "/Users/demo/code/site",
                          title: "帮我看看为什么构建在 CI 上会超时，本地是好的", lastModified: now - 6 * day, size: 1_240_000),
            RecentSession(sessionId: "e4a7c3d9-1b6f-4e2a-b8c5-9d0e7f3a2c61", cwd: "/Users/demo/code/recipes",
                          title: "收藏页加上按标签筛选", lastModified: now - 2 * hour, size: 98_000),
            RecentSession(sessionId: "c6b2e8f4-5a1d-4b3c-9e7f-2d4a6c8e0b13", cwd: "/Users/demo/code/recipes",
                          title: "导入旧数据时报错", lastModified: now - 2 * day, size: 310_000),
            RecentSession(sessionId: "5f2c8e1a-7d4b-4a9c-a3e6-1c8b0d5f7e24", cwd: "/Users/demo/Documents/旅行",
                          title: "整理十一月东京行程", lastModified: now - 5 * hour, size: 64_000),
            RecentSession(sessionId: "d3f9a1c7-8e2b-4d6a-b5c4-7a0e3f1d9b86", cwd: "/Users/demo/Documents/旅行",
                          title: "比较三家酒店的退改规则", lastModified: now - 9 * day, size: 205_000),
        ]
        let blog: [(ChatRole, String, Int64, ChatChannel, String?)] = [
            (.user, "博客的评论区太挤了，改得松一点", 2 * 24 * hour + 30 * min, .cli, nil),
            (.assistant, "好，我把评论之间的间距加大，头像缩小一点。", 2 * 24 * hour + 29 * min, .app, nil),
            (.assistant, "评论区的样式改好了，等你有空看看。", 2 * 24 * hour, .app, nil),
        ]
        let photos: [(ChatRole, String, Int64, ChatChannel, String?)] = [
            (.user, "你好，我是 Palo。主人的照片在 ~/Pictures/整理，按月份分好，重复的先别删。", 7 * 24 * hour, .system, "Palo"),
            (.assistant, "去年的照片按月份分好了，重复的挪进了「待删」。", 6 * 24 * hour, .app, nil),
        ]
        var allPals = pals
        var logs = ["pal-site": log("pal-site", site), "pal-notes": log("pal-notes", notes),
                    "pal-blog": log("pal-blog", blog), "pal-photos": log("pal-photos", photos)]
        // `-demoPals <n>`: n more asleep (a long list).
        let more = UserDefaults.standard.integer(forKey: "demoPals")
        for i in stride(from: 1, through: max(0, more), by: 1) {
            let id = "pal-more-\(i)"
            allPals.append(Pal(id: id, name: "项目 \(i)", cwd: "/Users/demo/code/project-\(i)", sessionId: "more-\(i)", status: .asleep,
                               lastLine: "第 \(i) 个项目的事办完了。", createdBy: .owner, updatedAt: now - Int64(7 + i) * 24 * hour))
            logs[id] = log(id, [(.assistant, "第 \(i) 个项目的事办完了。", Int64(7 + i) * 24 * hour, .app, nil)])
        }
        // 网站帮手 and 博客改版 are tiled together; 笔记整理 finished something that is still unseen.
        for i in allPals.indices {
            switch allPals[i].id {
            case "pal-site": allPals[i].workspaceId = "ws-site"; allPals[i].updatedAt = now - min
            case "pal-blog": allPals[i].workspaceId = "ws-site"
            case "pal-notes": allPals[i].finishedAt = now - 40 * min; allPals[i].updatedAt = now - 40 * min
            default: break
            }
        }
        let workspaces = [Workspace(id: "ws-site", name: "官网改版", memberIds: ["pal-site", "pal-blog"], layout: nil,
                                    createdAt: now - 3 * 24 * hour, updatedAt: now - 2 * hour)]
        return PalSeed(pals: allPals, logs: logs,
                       others: others, approvals: approvals, questions: questions, proposal: proposal, recent: recent,
                       workspaces: workspaces)
    }
}
