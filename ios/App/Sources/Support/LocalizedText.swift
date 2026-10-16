import Foundation

enum LocalizedText {
    /// A sentence some caller built as a plain String (a literal, or already
    /// filled in): looked up in the catalog as it is, so literals translate and
    /// filled-in text passes through (no format or Markdown reading, unlike LocalizedStringKey).
    static func verbatimKey(_ text: String) -> String {
        String(localized: String.LocalizationValue(text))
    }
}
