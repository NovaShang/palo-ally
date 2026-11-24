import PaloAllyKit
import SwiftUI

/// 「Claude 用量」 (docs/workbench-design/usage.html §2).
struct UsagePage: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let title = String(localized: "\(store.harness.login.account) 用量")
        List {}
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .macPageTop(title, inRow: true)
    }
}
