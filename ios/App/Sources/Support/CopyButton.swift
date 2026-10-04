import SwiftUI
import UIKit

// Ported from bento (AgentChatView.swift: AcpClipboard / AcpCopyButton), in
// our glass look. Markdown blocks can't be drag-selected across, so one-tap
// copy is the way to lift a whole answer or a code block.

enum Clipboard {
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }
}

/// A small copy affordance that flashes a checkmark for feedback.
struct CopyButton: View {
    let text: String
    var label = "复制"
    @State private var copied = false

    var body: some View {
        Button {
            Clipboard.copy(text)
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
                .glassEffect(.regular.interactive(), in: .circle)
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
