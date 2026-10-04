import CoreGraphics

/// Distance between the end of the chat and the bottom of what the reader can
/// actually see (above the composer / keyboard), from SwiftUI's ScrollGeometry.
///
/// Measured on iOS 26/27 (iPhone 17 Pro, chat with a safeAreaInset composer):
/// `containerSize` is the frame minus the safe-area insets, `visibleRect` spans
/// the inset regions too, and `contentInsets.top` can carry a large stale value
/// from `defaultScrollAnchor(.bottom, for: .alignment)` (753 pt for a 1389 pt
/// list). So the UIKit-style `contentSize + inset.bottom − container − offset`
/// is wrong by `inset.top + inset.bottom` or more; the reliable quantity is the
/// visible rect's bottom minus the bottom inset (the part under the composer).
public enum ChatScrollMath {
    public static func distanceFromBottom(contentHeight: CGFloat, visibleMaxY: CGFloat, bottomInset: CGFloat) -> CGFloat {
        max(0, contentHeight - (visibleMaxY - bottomInset))
    }
}
