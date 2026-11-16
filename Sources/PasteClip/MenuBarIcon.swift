import AppKit

/// The menu bar icon: the app icon's card with its clip, and a second card behind it, drawn as
/// a template so macOS colours it for a light or dark menu bar.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let line: CGFloat = 1.4
            let front = CGRect(x: 1.8, y: 1.2, width: 10.6, height: 13)
            let back = CGRect(x: 6.2, y: 4.8, width: 10, height: 12)
            let clip = CGRect(x: front.midX - 2.1, y: front.maxY - 1.3, width: 4.2, height: 2.5)

            // The card behind, hidden where the front card and its clip are.
            ctx.addPath(CGPath(roundedRect: back, cornerWidth: 2.3, cornerHeight: 2.3, transform: nil))
            ctx.setLineWidth(line)
            ctx.strokePath()
            ctx.setBlendMode(.clear)
            ctx.fill(front.insetBy(dx: -line, dy: -line))
            ctx.addPath(CGPath(roundedRect: clip.insetBy(dx: -line, dy: -line), cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
            ctx.setBlendMode(.normal)

            // The front card, open at the top where the clip sits.
            ctx.addPath(CGPath(roundedRect: front.insetBy(dx: line / 2, dy: line / 2), cornerWidth: 2.2, cornerHeight: 2.2,
                               transform: nil))
            ctx.strokePath()
            ctx.setBlendMode(.clear)
            ctx.addPath(CGPath(roundedRect: clip.insetBy(dx: -0.9, dy: -0.8), cornerWidth: 1.6, cornerHeight: 1.6, transform: nil))
            ctx.fillPath()
            ctx.setBlendMode(.normal)
            ctx.addPath(CGPath(roundedRect: clip, cornerWidth: 1.2, cornerHeight: 1.2, transform: nil))
            ctx.fillPath()

            // Two lines of text.
            for (i, width) in [6.0, 4.2].enumerated() {
                let row = CGRect(x: front.minX + 2.3, y: front.maxY - 5.4 - CGFloat(i) * 3, width: width, height: 1.4)
                ctx.addPath(CGPath(roundedRect: row, cornerWidth: 0.7, cornerHeight: 0.7, transform: nil))
                ctx.fillPath()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "PasteClip"
        return image
    }()
}
