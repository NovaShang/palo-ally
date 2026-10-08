import SwiftUI
import UIKit
import PaloAllyKit

/// An assistant answer rendered as ONE attributed string in a non-editable
/// UITextView, so selection is the system's own: long-press a word, drag the
/// handles across paragraphs, Copy / Share / Look Up — like Notes or Safari.
/// MarkdownUI lays each block out as its own Text, and SwiftUI selection can't
/// cross blocks, which is why chat answers don't use it.
///
/// The look follows the `paloAlly` MarkdownUI theme (MarkdownText.swift):
/// body text with 0.2em line spacing, modest headings, monospaced code blocks
/// on a soft rounded background, a gray bar for quotes. Code blocks wrap
/// instead of scrolling sideways. Tables are split out before they get here
/// (ReplyMarkdown → MarkdownTableView); the tab-stop table below is a fallback.
struct SelectableMarkdown: UIViewRepresentable {
    let source: String
    var streaming: Bool = false
    /// 「引用回复」 in the selection menu: called with the selected text.
    var onQuote: ((String) -> Void)? = nil
    @Environment(\.appTheme) private var theme

    func makeUIView(context: Context) -> MarkdownTextView {
        let view = MarkdownTextView.make()
        view.onQuote = onQuote
        view.render(source: source, streaming: streaming, linkColor: theme.uiColor)
        return view
    }

    func updateUIView(_ view: MarkdownTextView, context: Context) {
        view.onQuote = onQuote
        view.render(source: source, streaming: streaming, linkColor: theme.uiColor)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MarkdownTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 10_000
        guard width > 0, width.isFinite else { return nil }
        // SwiftUI may size the view before updateUIView hands it the new text
        // (a streamed reply turning final): measure what it is about to show,
        // or the row keeps the shorter height and the end is cut off.
        uiView.render(source: source, streaming: streaming, linkColor: uiView.currentLinkColor ?? theme.uiColor)
        let fit = uiView.fittingSize(width: width)
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "textTrace") { debugLog("[text] size \(source.count)ch w=\(width) → h=\(fit.height)") }
        #endif
        return CGSize(width: proposal.width ?? ceil(fit.width), height: ceil(fit.height))
    }
}

final class MarkdownTextView: UITextView, UITextViewDelegate {
    var onQuote: ((String) -> Void)?
    private var lastSource: String?
    private var lastStreaming = false
    private var lastLinkColor: UIColor?
    var currentLinkColor: UIColor? { lastLinkColor }
    /// The text version a too-short frame was already reported for (see
    /// layoutSubviews), so one change asks SwiftUI to re-measure only once.
    private var renderVersion = 0
    private var reportedShortVersion = -1
    /// Measured sizes for the current text, by the width the text is laid
    /// out at. SwiftUI asks again on every layout pass, and each ask re-ran
    /// TextKit layout over the whole answer; a long chat full of long answers
    /// then pinned the main thread. Cleared whenever the text changes.
    private var measured: [CGFloat: CGSize] = [:]
    /// For each width SwiftUI gave the view, the width its text was laid out
    /// at (narrower while a window is being resized, see TextWidthSettling),
    /// so drawing uses exactly the layout that was measured.
    private var layoutWidthFor: [CGFloat: CGFloat] = [:]
    private var lastExactWidth: CGFloat?
    /// The width SwiftUI last measured the view at (nil until it has).
    var measuredWidth: CGFloat? { lastExactWidth }

    func fittingSize(width: CGFloat) -> CGSize {
        let exact = (width * 2).rounded(.down) / 2
        // Only real column widths count as a resize (not the huge width
        // SwiftUI proposes when it asks for an ideal size).
        let real = exact < 5000
        let key = real ? TextWidthSettling.layoutWidth(for: exact, previous: lastExactWidth, view: self) : exact
        if real { lastExactWidth = exact }
        if layoutWidthFor.count > 16 { layoutWidthFor.removeAll() }
        layoutWidthFor[exact] = key
        if let hit = measured[key] { return hit }
        let fit = layOut(width: key)
        if measured.count > 8 { measured.removeAll() }
        measured[key] = fit
        return fit
    }

    /// TextKit layout at `width`, once: the container keeps that width (it
    /// doesn't track the view), so a later frame change at the same width
    /// doesn't lay the whole answer out again, and measuring doesn't run a
    /// second throwaway layout the way UITextView.sizeThatFits does.
    private func layOut(width: CGFloat) -> CGSize {
        // UITextView shrinks the container's height to its frame on layout.
        // Measuring must lift that again, or a reply measured while it was
        // one streamed line stays one line tall after the rest arrives.
        if textContainer.size.width != width || textContainer.size.height < Self.unbounded {
            textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: textContainer)
        noteOpenBlockTop()
        let used = layoutManager.usedRect(for: textContainer)
        return CGSize(width: ceil(used.width),
                      height: ceil(used.height + textContainerInset.top + textContainerInset.bottom))
    }

