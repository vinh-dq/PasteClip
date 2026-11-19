// Draws the app icon (a fan of glass clip cards on a deep indigo squircle) and writes
// Resources/AppIcon.icns and docs/icon.png.
// Run from the project root: swift scripts/make-icon.swift [preview.png]
import AppKit

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

/// The macOS icon shape: a superellipse, smoother at the corners than a rounded rectangle.
func squircle(_ rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2, n: CGFloat = 5
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// A card at the origin, turned by `angle` around its centre, which sits at `centre`.
func card(in ctx: CGContext, centre: CGPoint, size: CGSize, angle: CGFloat, front: Bool, tint: [CGColor], unit u: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: centre.x, y: centre.y)
    ctx.rotate(by: angle)
    let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
    let shape = roundedRect(rect, size.width * 0.11)

    // Soft shadow under the card.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -u * 0.018), blur: u * 0.06, color: rgb(0x05061A, front ? 0.55 : 0.4))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x000000, front ? 1 : 0.6))
    ctx.fillPath()
    ctx.restoreGState()

    // Body: bright paper in front, tinted glass behind.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(gradient(tint), start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    // Sheen across the top.
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, front ? 0.55 : 0.35), rgb(0xFFFFFF, 0)]),
                           start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.midY), options: [])

    if front {
        // Lines of text, the first in the accent gradient.
        let lineHeight = size.height * 0.075
        let left = rect.minX + size.width * 0.15
        for (i, width) in [0.62, 0.70, 0.48].enumerated() {
            let y = rect.maxY - size.height * 0.36 - CGFloat(i) * lineHeight * 2.1
            let line = CGRect(x: left, y: y - lineHeight, width: size.width * width, height: lineHeight)
            ctx.saveGState()
            ctx.addPath(roundedRect(line, lineHeight / 2))
            ctx.clip()
            if i == 0 {
                ctx.drawLinearGradient(gradient([rgb(0x2DD4BF), rgb(0x7C5CFF)]), start: CGPoint(x: line.minX, y: 0),
                                       end: CGPoint(x: line.maxX, y: 0), options: [])
            } else {
                ctx.setFillColor(rgb(0x1E2140, 0.16))
                ctx.fill(line)
            }
            ctx.restoreGState()
        }
    }
    ctx.restoreGState()

    // Fine edge: light on glass, a hairline on paper.
    ctx.addPath(shape)
    ctx.setLineWidth(max(u * 0.004, 0.5))
    ctx.setStrokeColor(front ? rgb(0xFFFFFF, 0.9) : rgb(0xFFFFFF, 0.35))
    ctx.strokePath()

    if front {
        // The clip at the top of the card.
        let clipSize = CGSize(width: size.width * 0.36, height: size.height * 0.16)
        let clip = CGRect(x: -clipSize.width / 2, y: rect.maxY - clipSize.height * 0.55,
                          width: clipSize.width, height: clipSize.height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -u * 0.006), blur: u * 0.018, color: rgb(0x05061A, 0.45))
        ctx.addPath(roundedRect(clip, clipSize.height * 0.42))
        ctx.setFillColor(rgb(0x000000))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(roundedRect(clip, clipSize.height * 0.42))
        ctx.clip()
        ctx.drawLinearGradient(gradient([rgb(0x3B3F6B), rgb(0x161833)]), start: CGPoint(x: 0, y: clip.maxY),
                               end: CGPoint(x: 0, y: clip.minY), options: [])
        ctx.restoreGState()
        // A slot in the clip.
        let slot = CGRect(x: -clipSize.width * 0.2, y: clip.midY - clipSize.height * 0.1,
                          width: clipSize.width * 0.4, height: clipSize.height * 0.2)
        ctx.addPath(roundedRect(slot, slot.height / 2))
        ctx.setFillColor(rgb(0xFFFFFF, 0.55))
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
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // macOS icon grid: the shape is 824/1024 of the canvas, centred.
    let inset = s * 100 / 1024
    let shape = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let u = shape.width
    let outline = squircle(shape)

    // Drop shadow of the whole icon.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: rgb(0x000000, 0.35))
    ctx.addPath(outline)
    ctx.setFillColor(rgb(0x14163A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(outline)
    ctx.clip()
    // Deep indigo, lighter at the top.
    ctx.drawLinearGradient(gradient([rgb(0x4B3FD1), rgb(0x241F6B), rgb(0x0E1030)], [0, 0.55, 1]),
                           start: CGPoint(x: shape.minX, y: shape.maxY), end: CGPoint(x: shape.maxX, y: shape.minY), options: [])
    // A glow behind the cards, and a teal one low on the right.
    ctx.drawRadialGradient(gradient([rgb(0x8B7BFF, 0.55), rgb(0x8B7BFF, 0)]),
                           startCenter: CGPoint(x: shape.midX - u * 0.08, y: shape.midY + u * 0.18), startRadius: 0,
                           endCenter: CGPoint(x: shape.midX - u * 0.08, y: shape.midY + u * 0.18), endRadius: u * 0.55, options: [])
    ctx.drawRadialGradient(gradient([rgb(0x2DD4BF, 0.28), rgb(0x2DD4BF, 0)]),
                           startCenter: CGPoint(x: shape.maxX - u * 0.1, y: shape.minY + u * 0.12), startRadius: 0,
                           endCenter: CGPoint(x: shape.maxX - u * 0.1, y: shape.minY + u * 0.12), endRadius: u * 0.5, options: [])

    // The cards: two of tinted glass fanned out behind a paper one.
    let cardSize = CGSize(width: u * 0.46, height: u * 0.56)
    let centre = CGPoint(x: shape.midX, y: shape.midY - u * 0.03)
    card(in: ctx, centre: CGPoint(x: centre.x - u * 0.12, y: centre.y + u * 0.02), size: cardSize, angle: 0.24,
         front: false, tint: [rgb(0x7C5CFF, 0.85), rgb(0x4B3FD1, 0.75)], unit: u)
    card(in: ctx, centre: CGPoint(x: centre.x + u * 0.12, y: centre.y + u * 0.02), size: cardSize, angle: -0.24,
         front: false, tint: [rgb(0x2DD4BF, 0.85), rgb(0x1E8FA8, 0.75)], unit: u)
    card(in: ctx, centre: CGPoint(x: centre.x, y: centre.y - u * 0.02), size: cardSize, angle: 0,
         front: true, tint: [rgb(0xFFFFFF), rgb(0xE9EBF8)], unit: u)

    // Light along the top edge and a thin rim, like polished glass.
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)]),
                           start: CGPoint(x: shape.midX, y: shape.maxY), end: CGPoint(x: shape.midX, y: shape.maxY - u * 0.3), options: [])
    ctx.restoreGState()
    ctx.addPath(outline)
    ctx.setLineWidth(max(s * 0.003, 0.5))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.16))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

if CommandLine.arguments.count > 1 {
    try icon(size: 1024).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("Wrote \(CommandLine.arguments[1])")
    exit(0)
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try icon(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try icon(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try icon(size: 256).write(to: URL(fileURLWithPath: "docs/icon.png"))
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns and docs/icon.png" : "iconutil failed")
