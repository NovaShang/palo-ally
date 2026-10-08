import PaloAllyKit
import SwiftUI

/// Thresholds for following the live bottom while a reply streams.
enum ChatScroll {
    /// A user drag that takes the view more than this far from the end stops
    /// auto-follow (a few points: any deliberate drag up counts).
    static let detachDistance: CGFloat = 8
    /// A user scroll that ends (or drifts back down to) within this of the end
    /// resumes it, and the jump button only shows beyond it. Resting at the
    /// true end reads ~13 pt (the list's own bottom padding).
    static let reattachDistance: CGFloat = 56

    /// What the scroll logic reads from ScrollGeometry.
    struct Metrics: Equatable {
        var distanceFromBottom: CGFloat
        /// Composer + keyboard + home indicator: grows when the keyboard rises.
        var bottomInset: CGFloat
        /// Where the list is scrolled to, and how tall it is. The reader moved
        /// the list only when the offset changed and the height did not: the
        /// distance from the end also grows when a reply streams in or the
        /// lazy history re-estimates its rows, under a finger that is just
        /// resting on the screen.
        var offsetY: CGFloat
        var contentHeight: CGFloat

        init(_ g: ScrollGeometry) {
            distanceFromBottom = ChatScrollMath.distanceFromBottom(
                contentHeight: g.contentSize.height, visibleMaxY: g.visibleRect.maxY, bottomInset: g.contentInsets.bottom)
            bottomInset = g.contentInsets.bottom
            offsetY = g.contentOffset.y
            contentHeight = g.contentSize.height
        }

        /// The reader dragged (or flung) toward older messages.
        func movedUp(from old: Metrics) -> Bool {
            abs(contentHeight - old.contentHeight) < 0.5 && offsetY < old.offsetY - 0.5
        }

        /// The reader dragged (or flung) toward the end.
        func movedDown(from old: Metrics) -> Bool {
            abs(contentHeight - old.contentHeight) < 0.5 && offsetY > old.offsetY + 0.5
        }
    }

    /// The latest distance from the end (for the logs).
    @MainActor static var lastDistance: CGFloat = 0

    /// A change between following the end and reading back in history,
    /// persisted (all builds): `[scroll] following → detached (drag), 412 pt
    /// from the end`. States and numbers only.
    @MainActor static func log(_ what: String) {
        debugLog("[scroll] \(what), \(Int(lastDistance)) pt from the end")
        ChatSignposts.chat.emitEvent("scroll", "\(what)")
    }

    #if DEBUG
    /// The latest distance from the end, for the jump drill's log.
    @MainActor static var debugDistance: CGFloat { lastDistance }
    @MainActor static var traced = 0
    @MainActor static var lastTrace = ""
    /// `-pinTrace YES`: why the view followed the end or let go of it
    /// (scroll phases, pinned changes, distance growth not counted as a drag).
    @MainActor static let pinTraceOn = UserDefaults.standard.bool(forKey: "pinTrace")
    @MainActor static var pinTraced = 0
    @MainActor static func pinTrace(_ what: String) {
        guard pinTraceOn, pinTraced < 2000 else { return }
        pinTraced += 1
        debugLog("[pin] \(what), \(Int(debugDistance)) pt from the end")
    }
    /// `-scrollTrace YES`: content height / offset as layout sees them (first 20 000 changes).
    @MainActor static let traceOn = UserDefaults.standard.bool(forKey: "scrollTrace")
    @MainActor static func trace(_ g: ScrollGeometry) {
        guard traceOn, traced < 20_000 else { return }
        let line = "h=\(Int(g.contentSize.height)) y=\(Int(g.contentOffset.y)) vis=\(Int(g.visibleRect.minY))-\(Int(g.visibleRect.maxY)) inset=\(Int(g.contentInsets.top)),\(Int(g.contentInsets.bottom))"
        guard line != lastTrace else { return }
        lastTrace = line
        traced += 1
        debugLog("[geo] \(line)")
    }
    #endif
}

/// Small glass circle above the composer while the reader is up in history:
/// tap to jump to the newest text and follow it again. Neutral, not themed;
/// only its dot, for something new below that the reader hasn't seen, takes
/// the theme color. The system glass button: a hand-made interactive glass
/// circle inside a plain button took the touches for its own press effect,
/// so taps often never reached the button.
struct JumpToLatestButton: View {
    /// A message (or more of one) arrived below since the reader scrolled up.
    var hasNew: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(.primary) // the glass style draws its label in the tint
        .overlay(alignment: .topTrailing) {
            if hasNew {
                // On the circle's edge, up and to the right.
                Circle().fill(Color.accentColor).frame(width: 8, height: 8).offset(x: -7, y: 2)
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.snappy(duration: 0.2), value: hasNew)
        .accessibilityLabel(hasNew ? "回到最新，下面有新消息" : "回到最新")
        .accessibilityIdentifier("jumpToLatest")
    }
}
