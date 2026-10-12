import Foundation

/// Pals in the demo (pals-prd §8): two Pals with their conversations, one
/// waiting on a card; a terminal session and a background one to adopt.
/// A Pal answers what the owner types by streaming a reply, the way the
/// assistant does; 接管 on the background session takes a moment, on the
/// terminal one it waits to be quit there (`-demoAdoptAfter <s>`, default 6;
/// 0 never).
extension DemoHost {
    // MARK: requests

    /// The `pals.*` methods; nil for any other.
    func dispatchPals(_ method: String, _ p: JSONValue) async throws -> JSONValue? {
        switch method {
        case RPCMethod.palsList:
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
            guard !text.isEmpty else { throw DemoError(message: "要说的话不能是空的") }
            var m = palMessage(id, role: .user, text: text, channel: .app)
            m.clientMsgId = p["clientMsgId"]?.stringValue
            appendPal(m)
            palTurns[id]?.cancel()
            palTurns[id] = Task { await self.palAnswers(id, to: text) }
            return ["id": .string(m.id), "seq": .number(Double(m.seq))]
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
        emit(RPCEventName.palsUpdated, ["pals": (try? JSONValue.from(pals)) ?? .array([]),
                                        "others": (try? JSONValue.from(otherSessions)) ?? .array([]),
                                        "hooks": .bool(hooksEnabled)] as JSONValue)
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
        let n = (palLogs[id]?.last?.seq ?? 0) + 1
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
        setPal(id) { $0.status = .idle; $0.lastLine = acc }
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
    }

    /// 网站帮手 waits to run a long command; 笔记整理 is idle; 修登录跳转 runs in
    /// a terminal and 问卷数据清洗 in the background, asking a question.
    static func seedPals(now: Int64, nextSeq: Int64) -> PalSeed {
        let min: Int64 = 60_000
        let hour = 60 * min
        let pals = [
            Pal(id: "pal-site", name: "网站帮手", cwd: "/Users/demo/code/site", sessionId: "5d821f3c-7a1e-4c55-9b0e-2f6d81a4c901",
                status: .waiting, lastLine: "列表页做完了，跑一下构建看看有没有报错。", pending: 1, model: "claude-opus-5-5",
                createdBy: .palo),
            Pal(id: "pal-notes", name: "笔记整理", cwd: "/Users/demo/Documents/notes", sessionId: "9a40c2e7-1b3d-4e8f-a6c5-77d0e3b2f418",
                status: .idle, lastLine: "这周的 12 篇笔记都归好类了，标签也补上了。", model: "claude-sonnet-4-5", createdBy: .owner),
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
        let notes: [(ChatRole, String, Int64, ChatChannel, String?)] = [
            (.user, "每周把新笔记归类，补上标签", 5 * 24 * hour, .cli, nil),
            (.assistant, "好的，我先把现有的分类看一遍。", 5 * 24 * hour - min, .app, nil),
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
        return PalSeed(pals: pals, logs: ["pal-site": log("pal-site", site), "pal-notes": log("pal-notes", notes)],
                       others: others, approvals: approvals, questions: questions, proposal: proposal)
    }
}
