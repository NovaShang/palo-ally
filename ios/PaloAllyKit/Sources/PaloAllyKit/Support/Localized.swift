import Foundation

/// A user-facing string from this module's String Catalog (Chinese is the
/// development language, English the other). The catalog keys are the Chinese
/// sentences themselves, so the call site reads as the Chinese UI does.
func loc(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: Localization.bundle)
}

enum Localization {
    /// Where the strings come from: this module's catalog in the language the
    /// device is set to. In a test run (whose process has no language of its own)
    /// Chinese, the development language, unless PALOALLY_UI_LANGUAGE names another.
    static let bundle: Bundle = {
        let forced = ProcessInfo.processInfo.environment["PALOALLY_UI_LANGUAGE"]
        let inTests = Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
            || CommandLine.arguments.contains { $0.hasSuffix(".xctest") || $0.contains("xctest") }
        guard let language = forced ?? (inTests ? "zh-Hans" : nil),
              let path = Bundle.module.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .module }
        return bundle
    }()
}

/// A sentence written for the owner in the app's own words (not the host's):
/// it reaches the screen as it is.
struct FriendlyError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}
