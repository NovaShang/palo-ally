import PaloAllyKit
import SwiftUI

/// 以后再说 on an item of 等你的事: it goes on the 待办 of the folder it came
/// from (the assistant's for its own) and leaves the list. Not on what a
/// session is stopped on, nor on a card's item. The row decides it
/// (`PendingChoice.later` through `AppStore.decide`), as its other buttons.
struct PendingLaterButton: View {
    @Environment(AppStore.self) private var store
    let item: PendingItem
    let action: () -> Void

    var body: some View {
        if AppStore.canPutOff(item), store.backlogSupported != false {
            Button(String(localized: "以后再说", table: "Files"), action: action)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.footnote)
                .accessibilityIdentifier("pending-later-\(item.id)")
        }
    }
}
