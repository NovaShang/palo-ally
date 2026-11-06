import PaloAllyKit
import SwiftUI
import UIKit

/// What the detail column needs to know about the Mac's title bar (the same
/// in every window).
@MainActor @Observable
final class SidebarChrome {
    static let shared = SidebarChrome()
    /// The Mac: the title bar's middle line (the traffic lights'), in the window.
    var titlebarMidY: CGFloat = 26
}

/// The Mac: the title bar's middle line, kept for what lines up with it
/// (`SidebarChrome`). The sidebar's collapse is the system's own: its
/// button in the window toolbar, no capsule, no floating sidebar from the
/// left edge (the owner, 11-05).
struct SidebarCollapse: ViewModifier {
    let model: WindowModel

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in refreshChrome() }
            .task { refreshChrome() }
    }

    /// The Mac: the window's traffic lights end somewhere, and full screen has none.
    private func refreshChrome() {
        guard Platform.isMac else { return }
        Task { @MainActor in
            for delay in [0, 400, 1200] as [Int] {
                try? await Task.sleep(for: .milliseconds(delay))
                if let c = AppKitBundle.leadingChrome() {
                    SidebarChrome.shared.titlebarMidY = c.y
                }
            }
        }
    }
}

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
