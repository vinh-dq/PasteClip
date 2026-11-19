import AppKit
import SwiftUI

/// Hosting view for the shelf and popup. Moving cards under a still mouse makes AppKit send
/// `cursorUpdate` over and over, and setting the cursor, even to the same arrow, redraws it;
/// with an enlarged or recoloured pointer (Accessibility settings) that took a good share of
/// every frame. PasteClip shows no custom cursors, so the arrow is only set when it isn't already.
final class HostingView<Content: View>: NSHostingView<Content> {
    override func cursorUpdate(with event: NSEvent) {
        guard NSCursor.current != NSCursor.arrow else { return }
        super.cursorUpdate(with: event)
    }
}
