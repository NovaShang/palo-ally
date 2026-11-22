import Foundation
import Testing
@testable import PaloAllyKit

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

@Suite("The harness' capability descriptor")
@MainActor
struct HarnessTests {
    @Test func helloWithAndWithoutTheDescriptor() throws {
        let old = try decode(HelloResult.self, #"{"hostName":"Mac","version":"0.1.0"}"#)
        #expect(old.harnesses == nil)
        #expect(old.harness == nil)
        let new = try decode(HelloResult.self, """
        {"hostName":"Mac","version":"0.2.0","harness":"claude-code","harnesses":{"claude-code":{"id":"claude-code","name":"Claude Code","commandPrefix":"/",
        "login":{"kind":"oauth-code","account":"Claude","fromPhone":true},"models":[{"value":"default","displayName":"Default","description":"Opus","efforts":["low","high"]}],
        "efforts":["low","medium","high","xhigh","max"],"permissionModes":["default","auto","acceptEdits","plan"],"labels":{"turbo":"Turbo"},
        "features":{"rewind":true,"restoreFiles":false,"compact":true,"questions":{"multiSelect":true,"maxOptions":4}},
        "terminal":{"exitCommand":"/exit","resumeCommand":"claude --resume {sessionId}","newCommand":"claude"},"memory":{"projectFile":"CLAUDE.md"}}}}
        """)
        #expect(new.harness == "claude-code")
        let c = try #require(new.harnesses?["claude-code"])
        #expect(c.name == "Claude Code")
        #expect(c.login == .init(kind: "oauth-code", account: "Claude", fromPhone: true))
        #expect(c.models.map(\.value) == ["default"])
        #expect(c.permissionModes == ["default", "auto", "acceptEdits", "plan"])
        #expect(c.features.rewind && !c.features.restoreFiles && c.features.questionsMultiSelect)
        // a feature it doesn't name is off
        #expect(!c.features.globalHooks)
        #expect(c.terminal.resume("abc") == "claude --resume abc")
        #expect(c.projectFile == "CLAUDE.md")
        // labels: the app's own words for ids it knows, the host's for others, else the id
        #expect(c.effortLabel("high") == EffortName.label("high"))
        #expect(c.effortLabel("turbo") == "Turbo")
        #expect(c.modeLabel("weird") == "weird")
        #expect(c.modeLabel("plan") == PermissionModeName.label("plan"))
    }

    @Test func fallbackIsTodaysLists() {
        let f = HarnessCapabilities.claudeCodeFallback
        #expect(f.efforts == ["low", "medium", "high", "xhigh", "max"])
        #expect(f.permissionModes == ["default", "auto", "acceptEdits", "plan"])
        #expect(f.terminal.exitCommand == "/exit")
        #expect(f.login.account == "Claude")
        #expect(f.features == .all)
    }

    @Test func theStoreKeepsItFromHelloAndHarnessUpdated() async throws {
        let host = DemoHost(speed: 0, pals: false)
        let store = AppStore(transport: host.transport)
        #expect(store.harness == .claudeCodeFallback) // before hello: the built-in lists
        store.start()
        _ = await until { store.connection == .online }
        #expect(store.harness.name == "Claude Code")
        #expect(store.harness.permissionModes == ["default", "auto", "acceptEdits", "plan"])
        #expect(store.harness.models.first?.value == "default")
        store.apply(event: RPCEventName.harnessUpdated, data: ["id": "claude-code", "capabilities": ["id": "claude-code", "name": "Claude Code", "permissionModes": ["default", "plan"]]])
        #expect(store.harness.permissionModes == ["default", "plan"])
    }

    @Test func detailsTakeTheirWordsAndListsFromIt() {
        var h = HarnessCapabilities.claudeCodeFallback
        h.models = [ModelOption(value: "default", displayName: "默认", efforts: ["low", "turbo"]), ModelOption(value: "haiku", displayName: "Haiku")]
        h.labels = ["turbo": "Turbo"]
        // the assistant's page before model.get has answered: the harness' models
        let early = AgentDetail(assistant: nil, status: nil, tasks: [], harness: h)
        #expect(early.models.map(\.id) == ["default", "haiku"])
        #expect(early.efforts == ["low", "turbo"])
        #expect(early.harness.effortLabel("turbo") == "Turbo")
        // once it has: model.get's
        let later = AgentDetail(assistant: ModelInfo(models: [ModelOption(value: "opus", displayName: "Opus")]), status: nil, tasks: [], harness: h)
        #expect(later.models.map(\.id) == ["opus"])
        // an older host: the built-in words, as before
        #expect(AgentDetail(assistant: nil, status: nil, tasks: []).harness.modeLabel("acceptEdits") == PermissionModeName.label("acceptEdits"))
    }
}