    override func layoutSubviews() {
        // Lay the text out at the width it was measured at for this frame.
        let exact = (bounds.width * 2).rounded(.down) / 2
        if exact > 0 {
            let key = layoutWidthFor[exact] ?? exact
            if textContainer.size.width != key || textContainer.size.height < Self.unbounded {
                textContainer.size = CGSize(width: key, height: .greatestFiniteMagnitude)
            }
        }
        super.layoutSubviews()
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "textTrace") {
            layoutManager.ensureLayout(for: textContainer)
            debugLog("[text] layout \(attributedText.length)ch frame=\(bounds.size) used=\(layoutManager.usedRect(for: textContainer).size)")
        }
        #endif
        // Safety net: if the laid-out text is taller than the frame SwiftUI
        // gave us, the measurement was stale. Drop it and ask again.
        if exact > 0, bounds.height > 0, reportedShortVersion != renderVersion {
            let needed = layOut(width: textContainer.size.width).height
            if needed > bounds.height + 1 {
                #if DEBUG
                debugLog("[text] stale height: needs \(needed) > frame \(bounds.height); re-measuring")
                #endif
                reportedShortVersion = renderVersion
                measured.removeAll()
                askForHeight()
            }
        }
    }

    /// A resize has settled: measure again at the exact width.
    func widthSettled() {
        layoutWidthFor.removeAll()
        measured.removeAll()
        askForHeight()
        setNeedsLayout()
    }

    /// Has SwiftUI measure the view again: through its intrinsic size, or
    /// for the live end of a reply being written, through its model.
    private func askForHeight() {
        if reportsHeightItself { heightMayHaveChanged?() } else { invalidateIntrinsicContentSize() }
    }

    private static let unbounded: CGFloat = 1e7

    /// TextKit 1, so the layout manager can draw block backgrounds.
    static func make() -> MarkdownTextView {
        let storage = NSTextStorage()
        let layout = MarkdownLayoutManager()
        storage.addLayoutManager(layout)
        let container = UnboundedHeightContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        // Set by measuring (fittingSize), not by the frame: see layOut(width:).
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let view = MarkdownTextView(frame: .zero, textContainer: container)
        layout.owner = view
        view.delegate = view
        view.isEditable = false
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.adjustsFontForContentSizeCategory = false // re-rendered on size changes instead
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (v: MarkdownTextView, _) in
            v.lastSource = nil
            v.measured.removeAll()
            v.layoutWidthFor.removeAll()
            v.render(source: v.pendingSource, streaming: v.lastStreaming, linkColor: v.lastLinkColor ?? .link)
            v.askForHeight()
        }
        return view
    }

    private var pendingSource = ""
    /// Set for the live end of a reply being written (ReplyTextModel): its
    /// height goes to SwiftUI through the model, which is told here when it
    /// may have changed for another reason than new text (Dynamic Type, a
    /// settled window width, a stale measurement).
    var reportsHeightItself = false
    var heightMayHaveChanged: (() -> Void)?

    /// The finished blocks at the start of a reply being written: rendered
    /// once and never touched again while it grows (design §3.3). Where the
    /// source's unfinished part begins (UTF-16), and how long the frozen part
    /// is in the text storage (with the separator after each block).
    private var frozenSource = 0
    private var frozenLength = 0

    func render(source: String, streaming: Bool, linkColor: UIColor) {
        pendingSource = source
        // Called on every update of the conversation: anything but a real
        // change must return here, or the whole reply is parsed and laid out
        // again (many times a second while a reply streams in).
        guard source != lastSource || streaming != lastStreaming || !Self.sameColor(linkColor, lastLinkColor) else { return }
        // The text only grew (a reply being written, or finished as written):
        // only the unfinished end is parsed and replaced, so TextKit lays out
        // just that again. Anything else: all of it.
        let grew = lastSource.map { source.hasBytePrefix($0) } == true && Self.sameColor(linkColor, lastLinkColor)
            && frozenLength <= textStorage.length && frozenSource <= (source as NSString).length
        // What a tail render replaces, to tell the newly revealed text apart.
        let fresh = lastSource == nil
        let wasStreaming = lastStreaming
        let oldFrozen = frozenLength
        let oldTail = grew ? (textStorage.string as NSString).substring(from: oldFrozen) as NSString : nil
        Self.renders &+= 1
        lastSource = source
        lastStreaming = streaming
        lastLinkColor = linkColor
        measured.removeAll()
        let began = CACurrentMediaTime()
        defer { Self.noteRender(chars: source.count, since: began) }
        if grew {
            renderTail(source, streaming: streaming)
        } else {
            renderAll(source, streaming: streaming)
            linkTextAttributes = [.foregroundColor: linkColor]
        }
        noteRevealed(fresh: fresh, oldFrozen: oldFrozen, oldTail: oldTail, wasStreaming: wasStreaming, streaming: streaming)
        // A code block / table background reaches 6 pt past its text; make
        // room when one is first or last so it isn't clipped.
        let storage = textStorage
        let pad = { (i: Int) -> CGFloat in
            guard storage.length > 0, let kind = storage.attribute(.paloBlock, at: i, effectiveRange: nil) as? String else { return 0 }
            return kind == "code" || kind == "table" ? 6 : 0
        }
        let inset = UIEdgeInsets(top: pad(0), left: 0, bottom: storage.length > 0 ? pad(storage.length - 1) : 0, right: 0)
        if inset != textContainerInset { textContainerInset = inset }
        // Nothing to select mid-stream; links work once it's finished.
        if isSelectable == streaming { isSelectable = !streaming }
        renderVersion += 1
        layoutWidthFor.removeAll()
        // New text, new height: have SwiftUI ask sizeThatFits again. Not for
        // the end of a reply being written: its model reports a new height
        // only when there is one, since SwiftUI's host turns this into a
        // layout pass of the whole conversation.
        if !reportsHeightItself { invalidateIntrinsicContentSize() }
        setNeedsLayout()
    }

    // MARK: fading in

    /// Text changes so far (any view), to tell frames that only fade.
    static var renders = 0
    /// After the text of a reply being written.
    private static let cursorLength = (" ▍" as NSString).length
    private var markdownLayout: MarkdownLayoutManager? { layoutManager as? MarkdownLayoutManager }

    /// The text just revealed fades in (design §3.2): what a tail render
    /// added past what was there before (the cursor aside), or all of a
    /// reply's first words. The text storage isn't touched for it.
    private func noteRevealed(fresh: Bool, oldFrozen: Int, oldTail: NSString?, wasStreaming: Bool, streaming: Bool) {
        guard let layout = markdownLayout else { return }
        let storage = textStorage.string as NSString
        let end = storage.length - (streaming ? Self.cursorLength : 0)
        var from: Int?
        if let oldTail, wasStreaming || streaming {
            let newTail = storage.substring(from: oldFrozen) as NSString
            var same = 0
            let n = min(oldTail.length, newTail.length)
            while same < n, oldTail.character(at: same) == newTail.character(at: same) { same += 1 }
            from = oldFrozen + min(same, oldTail.length - (wasStreaming ? Self.cursorLength : 0))
        } else if fresh, streaming {
            from = 0
        } else if oldTail == nil, !layout.fades.isEmpty {
            // Laid out anew: the old places mean nothing.
            layout.fades.removeAll()
        }
        guard let from else { return }
        // Text that changed under a fade starts over; past the end there's nothing.
        layout.fades = layout.fades.compactMap { f in
            let cut = min(NSMaxRange(f.range), from)
            return cut > f.range.location ? TextFade(range: NSRange(location: f.range.location, length: cut - f.range.location), start: f.start) : nil
        }
        guard end > from, TextFade.allowed(in: self) else { return }
        layout.fades.append(TextFade(range: NSRange(location: from, length: end - from), start: CACurrentMediaTime()))
        TextFadeClock.shared.add(self)
    }

    /// One frame of the fade: the fading text is drawn again (with the
    /// alpha for now). False once nothing fades.
    func advanceFades(at now: CFTimeInterval) -> Bool {
        guard let layout = markdownLayout, !layout.fades.isEmpty else { return false }
        var union = layout.fades[0].range
        for f in layout.fades.dropFirst() { union = NSUnionRange(union, f.range) }
        union = NSIntersectionRange(union, NSRange(location: 0, length: textStorage.length))
        if union.length > 0 { redraw(union) }
        layout.fades.removeAll { $0.done(at: now) }
        return !layout.fades.isEmpty
    }

    /// Has the lines showing `chars` drawn again, and only those: the text
    /// is drawn in tiles, and the layout manager's own invalidation redraws
    /// every tile of the view (the whole reply, each frame).
    private func redraw(_ chars: NSRange) {
        guard let canvas = textCanvas else {
            layoutManager.invalidateDisplay(forCharacterRange: chars)
            return
        }
        let glyphs = layoutManager.glyphRange(forCharacterRange: chars, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        // Whole lines, and a little room for glyphs that reach past theirs.
        rect = CGRect(x: 0, y: rect.minY + textContainerInset.top - 4, width: bounds.width, height: rect.height + 8)
        let local = canvas.convert(rect, from: self)
        // The tiles that show those lines (UIKit's tiled layer would redraw
        // all of them for any rect).
        let tiles = (canvas.layer.sublayers ?? []).filter { $0.frame.intersects(local) }
        if tiles.isEmpty {
            canvas.setNeedsDisplay(local)
        } else {
            for t in tiles { t.setNeedsDisplay() }
        }
    }

    /// The view the text view draws its text in, tile by tile (UIKit's
    /// canvas, inside its container view).
    private var textCanvas: UIView? {
        if let canvas = cachedCanvas, canvas.isDescendant(of: self) { return canvas }
        func find(_ v: UIView, _ depth: Int) -> UIView? {
            if NSStringFromClass(type(of: v)).contains("CanvasView") { return v }
            guard depth < 3 else { return nil }
            for s in v.subviews { if let hit = find(s, depth + 1) { return hit } }
            return nil
        }
        cachedCanvas = subviews.lazy.compactMap { find($0, 0) }.first
        return cachedCanvas
    }
    private weak var cachedCanvas: UIView?

    /// Fully drawn at once (the app is leaving the screen).
    func finishFades() {
        guard let layout = markdownLayout, !layout.fades.isEmpty else { return }
        var union = layout.fades[0].range
        for f in layout.fades.dropFirst() { union = NSUnionRange(union, f.range) }
        layout.fades.removeAll()
        redraw(NSIntersectionRange(union, NSRange(location: 0, length: textStorage.length)))
    }

    /// Where the open block (the one a reply being written still changes)
    /// began at the last layout: its first character and its top.
    private var openBlockTop: (char: Int, y: CGFloat)?

    private func noteOpenBlockTop() {
        guard !isSelectable, frozenLength < textStorage.length else { openBlockTop = nil; return }
        let glyph = layoutManager.glyphIndexForCharacter(at: frozenLength)
        openBlockTop = (frozenLength, layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY)
    }

    /// The text changed from `chars` on: if that's within the open block of
    /// a reply being written, only the tiles from that block down are drawn
    /// again (UIKit's own invalidation redraws every tile: the whole reply
    /// on every tick). False to leave it to UIKit.
    func redrawChanged(from chars: Int) -> Bool {
        guard !isSelectable, let top = openBlockTop, chars >= top.char, let canvas = textCanvas,
              let tiles = canvas.layer.sublayers, !tiles.isEmpty else { return false }
        let y = canvas.convert(CGPoint(x: 0, y: top.y + textContainerInset.top - 4), from: self).y
        for t in tiles where t.frame.maxY > y { t.setNeedsDisplay() }
        return true
    }

    /// This text's own layout invalidations so far (see `TextFadeClock`).
    var layoutInvalidations: Int { markdownLayout?.invalidations ?? 0 }

    /// Everything, from scratch; the blocks before the last are frozen.
    private func renderAll(_ source: String, streaming: Bool) {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let blocks = MarkdownRenderer.parse(streaming ? source + " ▍" : source)
        let out = NSMutableAttributedString()
        frozenLength = 0
        for (i, b) in blocks.enumerated() {
            out.append(MarkdownRenderer.piece(b.block, body: body))
            if i < blocks.count - 1 {
                out.append(MarkdownRenderer.separator(body))
                frozenLength = out.length
            }
        }
        frozenSource = blocks.last.map { Self.utf16Offset(ofLine: $0.line, in: source) } ?? 0
        attributedText = out
    }

    /// Only what follows the frozen blocks: parsed again, the blocks that
    /// have finished meanwhile frozen too, the last (still open) one replaced
    /// in the text storage.
    private func renderTail(_ source: String, streaming: Bool) {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let tail = (source as NSString).substring(from: frozenSource)
        let blocks = MarkdownRenderer.parse(streaming ? tail + " ▍" : tail)
        let replacement = NSMutableAttributedString()
        var newlyFrozen = 0
        for (i, b) in blocks.enumerated() {
            replacement.append(MarkdownRenderer.piece(b.block, body: body))
            if i < blocks.count - 1 {
                replacement.append(MarkdownRenderer.separator(body))
                newlyFrozen = replacement.length
            }
        }
        let storage = textStorage
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: frozenLength, length: storage.length - frozenLength), with: replacement)
        storage.endEditing()
        frozenLength += newlyFrozen
        if let last = blocks.last { frozenSource += Self.utf16Offset(ofLine: last.line, in: tail) }
    }

    /// Where line `n` of `text` begins, in UTF-16 units.
    private static func utf16Offset(ofLine n: Int, in text: String) -> Int {
        guard n > 0 else { return 0 }
        var offset = 0
        var line = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 10 {
                line += 1
                if line == n { return offset }
            }
        }
        return offset
    }

    /// Dynamic colors compare by identity; compare what they look like.
    private static func sameColor(_ a: UIColor, _ b: UIColor?) -> Bool {
        guard let b else { return false }
        if a === b || a == b { return true }
        for style in [UIUserInterfaceStyle.light, .dark] {
            let t = UITraitCollection(userInterfaceStyle: style)
            if a.resolvedColor(with: t) != b.resolvedColor(with: t) { return false }
        }
        return true
    }

    /// A long answer or a slow render leaves a breadcrumb (size and time,
    /// never text) for the stall watchdog. `-renderTrace YES` (DEBUG) logs a
    /// count of renders each second, so a re-render storm shows in the log.
    private static func noteRender(chars: Int, since began: CFTimeInterval) {
        let ms = (CACurrentMediaTime() - began) * 1000
        if chars > 2000 || ms > 30 { breadcrumb("text render \(chars)ch \(Int(ms)) ms") }
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: "renderTrace") else { return }
        traceCount += 1
        traceChars += chars
        traceMs += ms
        guard !traceFlushing else { return }
        traceFlushing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                debugLog("[render] \(traceCount) renders, \(traceChars) chars, \(Int(traceMs)) ms in the last second")
                (traceCount, traceChars, traceMs, traceFlushing) = (0, 0, 0, false)
            }
        }
        #endif
    }

    #if DEBUG
    private static var traceCount = 0
    private static var traceChars = 0
    private static var traceMs = 0.0
    private static var traceFlushing = false
    #endif

    /// Code blocks and quotes use line separators (U+2028) to stay one
    /// paragraph; copied text gets ordinary newlines back.
    override func copy(_ sender: Any?) {
        guard let range = selectedTextRange, let text = text(in: range) else { return super.copy(sender) }
        UIPasteboard.general.string = text.replacingOccurrences(of: "\u{2028}", with: "\n")
    }

    /// Adds 「引用回复」 to the system selection menu: quotes just the selection.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard onQuote != nil, range.length > 0 else { return nil }
        let selected = (textView.text as NSString).substring(with: range)
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: " ▍", with: "")
        let quote = UIAction(title: "引用回复", image: UIImage(systemName: "arrowshape.turn.up.left")) { [weak self] _ in
            self?.onQuote?(selected)
            textView.selectedTextRange = nil
        }
        return UIMenu(children: [quote] + suggestedActions)
    }
}

