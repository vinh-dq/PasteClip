import AppKit
import PasteClipCore
import Translation

/// Translates the text in an image and draws the translation where the text was, with the
/// service chosen in Settings.
final class ImageTranslator {
    /// The text found in an image: read once, then translated into any language.
    struct Reading {
        let blocks: [TextBlock]
        /// The language of each block, one of those text is read in; nil for one without letters.
        let languages: [String?]
        /// macOS's text recognition wasn't working, so only Latin writing was read, if any.
        var incomplete = false
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let settings: AppSettings
    private let keys: APIKeys

    init(settings: AppSettings, keys: APIKeys) {
        self.settings = settings
        self.keys = keys
    }

    /// Finds the text in an image. A small image is read at twice its size, which Vision reads
    /// small letters much better at.
    @MainActor
    func read(_ image: CGImage) async throws -> Reading {
        let languages = settings.textLanguages
        let reading = await Task.detached(priority: .userInitiated) { () -> Reading in
            let small = max(image.width, image.height) < 1200
            let lines = TextRecognizer.lines(in: small ? TextRecognizer.upscaled(image, by: 2) : image, languages: languages)
            let blocks = ImageTranslation.blocks(from: lines, size: CGSize(width: image.width, height: image.height))
            return Reading(blocks: blocks, languages: blocks.map { ImageTranslation.language(of: $0.text, allowed: languages) },
                           incomplete: TextRecognizer.isFailing)
        }.value
        guard !reading.blocks.isEmpty else { throw Failure(message: TextRecognizer.nothingFoundMessage) }
        return reading
    }

    /// The first language in Settings that some of the text isn't in.
    func defaultTarget(for reading: Reading) -> String {
        ImageTranslation.target(for: reading.languages, priority: settings.translationTargets)
    }

    /// `image` with its text in `target`, and what went wrong with any language that couldn't
    /// be translated (the rest still is). Text already in that language is left as it is.
    @MainActor
    func translate(_ image: CGImage, reading: Reading, to target: String) async throws -> (image: CGImage, problem: String?) {
        let (translations, problem) = try await translate(reading, to: target)
        guard translations.contains(where: { !$0.isEmpty }) else {
            throw Failure(message: problem ?? "The text is already in \(Translator.name(of: target))")
        }
        let blocks = reading.blocks
        let rendered = await Task.detached(priority: .userInitiated) {
            ImageTranslation.render(image, blocks: blocks, translations: translations)
        }.value
        guard let rendered else { throw Failure(message: "Couldn't draw the translation") }
        return (rendered, problem)
    }

    /// One translation per block, empty for those already in `target`. Blocks go in one request
    /// per language, since a service works out one language per request (in one request, the
    /// Japanese in a mostly Vietnamese image would come back untranslated), all at once.
    @MainActor
    private func translate(_ reading: Reading, to target: String) async throws -> ([String], String?) {
        var groups: [String: [Int]] = [:]
        for (i, language) in reading.languages.enumerated() {
            guard let language, !ImageTranslation.isAlready(language, in: target) else { continue }
            groups[language, default: []].append(i)
        }
        var service = settings.translationService
        if service == .apple, #unavailable(macOS 26.0) {
            // Before macOS 26 Apple's service only works inside a window's view; Google stands in.
            service = .google
        }
        let key = keys.key(for: service)
        guard !service.needsKey || !key.isEmpty else {
            throw Failure(message: "Add an API key for \(service.title) in Settings → Translation")
        }
        let translator = WebTranslator(service: service, key: key, region: settings.microsoftRegion,
                                       model: settings.translationModels[service.rawValue] ?? "")
        var results = [String](repeating: "", count: reading.blocks.count)
        var problem: String?
        // A language that fails (not downloaded for Apple's service, say) leaves the others translated.
        await withTaskGroup(of: Result<[(Int, String)], Error>.self) { group in
            for (language, indices) in groups {
                let texts = indices.map { reading.blocks[$0].text }
                group.addTask {
                    do {
                        let translated: [String]
                        if service == .apple, #available(macOS 26.0, *) {
                            translated = try await Self.translateWithApple(texts, from: language, to: target)
                        } else {
                            translated = try await Self.translate(texts, with: translator, to: target)
                        }
                        return .success(Array(zip(indices, translated)))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for await result in group {
                switch result {
                case .success(let pairs): for (i, text) in pairs { results[i] = text }
                case .failure(let error): problem = problem ?? error.localizedDescription
                }
            }
        }
        return (results, problem)
    }

    /// Texts in one language: together, one line each, when the service keeps the lines apart;
    /// else each on its own, four at a time.
    private static func translate(_ texts: [String], with translator: WebTranslator, to target: String) async throws -> [String] {
        let joined = texts.map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n")
        if let parts = ImageTranslation.split(try await translator.translate(joined, to: target).text, count: texts.count) {
            return parts
        }
        return try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var results = [String](repeating: "", count: texts.count)
            var next = 0
            func add() {
                guard next < texts.count else { return }
                let i = next, text = texts[i]
                next += 1
                group.addTask { (i, try await translator.translate(text, to: target).text) }
            }
            for _ in 0..<4 { add() }
            while let (i, text) = try await group.next() {
                results[i] = text
                add()
            }
            return results
        }
    }

    @available(macOS 26.0, *)
    private static func translateWithApple(_ texts: [String], from language: String, to target: String) async throws -> [String] {
        let source = Translator.normalized(language) ?? language
        guard let session = await AppleSessions.shared.session(from: source, to: target) else {
            throw Failure(message: "Download \(Translator.name(of: source)) and \(Translator.name(of: target)) for Apple's "
                          + "translation in System Settings, or pick another service")
        }
        let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: "\($0)") }
        var results = texts
        for response in try await session.translations(from: requests) {
            if let id = response.clientIdentifier, let i = Int(id), results.indices.contains(i) { results[i] = response.targetText }
        }
        return results
    }
}
