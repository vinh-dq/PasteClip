import AppKit
@preconcurrency import ScreenCaptureKit

/// Takes pictures of a part of the screen (or one window) with ScreenCaptureKit, leaving out
/// PasteClip's own windows, so the picker's dimming and the scroll capture's frame never show.
/// Made once, then `grab()` as often as needed: scroll capture takes about ten a second.
struct ScreenGrabber {
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    /// Pixels per point of the screen it reads.
    let scale: CGFloat

    /// A region in screen coordinates as AppKit gives them (origin at the bottom left).
    static func region(_ rect: NSRect) async -> ScreenGrabber? {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSPoint(x: rect.midX, y: rect.midY), $0.frame, false) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == number })
        else { return nil }
        let own = content.applications.filter { $0.processID == getpid() }
        let configuration = SCStreamConfiguration()
        // ScreenCaptureKit counts from the top left of the display.
        configuration.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY,
                                          width: rect.width, height: rect.height)
        configuration.width = Int((rect.width * screen.backingScaleFactor).rounded())
        configuration.height = Int((rect.height * screen.backingScaleFactor).rounded())
        configuration.showsCursor = false
        configuration.captureResolution = .best
        return ScreenGrabber(filter: SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []),
                             configuration: configuration, scale: screen.backingScaleFactor)
    }

    /// One window, by itself: what is over it or behind it doesn't show, nor does its shadow.
    static func window(_ window: SCWindow, scale: CGFloat) -> ScreenGrabber {
        let configuration = SCStreamConfiguration()
        configuration.width = Int((window.frame.width * scale).rounded())
        configuration.height = Int((window.frame.height * scale).rounded())
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        return ScreenGrabber(filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration, scale: scale)
    }

    func grab() async -> CGImage? {
        try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
