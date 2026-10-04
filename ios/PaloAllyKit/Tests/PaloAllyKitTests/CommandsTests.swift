import Foundation
import Testing
@testable import PaloAllyKit

@Suite("Slash commands & models")
struct CommandsTests {
    let all = [
        SlashCommand(name: "compact"), SlashCommand(name: "context"), SlashCommand(name: "cost"),
        SlashCommand(name: "pdf"), SlashCommand(name: "simplify"), SlashCommand(name: "kill"),
    ]

    @Test func filterPrefersPrefixThenSubstring() {
        #expect(SlashCommand.filter(all, typed: "co").map(\.name) == ["compact", "context", "cost"])
        #expect(SlashCommand.filter(all, typed: "pl").map(\.name) == ["simplify"])
        #expect(SlashCommand.filter(all, typed: "", limit: 2).count == 2)
        #expect(SlashCommand.filter(all, typed: "zzz").isEmpty)
    }

    @Test func modelNames() {
        #expect(ModelName.short("claude-opus-5-5[1m]") == "Opus 5.5")
        #expect(ModelName.short("claude-sonnet-5") == "Sonnet 5")
        #expect(ModelName.short("claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(ModelName.short("glm-4.6") == "glm-4.6")
        #expect(ModelName.short("") == "默认")
        #expect(EffortName.label("xhigh") == "很深")
        #expect(EffortName.label(nil) == "默认")
    }

    @Test func decodesTolerantly() throws {
        let json = #"{"model":"claude-sonnet-5","setting":null,"effort":"high","models":[{"value":"haiku","displayName":"Haiku","efforts":[]},{"bogus":1}]}"#
        let info = try JSONDecoder().decode(ModelInfo.self, from: Data(json.utf8))
        #expect(info.effort == "high")
        #expect(info.setting == nil)
        #expect(info.models.first?.value == "haiku")
        let cmds = try JSONDecoder().decode(CommandsResult.self, from: Data(#"{"commands":[{"name":"pdf","argumentHint":"<file>"}]}"#.utf8))
        #expect(cmds.commands.first?.argumentHint == "<file>")
    }
}
