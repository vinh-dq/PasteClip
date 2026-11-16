import AppKit
import ApplicationServices

/// Sends ⌘V to whichever app is frontmost. Requires Accessibility permission.
public enum Paster {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Posts ⌘V after `delay`, once the user has let go of any modifier keys (up to one second),
    /// so a held ⇧ or ⌃ from the triggering shortcut doesn't turn it into a different command.
    public static func pasteIntoFrontApp(after delay: TimeInterval = 0) {
        guard isTrusted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            whenModifiersReleased(deadline: Date().addingTimeInterval(1), postCommandV)
        }
    }

    private static func whenModifiersReleased(deadline: Date, _ action: @escaping () -> Void) {
        let held = CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
        if held.isEmpty || Date() > deadline {
            action()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { whenModifiersReleased(deadline: deadline, action) }
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
