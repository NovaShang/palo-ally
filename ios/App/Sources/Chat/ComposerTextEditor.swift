import SwiftUI
import UIKit

/// The composer's text input, ported from bento's `AcpComposerTextEditor`
/// (iOS half): a UITextView that grows to `maxHeight` then scrolls, and —
/// unlike SwiftUI's `TextField(axis: .vertical)` — doesn't re-lay out the whole
/// draft on every render, so big pastes stay smooth. Height is measured only on
/// real edits or width changes.
///
/// PaloAlly additions: Return on a hardware keyboard / Mac sends and
/// Shift/Option+Return is a newline, but never while an input method is
/// composing (picking a pinyin candidate must not send); the on-screen
/// keyboard's Return stays a newline. Focus is reported back so the composer
/// knows when it's editing.
struct ComposerTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    /// True while an IME composition (marked text) is on screen — the host hides
    /// the placeholder so it doesn't overlap the composing glyphs.
    @Binding var isComposing: Bool
    @Binding var isFocused: Bool
    var maxHeight: CGFloat
    /// Bump to raise the keyboard.
    var focusToken: Int
    var onReturn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComposerUITextView {
        let textView = ComposerUITextView()
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.textColor = .label
        textView.textContainerInset = UIEdgeInsets(top: 11, left: 0, bottom: 11, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = true
        textView.keyboardDismissMode = .interactive
        textView.text = text
        textView.onHardwareReturn = { [weak coordinator = context.coordinator] in coordinator?.parent.onReturn() }
        context.coordinator.textView = textView
        DispatchQueue.main.async { context.coordinator.recomputeHeight() }
        return textView
    }

    func updateUIView(_ textView: ComposerUITextView, context: Context) {
        context.coordinator.parent = self
        var recompute = false
        if textView.text != text { textView.text = text; recompute = true }
        // A width change (rotation, layout) re-wraps the text → new height.
        if abs(textView.bounds.width - context.coordinator.lastWidth) > 0.5 {
            context.coordinator.lastWidth = textView.bounds.width
            recompute = true
        }
        if recompute { context.coordinator.recomputeHeight() }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { textView.becomeFirstResponder() }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextEditor
        weak var textView: UITextView?
        var lastFocusToken: Int
        var lastWidth: CGFloat = 0

        init(_ parent: ComposerTextEditor) {
            self.parent = parent
            self.lastFocusToken = parent.focusToken
        }

        func textViewDidChange(_ textView: UITextView) {
            let composing = textView.markedTextRange != nil
            if parent.isComposing != composing { parent.isComposing = composing }
            parent.text = textView.text
            recomputeHeight()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }

        /// Grow the field with the draft up to maxHeight, then let it scroll.
        /// Measured only on real edits / width changes — never per render — so
        /// a huge paste doesn't re-measure on every SwiftUI pass.
        func recomputeHeight() {
            guard let textView else { return }
            let width = textView.bounds.width > 0 ? textView.bounds.width : 300
            let fit = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            let clamped = min(max(fit.height, 0), parent.maxHeight)
            guard abs(clamped - parent.measuredHeight) > 0.5 else { return }
            DispatchQueue.main.async { self.parent.measuredHeight = clamped }
        }
    }
}

/// Catches Return from a hardware keyboard (the on-screen keyboard doesn't
/// come through `pressesBegan`).
final class ComposerUITextView: UITextView {
    var onHardwareReturn: (() -> Void)?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let key = presses.first?.key,
           key.keyCode == .keyboardReturnOrEnter,
           markedTextRange == nil,
           key.modifierFlags.isDisjoint(with: [.shift, .alternate]) {
            onHardwareReturn?()
            return
        }
        super.pressesBegan(presses, with: event)
    }
}
