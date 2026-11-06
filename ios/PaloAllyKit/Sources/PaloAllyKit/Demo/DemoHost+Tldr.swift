import Foundation

/// 「TL;DR」 in the demo: the ask (the marker) is kept as the host keeps it,
/// marked `tldr` with its instruction for words, and answered after a moment
/// with canned points, in the assistant's conversation and a session's.
/// `-demoState tldr` puts a stretch ending in a long reply (the button
/// under it) in the assistant's conversation.
extension DemoHost {
    /// As host/src/i18n/zh/hub.ts words it (the demo has no host to ask).
    static let tldrInstruction = """
    （主人点了「TL;DR」）请把这段对话最近的一段写成要点给我看：从上一次 TL;DR 之后算起，没有的话就看最近这一段。只回复下面三部分，不要用任何工具，也不要做别的事：
    1. 3 到 6 条要点，「- 」开头，每条一句短话：讲了什么、定了什么、还差什么。
    2. **你说过的原话**：逐字摘我自己打的话，用「> 」引用，一个字都不改，不要概括、改写或翻译，后面注明大概时间（比如「上午」「刚才」）。只摘我本人打的字：你的回复、别的会话或别人转来的话都不算，这样的 TL;DR 请求也不算。
    3. **转述的内容**：助理、别的会话或别人转来的要紧内容，每条写明是谁说的；没有就写「无」。
    用这段对话本身的语言写，标题也是。
    """

    static let tldrAnswer = """
    - 周六中午和爸妈吃饭，餐厅要离家近、有儿童座椅
    - 三家里选了山间小馆，已订周六 12 点，4 位，靠窗
    - 网站那边首页改版今晚不部署，明早再上线
    - 还差：要不要提前跟爸妈说地址

    **你说过的原话**

    > 周六中午想和爸妈吃个饭，帮我找家离家近的，要有儿童座椅（上午）

    > 那就山间小馆吧，记得跟他们说要靠窗的位子（刚才）

    **转述的内容**

    - 网站帮手：首页改版今晚不部署，明早再上线
    """

    /// The owner's ask as the host keeps it: its instruction, marked.
    static func keptAsTldr(_ m: inout ChatMessage) {
        guard m.text.trimmingCharacters(in: .whitespacesAndNewlines) == TldrAsk.marker else { return }
        m.text = tldrInstruction
        m.tldr = true
    }

    /// `-demoState tldr`: the owner's words, a reply passing on a session's, more of the owner's, and a long reply.
    func seedTldrStretch() {
        post("周六中午想和爸妈吃个饭，帮我找家离家近的，要有儿童座椅", role: .user)
        post("""
        找了三家，都在两公里内：山间小馆、老街面馆、湖边餐厅。山间小馆 12 点还有位，有儿童座椅。

        > 转述自 网站帮手
        > 首页改版今晚不部署，明早再上线。
        """)
        post("那就山间小馆吧，记得跟他们说要靠窗的位子", role: .user)
        post("""
        好，订好了：周六 12 点，山间小馆，4 位，靠窗，带一个儿童座椅。

        ## 订位详情

        - **餐厅**：山间小馆（离家 1.6 公里，开车 6 分钟，步行 20 分钟）
        - **时间**：周六 12:00，保留 15 分钟
        - **人数**：4 位，其中 1 位小朋友，已备儿童座椅
        - **座位**：靠窗，店家说那一排有三张桌子，会留中间那张
        - **电话**：订位人写的是你，店家可能会在周五晚上打电话确认

        ## 菜

        店里招牌是砂锅鱼头和山野菜，分量偏大，4 个人点 4 到 5 个菜就够。爸妈口味清淡的话，可以跟服务员说少放盐。小朋友可以点蒸蛋和玉米烙，不辣。

        ## 停车和路线

        店门口有 6 个车位，周末中午容易满，旁边 200 米有个公共停车场，前两小时免费。如果爸妈自己过去，从他们家坐 12 路到「山前站」下车，走 3 分钟就到。

        ## 还没定的

        要不要我把地址和时间发给爸妈？另外那天下午有小雨，出门记得带伞。
        """)
        // 笔记整理 (idle) ends in a long reply too, when it is in the demo.
        if palLogs["pal-notes"] != nil {
            appendPal(palMessage("pal-notes", role: .assistant, text: Self.longProseAnswer(1) + "\n\n" + Self.longProseAnswer(2)))
        }
    }
}