/// A text container that stays unbounded in height. A non-scrolling
/// UITextView sets its container's height to its frame each time the frame
/// changes (every new line of a reply being written), and measuring set it
/// back: each change made TextKit invalidate the whole text's layout.
final class UnboundedHeightContainer: NSTextContainer {
    override var size: CGSize {
        get { super.size }
        set {
            let s = CGSize(width: newValue.width, height: .greatestFiniteMagnitude)
            if s != super.size { super.size = s }
        }
    }
}

// MARK: - Block backgrounds

extension NSAttributedString.Key {
    /// "code" | "quote" | "table" | "rule": drawn by MarkdownLayoutManager.
    static let paloBlock = NSAttributedString.Key("paloBlock")
}

final class MarkdownLayoutManager: NSLayoutManager {
    /// Text fading in, in order, not overlapping: drawn with less alpha.
    var fades: [TextFade] = []
    /// Times the layout was invalidated (a text change, a new width): a
    /// frame that only fades must leave this alone.
    private(set) var invalidations = 0

    override func processEditing(for textStorage: NSTextStorage, edited editMask: NSTextStorage.EditActions, range newCharRange: NSRange,
                                 changeInLength delta: Int, invalidatedRange invalidatedCharRange: NSRange) {
        invalidations &+= 1
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange, changeInLength: delta, invalidatedRange: invalidatedCharRange)
    }

    override func invalidateLayout(forCharacterRange charRange: NSRange, actualCharacterRange actualCharRange: NSRangePointer?) {
        invalidations &+= 1
        super.invalidateLayout(forCharacterRange: charRange, actualCharacterRange: actualCharRange)
    }

    override func textContainerChangedGeometry(_ container: NSTextContainer) {
        invalidations &+= 1
        super.textContainerChangedGeometry(container)
    }

    /// The text view this lays out.
    weak var owner: MarkdownTextView?
    #if DEBUG
    /// `-fadeTrace YES`: what each frame redraws.
    private static let trace = UserDefaults.standard.bool(forKey: "fadeTrace")
    #endif

    /// New text at the end of a reply being written: only the tiles that
    /// show it are drawn again (see `MarkdownTextView.redrawChanged`).
    override func invalidateDisplay(forGlyphRange glyphRange: NSRange) {
        let chars = characterRange(forGlyphRange: NSRange(location: glyphRange.location, length: 0), actualGlyphRange: nil).location
        #if DEBUG
        if Self.trace { debugLog("[fadetrace] invalidateDisplay glyphs \(glyphRange.location)+\(glyphRange.length) of \(numberOfGlyphs)") }
        #endif
        if let owner, MainActor.assumeIsolated({ owner.redrawChanged(from: chars) }) { return }
        super.invalidateDisplay(forGlyphRange: glyphRange)
    }

    /// The alpha a character is drawn with now.
    func fadeAlpha(at char: Int) -> CGFloat {
        guard !fades.isEmpty else { return 1 }
        let now = CACurrentMediaTime()
        for f in fades where NSLocationInRange(char, f.range) { return f.alpha(at: now) }
        return 1
    }

    /// Glyphs drawn so far, all views (how much a fade frame redraws).
    nonisolated(unsafe) static var glyphsDrawn = 0

    /// The glyphs, the fading ones with their alpha for now.
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        Self.glyphsDrawn &+= glyphsToShow.length
        #if DEBUG
        if Self.trace {
            let ctx = UIGraphicsGetCurrentContext()
            debugLog("[fadetrace] draw glyphs \(glyphsToShow.location)+\(glyphsToShow.length) of \(numberOfGlyphs), clip \(ctx.map { $0.boundingBoxOfClipPath } ?? .zero), fades \(fades.map { "\($0.range.location)+\($0.range.length)" })")
        }
        #endif
        guard !fades.isEmpty, let ctx = UIGraphicsGetCurrentContext(), let length = textStorage?.length else {
            return super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        }
        let now = CACurrentMediaTime()
        var from = glyphsToShow.location
        let end = NSMaxRange(glyphsToShow)
        for f in fades {
            let alpha = f.alpha(at: now)
            let chars = NSIntersectionRange(f.range, NSRange(location: 0, length: length))
            guard alpha < 1, chars.length > 0 else { continue }
            let g = glyphRange(forCharacterRange: chars, actualCharacterRange: nil)
            let lo = max(g.location, from)
            let hi = min(NSMaxRange(g), end)
            guard hi > lo else { continue }
            if lo > from { super.drawGlyphs(forGlyphRange: NSRange(location: from, length: lo - from), at: origin) }
            ctx.saveGState()
            ctx.setAlpha(alpha)
            super.drawGlyphs(forGlyphRange: NSRange(location: lo, length: hi - lo), at: origin)
            ctx.restoreGState()
            from = hi
        }
        if end > from { super.drawGlyphs(forGlyphRange: NSRange(location: from, length: end - from), at: origin) }
    }

    /// Backgrounds behind fading text (inline code) fade with it.
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<CGRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: UIColor) {
        let alpha = fadeAlpha(at: charRange.location)
        guard alpha < 1, let ctx = UIGraphicsGetCurrentContext() else {
            return super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
        }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
        ctx.restoreGState()
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first,
              let ctx = UIGraphicsGetCurrentContext() else { return }
        let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let all = NSRange(location: 0, length: storage.length)
        var seen = Set<Int>()
        storage.enumerateAttribute(.paloBlock, in: visible) { value, range, _ in
            guard let kind = value as? String else { return }
            // The whole block, not just the part being redrawn.
            var full = NSRange()
            _ = storage.attribute(.paloBlock, at: range.location, longestEffectiveRange: &full, in: all)
            guard seen.insert(full.location).inserted else { return }
            var rect = CGRect.null
            enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: full, actualCharacterRange: nil)) { frag, _, _, _, _ in
                rect = rect.union(frag)
            }
            guard !rect.isNull else { return }
            rect = rect.offsetBy(dx: origin.x, dy: origin.y)
            ctx.saveGState()
            defer { ctx.restoreGState() }
            // A block that's just appearing fades in with its first line.
            ctx.setAlpha(fadeAlpha(at: full.location))
            switch kind {
            case "code", "table":
                let box = CGRect(x: origin.x, y: rect.minY - 6, width: container.size.width, height: rect.height + 12)
                UIColor.secondaryLabel.withAlphaComponent(0.1).setFill()
                UIBezierPath(roundedRect: box, cornerRadius: 10).fill()
            case "quote":
                UIColor.secondaryLabel.withAlphaComponent(0.4).setFill()
                UIBezierPath(roundedRect: CGRect(x: origin.x, y: rect.minY, width: 3, height: rect.height), cornerRadius: 1.5).fill()
            case "rule":
                UIColor.separator.setFill()
                UIRectFill(CGRect(x: origin.x, y: rect.midY, width: container.size.width, height: 1 / max(UITraitCollection.current.displayScale, 1)))
            default:
                break
            }
        }
    }
}

