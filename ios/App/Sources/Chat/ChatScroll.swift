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
}

/// Small glass circle above the composer while the reader is up in history:
/// tap to jump to the newest text and follow it again. Neutral, not themed.
struct JumpToLatestButton: View {
    var streaming: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .glassEffect(.regular.interactive(), in: .circle)
                .overlay(alignment: .topTrailing) {
                    // A quiet dot while new text is still arriving below.
                    if streaming {
                        Circle().fill(.secondary).frame(width: 7, height: 7).offset(x: -2, y: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("回到最新")
    }
}
