import Foundation
import Testing
@testable import PaloAllyKit

@MainActor
@Suite("「试试」 suggestions")
struct SuggestionsTests {
    @Test func loadedAfterConnectUsedAndDismissed() async throws {
        let host = DemoHost(speed: 0, seeded: false)
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        #expect(await until { store.suggestions.count == 4 })

        // tapping one sends its full prompt and the host drops it
        let first = store.suggestions[0]
        store.use(first)
        #expect(!store.suggestions.contains(first))
        #expect(await until { store.messages.contains { $0.role == .user && $0.text == first.prompt } })
        #expect(await until { store.suggestions.count == 3 })

        // dismissed for good: gone locally and on the host
        let second = store.suggestions[0]
        store.dismiss(second)
        #expect(!store.suggestions.contains(second))
        #expect(await until {
            await store.loadSuggestions()
            return store.suggestions.count == 2 && !store.suggestions.contains { $0.id == second.id }
        })
    }

    @Test func updatedEventReplacesTheList() async throws {
        let host = ManualHost()
        let store = AppStore(transport: host.transport)
        store.start()
        #expect(await until { store.connection == .online })
        host.event("suggestions.updated", ["suggestions": [["id": "sg_9", "chip": "整理下载文件夹", "prompt": "把下载文件夹整理一下", "createdAt": 1]]])
        #expect(await until { store.suggestions.map(\.chip) == ["整理下载文件夹"] })
    }
}
