import PaloAllyKit
import UIKit

/// When the views' latest changes have reached the screen: the end of the
/// next UI update's Core Animation commit (UIKit's update link, iOS 18).
/// The store measures what a reply's tick costs with it (`[reveal]`).
/// Display-link callbacks in between (the glass's springs, the orb) are
/// counted apart: they run whether or not a reply is being written.
@MainActor
final class CommitWatch {
    static let shared = CommitWatch()

    #if !targetEnvironment(macCatalyst)
    private var link: UIUpdateLink?
    #endif
    private var waiting: [@MainActor (Double) -> Void] = []
    private var animationsCPU = 0.0
    private var displayLinksBegan = 0.0

    /// For `AppStore.whenCommitted`. Without an update link (Mac), after the
    /// current transaction's completion instead.
    func after(_ done: @escaping @MainActor (Double) -> Void) {
        #if !targetEnvironment(macCatalyst)
        if let link = link ?? makeLink() {
            if waiting.isEmpty { animationsCPU = 0 }
            waiting.append(done)
            link.isEnabled = true
            return
        }
        #endif
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { done(0) } }
    }

    #if !targetEnvironment(macCatalyst)
    private func makeLink() -> UIUpdateLink? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return nil }
        // Not continuous (the default): it only rides along updates that
        // happen anyway, never asks for frames of its own.
        let link = UIUpdateLink(windowScene: scene)
        link.addAction(to: .beforeCADisplayLinkDispatch) { [weak self] _, _ in
            self?.displayLinksBegan = Self.threadCPU()
        }
        link.addAction(to: .afterCADisplayLinkDispatch) { [weak self] _, _ in
            guard let self, displayLinksBegan > 0 else { return }
            animationsCPU += Self.threadCPU() - displayLinksBegan
            displayLinksBegan = 0
        }
        link.addAction(to: .afterCATransactionCommit) { [weak self] link, _ in
            guard let self else { return }
            link.isEnabled = false
            let done = waiting
            let animations = animationsCPU
            waiting = []
            animationsCPU = 0
            for d in done { d(animations) }
        }
        self.link = link
        return link
    }
    #endif

    private static func threadCPU() -> Double {
        var t = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
        return Double(t.tv_sec) + Double(t.tv_nsec) / 1_000_000_000
    }
}