// MARK: - Markdown → NSAttributedString

enum MarkdownRenderer {
    fileprivate enum Block {
        case heading(Int, String)
        case paragraph(String)
        case item(level: Int, marker: String, String)
        case quote([String])
        case code([String])
        case table([[String]])
        case rule
    }

    static func render(_ source: String) -> NSAttributedString {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let out = NSMutableAttributedString()
        let blocks = parse(source)
        for (i, b) in blocks.enumerated() {
            out.append(piece(b.block, body: body))
            if i < blocks.count - 1 { out.append(separator(body)) }
        }
        return out
    }

    /// Between two blocks.
    fileprivate static func separator(_ body: UIFont) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: [.font: body])
    }

    /// One block, styled.
    fileprivate static func piece(_ block: Block, body: UIFont) -> NSAttributedString {
        let size = body.pointSize
        let piece: NSAttributedString
            switch block {
            case let .heading(level, text):
                let scale: CGFloat = [1.3, 1.15, 1.05][min(level, 3) - 1]
                let weight: UIFont.Weight = level <= 2 ? .bold : .semibold
                let style = paragraph(size: size, before: level <= 2 ? 8 : 6, after: level <= 2 ? 4 : 2)
                piece = inline(text, font: .systemFont(ofSize: size * scale, weight: weight), style: style)
            case let .paragraph(text):
                piece = inline(text, font: body, style: paragraph(size: size, after: 8))
            case let .item(level, marker, text):
                let indent = CGFloat(level) * 18 + (marker.count > 2 ? 26 : 18)
                let style = paragraph(size: size, after: 4)
                style.headIndent = indent
                style.firstLineHeadIndent = CGFloat(level) * 18
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                let line = NSMutableAttributedString(string: marker + "\t", attributes: [.font: body, .foregroundColor: UIColor.secondaryLabel, .paragraphStyle: style])
                line.append(inline(text, font: body, style: style))
                piece = line
            case let .quote(lines):
                let style = paragraph(size: size, after: 8)
                style.headIndent = 13
                style.firstLineHeadIndent = 13
                let q = NSMutableAttributedString(attributedString: inline(lines.joined(separator: "\u{2028}"), font: body, style: style, color: .secondaryLabel))
                q.addAttribute(.paloBlock, value: "quote", range: NSRange(location: 0, length: q.length))
                piece = q
            case let .code(lines):
                let mono = UIFont.monospacedSystemFont(ofSize: size * 0.85, weight: .regular)
                let style = paragraph(size: size * 0.85, before: 10, after: 16)
                style.headIndent = 10
                style.firstLineHeadIndent = 10
                style.tailIndent = -10
                style.lineBreakMode = .byCharWrapping
                let c = NSMutableAttributedString(string: lines.joined(separator: "\u{2028}"), attributes: [.font: mono, .foregroundColor: UIColor.label, .paragraphStyle: style])
                c.addAttribute(.paloBlock, value: "code", range: NSRange(location: 0, length: c.length))
                piece = c
            case let .table(rows):
                piece = table(rows, body: body)
            case .rule:
                let style = paragraph(size: size, before: 4, after: 8)
                piece = NSAttributedString(string: "\u{00A0}", attributes: [.font: body, .paragraphStyle: style, .paloBlock: "rule"])
            }
        return piece
    }

    private static func paragraph(size: CGFloat, before: CGFloat = 0, after: CGFloat = 0) -> NSMutableParagraphStyle {
        let s = NSMutableParagraphStyle()
        s.lineSpacing = size * 0.2
        s.paragraphSpacingBefore = before
        s.paragraphSpacing = after
        return s
    }

    /// Inline markdown (bold, italic, `code`, ~~strike~~, links) via Foundation.
    private static func inline(_ text: String, font: UIFont, style: NSParagraphStyle, color: UIColor = .label) -> NSAttributedString {
        let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
            let intent = run.inlinePresentationIntent ?? []
            var traits: UIFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            if !traits.isEmpty, let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits)) {
                attrs[.font] = UIFont(descriptor: d, size: font.pointSize)
            }
            if intent.contains(.code) {
                attrs[.font] = UIFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
                attrs[.backgroundColor] = UIColor.secondaryLabel.withAlphaComponent(0.12)
            }
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attrs[.link] = link }
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }

    /// Tables: cells separated by tabs, column stops sized to the widest cell
    /// (capped, so a long cell wraps instead of pushing the rest away).
    private static func table(_ rows: [[String]], body: UIFont) -> NSAttributedString {
        let font = UIFont.systemFont(ofSize: body.pointSize * 0.9)
        let bold = UIFont.systemFont(ofSize: body.pointSize * 0.9, weight: .semibold)
        let columns = rows.map(\.count).max() ?? 0
        var widths = Array(repeating: CGFloat(0), count: columns)
        for (r, row) in rows.enumerated() {
            for (c, cell) in row.enumerated() {
                let w = NSAttributedString(string: plain(cell), attributes: [.font: r == 0 ? bold : font]).size().width
                widths[c] = min(max(widths[c], w + 16), 180)
            }
        }
        var stops: [NSTextTab] = []
        var x: CGFloat = 10
        for w in widths.dropLast() { x += w; stops.append(NSTextTab(textAlignment: .left, location: x)) }
        let out = NSMutableAttributedString()
        for (r, row) in rows.enumerated() {
            let style = paragraph(size: font.pointSize, before: r == 0 ? 10 : 0, after: r == rows.count - 1 ? 16 : 4)
            style.firstLineHeadIndent = 10
            style.headIndent = 10
            style.tabStops = stops
            for (c, cell) in row.enumerated() {
                if c > 0 { out.append(NSAttributedString(string: "\t", attributes: [.font: font, .paragraphStyle: style])) }
                out.append(inline(cell, font: r == 0 ? bold : font, style: style))
            }
            if r < rows.count - 1 { out.append(NSAttributedString(string: "\u{2028}", attributes: [.font: font, .paragraphStyle: style])) }
        }
        out.addAttribute(.paloBlock, value: "table", range: NSRange(location: 0, length: out.length))
        return out
    }

    private static func plain(_ s: String) -> String {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? s
    }

    // MARK: parsing (line-based, GitHub-flavored enough for chat)

    /// The blocks, each with the line it starts on. Line by line, forward
    /// only: once the next block has begun, a block never changes, which is
    /// what lets a reply being written freeze its finished blocks.
    fileprivate static func parse(_ source: String) -> [(block: Block, line: Int)] {
        var blocks: [(block: Block, line: Int)] = []
        var para: [String] = []
        var paraStart = 0
        var quote: [String] = []
        var quoteStart = 0
        var table: [[String]] = []
        var tableStart = 0
        var code: [String]? = nil
        var codeStart = 0

        func flush() {
            if !para.isEmpty { blocks.append((.paragraph(para.joined(separator: "\u{2028}")), paraStart)); para = [] }
            if !quote.isEmpty { blocks.append((.quote(quote), quoteStart)); quote = [] }
            if !table.isEmpty { blocks.append((.table(table), tableStart)); table = [] }
        }

        for (ln, raw) in source.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if var c = code {
                if line.hasPrefix("```") { blocks.append((.code(c), codeStart)); code = nil } else { c.append(raw); code = c }
                continue
            }
            if line.hasPrefix("```") { flush(); code = []; codeStart = ln; continue }
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("|") {
                if table.isEmpty { flush(); tableStart = ln }
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                // The |---|:--:| separator row carries no text.
                if !cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { table.append(cells) }
                continue
            }
            if !table.isEmpty { flush() }
            if line == "---" || line == "***" || line == "___" { flush(); blocks.append((.rule, ln)); continue }
            if let h = heading(line) { flush(); blocks.append((.heading(h.0, h.1), ln)); continue }
            let level = min(leadingSpaces(raw) / 2, 4)
            if let b = bullet(line) { flush(); blocks.append((.item(level: level, marker: b.0, b.1), ln)); continue }
            if let n = numbered(line) { flush(); blocks.append((.item(level: level, marker: "\(n.0).", n.1), ln)); continue }
            if line.hasPrefix(">") {
                if quote.isEmpty { flush(); quoteStart = ln }
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)); continue
            }
            if !quote.isEmpty { flush() }
            if para.isEmpty { paraStart = ln }
            para.append(line)
        }
        if let c = code { blocks.append((.code(c), codeStart)) } // still streaming a code block
        flush()
        return blocks
    }

    private static func leadingSpaces(_ s: String) -> Int {
        s.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)))
    }

    private static func bullet(_ line: String) -> (String, String)? {
        for p in ["- ", "* ", "+ ", "• "] where line.hasPrefix(p) {
            let rest = String(line.dropFirst(p.count))
            if rest.hasPrefix("[ ] ") { return ("☐", String(rest.dropFirst(4))) }
            if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") { return ("☑︎", String(rest.dropFirst(4))) }
            return ("•", rest)
        }
        return nil
    }

    private static func numbered(_ line: String) -> (Int, String)? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, let n = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (n, String(rest.dropFirst(2)))
    }
}

