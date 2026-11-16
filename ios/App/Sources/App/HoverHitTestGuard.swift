import ObjectiveC
import PaloAllyKit
import UIKit

/// The Mac (macOS 27.0 beta, 26A5421a): moving the mouse, UIKit's hover
/// re-hit-test sometimes asks a SwiftUI hosting view to hit-test with no
/// context, and SwiftUI's `_UIHostingView._hitTest(with:)` traps on it
/// (`cbz x0 → brk`): the app quits mid-hover (11-14, 11-15, both with the
/// same stack and nothing of ours on it). Each hosting view class met is
/// given an override that answers such a call with no view (that one hover
/// misses) and passes every other call to SwiftUI's own.
///
/// Hosting view classes are generic and appear as views of new kinds are
/// made, so they are patched as they move into a window.
@MainActor
enum HoverHitTestGuard {
    private static let selector = NSSelectorFromString("_hitTestWithContext:")
    private static var seen = Set<ObjectIdentifier>()
    private static var patched = Set<ObjectIdentifier>()
    private static var installed = false

    static func install() {
        #if targetEnvironment(macCatalyst)
        guard !installed, UIView.instancesRespond(to: selector) else { return }
        installed = true
        let original = #selector(UIView.didMoveToWindow)
        let swapped = #selector(UIView.paloAlly_didMoveToWindow)
        guard let a = class_getInstanceMethod(UIView.self, original),
              let b = class_getInstanceMethod(UIView.self, swapped) else { return }
        method_exchangeImplementations(a, b)
        debugLog("[hover] hit-test guard installed")
        #endif
    }

    /// A view moved into a window: its class (or the hosting class it comes
    /// from) gets the guard once.
    static func check(_ view: UIView) {
        let cls: AnyClass = object_getClass(view) ?? type(of: view)
        guard seen.insert(ObjectIdentifier(cls)).inserted else { return }
        // The class that itself defines SwiftUI's hit test.
        var c: AnyClass? = cls
        while let k = c, k != UIView.self {
            if NSStringFromClass(k).contains("UIHostingView"), defines(k) {
                patch(k)
                return
            }
            c = class_getSuperclass(k)
        }
    }

    private static func defines(_ cls: AnyClass) -> Bool {
        var count: UInt32 = 0
        guard let list = class_copyMethodList(cls, &count) else { return false }
        defer { free(list) }
        for i in 0..<Int(count) where method_getName(list[i]) == selector { return true }
        return false
    }

    private static func patch(_ cls: AnyClass) {
        guard patched.insert(ObjectIdentifier(cls)).inserted,
              let method = class_getInstanceMethod(cls, selector) else { return }
        typealias HitTest = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
        let old = unsafeBitCast(method_getImplementation(method), to: HitTest.self)
        let sel = selector
        let block: @convention(block) (AnyObject, AnyObject?) -> AnyObject? = { me, context in
            guard let context else { return nil }
            return old(me, sel, context)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        debugLog("[hover] hit-test guard on \(NSStringFromClass(cls).prefix(80))")
    }
}

extension UIView {
    /// Swapped with `didMoveToWindow` (`HoverHitTestGuard`): calls the
    /// original, which now has this name.
    @objc func paloAlly_didMoveToWindow() {
        paloAlly_didMoveToWindow()
        if window != nil { MainActor.assumeIsolated { HoverHitTestGuard.check(self) } }
    }
}
