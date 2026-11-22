import Foundation

// 等你的事 in the demo host, as host/src/pending.ts keeps it: the seeded
// list (every card waiting on the owner is a blocking item, plus one of the
// assistant's with options and one from the brief without), the owner's
// hand on it, answers and 聊这件. The other cards that wait on the owner
// (proposals, Ally drafts, tasks that need them) are linked items, as
// host/src/pendingLinks.ts keeps them.
extension DemoHost {
    static func seededPending(now: Int64, approvals: [Approval], questions: [Question], messages: [ChatMessage],
                              assistant: String) -> [PendingItem] {
        let min: Int64 = 60_000
        var items: [PendingItem] = []
        for a in approvals where a.isPending {
            items.append(item(approval: a, assistant: assistant, messageId: messages.first { $0.approvalId == a.id }?.id))
        }
        for q in questions where q.isPending {
            items.append(item(question: q, assistant: assistant, messageId: messages.first { $0.questionId == q.id }?.id))
        }
        let name = assistant.isEmpty ? "Palo" : assistant
        items.append(PendingItem(id: "p_meeting", source: PendingSource(kind: .palo, name: name),
                                 title: "周四和王老师的会改不改时间", context: "他提议改到周五下午 3 点，你那天下午是空的。",
                                 options: ["改到周五", "维持周四"], createdAt: now - 2 * 60 * min,
                                 messageId: messages.last { $0.role == .assistant && $0.kind == .text && $0.card == nil }?.id))
        items.append(PendingItem(id: "p_flight", source: PendingSource(kind: .brief, id: "w1", name: "晨报"),
                                 title: "回国机票：现在买还是再等等", context: "现在最低 ¥4,860，比上周低 6%；离出发还有 5 周。",
                                 createdAt: now - 5 * 60 * min, messageId: messages.first { $0.card?.goalId == "w1" }?.id))
        // Decided earlier today (今天处理过).
        items.append(PendingItem(id: "p_hotel", source: PendingSource(kind: .palo, name: name), title: "上海的酒店订全季还是亚朵",
                                 options: ["全季", "亚朵"], createdAt: now - 4 * 60 * min, status: .done, conclusion: "订静安的全季",
                                 resolvedAt: now - 3 * 60 * min))
        return items
    }

    static func item(approval a: Approval, assistant: String, messageId: String?) -> PendingItem {
        let source = a.source.map { PendingSource(kind: $0.isPal ? .pal : .session, id: $0.id, name: $0.name) }
            ?? PendingSource(kind: .palo, name: assistant.isEmpty ? "Palo" : assistant)
        return PendingItem(id: "p_\(a.id)", source: source, title: a.title, context: String(a.detail.prefix(300)),
                           options: ["允许", "拒绝"], createdAt: a.createdAt, blocking: true, messageId: messageId,
                           pal: a.source?.isPal == true ? a.source?.id : nil, approvalId: a.id)
    }

    static func item(question q: Question, assistant: String, messageId: String?) -> PendingItem {
        let source = q.source.map { PendingSource(kind: $0.isPal ? .pal : .session, id: $0.id, name: $0.name) }
            ?? PendingSource(kind: .palo, name: assistant.isEmpty ? "Palo" : assistant)
        let first = q.items.first
        let one = q.items.count == 1 && first?.multiSelect == false
        let title = q.items.count > 1 ? "\(first?.question ?? "")（共 \(q.items.count) 个问题）" : first?.question ?? ""
        return PendingItem(id: "p_\(q.id)", source: source, title: title, context: first?.header,
                           options: one ? first?.options.map(\.label) : nil, createdAt: q.createdAt, blocking: true,
                           messageId: messageId, pal: q.source?.isPal == true ? q.source?.id : nil, questionId: q.id)
    }

    // MARK: following the cards

    /// The items of the proposal cards, Ally drafts and tasks waiting now.
    static func linkedItems(messages: [ChatMessage], allies: [AllyInfo], allyLogs: [String: [AllyEntry]], tasks: [AllyTask],
                            assistant: String) -> [PendingItem] {
        let palo = PendingSource(kind: .palo, name: assistant.isEmpty ? "Palo" : assistant)
        var live: [PendingItem] = []
        for m in messages where m.pal == nil {
            if m.kind == .helper, let p = m.proposal, p.isPending {
                live.append(PendingItem(id: "p_\(p.id)", source: palo, title: m.text, context: p.duty, options: ["开吧", "不用"],
                                        createdAt: m.ts, messageId: m.id, link: PendingLink(kind: .proposal, id: p.id)))
            } else if m.kind == .palAdopt, let p = m.adoption, p.isPending {
                live.append(PendingItem(id: "p_\(p.id)", source: palo, title: m.text, options: ["接管", "不用"],
                                        createdAt: m.ts, messageId: m.id, link: PendingLink(kind: .proposal, id: p.id)))
            }
        }
        for (allyId, log) in allyLogs.sorted(by: { $0.key < $1.key }) {
            let who = allies.first { $0.id == allyId }?.ownerName ?? ""
            for e in log where e.dir == .outgoing && e.status == .draft {
                live.append(PendingItem(id: "p_\(e.id)", source: PendingSource(kind: .ally, id: allyId, name: who),
                                        title: "要不要把这段话发给\(who)", context: String(e.text.prefix(300)), options: ["发送", "不发"],
                                        createdAt: e.ts, messageId: messages.last { $0.kind == .ally && $0.entryId == e.id }?.id,
                                        link: PendingLink(kind: .allyDraft, id: e.id)))
            }
        }
        for t in tasks where t.status == .needsInput {
            live.append(PendingItem(id: "p_\(t.id)", source: palo, title: "「\(t.title)」需要你", context: t.summary.isEmpty ? nil : t.summary,
                                    createdAt: t.updatedAt, link: PendingLink(kind: .task, id: t.id)))
        }
        return live
    }

