import SwiftUI
import UIKit

// Ported from bento (AgentChatView.swift: AcpClipboard / AcpCopyButton).
// Deliberately plain: a quiet glyph, no glass or container — it sits under
// every answer and shouldn't compete with the text.

enum Clipboard {
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }
}

/// A small copy affordance that flashes a checkmark for feedback.
struct CopyButton: View {
    let text: String
    var label = "复制"
    /// Where the glyph sits inside its (larger, invisible) tap area — `.leading`
    /// lines it up with text above it.
    var glyphAlignment: Alignment = .center
    @State private var copied = false

    var body: some View {
        Button {
            Clipboard.copy(text)
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 32, alignment: glyphAlignment)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "已复制" : label)
        .sensoryFeedback(.success, trigger: copied) { _, now in now }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.3))
            withAnimation(.easeOut(duration: 0.15)) { copied = false }
        }
    }
}
