import PaloAllyKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            #if DEBUG
            if model.launch.screen == "glassDrops" {
                GlassDropsDemo(theme: model.currentTheme)
            } else if model.launch.screen == "scrollLab" {
                ScrollLab()
            } else {
                screens
            }
            #else
            screens
            #endif
        }
        // Each assistant has its own color; switching re-tints the whole app.
        .appTheme(model.currentTheme)
        .animation(.snappy, value: model.activeHostID)
        #if DEBUG
        .modifier(DemoCapture(demo: model.mode == .demo))
        .modifier(LayoutStressTest(model: model))
        #endif
    }

    @ViewBuilder private var screens: some View {
        Group {
            if model.launch.screen == "avatars" {
                AvatarGallery()
            } else if let store = model.store {
                MainScreen()
                    .environment(store)
                    .id(ObjectIdentifier(store))
            } else {
                PairingView(isSheet: false)
            }
        }
    }
}

#if DEBUG
/// Screenshot automation for the demo, where tools may not capture or resize
/// windows: `-demoWindow 1440x900` sizes the Mac window, `-demoOrientation
/// landscape` turns an iPad, `-demoAppearance dark` forces an appearance, and
/// `-demoSnapshot <name>` writes the window to
/// <app tmp>/<name>.png a few seconds after launch (the app is sandboxed).
private struct DemoCapture: ViewModifier {
    let demo: Bool

    func body(content: Content) -> some View {
        content.task {
            guard demo else { return }
            let d = UserDefaults.standard
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            // `-demoAppearance dark|light`: the system setting isn't reachable from a launch argument.
            if let look = d.string(forKey: "demoAppearance") {
                for w in scene?.windows ?? [] { w.overrideUserInterfaceStyle = look == "dark" ? .dark : .light }
            }
            if let size = d.string(forKey: "demoWindow")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
                scene?.sizeRestrictions?.minimumSize = CGSize(width: min(size[0], 400), height: min(size[1], 400))
                // The window must be up first, and an early request is sometimes dropped.
                for _ in 0..<3 {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard let scene, abs(scene.effectiveGeometry.coordinateSpace.bounds.width - size[0]) > 1 else { break }
                    scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 60, y: 40, width: size[0], height: size[1]))) {
                        print("[demo] window: \($0)")
                    }
                }
            }
            if d.string(forKey: "demoOrientation") == "landscape" {
                scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
            }
            guard let name = d.string(forKey: "demoSnapshot") else { return }
            let delay = d.double(forKey: "demoSnapshotDelay")
            try? await Task.sleep(for: .seconds(delay > 0 ? delay : 3))
            guard let window = scene?.keyWindow ?? scene?.windows.first else { return }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png")
            try? image.pngData()?.write(to: url)
            print("[demo] snapshot \(url.path)")
        }
    }
}
#endif

#if DEBUG
/// DEBUG automation for checks without a usable screen:
/// `-resizeTest YES` walks the Mac window through a series of widths and
/// toggles the sidebar and inspector, logging each step (the stall watchdog
/// logs any hang in between); `-demoActions "assistant,back,..."` performs
/// navigation steps two seconds apart (back = ⌘[; assistant: management;
/// library: 成果; settings; sidebar: the list's column; list), logging what's
/// on screen after each.
private struct LayoutStressTest: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.task {
            let d = UserDefaults.standard
            if let actions = d.string(forKey: "demoActions") {
                try? await Task.sleep(for: .seconds(d.double(forKey: "demoActionsDelay") > 0 ? d.double(forKey: "demoActionsDelay") : 4))
                for a in actions.split(separator: ",").map(String.init) {
                    guard model.store != nil else { break }
                    switch a {
                    case "back": model.goBack()
                    case "assistant": model.toggleManagement()
                    case "library": model.toggleLibrary()
                    case "settings": model.openSettings()
                    case "sidebar": model.columnVisibility = model.columnVisibility == .detailOnly ? .all : .detailOnly
                    case "list": model.showList()
                    default: break
                    }
                    try? await Task.sleep(for: .seconds(1.5))
                    debugLog("[nav] after \(a): layout \(model.layout.rawValue) selection \(String(describing: model.selection)) management \(model.showManagement) inspector \(model.inspectorShown) settings \(model.showSettings)")
                    try? await Task.sleep(for: .seconds(0.5))
                }
            }
            guard d.bool(forKey: "resizeTest") else { return }
            try? await Task.sleep(for: .seconds(6))
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
            scene.sizeRestrictions?.minimumSize = CGSize(width: 500, height: 500)
            @MainActor func size(_ w: CGFloat) async {
                debugLog("[resize] → \(Int(w))")
                scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 60, y: 40, width: w, height: 860)))
                try? await Task.sleep(for: .milliseconds(120))
            }
            // A live drag: many small steps, both ways, around the widths that matter.
            for w in stride(from: 1450.0, through: 640.0, by: -18.0) { await size(w) }
            for w in stride(from: 640.0, through: 1450.0, by: 18.0) { await size(w) }
            try? await Task.sleep(for: .seconds(1))
            for w: CGFloat in [1450, 1000, 820] {
                await size(w)
                try? await Task.sleep(for: .seconds(1))
                for _ in 0..<2 {
                    debugLog("[resize] sidebar toggle at \(Int(w))")
                    model.columnVisibility = model.columnVisibility == .detailOnly ? .all : .detailOnly
                    try? await Task.sleep(for: .seconds(1.2))
                    debugLog("[resize] inspector toggle at \(Int(w))")
                    model.inspectorShown.toggle()
                    try? await Task.sleep(for: .seconds(1.2))
                }
            }
            debugLog("[resize] done")
        }
    }
}
#endif

