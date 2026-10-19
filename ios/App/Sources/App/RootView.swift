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
/// <app tmp>/<name>.png a few seconds after launch (the app is sandboxed),
/// and on a Mac <name>-window.png with the titlebar's controls drawn over it.
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
            #if targetEnvironment(macCatalyst)
            // The window as AppKit draws it, with its titlebar and toolbar.
            let full = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-window.png")
            if let composite = AppKitBundle.addTitlebar(to: image) {
                try? composite.pngData()?.write(to: full)
                print("[demo] window snapshot \(full.path)")
            }
            #endif
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
                    debugLog("[nav] after \(a): layout \(model.layout.rawValue) selection \(String(describing: model.selection)) management \(model.showManagement) pane \(model.paneIsOpen) settings \(model.showSettings)")
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
                    debugLog("[resize] pane toggle at \(Int(w))")
                    model.togglePane()
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
    /// Local to this computer: the sidebar away or not.
    private static let sidebarCollapsedKey = "sidebarCollapsed"

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $model.columnVisibility, preferredCompactColumn: $model.compactColumn) {
            ConversationList()
                .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 400)
                .modifier(InContentNavigationBar())
        } detail: {
            ConversationDetail()
        }
        // The right pane beside the conversation: on the split view, not in its
        // detail column (see RightPaneHost).
        .modifier(RightPaneHost(model: model, store: store))
        // The sidebar's capsule and its way back from the left edge.
        .modifier(SidebarCollapse(model: model))
        // The pane's tabs come from the computer (once online, and again on reconnect).
        .task(id: store.connection.isOnline) {
            if store.connection.isOnline { await PaneTabsHub.shared(for: store).load() }
        }
        .onChange(of: sizeClass, initial: true) { _, c in
            model.shortWindow = heightClass == .compact
            model.setLayout(c == .compact ? .phone : .split)
            // The sidebar stays as it was left on this computer (one setting, not per workspace).
            if c != .compact, UserDefaults.standard.bool(forKey: Self.sidebarCollapsedKey) {
                model.columnVisibility = .detailOnly
            }
            model.applyLaunchScreen()
        }
        .onChange(of: heightClass) { _, h in model.shortWindow = h == .compact }
        .onChange(of: model.columnVisibility) { _, v in
            guard sizeClass == .regular else { return }
            UserDefaults.standard.set(v == .detailOnly, forKey: Self.sidebarCollapsedKey)
        }
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
            if model.launch.screen == "voice" { voice.showPreview("你好，你好，你好，我正在说话" /* i18n-ok: demo preview text */) }
            model.markSeen()
            model.installPaneOpeners()
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
        // 新建会话 (⌘N, ＋) and 新建工作区 (⌘⇧N, ＋, a session's 并排…).
        .sheet(isPresented: $model.newSession, onDismiss: { model.newSessionIntoWorkspace = nil }) {
            NewSessionPanel().environment(model).environment(store)
        }
        .sheet(isPresented: Binding(get: { model.newWorkspace != nil }, set: { if !$0 { model.newWorkspace = nil } })) {
            NewWorkspaceSheet(preselected: model.newWorkspace ?? []).environment(model).environment(store)
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
        // A pairing link for this very computer: for passing on to another device.
        .modifier(LinkForAnotherDeviceAlert(model: model))
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
                case .workspace(let id):
                    // Phones don't tile (workbench-prd §12): the sessions, one tap each.
                    if model.layout == .phone {
                        WorkspacePage(workspaceID: id).id("workspace-\(id)")
                    } else {
                        WorkspaceTilesPage(workspaceID: id).id("workspace-\(id)")
                    }
                case .earlier:
                    EarlierPage()
                case .session(let id):
                    SessionPage(sessionID: id).id("session-\(id)")
                case .devices:
                    DevicesPage()
                }
            }
            .modifier(InContentNavigationBar())
            .modifier(HidesSystemSidebarToggle())
            // A folder's tree over 成果 (phones), and the files paths in replies link to.
            .modifier(FilesInConversation(current: current))
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
            if model.libraryBeside && model.paneKey == PaneTabsKey.palo && model.paneIsOpen {
                Button("关闭成果") { model.setPane(open: false) }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        // Beside the sidebar the conversation gets roomier margins.
        .environment(\.placesAsColumns, model.layout != .phone)
    }
}

/// The right pane (workbench-prd §7): large screens set it beside the
/// conversation as the split view's inspector; phones (and short windows) show
/// the same pane as a full page from the same button. Whose tabs it shows
/// follows the open page (`AppModel.paneKey`). Phones don't get the inspector
/// at all (one that isn't shown still lends its toolbar and search field to
/// the conversation there).
///
/// It goes on the split view itself. Inside the detail column, the
/// inspector's own stack was taken for the column's: on the Mac a click on
/// an item only highlighted its row, and opening one from the conversation
/// crashed SwiftUI comparing paths (`AnyNavigationPath.Error.comparisonTypeMismatch`).
private struct RightPaneHost: ViewModifier {
    let model: AppModel
    let store: AppStore

    func body(content: Content) -> some View {
        let key = model.paneKey ?? PaneTabsKey.palo
        if !model.libraryBeside {
            content.rightPaneCover(
                isPresented: Binding(get: { model.paneCover }, set: { model.paneCover = $0 }),
                key: key, activeSessionID: model.paneSessionID)
        } else {
            // Opened only on demand (its state is kept per page on the computer).
            content.inspector(isPresented: Binding(
                get: { model.paneKey != nil && model.paneIsOpen },
                set: { if !$0 { model.setPane(open: false) } }
            )) {
                // Presented outside this hierarchy on some platforms: pass what it reads.
                RightPane(key: key, activeSessionID: model.paneSessionID)
                    .id(key)
                    .environment(model)
                    .environment(store)
                    .inspectorColumnWidth(min: 320, ideal: 400, max: 640)
            }
        }
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
