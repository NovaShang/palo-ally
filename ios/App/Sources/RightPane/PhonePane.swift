import PaloAllyFilePreview
import PaloAllyKit
import SafariServices
import SwiftUI

// The phone's right pane (workbench-prd §7): no tabs. One page with a
// segmented 成果 / 文件 control; anything opened from it, or from a path or
// link in a reply, is a full-screen modal that closes back to where it came
// from. Nothing is remembered.

/// Which half of the phone's pane page shows.
@MainActor @Observable
final class PhonePaneState {
    static let shared = PhonePaneState()
    enum Segment: Hashable { case library, files }
    var segment: Segment = .library
}

extension EnvironmentValues {
    /// 成果 inside the phone's pane: an item opens as a full-screen modal, not pushed.
    @Entry var libraryOpensModal: Bool = false
    /// The session whose items 成果 offers first (nil: Palo's, everything).
    @Entry var libraryPalID: String? = nil
}

/// Full-screen modals over whatever is on screen.
@MainActor
enum PaneModal {
    static func file(_ target: FileTarget, model: AppModel, store: AppStore) {
        present(model: model, store: store) { close in
            FilePage(target: target, close: close)
        }
    }

    static func artifact(_ id: String, model: AppModel, store: AppStore) {
        present(model: model, store: store) { close in
            ArtifactDetailView(artifactID: id)
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button(role: .close, action: close) } }
        }
    }

    /// A page in the system's browser view. false: not a web address.
    @discardableResult
    static func web(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let top = QuickLookPresenter.topController() else { return false }
        let safari = SFSafariViewController(url: url)
        safari.modalPresentationStyle = .fullScreen
        top.present(safari, animated: true)
        return true
    }

    private static func present<Content: View>(model: AppModel, store: AppStore,
                                               @ViewBuilder _ content: @escaping (@escaping () -> Void) -> Content) {
        guard let top = QuickLookPresenter.topController() else { return }
        weak var presented: UIViewController?
        let close: () -> Void = { presented?.dismiss(animated: true) }
        let page = NavigationStack { content(close) }
            .environment(model)
            .environment(store)
        let controller = UIHostingController(rootView: page)
        controller.modalPresentationStyle = .fullScreen
        presented = controller
        top.present(controller, animated: true)
    }
}

/// The pane as one page on a phone.
struct PhonePane: View {
    let key: String
    var activeSessionID: String? = nil
    let onClose: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(AppStore.self) private var store
    private var state: PhonePaneState { .shared }

    var body: some View {
        @Bindable var state = state
        let scope = RightPaneScope.resolve(key: key, activeSessionID: activeSessionID, store: store)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker(selection: $state.segment) {
                    Text("成果", tableName: "Files").tag(PhonePaneState.Segment.library)
                    Text("文件", tableName: "Files").tag(PhonePaneState.Segment.files)
                } label: {
                    Text("文件", tableName: "Files")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("phone-pane-segment")
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 32, height: 32).contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel(String(localized: "关闭侧栏", table: "Files"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            switch state.segment {
            case .library:
                LibraryTab()
                    .environment(\.libraryOpensModal, true)
                    .environment(\.libraryPalID, RightPaneScope.palID(of: scope))
            case .files:
                NavigationStack {
                    FileTreeScreen(scope: scope,
                                   onOpenFile: { PaneModal.file($0, model: model, store: store) })
                }
                .id(scope)
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .accessibilityIdentifier("right-pane")
    }
}
