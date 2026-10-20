import SwiftUI
import UIKit

/// Something that keeps moving (an orb, a drop, a breathing dot), drawn in a
/// view graph of its own. In one graph, every frame of a continuous
/// animation is a render pass over the whole window's display list (on the
/// Mac with a split workspace and long chats, a third of a core at rest);
/// hosted apart, a frame redraws only this.
///
/// The content gets no SwiftUI environment from around it (UIKit traits
/// such as the color scheme and the display scale do come through), and
/// takes no touches: whatever it sits in (a button) gets them.
struct IsolatedHost<Content: View>: UIViewRepresentable {
    let content: Content

    init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    func makeUIView(context: Context) -> UIView {
        let controller = UIHostingController(rootView: content)
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        controller.safeAreaRegions = []
        context.coordinator.controller = controller
        return controller.view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.controller?.rootView = content
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        // It fills what it's given (callers frame it).
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var controller: UIHostingController<Content>?
    }
}
