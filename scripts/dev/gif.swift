// gif <in.mov> <out.gif> [fps=10] [width=760] [start=0] [end] [speed=1] — turns a screen recording
// (screencapture -v) into a looping GIF for the README, with Apple's frameworks only. With an
// out.png instead, the frames are laid out in a grid on one image, to check a recording at a glance.
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else { print("gif <in.mov> <out.gif> [fps] [width] [start] [end]"); exit(1) }
let fps = args.count > 3 ? Double(args[3]) ?? 10 : 10
let width = args.count > 4 ? Double(args[4]) ?? 760 : 760
let start = args.count > 5 ? Double(args[5]) ?? 0 : 0

let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let duration = CMTimeGetSeconds(asset.duration)
let end = args.count > 6 ? min(Double(args[6]) ?? duration, duration) : duration
// Played faster than recorded: frames are taken further apart, each shown as long.
let speed = args.count > 7 ? Double(args[7]) ?? 1 : 1
let generator = AVAssetImageGenerator(asset: asset)
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
generator.maximumSize = CGSize(width: width, height: 10_000)
generator.appliesPreferredTrackTransform = true

let times = stride(from: start, to: end, by: speed / fps).map { CMTime(seconds: $0, preferredTimescale: 600) }
if args[2].hasSuffix(".png") {
    let frames = times.compactMap { try? generator.copyCGImage(at: $0, actualTime: nil) }
    guard let first = frames.first else { exit(1) }
    let columns = 3, rows = (frames.count + columns - 1) / columns
    let w = first.width, h = first.height
    let ctx = CGContext(data: nil, width: w * columns, height: h * rows, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for (i, frame) in frames.enumerated() {
        ctx.draw(frame, in: CGRect(x: (i % columns) * w, y: (rows - 1 - i / columns) * h, width: w, height: h))
    }
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    print("\(frames.count) frames in a grid")
    exit(0)
}
guard let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.gif.identifier as CFString,
                                                times.count, nil) else { exit(1) }
CGImageDestinationSetProperties(out, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
var written = 0
for time in times {
    guard let image = try? generator.copyCGImage(at: time, actualTime: nil) else { continue }
    CGImageDestinationAddImage(out, image, frame)
    written += 1
}
guard CGImageDestinationFinalize(out) else { exit(1) }
let size = (try? FileManager.default.attributesOfItem(atPath: args[2])[.size] as? Int) ?? 0
print("\(written) frames, \(size / 1024) KB")
