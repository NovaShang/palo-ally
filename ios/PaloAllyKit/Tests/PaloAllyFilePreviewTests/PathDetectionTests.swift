import Foundation
import Testing
@testable import PaloAllyFilePreview

/// Paths in a reply's text (Bento Term's PathDetector, listing every
/// candidate rather than hit-testing one cell).
struct PathDetectionTests {
    private func paths(_ text: String) -> [String] { PathDetector.candidates(in: text).map(\.path) }

    @Test("Absolute, home, dot-relative, bare relative, bare names and dotfiles")
    func kinds() {
        #expect(paths("看 /Users/x/code/site/README.md 和 ~/notes/a.md") == ["/Users/x/code/site/README.md", "~/notes/a.md"])
        #expect(paths("改了 ./src/app.ts、../lib/x.swift") == ["./src/app.ts", "../lib/x.swift"])
        #expect(paths("改了 src/pages/ListPage.tsx 和 useItems.ts。") == ["src/pages/ListPage.tsx", "useItems.ts"])
        #expect(paths("别忘了 .gitignore 和 .env.local") == [".gitignore", ".env.local"])
        let explicit = PathDetector.candidates(in: "/a/b.md src/c.ts d.md").map(\.explicit)
        #expect(explicit == [true, false, false])
    }

    @Test("CJK paths and CJK punctuation around them")
    func cjk() {
        #expect(paths("设计稿在 notes/设计/列表页.md，间距按那份来。") == ["notes/设计/列表页.md"])
        #expect(paths("（见 docs/说明.md）") == ["docs/说明.md"])
        #expect(paths("「README.md」") == ["README.md"])
    }

    @Test("Line suffixes come off the path but stay in the range")
    func lineSuffix() throws {
        let text = "错在 src/main.rs:42:7 这里"
        let c = try #require(PathDetector.candidates(in: text).first)
        #expect(c.path == "src/main.rs")
        #expect(c.line == 42 && c.column == 7)
        #expect((text as NSString).substring(with: c.range) == "src/main.rs:42:7")
    }

    @Test("Trailing prose punctuation and unbalanced closers are not part of it")
    func junk() throws {
        let text = "(see /etc/hosts). Done."
        let c = try #require(PathDetector.candidates(in: text).first)
        #expect(c.path == "/etc/hosts")
        #expect((text as NSString).substring(with: c.range) == "/etc/hosts")
    }

    @Test("Not paths: URLs, versions, plain words, a lone slash")
    func notPaths() {
        #expect(paths("https://github.com/a/b 打开看看") == [])
        #expect(paths("升级到 1.2.3 版本") == [])
        #expect(paths("and / or") == [])
        #expect(paths("") == [])
    }

    @Test("Quoted paths with spaces, and a cut-off path after an ellipsis")
    func quotedAndTruncated() {
        #expect(paths(#"打开 "My Docs/report v2.pdf" 看看"#) == ["My Docs/report v2.pdf"])
        let cut = PathDetector.candidates(in: "…/App/File.swift")
        #expect(cut.map(\.path) == ["App/File.swift"])
        #expect(cut.first?.explicit == false)
    }

    @Test("Ranges are UTF-16, for attributed strings")
    func utf16Ranges() throws {
        let text = "😀 改了 a/b.md"
        let c = try #require(PathDetector.candidates(in: text).first)
        #expect((text as NSString).substring(with: c.range) == "a/b.md")
    }
}

/// Every way a stretch of a reply can be read as a path (what's asked of
/// the computer, best first), as the reply's text view lays it out.
struct PathGuessTests {
    /// Each guess's readings: path and the text it covers.
    private func readings(_ text: String, code: [String] = [], links: [(String, String)] = []) -> [[String]] {
        let ns = text as NSString
        let spans = code.map { ns.range(of: $0) }
        let linked = links.map { (range: ns.range(of: $0.0), url: URL(string: $0.1)!) }
        return PathDetector.guesses(in: text, codeSpans: spans, links: linked).map { g in
            g.readings.map { r in
                let shown = ns.substring(with: r.range)
                return shown == r.path ? r.path : "\(r.path) @\(shown)"
            }
        }
    }

