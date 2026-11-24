import Foundation
import Testing
@testable import PaloAllyKit

/// The details page's one shape (AgentDetail) from both of the host's, the
/// one status line for an agent, and an agent's memory through the store.
@MainActor
@Suite("Agent details")
struct AgentDetailTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func anAgentsDetailsFromPalsDetail() throws {
        let d = try decode(PalDetail.self, """
        {"pal":{"id":"pal_1","name":"官网","cwd":"/x","sessionId":"s","status":"busy","contextPct":40,"model":"claude-opus-5-5[1m]"},
         "contextTokens":82000,"contextWindow":200000,"costTotalUsd":1,"spentToday":0.5,
         "model":"claude-opus-5-5[1m]","effort":"high","modelOption":"opus[1m]",
         "models":[{"id":"opus","name":"Opus","efforts":["low","high","max"]},{"id":"opus[1m]","name":"Opus 1M","efforts":["low","high"]}],
         "efforts":["low","high"],"permissionMode":"auto","runningMode":"default","permissionModes":["default","auto","plan"],
         "tasks":[{"id":"t1","title":"跑测试","kind":"bg","startedAt":10,"summary":"已跑 40 个"}],
         "pastTasks":[{"id":"t0","title":"查调用方","kind":"subagent","startedAt":1,"endedAt":5,"status":"failed"}]}
        """)
        let a = AgentDetail(d)
        #expect(a.models.map(\.id) == ["opus", "opus[1m]"])
        #expect(a.model == "opus[1m]")
        #expect(a.selectedModel == "opus[1m]")
        #expect(a.runningModel == "claude-opus-5-5[1m]")
        #expect(a.effort == "high" && a.efforts == ["low", "high"])
        #expect(a.contextFill == 41) // from the tokens, not the rounded percent
        #expect(a.tasks == [AgentTask(id: "t1", title: "跑测试", kind: .background, startedAt: 10, summary: "已跑 40 个")])
        #expect(a.pastTasks.first?.kind == .subagent && a.pastTasks.first?.ending == .failed)
        #expect(a.permissionMode == "auto" && a.runningMode == "default")
        #expect(a.capabilities == .agent)
    }

    @Test func aModelNoOptionMatchesStaysUnselectedButShown() throws {
        let d = try decode(PalDetail.self, """
        {"pal":{"id":"pal_1","name":"官网","cwd":"/x","sessionId":"s","status":"idle"},"costTotalUsd":0,"spentToday":0,
         "model":"claude-haiku-4-5","models":[{"id":"opus","name":"Opus","efforts":[]}],"permissionMode":"auto","runningMode":"auto"}
        """)
        let a = AgentDetail(d)
        #expect(a.model == nil)
        #expect(a.selectedModel == "claude-haiku-4-5") // no default to fall back to: what runs
        #expect(a.runningMode == nil) // the same as the chosen one: nothing to say
    }

    @Test func theAssistantsDetailsFromItsModelListStatusAndTasks() {
        let info = ModelInfo(model: "claude-opus-5-5", setting: nil, effort: "high", models: [
            ModelOption(value: "default", displayName: "默认", efforts: ["low", "high"]),
            ModelOption(value: "haiku", displayName: "Haiku", efforts: []),
        ])
        var status = HostStatus(online: true, busy: false, model: "claude-opus-5-5", sessionId: "s", wechat: .off, version: "1")
        status.effort = "high"
        status.contextTokens = 50_000
        status.contextWindow = 200_000
        let tasks = [
            AllyTask(id: "a", title: "整理发票", summary: "", status: .running, createdAt: 1, updatedAt: 9),
            AllyTask(id: "b", title: "订机票", summary: "订好了", status: .done, createdAt: 1, updatedAt: 5),
            AllyTask(id: "c", title: "问一下", summary: "", status: .needsInput, createdAt: 1, updatedAt: 7),
        ]
        let a = AgentDetail(assistant: info, status: status, tasks: tasks)
        #expect(a.model == nil) // the default: nothing saved
        #expect(a.selectedModel == "default")
        #expect(a.efforts == ["low", "high"])
        #expect(a.contextFill == 25)
        #expect(a.tasks.map(\.id) == ["a", "c"])
        #expect(a.tasks.last?.needsYou == true)
        #expect(a.pastTasks.map(\.id) == ["b"])
        #expect(a.pastTasks.first?.ending == .done && a.pastTasks.first?.endedAt == 5)
        #expect(a.capabilities == .assistant)
        let onHaiku = AgentDetail(assistant: ModelInfo(model: "claude-haiku-4-5", setting: "haiku", models: info.models), status: nil, tasks: [])
        #expect(onHaiku.selectedModel == "haiku" && onHaiku.efforts.isEmpty)
    }

    @Test func theTilesItHas() {
        let full = AgentDetail(permissionMode: "auto", permissionModes: ["auto", "plan"], capabilities: .agent)
        #expect(full.tiles(memory: true, terminal: true) == [.history, .memory, .permissions, .terminal])
        // what its host or harness can't do is left out
        #expect(AgentDetail(capabilities: .agent).tiles(memory: false, terminal: false) == [.history])
        #expect(AgentDetail(capabilities: .assistant).tiles(memory: true, terminal: true) == [.goals, .history, .memory, .settings])
    }

    @Test func theDepthBars() {
        var d = AgentDetail(effort: "high", efforts: ["low", "medium", "high", "xhigh", "max"], capabilities: .agent)
        #expect(d.depthIndex == 2)
        #expect((0..<5).map { AgentDetail.barHeight($0, of: 5) } == [12, 19, 26, 33, 40])
        #expect((0..<3).map { AgentDetail.barHeight($0, of: 3) } == [12, 26, 40])
        #expect(AgentDetail.barHeight(0, of: 1) == 40)
        // the default, or one it isn't offered: none filled
        d.effort = nil
        #expect(d.depthIndex == nil)
        d.effort = "ultra"
        #expect(d.depthIndex == nil)
    }

    @Test func anAgentBeforeItsHostHasTold() {
        var pal = Pal(id: "p", name: "官网", cwd: "/x", sessionId: "s", status: .idle, model: "claude-opus-5-5", contextPct: 41)
        pal.effort = "max"
        let d = AgentDetail(early: pal, harness: .claudeCodeFallback)
        #expect(d.modelName == "Opus 5.5" && d.models.isEmpty)
        #expect(d.depthIndex == 4 && d.contextFill == 41)
        // an older host doesn't say its permission mode
        #expect(d.tiles(memory: true, terminal: true) == [.history, .memory, .terminal])
    }

    @Test func theAssistantIsCompactedByItsHarnessCommandAndAnAgentsTaskStops() async throws {
        let host = DemoHost(speed: 0, pals: true)
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        store.replyDraft = ReplyTo(messageId: "m1", excerpt: "引用")
        store.compactAssistant()
        #expect(store.replyDraft?.excerpt == "引用") // still waiting in the composer
        #expect(await until { store.status?.contextPct == 15 })
        #expect(await host.lastParams["chat.send"]?["text"] == .string("/compact"))
        #expect(await host.lastParams["chat.send"]?["replyTo"] == nil)
        let before = try await store.palDetail(id: "pal-site").tasks.map(\.id)
        #expect(before == ["t_run", "t_sub"])
        try await store.stopTask(id: "pal-site", taskId: "t_run")
        #expect(try await store.palDetail(id: "pal-site").tasks.map(\.id) == ["t_sub"])
    }

    @Test func anAgentsLineSaysWhatItDoesElseItsStateInTheOneVocabulary() {
        func pal(_ s: PalStatus, activity: String? = nil, note: String? = nil, pending: Int = 0) -> Pal {
            Pal(id: "p", name: "官网", cwd: "/x", sessionId: "s", status: s, pending: pending, activity: activity, note: note)
        }
        #expect(AgentStatusLine.of(pal(.busy, activity: "在跑测试")) == AgentStatusLine(kind: .working, text: "在跑测试…"))
        #expect(AgentStatusLine.of(pal(.busy)).text == "在想…")
        #expect(AgentStatusLine.of(pal(.idle)) == AgentStatusLine(kind: .idle, text: "空闲"))
        #expect(AgentStatusLine.of(pal(.waiting, pending: 1)).dot == .waiting)
        #expect(AgentStatusLine.of(pal(.waiting, pending: 1)).text == "等你")
        #expect(AgentStatusLine.of(pal(.stopped, note: "今天的花费到上限了")).text == "今天的花费到上限了")
        var bg = pal(.idle)
        bg.tasksRunning = 2
        #expect(AgentStatusLine.of(bg) == AgentStatusLine(kind: .tasks, text: "2 件事在做"))
        #expect(AgentStatusLine.of(bg).dot == .working)
        #expect([StatusDotKind.working, .waiting, .done, .idle].map(\.word) == ["在忙", "等你", "做完了", "空闲"])
    }

    @Test func anAgentsMemoryThroughTheStoreWithItsOwnConflictWords() async throws {
        let host = DemoHost(speed: 0, pals: true)
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        // the assistant's, as before (no agent sent)
        let mine = try await store.memoryFiles()
        #expect(mine.contains { $0.path == "user.md" })
        #expect(await host.lastParams["memory.list"]?["agent"] == nil)
        // an agent's: its CLAUDE.md and project memory
        let site = try await store.memoryFiles(agent: "pal-site")
        #expect(await host.lastParams["memory.list"]?["agent"] == .string("pal-site"))
        #expect(site.map(\.path) == ["CLAUDE.md", "memory/MEMORY.md", "memory/deploy.md", "memory/testing.md"])
        #expect(!site.contains { $0.path == "user.md" })
        // one with none yet: CLAUDE.md to start, read as empty
        let notes = try await store.memoryFiles(agent: "pal-notes")
        #expect(notes == [MemoryFile(path: "CLAUDE.md", scope: .core, size: 0, updatedAt: 0, missing: true)])
        #expect(try await store.readMemory(path: "CLAUDE.md", agent: "pal-notes").content == "")
        // written, then a stale save refused in the agent's words
        let r = try await store.readMemory(path: "CLAUDE.md", agent: "pal-site")
        let stamp = try await store.writeMemory(path: "CLAUDE.md", content: "# 新规矩", baseUpdatedAt: r.updatedAt, agent: "pal-site")
        #expect(try await store.readMemory(path: "CLAUDE.md", agent: "pal-site").content == "# 新规矩")
        #expect(try await store.readMemory(path: "user.md").content != "# 新规矩")
        do {
            try await store.writeMemory(path: "CLAUDE.md", content: "旧的", baseUpdatedAt: r.updatedAt, agent: "pal-site")
            Issue.record("expected a conflict")
        } catch {
            #expect(Friendly.message(error) == "这个文件刚被改过，请重新打开再改")
        }
        try await store.writeMemory(path: "CLAUDE.md", content: "# 再改", baseUpdatedAt: stamp, agent: "pal-site")
    }

    @Test func memoryFilesFromAnOlderHostHaveNoMissingFlag() throws {
        let f = try decode(MemoryFile.self, #"{"path":"user.md","scope":"core","size":3,"updatedAt":1}"#)
        #expect(!f.missing)
        let sent = String(decoding: try JSONEncoder().encode(MemoryListParams()), as: UTF8.self)
        #expect(sent == "{}") // an older host sees what it always did
    }
}
