import PaloAllyKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let store = model.store {
            MainTabs()
                .environment(store)
                .id(ObjectIdentifier(store))
        } else {
            PairingView(isSheet: false)
        }
    }
}

struct MainTabs: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            Tab("对话", systemImage: "bubble.left.and.text.bubble.right", value: AppTab.chat) {
                NavigationStack {
                    ChatView()
                        .navigationDestination(isPresented: $model.showAssistant) {
                            AssistantView()
                        }
                }
            }
            .badge(store.pendingApprovals.count)

            Tab("资料库", systemImage: "books.vertical", value: AppTab.library) {
                NavigationStack(path: $model.libraryPath) {
                    LibraryView()
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .sheet(isPresented: $model.showPairingSheet) {
            PairingView(isSheet: true)
        }
    }
}

#Preview("Demo") {
    let model = AppModel.demo()
    RootView().environment(model)
}
