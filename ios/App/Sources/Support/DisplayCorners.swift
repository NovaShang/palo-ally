import UIKit

/// The display's corner radius and home-indicator inset, for laying things out
/// concentric with the screen corners (the iOS 26 look). The radius comes from
/// UIKit's own container-concentric resolution: a probe view flush in the
/// window's bottom corner with `.containerConcentric()` corners reports the
/// display's radius (0 where the screen or window has square corners).
@MainActor
enum DisplayCorners {
    private static var cachedRadius: CGFloat?

    static var radius: CGFloat {
        if let cachedRadius { return cachedRadius }
        guard let window = keyWindow else { return 0 }
        // Big enough that its own size never caps the radius (a view's radius
        // is clamped to half its shorter side).
        let side = min(window.bounds.width, window.bounds.height)
        let probe = UIView(frame: CGRect(x: 0, y: window.bounds.height - side, width: side, height: side))
        probe.cornerConfiguration = .corners(radius: .containerConcentric())
        window.addSubview(probe)
        probe.layoutIfNeeded()
        let r = probe.effectiveRadius(corner: .bottomLeft)
        probe.removeFromSuperview()
        cachedRadius = r
        return r
    }

    /// The window's bottom safe-area inset (the home indicator), keyboard aside.
    static var bottomInset: CGFloat { keyWindow?.safeAreaInsets.bottom ?? 0 }

    /// The window's top safe-area inset: the status bar, and the Dynamic
    /// Island above whatever floats near the top.
    static var topInset: CGFloat { keyWindow?.safeAreaInsets.top ?? 0 }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }
}