/// Standard navigation (pals-prd §2): the list (the assistant, its Pals, its
/// Allies) and the conversation picked in it, in a system split view.
/// Phones collapse it into one stack that opens on the assistant's
/// conversation, the list one step back; iPads and the Mac keep the list in
/// a sidebar the system toggle shows and hides. Management (the orb) and 成果
/// are pushed over the conversation on phones; on large screens management
/// is a sheet and 成果 the inspector beside the conversation.
struct MainScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var heightClass
    @State private var voice = VoiceInputController()

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $model.columnVisibility, preferredCompactColumn: $model.compactColumn) {
            ConversationList()
                .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 400)
                .modifier(InContentNavigationBar())
        } detail: {
            ConversationDetail()
        }
        // 成果 beside the conversation: on the split view, not in its detail
        // column (see LibraryInspector).
        .modifier(LibraryInspector(model: model, store: store))
        .onChange(of: sizeClass, initial: true) { _, c in
            model.shortWindow = heightClass == .compact
            model.setLayout(c == .compact ? .phone : .split)
            model.applyLaunchScreen()
        }
        .onChange(of: heightClass) { _, h in model.shortWindow = h == .compact }
        .environment(voice)
        // Voice input hears better with the conversation's names and terms.
        .task(id: ObjectIdentifier(store)) {
            voice.dictation.contextProvider = { [store] in
                VoiceContext.build(
                    messages: store.messages,
                    assistantName: store.assistantName,
                    goalTitles: store.watches.map(\.title),
                    artifactTitles: store.artifacts.sorted { $0.updatedAt > $1.updatedAt }.map(\.title),
                    quote: store.replyDraft?.excerpt)
            }
        }
        .modifier(MacWindowChrome(model: model))
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && voice.previewText == nil { voice.abort() }
        }
        // Leaving a conversation (phones: back to the list, or a page pushed
        // over it): put the keyboard and any recording away.
        .onChange(of: model.compactColumn) { _, column in
            guard column == .sidebar, model.layout == .phone else { return }
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            if voice.previewText == nil { voice.abort() }
        }
        .onAppear {
            if model.launch.screen == "voice" { voice.showPreview("你好，你好，你好，我正在说话") }
            model.markSeen()
        }
        // Everything on screen counts as seen (drives the other assistants' unread dots).
        .onChange(of: store.lastSeq) { model.markSeen() }
        // Large screens: the assistant's management over everything.
        .sheet(isPresented: $model.showManagement) {
            ManagementSheet()
                .environment(model)
                .environment(store)
                .environment(voice)
        }
        .sheet(isPresented: Binding(get: { model.showPairingSheet }, set: { if !$0 { model.showPairingSheet = false } })) {
            PairingView(isSheet: true).environment(model).environment(store)
        }
        // Right after pairing, once: 「给它起个名字」.
        .sheet(isPresented: Binding(get: { needsNaming }, set: { if !$0 { model.namingDone = true } })) {
            IdentityEditor(purpose: .firstTime).environment(model).environment(store)
        }
        // An Ally's invite opened from the system Camera.
        .sheet(item: Binding(get: { model.allyInvite }, set: { model.allyInvite = $0 })) { pending in
            AllyAcceptSheet(pending: pending).environment(model).environment(store)
        }
        .sheet(isPresented: $model.showAllyInvite) {
            AllyInviteSheet().environment(store)
        }
    }

    /// Asked once per computer: it's paired, its settings arrived and it has no name yet.
    private var needsNaming: Bool {
        guard !model.namingDone, !model.showPairingSheet else { return false }
        if model.launch.screen == "naming" { return store.settings != nil }
        guard model.mode == .paired, let s = store.settings else { return false }
        return s.assistantName.isEmpty
    }
}

