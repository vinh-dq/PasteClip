import AppKit
import ImageIO
import PasteClipCore
import UniformTypeIdentifiers

/// Reads text in a process of its own, for when reading in the app fails (see
/// `TextRecognizer.readElsewhere`): PasteClip's own executable, run with `--read-text`, reads
/// one image, writes its lines as JSON and quits, without starting the app.
enum TextReadingProcess {
    private static let argument = "--read-text"

    /// In that process: reads the image and quits. Does nothing in the app itself.
    static func runIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: argument), args.count > i + 3 else { return }
        let image = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[i + 1]) as CFURL, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        guard let image else { exit(1) }
        let languages = args[i + 2].split(separator: ",").map(String.init)
        let lines = TextRecognizer.lines(in: image, languages: languages)
        guard !TextRecognizer.isFailing, let data = try? JSONEncoder().encode(lines),
              (try? data.write(to: URL(fileURLWithPath: args[i + 3]))) != nil else { exit(2) }
        exit(0)
    }

    /// In the app: reads `image` in a new process, waiting for it (off the main thread). Nil if
    /// it can't read it either.
    static func read(_ image: CGImage, languages: [String]) -> [TextRecognizer.Line]? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PasteClip-read-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("image.png")
        let output = folder.appendingPathComponent("lines.json")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              let destination = CGImageDestinationCreateWithURL(input as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let process = Process()
        process.executableURL = executable
        process.arguments = [argument, input.path, languages.joined(separator: ","), output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return nil }
        // Most of a minute when macOS has to prepare its models there first; a moment otherwise.
        if done.wait(timeout: .now() + 120) == .timedOut {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0, let data = try? Data(contentsOf: output) else { return nil }
        return try? JSONDecoder().decode([TextRecognizer.Line].self, from: data)
    }
}