    @Test("Plain text: absolute, relative, ~/, :line, Chinese punctuation after")
    func plain() {
        #expect(readings("改了 /Users/x/code/site/README.md。") == [["/Users/x/code/site/README.md"]])
        #expect(readings("见 src/main.rs:42，然后 ~/notes/a.md、./b.md！") ==
                [["src/main.rs @src/main.rs:42"], ["~/notes/a.md"], ["./b.md"]])
        #expect(readings("（/etc/hosts）") == [["/etc/hosts"]])
    }

    @Test("A path right against Chinese is read with and without it")
    func againstChinese() {
        // Absolute after a word: the bare reading, then without the word.
        #expect(readings("文件在/Users/x/a.md里") == [["文件在/Users/x/a.md里", "文件在/Users/x/a.md", "/Users/x/a.md里", "/Users/x/a.md"]])
        #expect(readings("改了src/main.rs里的排序") == [["改了src/main.rs里的排序", "改了src/main.rs", "src/main.rs里的排序", "src/main.rs"]])
        #expect(readings("先看README.md里面") == [["先看README.md", "README.md"]])
        #expect(readings("在~/notes/a.md里") == [["~/notes/a.md里", "~/notes/a.md"]])
        // A Chinese folder name stays one path.
        #expect(readings("设计稿在 notes/设计/列表页.md") == [["notes/设计/列表页.md"]])
    }

    @Test("A code span is read whole first (spaces kept), then the paths inside")
    func codeSpans() {
        let text = "打开 /Users/x/My Docs/report v2.md 看看"
        #expect(readings(text, code: ["/Users/x/My Docs/report v2.md"]) ==
                [["/Users/x/My Docs/report v2.md", "/Users/x/My", "Docs/report", "v2.md"]])
        #expect(readings("在 src/app.ts:12 里", code: ["src/app.ts:12"]) == [["src/app.ts @src/app.ts:12"]])
        // A command: read whole too (the computer has no such file), then the path in it.
        #expect(readings("跑 npm test -- src/a.test.ts 就行", code: ["npm test -- src/a.test.ts"]) == [["npm test -- src/a.test.ts", "src/a.test.ts"]])
        #expect(readings("跑 npm run dev", code: ["npm run dev"]) == [])
    }

    @Test("A link to a path: its target first, then what its text says")
    func links() {
        #expect(readings("改了 ListPage.tsx:12 这里", links: [("ListPage.tsx:12", "src/pages/ListPage.tsx#L12")]) ==
                [["src/pages/ListPage.tsx @ListPage.tsx:12", "ListPage.tsx @ListPage.tsx:12"]])
        #expect(readings("见 报告", links: [("报告", "/Users/x/My%20Docs/a.md")]) == [["/Users/x/My Docs/a.md @报告"]])
        #expect(readings("见 a.md", links: [("a.md", "file:///Users/x/a.md")]) == [["/Users/x/a.md @a.md", "a.md"]])
        // Web addresses and anchors stay what they are.
        #expect(readings("见 README.md", links: [("README.md", "https://github.com/a/b/blob/main/README.md")]) == [["README.md"]])
        #expect(readings("见 上面", links: [("上面", "#setup")]) == [])
    }

    @Test("A link's target: path, percent escapes, line from #L or :line")
    func linkedPath() {
        #expect(PathDetector.linkedPath(URL(string: "src/a.ts#L12-L20")!)! == ("src/a.ts", 12))
        #expect(PathDetector.linkedPath(URL(string: "/Users/x/a.swift:42")!)! == ("/Users/x/a.swift", 42))
        #expect(PathDetector.linkedPath(URL(string: "file:///Users/x/%E8%AE%BE%E8%AE%A1.md")!)! == ("/Users/x/设计.md", nil))
        #expect(PathDetector.linkedPath(URL(string: "https://x.com/a.md")!) == nil)
        #expect(PathDetector.linkedPath(URL(string: "mailto:a@b.c")!) == nil)
        #expect(PathDetector.linkedPath(URL(string: "#top")!) == nil)
    }
}