/// The detail column: the conversation picked in the list, with pages
/// pushed over it (phones).
private struct ConversationDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let current = model.selection ?? .palo
        NavigationStack(path: $model.detailPath) {
            Group {
                switch current {
                case .palo:
                    ChatView()
                case .pal(let id):
                    PalPage(palID: id).id("pal-\(id)")
                case .ally(let id):
                    AllyConversationView(allyID: id).id("ally-\(id)")
                case .recent:
                    RecentConversationsPage()
                }
            }
            .modifier(InContentNavigationBar())
            .navigationDestination(for: AppModel.Page.self) { page in
                switch page {
                case .manage: AssistantView()
                case .library: LibraryView()
                case .artifact(let id): ArtifactDetailView(artifactID: id)
                case .task(let id): TaskDetailView(taskID: id)
                }
            }
        }
        // Each conversation keeps its own unsent words.
        .environment(\.chatDraft, Binding(get: { model.drafts[current] ?? "" }, set: { model.drafts[current] = $0 }))
        .background {
            // Esc puts 成果 away, like ⌘[.
            if model.libraryBeside && model.inspectorShown {
                Button("关闭成果") { model.inspectorShown = false }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        // Beside the sidebar the conversation gets roomier margins.
        .environment(\.placesAsColumns, model.layout != .phone)
    }
}

/// Large screens: 成果 in the inspector beside the conversation. Phones push
/// it instead, and don't get the modifier at all (an inspector that isn't
/// shown still lends its toolbar and search field to the conversation there).
///
/// It goes on the split view itself. Inside the detail column, the
/// inspector's own stack was taken for the column's: on the Mac a click on
/// an item only highlighted its row, and opening one from the conversation
/// (changing `libraryPath`) crashed SwiftUI comparing that path with the
/// conversation's (`AnyNavigationPath.Error.comparisonTypeMismatch`).
private struct LibraryInspector: ViewModifier {
    let model: AppModel
    let store: AppStore

    func body(content: Content) -> some View {
        if !model.libraryBeside {
            content
        } else {
            // Opened only on demand: the system may close it (too narrow) but
            // its restored state from the last run doesn't reopen it.
            content.inspector(isPresented: Binding(
                get: { model.inspectorShown },
                set: { if !$0 { model.inspectorShown = false } }
            )) {
                // Presented outside this hierarchy on some platforms: pass what it reads.
                LibraryPanel()
                    .environment(model)
                    .environment(store)
                    .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
            }
        }
    }
}

/// 成果 beside the conversation (large screens): the list, items pushed over it.
private struct LibraryPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.libraryPath) {
            LibraryView()
                .modifier(InContentNavigationBar())
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { model.inspectorShown = false } label: { Image(systemName: "xmark") }
                            .tint(.primary)
                            .accessibilityLabel("关闭成果")
                    }
                }
        }
        .environment(\.placesAsColumns, true)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}

/// The assistant's management as a sheet (large screens), with its own pages.
private struct ManagementSheet: View {
    var body: some View {
        NavigationStack {
            AssistantView(inSheet: true)
                .modifier(InContentNavigationBar())
        }
        .presentationSizing(.page)
    }
}

extension EnvironmentValues {
    /// Large screens: the conversation sits beside the sidebar (or 成果 in
    /// the inspector), with roomier margins.
    @Entry var placesAsColumns = false
    /// The open conversation's unsent text (kept per conversation by AppModel).
    @Entry var chatDraft: Binding<String> = .constant("")
}

#Preview("Demo") {
    let model = AppModel.demo()
    RootView().environment(model)
}
