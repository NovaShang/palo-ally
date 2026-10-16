import Foundation
import Testing
@testable import PaloAllyKit

/// Files on the computer (docs/files-prd.md): as the host sends them, and
/// the demo host answering like it.
@Suite("Files")
@MainActor
struct FilesTests {
    @Test func decodesAsTheHostSendsIt() throws {
        let list = #"{"root":"/Users/x/site","path":"src","entries":[{"name":"pages","kind":"dir","size":0,"mtime":1},{"name":"app.ts","kind":"file","size":20,"mtime":2}],"truncated":false}"#
        let (r, issues) = try LenientDiagnostics.collect { try JSONDecoder().decode(FilesListResult.self, from: Data(list.utf8)) }
        #expect(issues.isEmpty)
        #expect(r.entries.map(\.isDir) == [true, false])
        let big = #"{"data":"","size":6000000,"mime":"video/quicktime","eof":true,"tooLarge":true}"#
        #expect(try JSONDecoder().decode(FileChunk.self, from: Data(big.utf8)).tooLarge)
        let small = #"{"data":"aGk=","size":2,"mime":"text/plain","eof":true}"#
        let chunk = try JSONDecoder().decode(FileChunk.self, from: Data(small.utf8))
        #expect(!chunk.tooLarge && String(decoding: chunk.data, as: UTF8.self) == "hi")
        // The scope goes out as the host reads it: no id for the assistant's.
        let palo = String(decoding: try JSONEncoder().encode(FileScope.palo), as: UTF8.self)
        #expect(palo == #"{"kind":"palo"}"#)
        #expect(FileScope(kind: .palo, id: "x") == .palo)
    }

    @Test func browsesReadsSearchesAndResolvesInAPalsFolder() async throws {
        let host = DemoHost(speed: 0, pals: true)
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online && store.pals.count == 4 })
        let pal = try #require(await host.pals.first)
        let scope = FileScope.pal(pal.id)
        let root = try await store.listFiles(scope)
        #expect(root.root == pal.cwd)
        #expect(root.entries.first?.isDir == true)
        #expect(!root.entries.contains { $0.name == ".git" || $0.name == "node_modules" })
        #expect(try await store.listFiles(scope, showHidden: true).entries.contains { $0.name == ".git" })
        #expect(try await store.listFiles(scope, path: "src/pages").entries.map(\.name) == ["DetailPage.tsx", "ListPage.tsx"])
        let readme = try await store.readFile(scope, path: "README.md")
        #expect(String(decoding: readme.data, as: UTF8.self).hasPrefix("# 网站"))
        #expect(!readme.tooLarge)
        let video = try await store.readFile(scope, path: "docs/intro.mov")
        #expect(video.tooLarge && video.data.isEmpty && video.size > FileChunk.maxFile)
        await #expect(throws: (any Error).self) { try await store.readFile(scope, path: "../secret.txt") }
        #expect(try await store.searchFiles(scope, query: "listpage").matches.first?.path == "src/pages/ListPage.tsx")
        let resolved = try await store.resolveFiles(scope, paths: ["ListPage.tsx", "src/hooks/useItems.ts:3", "nope.md", "\(pal.cwd)/README.md", "/etc/hosts"])
        #expect(resolved.map(\.path) == ["src/pages/ListPage.tsx", "src/hooks/useItems.ts", "README.md"])
    }

    @Test func opensAndForgetsTheOwnersFolders() async throws {
        let host = DemoHost(speed: 0)
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        let home = try await store.browseFolders()
        #expect(home.path == "/Users/demo" && home.entries.map(\.name).contains("code"))
        #expect(try await store.browseFolders(path: home.path + "/code").entries.map(\.name) == ["app", "blog", "site"])
        await #expect(throws: (any Error).self) { try await store.addOwnerFolder(path: "/Users/demo") }
        let f = try await store.addOwnerFolder(path: "/Users/demo/code/blog")
        #expect(f.name == "blog")
        #expect(try await store.ownerFolders().map(\.id) == [f.id])
        #expect(try await store.listFiles(.folder(f.id)).root == "/Users/demo/code/blog")
        try await store.removeOwnerFolder(id: f.id)
        #expect(try await store.ownerFolders().isEmpty)
    }
}
