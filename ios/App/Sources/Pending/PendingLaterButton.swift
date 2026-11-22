import PaloAllyKit
import SwiftUI

/// 以后再说 on an item of 等你的事: it goes on the 待办 of the folder it came
/// from (the assistant's for its own) and leaves the list. Not on what a
/// session is stopped on, nor on a card's item.
struct PendingLaterButton: View {
    @Environment(AppStore.self) private var store
    let item: PendingItem
    @State private var failed = false

    var body: some View {
        if AppStore.canPutOff(item), store.backlogSupported != false {
            Button(String(localized: "以后再说", table: "Files")) {
                Task {
                    do {
                        try await store.laterPending(item, conclusion: String(localized: "放进待办了", table: "Files"))
                    } catch {
                        failed = true
                    }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(failed ? Color.red : .secondary)
            .font(.footnote)
            .accessibilityIdentifier("pending-later-\(item.id)")
        }
    }
}