    /// The proposal cards, Ally drafts and tasks waiting now each have their
    /// item; an item whose card was settled closes with what became of it.
    func syncLinkedPending() {
        let live = Self.linkedItems(messages: messages, allies: allies, allyLogs: allyLogs, tasks: tasks, assistant: settings.assistantName)
        for var item in live {
            if let cur = pendingItems.first(where: { $0.link == item.link }) {
                // Once per card; only its place in the conversation, once it's there.
                guard cur.isOpen, cur.messageId == nil, let at = item.messageId else { continue }
                item = cur
                item.messageId = at
            }
            setPending(item)
        }
        let waiting = Set(live.compactMap(\.link))
        for var item in pendingItems where item.link != nil && (item.isOpen || item.status == .snoozed) && !waiting.contains(item.link!) {
            item.status = .done
            item.resolvedAt = Date().epochMillis
            item.conclusion = linkOutcome(item.link!)
            setPending(item)
        }
    }

    private func linkOutcome(_ link: PendingLink) -> String {
        switch link.kind {
        case .proposal:
            let m = messages.first { $0.proposal?.id == link.id || $0.adoption?.id == link.id }
            switch (m?.proposal?.status, m?.adoption?.status) {
            case (.created?, _): return "开了"
            case (_, .adopted?): return "接管了"
            case (.discarded?, _), (_, .discarded?): return "不用了"
            case (.expired?, _), (_, .expired?): return "过期了"
            default: return "已经不用定了"
            }
        case .allyDraft:
            return allyLogs.values.joined().first { $0.id == link.id }?.status == .rejected ? "没发" : "发了"
        case .task:
            return tasks.first { $0.id == link.id }?.status == .running ? "接着做了" : "这件已经结束"
        case .unknown:
            return "已经不用定了"
        }
    }

    func pendingFollow(question q: Question) {
        if q.isPending {
            guard !pendingItems.contains(where: { $0.questionId == q.id }) else { return }
            setPending(Self.item(question: q, assistant: settings.assistantName, messageId: messages.first { $0.questionId == q.id }?.id))
            return
        }
        guard var i = pendingItems.first(where: { $0.questionId == q.id }), i.isOpen else { return }
        i.status = .done
        i.resolvedAt = Date().epochMillis
        i.conclusion = q.answers.map { $0.values.sorted().joined(separator: "、") }.flatMap { $0.isEmpty ? nil : $0 } ?? "没等到回答"
        setPending(i)
    }

    func pendingFollow(approval a: Approval) {
        if a.isPending {
            guard !pendingItems.contains(where: { $0.approvalId == a.id }) else { return }
            setPending(Self.item(approval: a, assistant: settings.assistantName, messageId: messages.first { $0.approvalId == a.id }?.id))
            return
        }
        guard var i = pendingItems.first(where: { $0.approvalId == a.id }), i.isOpen else { return }
        i.status = .done
        i.resolvedAt = Date().epochMillis
        i.conclusion = a.status == .allowed ? "允许了" : a.status == .denied ? "拒绝了" : "没等到回答"
        setPending(i)
    }

    func setPending(_ item: PendingItem) {
        if let i = pendingItems.firstIndex(where: { $0.id == item.id }) { pendingItems[i] = item } else { pendingItems.append(item) }
        emit(RPCEventName.pendingUpdated, item)
    }

    // MARK: the methods

