import Foundation

// 待办 in the demo host, as host/src/backlog.ts keeps it: one list per
// folder (the assistant's, 网站帮手's from the mockup, 笔记整理's), the
// owner's hand on them, and 以后再说 from 等你的事. `-demoState backlogDoing`
// (the mockup's: one being done, two agents in the folder) | backlogMany (30
// in line) | backlogEmpty | backlogOld (a host from before editing).
extension DemoHost {
    static let demoAssistantFolder = "/Users/demo/.paloally/home"

    static func seededBacklogs(now: Int64) -> [String: Backlog] {
        let min: Int64 = 60_000
        let day = 24 * 60 * min
        func list(_ folder: String, assistant: Bool = false, _ items: [BacklogItem]) -> Backlog {
            Backlog(folder: folder, name: (folder as NSString).lastPathComponent, assistant: assistant ? true : nil, editable: true, items: items)
        }
        let mine = list(demoAssistantFolder, assistant: true, [
            BacklogItem(id: "b_receipts", text: "整理十月的报销单", note: "发票在邮箱里，打车的在微信", addedAt: now - 2 * day),
            BacklogItem(id: "b_car", text: "车险月底到期，比一下三家的价", addedAt: now - day),
            BacklogItem(id: "b_shots", text: "把相册里的截图清一清", addedAt: now - 3 * day),
            BacklogItem(id: "b_train", text: "订下周去上海的高铁", state: .done, addedAt: now - 4 * day, doneAt: now - 5 * 60 * min),
        ])
        let site = list("/Users/demo/code/site", [
            BacklogItem(id: "b_lazy", text: "首页图片懒加载", note: "首屏 3.2 MB，大部分是图", addedAt: now - 3 * day),
            BacklogItem(id: "b_toc", text: "文章页加目录", note: "长文右侧浮动目录", addedAt: now - 2 * day),
            BacklogItem(id: "b_404", text: "404 页面重做", addedAt: now - 2 * day),
            BacklogItem(id: "b_sms", text: "登录页支持手机号验证码", note: "不急", addedAt: now - day),
            BacklogItem(id: "b_radius", text: "统一按钮圆角", addedAt: now - day),
            BacklogItem(id: "b_alt", text: "图片 alt 文案补齐", addedAt: now - day),
            BacklogItem(id: "b_sitemap", text: "站点地图自动生成", addedAt: now - 12 * 60 * min),
            BacklogItem(id: "b_nav", text: "导航栏改成固定在顶部", state: .done, addedAt: now - 5 * day, doneAt: now - day),
            BacklogItem(id: "b_sort", text: "列表页按日期排序", state: .done, pal: "pal-site", palName: "网站帮手",
                        addedAt: now - 4 * day, doneAt: now - 2 * 60 * min),
        ])
        let notes = list("/Users/demo/Documents/notes", [
            BacklogItem(id: "b_tags", text: "把去年的读书笔记也补上标签", addedAt: now - day),
            BacklogItem(id: "b_dupes", text: "找出内容重复的笔记，列个清单给我", addedAt: now - 2 * day),
            BacklogItem(id: "b_index", text: "做一页按主题的索引", addedAt: now - 3 * day),
        ])
        return [mine.folder: mine, site.folder: site, notes.folder: notes]
    }

    /// The `backlog…` states, for 网站帮手's folder and the assistant's.
    func applyBacklogScenario(_ name: String) {
        let site = "/Users/demo/code/site"
        func set(_ folder: String, _ change: (inout Backlog) -> Void) {
            var b = backlogList(folder)
            change(&b)
            _ = setBacklog(b)
        }
        switch name {
        case "backlogEmpty":
            for folder in [site, Self.demoAssistantFolder] { set(folder) { $0.items = [] } }
        case "backlogOld":
            backlogEditing = false
            for folder in Array(backlogs.keys) { set(folder) { $0.editable = nil } }
        default:
            // Another agent in the folder; the mockup's words.
            if let i = pals.firstIndex(where: { $0.id == "pal-blog" }) { pals[i].cwd = site }
            emitPals()
            set(site) { b in
                let now = Date().epochMillis
                var items = [BacklogItem(id: "b_date", text: "列表页按日期排序", state: .doing, pal: "pal-site", addedAt: now)]
                items += b.queued
                for i in items.indices {
                    if items[i].id == "b_toc" { items[i].pal = "pal-blog" }
                    if items[i].id == "b_sms" { items[i].note = nil }
                    if items[i].id == "b_alt" { items[i].text = "图片 alt 文案补齐，先补文章页，再补产品页，最后把占位图也换掉" }
                }
                if name == "backlogMany" {
                    let words = ["分页改成无限滚动", "页脚链接核对", "暗色模式对比度", "评论区加载更快", "封面图裁切", "RSS 修日期", "搜索支持拼音"]
                    for n in 8...30 { items.append(BacklogItem(id: "b_many\(n)", text: "\(words[n % 7]) \(n)", addedAt: now)) }
                }
                items.append(BacklogItem(id: "b_test", text: "补两条排序测试", state: .done, addedAt: now, doneAt: now - 1000))
                items.append(BacklogItem(id: "b_head", text: "表头加排序按钮", state: .done, addedAt: now, doneAt: now))
                b.items = items
            }
        }
    }

    /// Whose list a call means: an agent's folder, a folder, or the assistant's.
    private func backlogFolder(_ p: JSONValue) throws -> String {
        if let id = p["pal"]?.stringValue, !id.isEmpty {
            guard let pal = pals.first(where: { $0.id == id }) else { throw DemoError(message: "没有这个 agent") }
            return pal.cwd
        }
        if let f = p["folder"]?.stringValue, !f.isEmpty { return f }
        return Self.demoAssistantFolder
    }

