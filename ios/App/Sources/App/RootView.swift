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
    @Environment(\.scenePhase) private var scenePhase
    @State private var voice = VoiceInputController()

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ChatView()
                .navigationDestination(isPresented: $model.showAssistant) {
                    AssistantView()
                }
        }
        .environment(voice)
        // Hold-to-talk screen dims everything, nav bar included.
        .overlay {
            if voice.isActive {
                VoiceInputOverlay(voice: voice)
            }
        }
        .animation(.easeOut(duration: 0.15), value: voice.isActive)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && voice.previewText == nil { voice.abort() }
        }
        .onAppear {
            if model.launch.screen == "voice" { voice.showPreview("你好，你好，你好，我正在说话") }
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
            // On Mac (and iPad) a form-sized sheet is too cramped for documents.
            .presentationSizing(.page)
            #if targetEnvironment(macCatalyst)
            .frame(minWidth: 720, idealWidth: 900, minHeight: 640, idealHeight: 800)
            #endif
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
