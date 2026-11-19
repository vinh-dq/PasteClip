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
            whenModifiersReleased(deadline: Date().addingTimeInterval(1)) { postCommand(key: 9) } // V
        }
    }

    /// The page in front in a browser's focused window, as Accessibility sees it.
    public struct WebPage {
        public let url: URL?
        /// The page has finished loading.
        public let loaded: Bool
        /// How many elements the page has, which changes as soon as it takes a pasted image.
        public let elements: Int
    }

    /// Asks a browser to show its pages to Accessibility: Chrome and the browsers built on it
    /// only do once an assistive app asks.
    public static func exposePages(of app: NSRunningApplication) {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// The page in `app`'s focused window, or nil when there's none or the browser doesn't show
    /// its pages to Accessibility. Needs Accessibility permission.
    public static func frontPage(of app: NSRunningApplication) -> WebPage? {
        guard let window = value(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute)
                .flatMap(asElement), let page = first(in: window, where: { role(of: $0) == "AXWebArea" })
        else { return nil }
        // Pages that don't report loading are taken as loaded.
        let loaded = value(page, "AXLoaded") as? Bool ?? true
        var elements = 0
        var budget = 5000
        visit(page, depth: 0, budget: &budget) { _ in elements += 1 }
        return WebPage(url: value(page, kAXURLAttribute) as? URL, loaded: loaded, elements: elements)
    }

    private static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func asElement(_ value: CFTypeRef) -> AXUIElement? {
        CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! AXUIElement) : nil
    }

    private static func role(of element: AXUIElement) -> String? { value(element, kAXRoleAttribute) as? String }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute) as? [AnyObject] ?? []).compactMap { asElement($0) }
    }

    private static func first(in element: AXUIElement, depth: Int = 0, where test: (AXUIElement) -> Bool) -> AXUIElement? {
        if test(element) { return element }
        guard depth < 30 else { return nil }
        for child in children(of: element) {
            if let found = first(in: child, depth: depth + 1, where: test) { return found }
        }
        return nil
    }

    private static func visit(_ element: AXUIElement, depth: Int, budget: inout Int, _ body: (AXUIElement) -> Void) {
        guard budget > 0 else { return }
        budget -= 1
        body(element)
        guard depth < 60 else { return }
        for child in children(of: element) { visit(child, depth: depth + 1, budget: &budget, body) }
    }

    /// Sends ⌘C to the front app once modifier keys are let go, then calls `completion`.
    public static func copyInFrontApp(then completion: @escaping () -> Void) {
        guard isTrusted else { return completion() }
        whenModifiersReleased(deadline: Date().addingTimeInterval(1)) {
            postCommand(key: 8) // C
            completion()
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

    private static func postCommand(key: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
