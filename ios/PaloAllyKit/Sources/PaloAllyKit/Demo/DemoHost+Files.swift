import Foundation

/// Files on the computer in the demo (docs/files-prd.md): every Pal's folder
/// is a small made-up website project, the assistant's home has its core
/// files and an artifact, and the computer's folders (to open from the
/// preview pane) are a home folder with a few projects. As the host: `.git`
/// and `node_modules` hidden until asked, nothing outside a scope, files over
/// 5 MB give their size only.
extension DemoHost {
    /// A made-up file: its text, or just a size (too big to read).
    struct DemoFile {
        var data: Data
        var size: Int64
        init(_ text: String) { data = Data(text.utf8); size = Int64(data.count) }
        init(data: Data) { self.data = data; size = Int64(data.count) }
        init(size: Int64) { data = Data(); self.size = size }
    }

    static let demoHome = "/Users/demo"
    static let hiddenNames: Set<String> = [".git", "node_modules", ".build", "DerivedData", ".DS_Store"]

    /// A 1×1 PNG (the README's picture).
    static let demoPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!

    /// A small made-up picture, an SVG (so it is crisp and visible in a shot).
    static func demoSVG(_ label: String, _ color: String) -> Data {
        Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="320" height="160" viewBox="0 0 320 160">\
        <rect width="320" height="160" rx="16" fill="\(color)"/>\
        <text x="160" y="88" font-family="sans-serif" font-size="28" fill="white" text-anchor="middle">\(label)</text></svg>
        """.utf8)
    }

    /// A Pal's project (any Pal's: the demo has one kind).
    static let projectFiles: [String: DemoFile] = [
        "README.md": DemoFile("""
        # 网站

        个人网站，列表页和详情页都在 `src/pages/` 里。

        - 列表页：`src/pages/ListPage.tsx`
        - 数据：`src/hooks/useItems.ts`
        - 设计稿：`notes/设计/列表页.md`

        ![首页示意](docs/preview.svg)

        ## 本地运行

        ```sh
        npm install
        npm run dev
        ```

        ![首页](docs/home.png)
        """),
        "package.json": DemoFile("{\n  \"name\": \"site\",\n  \"private\": true,\n  \"scripts\": { \"dev\": \"vite\", \"build\": \"vite build\" }\n}\n"),
        ".gitignore": DemoFile("node_modules\ndist\n"),
        "src/app.ts": DemoFile("import { createRoot } from \"react-dom/client\";\nimport { App } from \"./App\";\n\ncreateRoot(document.getElementById(\"root\")!).render(<App />);\n"),
        "src/pages/ListPage.tsx": DemoFile("""
        import { useItems } from "../hooks/useItems";

        // 列表页：默认最新的在前，表头可以按日期排序。
        export function ListPage() {
          const { items, sortByDate } = useItems();
          return (
            <table>
              <thead>
                <tr><th onClick={sortByDate}>日期</th><th>标题</th></tr>
              </thead>
              <tbody>
                {items.map((it) => (
                  <tr key={it.id}><td>{it.updatedAt}</td><td>{it.title}</td></tr>
                ))}
              </tbody>
            </table>
          );
        }
        """),
        "src/pages/DetailPage.tsx": DemoFile("export function DetailPage() {\n  return <article />;\n}\n"),
        "src/hooks/useItems.ts": DemoFile("""
        export function useItems() {
          const items = load().sort((a, b) => b.updatedAt - a.updatedAt);
          return { items, sortByDate: () => items.reverse() };
        }
        """),
        "notes/设计/列表页.md": DemoFile("# 列表页\n\n- 间距用 8 的倍数\n- 标题 17pt，日期 13pt 灰色\n\n![草图](sketch.svg)\n\n![缺图](gone.png)\n"),
        "notes/设计/sketch.svg": DemoFile(data: DemoHost.demoSVG("列表页草图", "#5B7FE0")),
        "docs/preview.svg": DemoFile(data: DemoHost.demoSVG("首页示意", "#3FA37A")),
        "docs/home.png": DemoFile(data: DemoHost.demoPNG),
        "docs/intro.mov": DemoFile(size: 48 * 1024 * 1024),
        ".git/HEAD": DemoFile("ref: refs/heads/main\n"),
        "node_modules/react/index.js": DemoFile("module.exports = {};\n"),
    ]

    /// The assistant's home.
    static let homeFiles: [String: DemoFile] = [
        "CLAUDE.md": DemoFile("# 助理\n\n你是主人的个人助理。\n"),
        "user.md": DemoFile("# 关于主人\n\n- 称呼：主人\n"),
        "soul.md": DemoFile("# 性格\n\n简洁、可靠。\n"),
        "artifacts/brief/brief.md": DemoFile("# 晨报\n\n- 今天没什么要你处理的\n"),
    ]

    /// The computer's folders, for 打开文件夹… (folders only).
    static let computerFolders: [String] = [
        "code/site/src", "code/site/docs", "code/blog", "code/app", "Documents/notes", "Documents/报销", "Pictures", "Desktop",
    ]

    /// A scope's folder and files.
    func filesScope(_ p: JSONValue?) throws -> (root: String, files: [String: DemoFile]) {
        let kind = p?["kind"]?.stringValue ?? ""
        let id = p?["id"]?.stringValue ?? ""
        switch kind {
        case "palo": return ("\(Self.demoHome)/.paloally/home", Self.homeFiles)
        case "pal":
            guard let pal = pals.first(where: { $0.id == id }) else { throw DemoError(message: "没有这个文件夹") }
            return (pal.cwd, Self.projectFiles)
        case "folder":
            guard let f = ownerFolders.first(where: { $0.id == id }) else { throw DemoError(message: "没有这个文件夹") }
            return (f.path, Self.projectFiles)
        default: throw DemoError(message: "没有这个文件夹")
        }
    }

    /// The `files.*` methods; nil for any other.
    func dispatchFiles(_ method: String, _ p: JSONValue) throws -> JSONValue? {
        switch method {
        case RPCMethod.filesList:
            let (root, files) = try filesScope(p["scope"])
            let dir = Self.normalize(p["path"]?.stringValue ?? "", root: root)
            guard let dir, dir.isEmpty || Self.isDir(dir, in: files) else { throw DemoError(message: "找不到这个文件，或者它不在能看的范围里") }
            let hidden = p["showHidden"]?.boolValue == true
            var entries: [String: FileEntry] = [:]
            for (path, file) in files {
                guard dir.isEmpty || path.hasPrefix(dir + "/") else { continue }
                let rest = dir.isEmpty ? path : String(path.dropFirst(dir.count + 1))
                let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
                guard let name = parts.first, hidden || !Self.hiddenNames.contains(name) else { continue }
                entries[name] = parts.count > 1
                    ? FileEntry(name: name, kind: .dir, size: 0, mtime: Date().epochMillis - 3_600_000)
                    : FileEntry(name: name, kind: .file, size: file.size, mtime: Date().epochMillis - 7_200_000)
            }
            return try .from(FilesListResult(root: root, path: dir, entries: Self.sorted(Array(entries.values))))
        case RPCMethod.filesRead:
            let (root, files) = try filesScope(p["scope"])
            guard let path = Self.normalize(p["path"]?.stringValue ?? "", root: root), let file = files[path] else {
                throw DemoError(message: "找不到这个文件，或者它不在能看的范围里")
            }
            let mime = DemoHost.mime(for: path)
            if file.size > FileChunk.maxFile {
                return ["data": "", "size": .number(Double(file.size)), "mime": .string(mime), "eof": true, "tooLarge": true]
            }
            let offset = min(Int(p["offset"]?.doubleValue ?? 0), file.data.count)
            let end = min(file.data.count, offset + 256 * 1024)
            return ["data": .string(file.data.subdata(in: offset..<end).base64EncodedString()), "size": .number(Double(file.size)),
                    "mime": .string(mime), "eof": .bool(end >= file.data.count)]
        case RPCMethod.filesSearch:
            let (_, files) = try filesScope(p["scope"])
            let q = (p["query"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            guard !q.isEmpty else { return try .from(FilesSearchResult(matches: [])) }
            var all: [FileMatch] = []
            var dirs = Set<String>()
            for path in files.keys {
                let parts = path.split(separator: "/").map(String.init)
                guard !parts.contains(where: { Self.hiddenNames.contains($0) }) else { continue }
                for i in 1..<max(1, parts.count) { dirs.insert(parts[0..<i].joined(separator: "/")) }
                all.append(FileMatch(path: path, kind: .file))
            }
            all += dirs.map { FileMatch(path: $0, kind: .dir) }
            let hits = all.filter { (q.contains("/") ? $0.path : $0.name).lowercased().contains(q) }
                .sorted { a, b in
                    let ra = a.name.lowercased() == q ? 0 : a.name.lowercased().hasPrefix(q) ? 1 : 2
                    let rb = b.name.lowercased() == q ? 0 : b.name.lowercased().hasPrefix(q) ? 1 : 2
                    return (ra, a.kind == .file ? 0 : 1, a.path.count, a.path) < (rb, b.kind == .file ? 0 : 1, b.path.count, b.path)
                }
            return try .from(FilesSearchResult(matches: Array(hits.prefix(Int(p["limit"]?.doubleValue ?? 50)))))
        case RPCMethod.filesResolve:
            let (root, files) = try filesScope(p["scope"])
            var asked: [String] = []
            if case .array(let list)? = p["paths"] { asked = list.compactMap(\.stringValue) }
            if let one = p["text"]?.stringValue { asked.append(one) }
            var out: [ResolvedFile] = []
            for text in asked {
                var c = text.replacingOccurrences(of: #":\d+(:\d+)?$"#, with: "", options: .regularExpression)
                while c.hasPrefix("./") { c.removeFirst(2) }
                if c.hasPrefix("~/") { c = Self.demoHome + c.dropFirst(1) }
                guard let rel = Self.normalize(c, root: root) else { continue }
                let hit = files[rel] != nil ? rel
                    : c.hasPrefix("/") ? nil
                    : files.keys.sorted().first { $0.hasSuffix("/" + rel) && !$0.split(separator: "/").contains { Self.hiddenNames.contains(String($0)) } }
                guard let hit, let f = files[hit] else { continue }
                out.append(ResolvedFile(text: text, path: hit, size: f.size))
            }
            return try .from(FilesResolveResult(files: out))
        case RPCMethod.filesFoldersList:
            return try .from(OwnerFoldersResult(folders: ownerFolders))
        case RPCMethod.filesFoldersBrowse:
            let raw = p["path"]?.stringValue ?? Self.demoHome
            let path = raw.hasPrefix("~") ? Self.demoHome + raw.dropFirst(1) : (raw.isEmpty ? Self.demoHome : raw)
            let clean = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            var names = Set<String>()
            let all = ["/Users", Self.demoHome] + Self.computerFolders.flatMap { f -> [String] in
                let parts = f.split(separator: "/")
                return (1...parts.count).map { Self.demoHome + "/" + parts[0..<$0].joined(separator: "/") }
            }
            for f in all {
                let prefix = clean == "/" ? "/" : clean + "/"
                guard f.hasPrefix(prefix) else { continue }
                if let name = f.dropFirst(prefix.count).split(separator: "/").first { names.insert(String(name)) }
            }
            guard clean == "/" || all.contains(clean) else { throw DemoError(message: "找不到这个文件，或者它不在能看的范围里") }
            let parent = clean == "/" ? nil : ((clean as NSString).deletingLastPathComponent as String)
            let entries = names.sorted().map { FileEntry(name: $0, kind: .dir, size: 0, mtime: Date().epochMillis) }
            return try .from(FolderBrowseResult(path: clean, parent: parent, entries: entries))
        case RPCMethod.filesFoldersAdd:
            var path = p["path"]?.stringValue ?? ""
            if path.hasPrefix("~") { path = Self.demoHome + path.dropFirst(1) }
            guard path != "/", path != Self.demoHome, path != "/Users", path.hasPrefix(Self.demoHome + "/") else {
                throw DemoError(message: "选一个具体的文件夹，不能是整个磁盘、整个个人文件夹或 PaloAlly 自己的文件夹")
            }
            if let had = ownerFolders.first(where: { $0.path == path }) { return ["folder": try .from(had)] }
            let folder = OwnerFolder(id: nextID("fld"), path: path, name: (path as NSString).lastPathComponent, addedAt: Date().epochMillis)
            ownerFolders.append(folder)
            return ["folder": try .from(folder)]
        case RPCMethod.filesFoldersRemove:
            let id = p["id"]?.stringValue ?? ""
            guard ownerFolders.contains(where: { $0.id == id }) else { throw DemoError(message: "没有这个文件夹") }
            ownerFolders.removeAll { $0.id == id }
            return ["ok": true]
        default:
            return nil
        }
    }

    /// `path` relative to the scope's root, or nil when it isn't inside it.
    static func normalize(_ path: String, root: String) -> String? {
        var p = path.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("/") {
            guard p == root || p.hasPrefix(root + "/") else { return nil }
            p = String(p.dropFirst(root.count))
        }
        var parts: [Substring] = []
        for piece in p.split(separator: "/") {
            switch piece {
            case "", ".": continue
            case "..": return nil
            default: parts.append(piece)
            }
        }
        return parts.joined(separator: "/")
    }

    static func isDir(_ path: String, in files: [String: DemoFile]) -> Bool {
        files.keys.contains { $0.hasPrefix(path + "/") }
    }

    /// Folders first, then by name (numbers in order).
    static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { a, b in
            if a.kind != b.kind { return a.kind == .dir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