/// Live resizing (a window edge dragged, a sidebar sliding in) proposes a new
/// width on every frame, and laying out every visible answer at each one
/// stuttered. While widths keep changing, text is laid out at a coarse width
/// (rounded down to a step, so it never overflows), which most frames then
/// find already measured; once the width has been still for a moment, the
/// views that used a coarse width measure exactly once more.
@MainActor
enum TextWidthSettling {
    static let step: CGFloat = 24
    static let quiet: TimeInterval = 0.3
    private static var lastChange: CFTimeInterval = 0
    private static var resizing = false
    private static var coarse = NSHashTable<MarkdownTextView>.weakObjects()
    private static var settle: Timer?

    static func layoutWidth(for exact: CGFloat, previous: CGFloat?, view: MarkdownTextView) -> CGFloat {
        // Phones don't live-resize: always lay out at the exact width there.
        if UIDevice.current.userInterfaceIdiom == .phone { return exact }
        if let previous, previous != exact {
            let now = CACurrentMediaTime()
            if now - lastChange < quiet { resizing = true }
            lastChange = now
            settle?.invalidate()
            settle = Timer.scheduledTimer(withTimeInterval: quiet, repeats: false) { _ in
                MainActor.assumeIsolated { settled() }
            }
        }
        guard resizing else { return exact }
        coarse.add(view)
        return max(step, (exact / step).rounded(.down) * step)
    }

