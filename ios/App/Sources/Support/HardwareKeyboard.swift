import GameController
import PaloAllyKit
import UIKit

/// What the hardware keyboard is doing: whether one is in use, and whether a
/// modifier that turns Return into a newline (Shift, Option, Command) is held.
/// The composer uses it to make a hardware Return send.
enum HardwareKeyboard {
    /// A hardware keyboard is in use. Always true on the Mac.
    static var isAttached: Bool {
        ProcessInfo.processInfo.isMacCatalystApp || GCKeyboard.coalesced != nil
    }

    /// Shift, Option or Command is held right now.
    static var newlineModifierDown: Bool {
        if ProcessInfo.processInfo.isMacCatalystApp {
            // AppKit's +[NSEvent modifierFlags]: the live state, no permission needed.
            guard let event = NSClassFromString("NSEvent"),
                  let raw = ((event as AnyObject).value(forKey: "modifierFlags") as? NSNumber)?.uintValue
            else { return false }
            let shift: UInt = 1 << 17, option: UInt = 1 << 19, command: UInt = 1 << 20
            return raw & (shift | option | command) != 0
        }
        guard let keys = GCKeyboard.coalesced?.keyboardInput else { return false }
        let codes: [GCKeyCode] = [.leftShift, .rightShift, .leftAlt, .rightAlt, .leftGUI, .rightGUI]
        return codes.contains { keys.button(forKeyCode: $0)?.isPressed == true }
    }

    /// The text input that has the keyboard, if any.
    static var focusedTextInput: (UIResponder & UITextInput)? {
        UIResponder.paloFocused = nil
        UIApplication.shared.sendAction(#selector(UIResponder.paloCaptureFocused), to: nil, from: nil, for: nil)
        return UIResponder.paloFocused as? UIResponder & UITextInput
    }

    /// An input method is composing (e.g. pinyin with marked text): Return
    /// belongs to it.
    static var isComposing: Bool { focusedTextInput?.markedTextRange != nil }

    /// Types a newline at the cursor of whatever has the keyboard.
    static func insertNewline() {
        UIApplication.shared.sendAction(#selector(UIResponder.paloInsertNewline), to: nil, from: nil, for: nil)
    }

    /// GameController notices keyboards only once something has asked.
    static func startWatching() {
        _ = GCKeyboard.coalesced
        #if DEBUG
        let appKit = NSClassFromString("NSEvent") != nil
        debugLog("[keys] hardware keyboard \(isAttached), NSEvent \(appKit), modifier held \(newlineModifierDown)")
        #endif
    }
}

extension UIResponder {
    fileprivate static weak var paloFocused: UIResponder?

    @objc fileprivate func paloCaptureFocused() { UIResponder.paloFocused = self }

    @objc fileprivate func paloInsertNewline() { (self as? UIKeyInput)?.insertText("\n") }
}