    func dispatchPending(_ method: String, _ p: JSONValue) async throws -> JSONValue? {
        switch method {
        case RPCMethod.pendingList:
            return ["items": try .from(pendingItems)]
        case RPCMethod.pendingUpdate:
            guard var item = pendingItems.first(where: { $0.id == p["id"]?.stringValue }) else { throw DemoError(message: "没有这件事") }
            switch p["action"]?.stringValue {
            case "ignore": item.status = .ignored; item.resolvedAt = Date().epochMillis
            case "snooze": item.status = .snoozed; item.resolvedAt = Date().epochMillis
            case "later": item = try putOff(item)
            case "reopen":
                guard !item.isCard || item.isOpen else { throw DemoError(message: "这个提问已经结束，放不回去了") }
                item.status = .open; item.resolvedAt = nil; item.conclusion = nil
            default: throw DemoError(message: "不认识的操作")
            }
            setPending(item)
            return ["item": try .from(item)]
        case RPCMethod.pendingAnswer:
            guard let item = pendingItems.first(where: { $0.id == p["id"]?.stringValue }) else { throw DemoError(message: "没有这件事") }
            let answer = (p["answer"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { throw DemoError(message: "要回答点什么") }
            guard item.isOpen else { return ["item": try .from(item)] }
            if let link = item.link {
                // The card's button, for an option; the owner's own words go to the assistant, the card still waiting.
                switch (link.kind, answer) {
                case (.proposal, "开吧"), (.proposal, "接管"):
                    _ = try await dispatchPendingCard(RPCMethod.helperDecide, ["proposalId": .string(link.id), "action": "create"])
                case (.proposal, "不用"):
                    _ = try await dispatchPendingCard(RPCMethod.helperDecide, ["proposalId": .string(link.id), "action": "discard"])
                case (.allyDraft, "发送"):
                    _ = try await dispatchPendingCard(RPCMethod.allyDraftDecide, ["id": .string(link.id), "action": "send"])
                case (.allyDraft, "不发"):
                    _ = try await dispatchPendingCard(RPCMethod.allyDraftDecide, ["id": .string(link.id), "action": "discard"])
                default:
                    await answered(item, answer, stillWaiting: true)
                }
            } else if let qid = item.questionId, let q = questions.first(where: { $0.id == qid }), let first = q.items.first {
                _ = try await dispatchPendingCard(RPCMethod.questionAnswer, ["id": .string(qid), "answers": [first.question: .string(answer)]])
            } else if let aid = item.approvalId {
                _ = try await dispatchPendingCard(RPCMethod.approvalAnswer, ["id": .string(aid), "allow": .bool(answer == "允许")])
            } else {
                var done = item
                done.status = .done
                done.conclusion = answer
                done.resolvedAt = Date().epochMillis
                setPending(done)
                if item.source.kind != .pal { await answered(item, answer) }
            }
            return ["item": try .from(pendingItems.first { $0.id == item.id } ?? item)]
        case RPCMethod.pendingSurface:
            guard var item = pendingItems.first(where: { $0.id == p["id"]?.stringValue }) else { throw DemoError(message: "没有这件事") }
            if !item.isOpen, !item.isCard {
                item.status = .open; item.resolvedAt = nil; item.conclusion = nil
                setPending(item)
            }
            seq += 1
            var card = ChatMessage(seq: seq, id: "m\(seq)", role: .assistant, kind: .pending, text: item.title, channel: .system,
                                   ts: Date().epochMillis)
            card.pendingId = item.id
            messages.append(card)
            emit(RPCEventName.chatMessage, card)
            let title = item.title
            Task {
                await self.pause(0.8)
                self.post(Self.surfaceLine(title))
            }
            return ["id": .string(card.id), "seq": .number(Double(card.seq))]
        default:
            return nil
        }
    }

    /// A question or approval answered from the list goes through its own method.
    private func dispatchPendingCard(_ method: String, _ p: JSONValue) async throws -> JSONValue {
        try await dispatch(method, p)
    }

    /// The owner's answer, as theirs in the conversation, and the assistant's
    /// next line: what's left, and whether to go on now.
    private func answered(_ item: PendingItem, _ answer: String, stillWaiting: Bool = false) async {
        seq += 1
        var mine = ChatMessage(seq: seq, id: "m\(seq)", role: .user, kind: .text, text: answer, channel: .app, ts: Date().epochMillis)
        mine.pendingId = item.id
        if let card = messages.last(where: { $0.kind == .pending && $0.pendingId == item.id }) ?? item.messageId.flatMap({ id in messages.first { $0.id == id } }) {
            mine.replyTo = ReplyTo(messageId: card.id, excerpt: item.title)
        }
        mine.uuid = "u-\(mine.id)"
        messages.append(mine)
        emit(RPCEventName.chatMessage, mine)
        let left = pendingItems.filter(\.isOpen).sorted { ($0.blocking ? 1 : 0, $0.createdAt) > ($1.blocking ? 1 : 0, $1.createdAt) }
        Task {
            await self.pause(0.8)
            if stillWaiting {
                self.post("好，我记下了。那张卡还在，要定的时候点一下就行。")
            } else if let next = left.first {
                self.post("好，就按「\(answer)」办。还剩 \(left.count) 件，下一件是「\(next.title)」，现在聊吗？")
            } else {
                self.post("好，就按「\(answer)」办。等你的事都过完了。")
            }
        }
    }

    static func surfaceLine(_ title: String) -> String {
        if title.contains("机票") { return "我倾向再等一周：离出发还早，这条线过去两年 11 月中都还会降一点。你定。" }
        if title.contains("王老师") { return "改到周五对你没影响，那天下午是空的；维持周四的话我回他一句就行。" }
        return "选项都在上面，你点一个就行；也可以直接打字说你的想法。"
    }
}