    private static func settled() {
        resizing = false
        let views = coarse.allObjects
        coarse.removeAllObjects()
        for v in views { v.widthSettled() }
    }
}

// MARK: - Fading in

/// Text just revealed fades in: drawn with an alpha rising from 0 to 1 over
/// 0.3 s (ease-out), redrawn each frame. Only drawing is redone; the text
/// storage and its layout stay as they are (a color change in the storage
/// would lay the paragraph out again on every frame). No fade with Reduce
/// Motion, off screen, or in the background.
struct TextFade {
    var range: NSRange
    var start: CFTimeInterval
    static let duration: CFTimeInterval = 0.3

    func alpha(at now: CFTimeInterval) -> CGFloat {
        let t = min(max((now - start) / Self.duration, 0), 1)
        return CGFloat(1 - pow(1 - t, 3))
    }

    func done(at now: CFTimeInterval) -> Bool { now - start >= Self.duration }

    @MainActor
    static func allowed(in view: UIView) -> Bool {
        guard !UIAccessibility.isReduceMotionEnabled, let window = view.window,
              window.windowScene?.activationState == .foregroundActive else { return false }
        return window.bounds.intersects(view.convert(view.bounds, to: window))
    }
}

/// Runs the fades: one display link (60 Hz) while any text fades. Logs what
/// the fades cost once a reply's are over (`[reveal] fade:`): per frame,
/// the callback plus the commit that redraws, and whether the fading text's
/// layout was touched in a frame that changed no text (it must not be).
@MainActor
final class TextFadeClock {
    static let shared = TextFadeClock()
    private let views = NSHashTable<MarkdownTextView>.weakObjects()
    private var link: CADisplayLink?
    private var stats = Stats()
    private var generation = 0

