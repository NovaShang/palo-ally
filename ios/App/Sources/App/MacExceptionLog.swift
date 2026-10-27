#if targetEnvironment(macCatalyst)
import Foundation
import ObjectiveC
import PaloAllyKit

/// An Objective-C exception thrown while the Mac app handles an event is
/// caught by AppKit (`-[NSApplication reportException:]`), which only logs it,
/// redacted, to the system log. UIKit can be left inconsistent and trap a few
/// seconds later in `-[UIApplication sendEvent:]`, with nothing in the crash
/// report saying why (this Mac on 10-23, a family Mac on 10-26, both scrolling
/// or moving the pointer). Its name, reason and the stack where it was thrown
/// go to the debug log too, then AppKit carries on as before.
@MainActor
enum MacExceptionLog {
    private static var installed = false

    static func install() {
        guard !installed, let cls = NSClassFromString("NSApplication") else { return }
        installed = true
        let selector = NSSelectorFromString("reportException:")
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        typealias Report = @convention(c) (AnyObject, Selector, NSException) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Report.self)
        let block: @convention(block) (AnyObject, NSException) -> Void = { app, exception in
            let stack = exception.callStackSymbols.prefix(40).joined(separator: "\n")
            debugLog("[exception] \(exception.name.rawValue): \(exception.reason ?? "")\n\(stack)")
            original(app, selector, exception)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}
#endif