/// The directory picker's location (Bento Term's tests, ported).
struct DirectoryPickerPathTests {
    @Test func noLocationCannotConfirmOrMove() {
        var p = DirectoryPickerPath()
        #expect(p.selectedPath == nil && !p.canConfirm && !p.canGoUp && p.breadcrumb.isEmpty)
        p.enter("src")
        p.up()
        #expect(p.selectedPath == nil)
    }

    @Test func entersGoesUpAndStopsAtTheRoot() {
        var p = DirectoryPickerPath("/Users/x/repo")
        p.enter("src")
        #expect(p.selectedPath == "/Users/x/repo/src")
        p.up(); p.up(); p.up(); p.up(); p.up()
        #expect(p.selectedPath == "/")
        #expect(!p.canGoUp)
        p.enter("etc")
        #expect(p.selectedPath == "/etc")
    }

    @Test func breadcrumbAndJumps() {
        var p = DirectoryPickerPath("/Users/x/repo//")
        #expect(p.breadcrumb.map(\.label) == ["/", "Users", "x", "repo"])
        p.jump(to: "/Users/x/other")
        #expect(p.selectedPath == "/Users/x/repo")
        p.jump(to: "/Users")
        #expect(p.selectedPath == "/Users")
        var q = DirectoryPickerPath("/Users/xylophone")
        q.jump(to: "/Users/x")
        #expect(q.selectedPath == "/Users/xylophone")
        q.reset(nil)
        #expect(q.selectedPath == nil)
    }
}

/// How a file on the computer opens.
struct FileContentKindTests {
    @Test func byName() {
        #expect(FileContentKind.forName("README.md") == .markdown)
        #expect(FileContentKind.forName("src/app.ts") == .text)       // TypeScript, not a video
        #expect(FileContentKind.forName("main.swift") == .text)
        #expect(FileContentKind.forName("package.json") == .text)
        #expect(FileContentKind.forName("Makefile") == .text)
        #expect(FileContentKind.forName("photo.jpg") == .quickLook)
        #expect(FileContentKind.forName("icon.svg") == .quickLook)
        #expect(FileContentKind.forName("report.pdf") == .quickLook)
        #expect(FileContentKind.forName("deck.key") == .quickLook)
        #expect(FileContentKind.forName("clip.mov") == .quickLook)
    }

    @Test func bytesDecideForText() {
        #expect(FileContentKind.sniff(Data("hello\n".utf8)) == .text)
        #expect(FileContentKind.sniff(Data([0x41, 0x00, 0x42])) == .quickLook)
        #expect(FileContentKind.sniff(Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0, 0, 0, 0, 0])) == .quickLook)
    }
}

/// The lazy tree: one listing per opened folder, hidden things listed again on request.
@MainActor
struct LazyDirectoryTreeStoreTests {
    final class Calls: @unchecked Sendable {
        var log: [String] = []
        let lock = NSLock()
        func add(_ s: String) { lock.withLock { log.append(s) } }
        var all: [String] { lock.withLock { log } }
    }

    private func until(_ ok: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if ok() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return ok()
    }

    @Test func listsTheRootThenEachFolderOnceWhenOpened() async {
        let calls = Calls()
        let store = LazyDirectoryTreeStore()
        store.reset { rel, hidden in
            calls.add("\(rel)|\(hidden)")
            if rel == "" {
                return DirectoryListResult(entries: [.init(name: "src", isDir: true), .init(name: "README.md", isDir: false)]
                    + (hidden ? [.init(name: ".git", isDir: true)] : []))
            }
            if rel == "src" { return DirectoryListResult(entries: [.init(name: "app.ts", isDir: false)]) }
            throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到"])
        }
        #expect(await until { store.state(of: "").entries?.count == 2 })
        #expect(!store.rootLoading)
        store.toggle("src")
        #expect(await until { store.state(of: "src").entries?.map(\.name) == ["app.ts"] })
        store.toggle("src")
        store.toggle("src")   // open again: no second listing
        #expect(calls.all == ["|false", "src|false"])
        store.toggle("gone")
        #expect(await until { store.state(of: "gone").error == "找不到" })
        store.setShowHidden(true)
        #expect(await until { store.state(of: "").entries?.map(\.name).contains(".git") == true })
        #expect(calls.all.contains("|true") && calls.all.contains("src|true"))
    }
}
