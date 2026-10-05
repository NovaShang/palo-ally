import PaloAllyKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let store = model.store {
                MainScreen()
                    .environment(store)
                    .id(ObjectIdentifier(store))
            } else {
                PairingView(isSheet: false)
            }
        }
        // Each assistant has its own color; switching re-tints the whole app.
        .appTheme(model.currentTheme)
        .animation(.snappy, value: model.activeHostID)
    }
}

/// The conversation is the one main screen. Everything else — the assistant
/// (top-left), the library (top-right), a single artifact or task opened from
/// the conversation — is one temporary layer over it, always a full-height
/// sheet with its own navigation inside. Closing it returns to the chat.
struct MainScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var voice = VoiceInputController()

    var body: some View {
        NavigationStack {
            ChatView()
        }
        .environment(voice)
        .animation(.easeOut(duration: 0.15), value: voice.isActive)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && voice.previewText == nil { voice.abort() }
        }
        .onAppear {
            if model.launch.screen == "voice" { voice.showPreview("你好，你好，你好，我正在说话") }
            model.markSeen()
        }
        // Everything on screen counts as seen (drives the other assistants' unread dots).
        .onChange(of: store.lastSeq) { model.markSeen() }
        // One sheet for whichever layer is open; switching layers swaps its
        // content in place instead of stacking sheets.
        .sheet(isPresented: Binding(get: { model.layer != nil }, set: { if !$0 { model.layer = nil } })) {
            LayerView()
                .environment(store)
                // On Mac (and iPad) a form-sized sheet is too cramped for documents.
                .presentationSizing(.page)
                #if targetEnvironment(macCatalyst)
                .frame(minWidth: 720, idealWidth: 900, minHeight: 640, idealHeight: 800)
                #endif
        }
        .sheet(isPresented: Binding(get: { model.showPairingSheet && model.layer == nil },
                                    set: { if !$0 { model.showPairingSheet = false } })) {
            PairingView(isSheet: true)
        }
    }
}

/// The content of the one open layer. Each case gets a fresh NavigationStack,
/// so an artifact opened from the chat closes straight back to the chat.
private struct LayerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.layer {
            case .assistant:
                NavigationStack {
                    AssistantView().toolbar { closeItem }
                }
            case .library:
                NavigationStack(path: $model.libraryPath) {
                    LibraryView().toolbar { closeItem }
                }
            case .artifact(let id):
                NavigationStack {
                    ArtifactDetailView(artifactID: id)
                        .toolbar {
                            closeItem
                            ToolbarItem(placement: .bottomBar) {
                                Button("在产出物库中查看") { model.showInLibrary(id) }
                                    .tint(.primary)
                            }
                        }
                }
            case .task(let id):
                NavigationStack {
                    TaskDetailView(taskID: id)
                        .toolbar {
                            closeItem
                            ToolbarItem(placement: .bottomBar) {
                                Button("全部任务") { model.showAllTasks() }
                                    .tint(.primary)
                            }
                        }
                }
            case nil:
                EmptyView()
            }
        }
        .id(layerKey)
        // Pairing opened from inside a layer (settings → 添加另一台电脑) stacks on it.
        .sheet(isPresented: Binding(get: { model.showPairingSheet && model.layer != nil },
                                    set: { if !$0 { model.showPairingSheet = false } })) {
            PairingView(isSheet: true)
        }
    }

    private var closeItem: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("完成", role: .close) { model.layer = nil }
                .tint(.primary)
        }
    }

    private var layerKey: String {
        switch model.layer {
        case .assistant: "assistant"
        case .library: "library"
        case .artifact(let id): "artifact:\(id)"
        case .task(let id): "task:\(id)"
        case nil: "none"
        }
    }
}

#Preview("Demo") {
    let model = AppModel.demo()
    RootView().environment(model)
}
