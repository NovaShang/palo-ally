import Foundation

/// 「TL;DR」 in the demo: a canned answer after a moment, its quotes the
/// owner's latest words in the conversation asked about (so they tap
/// through to their messages); `-demoTldrError <why>` makes it fail.
/// `-demoState tldr` puts a stretch with words passed on in the assistant's
/// conversation.
extension DemoHost {
    func demoTldr(_ p: JSONValue) async throws -> JSONValue {
        await pause(1.2)
        if let why = UserDefaults.standard.string(forKey: "demoTldrError") { throw DemoError(message: why) }
        let scoped = p["scope"]?.stringValue == "pal"
        let log = scoped ? palLogs[p["id"]?.stringValue ?? ""] ?? [] : messages
        let recent = Array(log.suffix(40))
        let own = recent.filter { $0.role == .user && $0.from == nil && $0.kind == .text && !$0.text.isEmpty }.suffix(3)
        guard !own.isEmpty else { throw DemoError(message: "这段对话里还没有你说的话，没什么可总结的") }
        let result: JSONValue = [
            "points": [
                "周六中午和爸妈吃饭，餐厅要离家近、有儿童座椅",
                "助理找了三家，倾向「山间小馆」，12 点有位",
                "网站帮手那边转来：首页改版今晚不部署，明早再上",
                "还差你定下哪一家，定了就订",
            ],
            "ownWords": .array(own.map { ["text": .string($0.text), "messageId": .string($0.id), "ts": .number(Double($0.ts))] }),
            "relayed": [
                ["who": "网站帮手", "gist": "首页改版今晚不部署，明早再上线"],
                ["who": .string(settings.assistantName), "gist": "三家里「山间小馆」最近，12 点有儿童座椅"],
            ],
            "covered": .number(Double(recent.count)),
            "since": .number(Double(recent.first?.ts ?? 0)),
            "until": .number(Double(recent.last?.ts ?? 0)),
            "lastMessageId": .string(recent.last?.id ?? ""),
            "cached": false,
        ]
        return result
    }

    /// `-demoState tldr`: the owner's words, a reply passing on a session's, and more of the owner's.
    func seedTldrStretch() {
        post("周六中午想和爸妈吃个饭，帮我找家离家近的，要有儿童座椅", role: .user)
        post("""
        找了三家，都在两公里内：山间小馆、老街面馆、湖边餐厅。山间小馆 12 点还有位，有儿童座椅。

        > 转述自 网站帮手
        > 首页改版今晚不部署，明早再上线。
        """)
        post("那就山间小馆吧，记得跟他们说要靠窗的位子", role: .user)
        post("好，订好了：周六 12 点，山间小馆，4 位，靠窗，带一个儿童座椅。")
    }
}
