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

        init(_ g: ScrollGeometry) {
            distanceFromBottom = ChatScrollMath.distanceFromBottom(
                contentHeight: g.contentSize.height, visibleMaxY: g.visibleRect.maxY, bottomInset: g.contentInsets.bottom)
            bottomInset = g.contentInsets.bottom
        }
    }

    #if DEBUG
    /// The latest distance from the end, for the jump drill's log.
    @MainActor static var debugDistance: CGFloat = 0
    @MainActor static var traced = 0
    @MainActor static var lastTrace = ""
    /// `-scrollTrace YES`: content height / offset as layout sees them (first 3000 changes).
    @MainActor static func trace(_ g: ScrollGeometry) {
        guard UserDefaults.standard.bool(forKey: "scrollTrace"), traced < 3000 else { return }
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