    private struct Stats {
        var frames = 0
        var fadeOnly: [Double] = []
        var relaidOut = 0
        var glyphs: [Double] = []
    }
    /// Text changes as of the last frame's commit.
    private var rendersAtCommit = 0

    private init() {
        NotificationCenter.default.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TextFadeClock.shared.finishAll() }
        }
    }

    func add(_ view: MarkdownTextView) {
        views.add(view)
        if link == nil {
            let link = CADisplayLink(target: LinkTarget { [weak self] in self?.frame() }, selector: #selector(LinkTarget.fire))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = false
        generation += 1
    }

    private func frame() {
        let began = CommitWatch.threadCPU()
        let signpost = ChatSignposts.chat.beginInterval("fade")
        let now = CACurrentMediaTime()
        let fading = views.allObjects
        let invalidations = fading.map(\.layoutInvalidations)
        var active = false
        for v in fading {
            if v.advanceFades(at: now) { active = true } else { views.remove(v) }
        }
        let callback = CommitWatch.threadCPU() - began
        stats.frames += 1
        let glyphs = MarkdownLayoutManager.glyphsDrawn
        CommitWatch.shared.afterCommit { [weak self] commit in
            ChatSignposts.chat.endInterval("fade", signpost)
            guard let self else { return }
            defer { rendersAtCommit = MarkdownTextView.renders }
            // No text changed since the last frame: all this one did was fade.
            guard MarkdownTextView.renders == rendersAtCommit else { return }
            stats.fadeOnly.append((callback + commit) * 1000)
            stats.glyphs.append(Double(MarkdownLayoutManager.glyphsDrawn - glyphs))
            if zip(fading, invalidations).contains(where: { $0.layoutInvalidations != $1 }) { stats.relaidOut += 1 }
        }
        if !active {
            link?.isPaused = true
            report(after: generation)
        }
    }

    private func finishAll() {
        for v in views.allObjects { v.finishFades() }
        views.removeAllObjects()
        link?.isPaused = true
    }

    /// Once fading has stopped for a while (the reply is done).
    private func report(after mark: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, generation == mark, stats.frames > 0 else { return }
            let s = stats
            stats = Stats()
            let glyphs = s.glyphs.sorted()
            debugLog("[reveal] fade: \(s.frames) frames, \(s.fadeOnly.count) that only faded: per frame (callback + redraw) \(Self.spread(s.fadeOnly)), glyphs redrawn p50 \(Int(glyphs.isEmpty ? 0 : glyphs[glyphs.count / 2])); layout touched in \(s.relaidOut) of them")
        }
    }

    private static func spread(_ values: [Double]) -> String {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return "n/a" }
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))] }
        return String(format: "p50 %.2f, p95 %.2f, max %.1f ms", at(0.5), at(0.95), sorted.last ?? 0)
    }

}
