import PaloAllyKit
import SwiftUI
import UIKit

extension EnvironmentValues {
    /// The list is the floating one: it doesn't claim the orb's resting place
    /// (the capsule has it while the sidebar is away).
    @Entry var inFloatingSidebar = false
}

/// What the detail column needs to know about the sidebar's chrome.
@MainActor @Observable
final class SidebarChrome {
    static let shared = SidebarChrome()
    /// An iPad in landscape with the sidebar away: the capsule is up, so the
    /// detail's own system sidebar button goes.
    var capsuleOnPad = false
}

/// The sidebar's collapse (workbench-prd §8), around the split view:
/// - the capsule at the window's top left (the sidebar button; collapsed, the
///   orb and what waits);
/// - collapsed, the sidebar floats in from the left over the content without
///   pushing it: the mouse at the window's left edge (Mac), a swipe from the
///   left edge (iPad). It goes when the mouse leaves it (300 ms), when a row
///   is picked, or on Esc.
/// The split view itself keeps doing the collapse (`columnVisibility`, the
/// full width for the detail); this only adds the way back.
struct SidebarCollapse: ViewModifier {
    let model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var peeking = false
    @State private var hideTask: Task<Void, Never>?
    @State private var landscape = true
    /// Where the traffic lights end and the toolbar's middle line, in the window.
    @State private var inset: CGFloat = 80
    @State private var midY: CGFloat = 26

    private var large: Bool { sizeClass == .regular && model.layout == .split }
    /// The capsule: always on the Mac (the sidebar's button), on an iPad when
    /// it is wide enough to be a landscape window.
    private var showsCapsule: Bool { large && (Platform.isMac || (landscape && model.sidebarCollapsed)) }
    private var canPeek: Bool { large && model.sidebarCollapsed && (Platform.isMac || landscape) }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                landscape = size.width > size.height
                refreshChrome()
            }
            .overlay(alignment: .leading) {
                if canPeek { peekLayer }
            }
            .overlay(alignment: .topLeading) {
                if showsCapsule { capsule }
            }
            #if !targetEnvironment(macCatalyst)
            .background { EdgeSwipe(enabled: canPeek && !peeking) { reveal() } }
            #endif
            .background {
                // Esc puts the floating sidebar away.
                if peeking {
                    Button("收起侧栏") { hide() }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: model.selection) { hide() }
            .onChange(of: canPeek) { _, can in if !can { hide() } }
            .onChange(of: showsCapsule && !Platform.isMac) { _, on in SidebarChrome.shared.capsuleOnPad = on }
            .task { refreshChrome() }
    }

    // MARK: capsule

    @ViewBuilder private var capsule: some View {
        if Platform.isMac {
            CollapsedSidebarCapsule(collapsed: model.sidebarCollapsed)
                .padding(.leading, inset)
                .padding(.top, max(2, midY - 17))
                .ignoresSafeArea()
        } else {
            CollapsedSidebarCapsule(collapsed: true)
                .padding(.leading, 12)
                .padding(.top, 6)
        }
    }

    /// The Mac: the window's traffic lights end somewhere, and full screen has none.
    private func refreshChrome() {
        guard Platform.isMac else { return }
        Task { @MainActor in
            for delay in [0, 400, 1200] as [Int] {
                try? await Task.sleep(for: .milliseconds(delay))
                if let c = AppKitBundle.leadingChrome() {
                    inset = c.x + 10
                    midY = c.y
                }
            }
        }
    }

    // MARK: the floating sidebar

    private var peekLayer: some View {
        ZStack(alignment: .leading) {
            if peeking && !Platform.isMac {
                // No hover on a touch screen: a tap beside it puts it away.
                Color.black.opacity(0.001)
                    .contentShape(.rect)
                    .onTapGesture { hide() }
                    .ignoresSafeArea()
            }
            // The hot zone: invisible, a little in from the window's resize edge.
            if !peeking {
                Color.clear
                    .frame(width: 8)
                    .padding(.leading, 3)
                    .padding(.top, 8)
                    .contentShape(.rect)
                    .onContinuousHover { phase in
                        if case .active = phase { reveal() }
                    }
                    .frame(maxHeight: .infinity)
            }
            if peeking {
                ConversationList()
                    .environment(\.inFloatingSidebar, true)
                    .frame(width: 310)
                    .scrollContentBackground(.hidden)
                    .clipShape(.rect(cornerRadius: 24))
                    .glassEffect(.regular, in: .rect(cornerRadius: 24))
                    .shadow(color: .black.opacity(0.22), radius: 28, x: 0, y: 8)
                    .padding(8)
                    .contentShape(.rect)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active: hideTask?.cancel()
                        case .ended: if Platform.isMac { scheduleHide() }
                        }
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .accessibilityIdentifier("sidebar-peek")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func reveal() {
        hideTask?.cancel()
        guard canPeek, !peeking else { return }
        withAnimation(.easeOut(duration: 0.15)) { peeking = true }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    private func hide() {
        hideTask?.cancel()
        guard peeking else { return }
        withAnimation(.easeIn(duration: 0.2)) { peeking = false }
    }
}

// MARK: - the sidebar button's two states, on the detail column

/// An iPad whose capsule is up has its own sidebar button: the system one in
/// the detail's navigation bar would be a second.
struct HidesSystemSidebarToggle: ViewModifier {
    func body(content: Content) -> some View {
        if SidebarChrome.shared.capsuleOnPad {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}

// MARK: - the iPad's swipe from the left edge

#if !targetEnvironment(macCatalyst)
/// A screen-edge pan from the left edge of the window, for the iPad.
private struct EdgeSwipe: UIViewRepresentable {
    let enabled: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Host {
        let v = Host()
        v.isUserInteractionEnabled = false
        v.coordinator = context.coordinator
        return v
    }

    func updateUIView(_ view: Host, context: Context) {
        context.coordinator.action = action
        context.coordinator.recognizer.isEnabled = enabled
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var action: () -> Void = {}
        let recognizer = UIScreenEdgePanGestureRecognizer()

        override init() {
            super.init()
            recognizer.edges = .left
            recognizer.delegate = self
            recognizer.addTarget(self, action: #selector(handle(_:)))
        }

        @objc func handle(_ r: UIScreenEdgePanGestureRecognizer) {
            if r.state == .began || r.state == .recognized { action() }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    final class Host: UIView {
        var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let r = coordinator?.recognizer else { return }
            r.view?.removeGestureRecognizer(r)
            window?.addGestureRecognizer(r)
        }
    }
}
#endif

// MARK: - the Mac's window chrome

#if targetEnvironment(macCatalyst)
extension AppKitBundle {
    /// Where the traffic lights end (0 in full screen, where there are none)
    /// and the middle of the toolbar's line, in the window's own points.
    static func leadingChrome() -> (x: CGFloat, y: CGFloat)? {
        guard let s = call("leadingChrome") else { return nil }
        let p = s.split(separator: ",").compactMap { Double($0) }
        return p.count == 2 ? (CGFloat(p[0]), CGFloat(p[1])) : nil
    }
}
#else
private enum AppKitBundle {
    static func leadingChrome() -> (x: CGFloat, y: CGFloat)? { nil }
}
#endif
