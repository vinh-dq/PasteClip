// Draws the app icon (three stacked clip cards on a gradient) and writes Resources/AppIcon.icns.
// Run from the project root: swift scripts/make-icon.swift
import AppKit

func card(_ rect: CGRect, header: NSColor, in ctx: CGContext) {
    let radius = rect.width * 0.09
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -rect.height * 0.03), blur: rect.width * 0.08,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let headerHeight = rect.height * 0.24
    ctx.setFillColor(header.cgColor)
    ctx.fill(CGRect(x: rect.minX, y: rect.maxY - headerHeight, width: rect.width, height: headerHeight))
    // Lines of "text".
    ctx.setFillColor(NSColor(white: 0.82, alpha: 1).cgColor)
    let lineHeight = rect.height * 0.065
    for (i, width) in [0.72, 0.56, 0.64].enumerated() {
        let y = rect.maxY - headerHeight - rect.height * 0.14 - CGFloat(i) * lineHeight * 2
        let line = CGRect(x: rect.minX + rect.width * 0.12, y: y - lineHeight,
                          width: rect.width * width, height: lineHeight)
        ctx.addPath(CGPath(roundedRect: line, cornerWidth: lineHeight / 2, cornerHeight: lineHeight / 2, transform: nil))
        ctx.fillPath()
    }
    ctx.restoreGState()
}

func icon(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: the shape is 824/1024 of the canvas, centred.
    let inset = s * 100 / 1024
    let shape = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shapePath = CGPath(roundedRect: shape, cornerWidth: shape.width * 0.225,
                           cornerHeight: shape.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03,
                  color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(shapePath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shapePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.36, green: 0.55, blue: 1.0, alpha: 1).cgColor,
        NSColor(red: 0.55, green: 0.33, blue: 0.95, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: shape.minX, y: shape.maxY),
                           end: CGPoint(x: shape.maxX, y: shape.minY), options: [])

    let w = shape.width * 0.5, h = shape.height * 0.56
    let colors: [NSColor] = [
        NSColor(red: 0.98, green: 0.36, blue: 0.40, alpha: 1),
        NSColor(red: 0.20, green: 0.78, blue: 0.55, alpha: 1),
        NSColor(red: 1.0, green: 0.70, blue: 0.20, alpha: 1),
    ]
    for (i, color) in colors.enumerated() {
        let offset = CGFloat(i - 1)
        let rect = CGRect(x: shape.midX - w / 2 + offset * shape.width * 0.13,
                          y: shape.midY - h / 2 - offset * shape.height * 0.07, width: w, height: h)
        card(rect, header: color, in: ctx)
    }
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try icon(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try icon(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
