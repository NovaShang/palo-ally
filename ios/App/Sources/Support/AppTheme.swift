import PaloAllyKit
import SwiftUI
import UIKit

/// The theme color. Each assistant (paired computer) has its own, picked in
/// 设置 → 主题色 or 我的助理; the app takes the current assistant's color.
/// 洋红 is the default — the owner's color (#D156A7). The app icon follows
/// the first assistant (alternate icons rendered by scripts/make_icons.py;
/// keep the light colors there in sync).
enum AppTheme: String, CaseIterable, Identifiable {
    case magenta, orchid, rose, berry, blue, violet, teal, orange, graphite

    static let storageKey = "themeColor"
    static let `default` = AppTheme.magenta

    var id: String { rawValue }

    var name: String {
        switch self {
        case .magenta: "洋红"
        case .orchid: "品红"
        case .rose: "玫红"
        case .berry: "深洋红"
        case .blue: "蓝"
        case .violet: "紫"
        case .teal: "青绿"
        case .orange: "橙"
        case .graphite: "石墨"
        }
    }

    /// Light-mode color, and a slightly more luminous one of the same hue for dark mode.
    private var hex: (light: UInt32, dark: UInt32) {
        switch self {
        case .magenta: (0xD156A7, 0xE06BB8)
        case .orchid: (0xA84FD0, 0xC27BE6)
        case .rose: (0xDE4A7C, 0xEE6E98)
        case .berry: (0xA3307F, 0xC9509F)
        case .blue: (0x2F6FE0, 0x5B8FF0)
        case .violet: (0x6E4BD8, 0x8E72EA)
        case .teal: (0x0F8F84, 0x2BB5A6)
        case .orange: (0xEC7355, 0xF99073)
        case .graphite: (0x4A5260, 0x7C8697)
        }
    }

    /// The accent: tints, icons, outlines. Adapts to light / dark.
    var color: Color {
        let (light, dark) = (UIColor(hex: hex.light), UIColor(hex: hex.dark))
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    /// The alternate icon for this theme (nil = the primary AppIcon).
    var iconName: String? { self == .default ? nil : "AppIcon-\(rawValue)" }

    /// The single app-wide choice older builds stored; migrated to the first assistant.
    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .default
    }

    /// Switches the home-screen icon to match (iOS shows its own confirmation).
    @MainActor static func applyIcon(_ theme: AppTheme) {
        let app = UIApplication.shared
        guard app.supportsAlternateIcons, app.alternateIconName != theme.iconName else { return }
        app.setAlternateIconName(theme.iconName) { error in
            if let error { debugLog("icon switch failed: \(error.localizedDescription)") }
        }
    }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.default
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

extension View {
    /// Applies the theme app-wide: `.tint` / `.tint` shape styles and
    /// `Color.accentColor` both follow it, and views can read `\.appTheme`.
    func appTheme(_ theme: AppTheme) -> some View {
        environment(\.appTheme, theme)
            .tint(theme.color)
            .accentColor(theme.color) // Color.accentColor resolves from this, not from .tint
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
