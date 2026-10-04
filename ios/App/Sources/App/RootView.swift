import PaloAllyKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let store = model.store {
            MainScreen()
                .environment(store)
                .id(ObjectIdentifier(store))
        } else {
            PairingView(isSheet: false)
        }
    }
}

/// The conversation is the one main screen. The assistant page is pushed from
/// the top-left; the library opens from the top-right as a temporary sheet.
struct MainScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ChatView()
                .navigationDestination(isPresented: $model.showAssistant) {
                    AssistantView()
                }
        }
        .sheet(isPresented: $model.showLibrary) {
            NavigationStack(path: $model.libraryPath) {
                LibraryView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { model.showLibrary = false }
                        }
                    }
            }
            .environment(store)
        }
        .sheet(isPresented: $model.showPairingSheet) {
            PairingView(isSheet: true)
        }
    }
}

#Preview("Demo") {
    let model = AppModel.demo()
    RootView().environment(model)
}
