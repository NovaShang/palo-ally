#if DEBUG || PERF_HARNESS
import Foundation

/// A heavier split workspace for measuring (DEBUG, or a Release build with
/// `PERF_HARNESS`):
///   -demoTiles <n>     官网改版 tiles n sessions (pal-site, pal-blog, pal-notes,
///                      pal-photos, then `-demoPals` ones)
///   -demoHistory <n>   each tiled session's conversation starts with n more
///                      messages (Markdown: lists, code, links)
///   -demoTick <s>      every s seconds a tiled session's status line, context
///                      and state change, as a working session's do (pals.updated);
///                      `-demoTickBusy NO` leaves the state as it is
///   -demoStreamEvery <s>  every s seconds the second tile streams a reply
/// Whether the perf drivers (ticks, typing, a divider moving) run now:
/// with `-perfAlternate YES` the meter turns them on and off each window, so
/// every busy window has a quiet one beside it to compare with.
public enum PerfSwitch {
    nonisolated(unsafe) public static var driving = true
}

enum PerfSeed {
    static func apply(pals: inout [Pal], logs: inout [String: [ChatMessage]], workspace: inout Workspace, now: Int64) {
        let d = UserDefaults.standard
        let tiles = d.integer(forKey: "demoTiles")
        if tiles > 2 {
            let order = ["pal-site", "pal-blog", "pal-notes", "pal-photos"]
                + pals.map(\.id).filter { $0.hasPrefix("pal-more-") }
            let ids = Array(order.prefix(tiles))
            workspace.memberIds = ids
            for i in pals.indices where ids.contains(pals[i].id) { pals[i].workspaceId = workspace.id }
        }
        let extra = d.integer(forKey: "demoHistory")
        guard extra > 0 else { return }
        for id in workspace.memberIds {
            let old = logs[id] ?? []
            let base = old.first?.ts ?? now
            let added: [ChatMessage] = (0..<extra).map { k in
                var m = ChatMessage(seq: Int64(k + 1), id: "\(id)-x\(k + 1)", role: k % 3 == 0 ? .user : .assistant,
                                    kind: .text, text: text(k), channel: .app,
                                    ts: base - Int64(extra - k) * 60_000)
                m.pal = id
                return m
            }
            let shifted = old.map { m -> ChatMessage in
                var m = m
                m.seq += Int64(extra)
                return m
            }
            logs[id] = added + shifted
        }
    }

    static func text(_ k: Int) -> String {
        switch k % 3 {
        case 0: return "第 \(k) 步：把列表页的间距再看一遍，顺便检查 `ListPage.tsx` 里的排序。"
        case 1:
            return """
            好的，第 \(k) 处改好了：

            - `ListPage.tsx`：表头的排序按钮换成图标
            - `useItems.ts`：按 `updatedAt` 倒序，空值放最后
            - 补了 **两条** 测试，见 [notes/设计/列表页.md](notes/设计/列表页.md)

            ```ts
            items.sort((a, b) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0))
            ```
            """
        default:
            return "构建通过，没有报错。第 \(k) 轮的测试 42 个全部通过，用时 3.2 秒。接下来看详情页的标题和面包屑，有问题我再问你。"
        }
    }
}

extension DemoHost {
    /// `-demoTick` / `-demoStreamEvery`: what working sessions send while the
    /// owner types in another tile.
    public func startPerfTicks() {
        let d = UserDefaults.standard
        let tick = d.double(forKey: "demoTick")
        if tick > 0 {
            Task {
                var n = 0
                while true {
                    try? await Task.sleep(for: .seconds(tick))
                    guard PerfSwitch.driving else { continue }
                    n += 1
                    let members = self.workspaces.first?.memberIds ?? []
                    guard !members.isEmpty else { continue }
                    let id = members[n % members.count]
                    let busy = d.object(forKey: "demoTickBusy") == nil || d.bool(forKey: "demoTickBusy")
                    self.setPal(id) {
                        if busy { $0.status = .busy }
                        $0.lastLine = "在跑第 \(n) 个测试文件。"
                        $0.contextPct = 20 + n % 70
                        $0.updatedAt = Date().epochMillis
                    }
                }
            }
        }
        let every = d.double(forKey: "demoStreamEvery")
        if every > 0 {
            Task {
                var n = 0
                while true {
                    try? await Task.sleep(for: .seconds(every))
                    guard PerfSwitch.driving else { continue }
                    n += 1
                    let members = self.workspaces.first?.memberIds ?? []
                    guard members.count > 1 else { continue }
                    await self.streamPal(members[1], "第 \(n) 轮：构建通过了，没有报错。列表页可以看了，接下来做详情页，有问题我再问你。")
                }
            }
        }
    }
}
#endif