    private func backlogList(_ folder: String) -> Backlog {
        backlogs[folder] ?? Backlog(folder: folder, name: (folder as NSString).lastPathComponent,
                                    assistant: folder == Self.demoAssistantFolder ? true : nil,
                                    editable: backlogEditing ? true : nil, items: [])
    }

    /// Being done, the queue, the done ones; each its agent's name now.
    private func setBacklog(_ b: Backlog) -> Backlog {
        var b = b
        b.items = b.doing + b.queued + b.items.filter { $0.state == .done }
        for i in b.items.indices {
            if let id = b.items[i].pal, let p = pals.first(where: { $0.id == id }) { b.items[i].palName = p.displayName }
        }
        backlogs[b.folder] = b
        emit(RPCEventName.backlogUpdated, b)
        return b
    }

    private func backlogItem(_ b: Backlog, _ p: JSONValue) throws -> Int {
        guard let i = b.items.firstIndex(where: { $0.id == p["id"]?.stringValue }) else { throw DemoError(message: "待办里没有这件") }
        return i
    }

    /// Adds to a folder's list (the end of its queue), as the host's backlog.add.
    @discardableResult
    func addBacklog(folder: String, text: String, note: String?, top: Bool = false) -> (BacklogItem, Backlog) {
        var b = backlogList(folder)
        let item = BacklogItem(id: "b_\(UUID().uuidString.prefix(8).lowercased())", text: text,
                               note: note?.isEmpty == false ? note : nil, addedAt: Date().epochMillis)
        let queue = b.items.indices.filter { b.items[$0].state == .queued }
        let at = top ? (queue.first ?? b.items.firstIndex { $0.state == .done } ?? b.items.count)
            : (b.items.firstIndex { $0.state == .done } ?? b.items.count)
        b.items.insert(item, at: at)
        return (item, setBacklog(b))
    }

    /// 以后再说: onto the 待办 of the folder it came from, off 等你的事.
    func putOff(_ item: PendingItem) throws -> PendingItem {
        guard !(item.blocking && item.isOpen) else { throw DemoError(message: "这件卡着一个 agent，要现在回答") }
        let palId = item.pal ?? (item.source.kind == .pal ? item.source.id : nil)
        let folder = palId.flatMap { id in pals.first { $0.id == id }?.cwd } ?? Self.demoAssistantFolder
        addBacklog(folder: folder, text: item.title, note: item.context)
        var done = item
        done.status = .done
        done.conclusion = "放进待办了"
        done.resolvedAt = Date().epochMillis
        return done
    }

    func dispatchBacklog(_ method: String, _ p: JSONValue) throws -> JSONValue? {
        guard RPCMethod.backlog.contains(method) else { return nil }
        if !backlogEditing, method == RPCMethod.backlogUpdate || method == RPCMethod.backlogRestore { return nil }
        let folder = try backlogFolder(p)
        var b = backlogList(folder)
        switch method {
        case RPCMethod.backlogList:
            return ["backlog": try .from(b)]
        case RPCMethod.backlogAdd:
            let text = (p["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw DemoError(message: "要写点内容") }
            let (item, list) = addBacklog(folder: folder, text: text, note: p["note"]?.stringValue, top: p["top"]?.boolValue == true)
            return ["item": try .from(item), "backlog": try .from(list)]
        case RPCMethod.backlogMove:
            let i = try backlogItem(b, p)
            let to = Int(p["to"]?.doubleValue ?? 0)
            b = b.moving(b.items[i].id, to: to)
        case RPCMethod.backlogAssign:
            let i = try backlogItem(b, p)
            b.items[i].pal = p["agent"]?.stringValue
            if b.items[i].pal == nil { b.items[i].palName = nil }
        case RPCMethod.backlogStart:
            let i = try backlogItem(b, p)
            var item = b.items.remove(at: i)
            item.state = .doing
            item.doneAt = nil
            item.pal = p["agent"]?.stringValue
            if item.pal == nil { item.palName = nil }
            b.items.insert(item, at: b.doing.count)
        case RPCMethod.backlogDone:
            let i = try backlogItem(b, p)
            var item = b.items.remove(at: i)
            if p["done"]?.boolValue == false {
                item.state = .queued; item.doneAt = nil; item.pal = nil; item.palName = nil
                b.items.insert(item, at: b.doing.count)
            } else {
                item.state = .done
                item.doneAt = Date().epochMillis
                b.items.append(item)
            }
        case RPCMethod.backlogRemove:
            b.items.remove(at: try backlogItem(b, p))
        case RPCMethod.backlogUpdate:
            let i = try backlogItem(b, p)
            if let raw = p["text"]?.stringValue {
                let text = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                guard !text.isEmpty else { throw DemoError(message: "要写点内容") }
                b.items[i].text = text
            }
            if let note = p["note"]?.stringValue { b.items[i].note = note.isEmpty ? nil : note }
            return ["item": try .from(b.items[i]), "backlog": try .from(setBacklog(b))]
        case RPCMethod.backlogRestore:
            guard let item = try p["item"]?.decode(BacklogItem.self), !item.text.isEmpty else { throw DemoError(message: "要写点内容") }
            b = b.restoring(item, to: Int(p["to"]?.doubleValue ?? 0))
        default:
            return nil
        }
        return ["backlog": try .from(setBacklog(b))]
    }
}
