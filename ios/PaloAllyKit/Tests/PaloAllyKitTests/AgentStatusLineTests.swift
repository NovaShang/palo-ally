import Testing
@testable import PaloAllyKit

@Suite("Agent status line")
struct AgentStatusLineTests {
    private func task(_ id: String, _ status: TaskStatus, summary: String = "", updated: Int64 = 0, title: String = "任务") -> AllyTask {
        AllyTask(id: id, title: title, summary: summary, status: status, source: .auto, createdAt: 0, updatedAt: updated)
    }

    @Test func offlineWinsOverEverything() {
        let s = AgentStatusLine.make(offlineText: "重连中…", pendingApprovals: 2, busy: true, activity: "在跑命令", tasks: [])
        #expect(s == AgentStatusLine(kind: .offline, text: "重连中…"))
    }

    @Test func needsYouComesBeforeWork() {
        let s = AgentStatusLine.make(offlineText: nil, pendingApprovals: 1, busy: true, activity: "在跑命令", tasks: [])
        #expect(s == AgentStatusLine(kind: .needsYou, text: "1 件等你确认"))
        let mixed = AgentStatusLine.make(offlineText: nil, pendingApprovals: 1, busy: false, activity: nil,
                                         tasks: [task("a", .needsInput)])
        #expect(mixed == AgentStatusLine(kind: .needsYou, text: "2 件事等你"))
        // a question the assistant asked (AskUserQuestion)
        #expect(AgentStatusLine.make(offlineText: nil, pendingApprovals: 0, pendingQuestions: 1, busy: true, activity: nil, tasks: [])
            == AgentStatusLine(kind: .needsYou, text: "等你回答"))
        #expect(AgentStatusLine.make(offlineText: nil, pendingApprovals: 1, pendingQuestions: 1, busy: false, activity: nil, tasks: []).text
            == "2 件事等你")
    }

    @Test func whatWaitsIsReadFromTheList() {
        func item(_ id: String, blocking: Bool = false, question: String? = nil, approval: String? = nil, link: PendingLink? = nil,
                  status: PendingStatus = .open) -> PendingItem {
            PendingItem(id: id, source: PendingSource(kind: .palo, name: "Palo"), title: id, createdAt: 0, blocking: blocking,
                        status: status, questionId: question, approvalId: approval, link: link)
        }
        let line = { (items: [PendingItem]) in AgentStatusLine.make(offlineText: nil, waiting: items, busy: true, activity: "在跑命令", tasks: [task("a", .needsInput)]) }
        // A task that needs the owner counts once, as its item; a plain item is the capsule's.
        #expect(line([item("t", link: PendingLink(kind: .task, id: "a")), item("plain")]) == AgentStatusLine(kind: .needsYou, text: "1 件事等你"))
        #expect(line([item("q", blocking: true, question: "q1")]).text == "等你回答")
        #expect(line([item("a", blocking: true, approval: "a1"), item("b", blocking: true, approval: "a2")]).text == "2 件等你确认")
        #expect(line([item("d", link: PendingLink(kind: .allyDraft, id: "e"))]).text == "等你点发送")
        #expect(line([item("p", link: PendingLink(kind: .proposal, id: "hp"))]).text == "等你点头")
        // Nothing holding it up (closed, or only plain items): what it does.
        #expect(line([item("plain"), item("x", blocking: true, approval: "a3", status: .done)]) == AgentStatusLine(kind: .working, text: "在跑命令…"))
    }

    @Test func mainActivityThenOtherTasks() {
        #expect(AgentStatusLine.make(offlineText: nil, pendingApprovals: 0, busy: true, activity: "在看网页…", tasks: []).text == "在看网页…")
        #expect(AgentStatusLine.make(offlineText: nil, pendingApprovals: 0, busy: true, activity: nil, tasks: []).text == "在想…")
        let both = AgentStatusLine.make(offlineText: nil, pendingApprovals: 0, busy: true, activity: "在跑命令",
                                        tasks: [task("a", .running), task("b", .running), task("c", .done)])
        #expect(both == AgentStatusLine(kind: .working, text: "在跑命令… · 另有 2 件事"))
    }

    @Test func backgroundTasksShowCountAndLatestLine() {
        let one = AgentStatusLine.make(offlineText: nil, pendingApprovals: 0, busy: false, activity: nil,
                                       tasks: [task("a", .running, summary: "已经找到 5 张发票")])
        #expect(one == AgentStatusLine(kind: .tasks, text: "已经找到 5 张发票"))
        let fresh = AgentStatusLine.make(offlineText: nil, pendingApprovals: 0, busy: false, activity: nil,
                                         tasks: [task("a", .running, title: "比价")])
        #expect(fresh.text == "在做：比价")
        let many = AgentStatusLine.make(offlineText: nil, pendingApprovals: 0, busy: false, activity: nil, tasks: [
            task("a", .running, summary: "旧的", updated: 1),
            task("b", .running, summary: "最新的", updated: 9),
            task("c", .running, summary: "中间", updated: 5),
        ])
        #expect(many == AgentStatusLine(kind: .tasks, text: "3 件事在做 · 最新的"))
    }

    @Test func idleWhenNothingIsGoingOn() {
        let s = AgentStatusLine.make(offlineText: nil, pendingApprovals: 0, busy: false, activity: nil,
                                     tasks: [task("a", .done), task("b", .failed)])
        #expect(s == AgentStatusLine(kind: .idle, text: "空闲"))
    }
}
