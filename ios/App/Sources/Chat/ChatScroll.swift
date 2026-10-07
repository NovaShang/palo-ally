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
    #endif
}

/// Small glass circle above the composer while the reader is up in history:
/// tap to jump to the newest text and follow it again. Neutral, not themed;
/// only its dot, for something new below that the reader hasn't seen, takes
/// the theme color.
struct JumpToLatestButton: View {
    /// A message (or more of one) arrived below since the reader scrolled up.
    var hasNew: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .glassEffect(.regular.interactive(), in: .circle)
                .overlay(alignment: .topTrailing) {
                    if hasNew {
                        Circle().fill(.tint).frame(width: 8, height: 8).offset(x: -1, y: 1)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.2), value: hasNew)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hasNew ? "回到最新，下面有新消息" : "回到最新")
    }
}
