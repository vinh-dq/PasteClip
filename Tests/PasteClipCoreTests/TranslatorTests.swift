import AppKit
import Foundation
import Testing
@testable import PasteClipCore

@Test func textGoesIntoTheFirstLanguageItIsNotAlreadyIn() {
    let priority = Translator.defaultTargets
    #expect(priority == ["vi", "en", "ja", "zh-Hans"])
    #expect(Translator.target(for: "en", priority: priority) == "vi")
    #expect(Translator.target(for: "ja", priority: priority) == "vi")
    #expect(Translator.target(for: "vi", priority: priority) == "en")
    #expect(Translator.target(for: nil, priority: priority) == "vi")
    #expect(Translator.target(for: "zh-Hant", priority: ["zh-Hans", "en"]) == "en")
    #expect(Translator.target(for: "en", priority: []) == "vi")
}

@Test func findsTheLanguageOfClearTextOnly() {
    #expect(Translator.detectLanguage("Hello world, how are you today?") == "en")
    #expect(Translator.detectLanguage("Xin chào, hôm nay bạn thế nào?") == "vi")
    #expect(Translator.detectLanguage("xin chao ban, hom nay the nao") == "vi")
    #expect(Translator.detectLanguage("会議は東京で行います") == "ja")
    #expect(Translator.detectLanguage("你好，今天怎么样") == "zh-Hans")
    #expect(Translator.detectLanguage("OK") == nil)
}

@Test func unsureTextStillHasLikelyLanguages() {
    #expect(Translator.detectLanguage("Keynote") == nil || Translator.likelyLanguages("Keynote").first != nil)
    #expect(!Translator.likelyLanguages("Keynote").isEmpty)
    #expect(Translator.likelyLanguages("会議は東京で行います").first == "ja")
    #expect(Translator.likelyLanguages("").isEmpty)
}

@Test func languageCodesMatchEachService() {
    #expect(Translator.code(for: "zh-Hans", in: .google) == "zh-CN")
    #expect(Translator.code(for: "zh-Hant", in: .googleCloud) == "zh-TW")
    #expect(Translator.code(for: "en", in: .deepL) == "EN-US")
    #expect(Translator.code(for: "zh-Hans", in: .deepL) == "ZH-HANS")
    #expect(Translator.code(for: "vi", in: .deepL) == "VI")
    #expect(Translator.code(for: "zh-Hant", in: .microsoft) == "zh-Hant")
    #expect(Translator.normalized("zh-CN") == "zh-Hans")
    #expect(Translator.normalized("ZH") == "zh-Hans")
    #expect(Translator.normalized("EN") == "en")
    #expect(Translator.normalized("") == nil)
    #expect(Translator.name(of: "vi") == "Vietnamese")
    #expect(Translator.name(of: "zh-Hans") == "Chinese")
}

@Test func longTextIsCutBetweenLinesAndJoinsBack() {
    let text = (1...40).map { "Line \($0) " + String(repeating: "word ", count: 20) }.joined(separator: "\n")
    let chunks = Translator.chunks(of: text, limit: 500)
    #expect(chunks.count > 1)
    #expect(chunks.allSatisfy { $0.count <= 500 })
    #expect(chunks.joined(separator: "\n") == text)
    #expect(Translator.chunks(of: "short\n\ntext") == ["short\n\ntext"])

    let line = String(repeating: "abc ", count: 300)
    let pieces = Translator.chunks(of: line, limit: 500)
    #expect(pieces.allSatisfy { $0.count <= 500 })
    #expect(pieces.joined() == line)
}

@Test func readsTheAnswerOfEachService() throws {
    let google = Data(#"{"sentences":[{"trans":"Xin chào thế giới.\n","orig":"Hello world.\n"},{"trans":"Bạn khỏe không?"}],"src":"en"}"#.utf8)
    #expect(try WebTranslator(service: .google).parse(google) == TranslationResult(text: "Xin chào thế giới.\nBạn khỏe không?", source: "en"))

    let cloud = Data(#"{"data":{"translations":[{"translatedText":"你好","detectedSourceLanguage":"vi"}]}}"#.utf8)
    #expect(try WebTranslator(service: .googleCloud).parse(cloud) == TranslationResult(text: "你好", source: "vi"))

    let deepL = Data(#"{"translations":[{"detected_source_language":"JA","text":"Hello"}]}"#.utf8)
    #expect(try WebTranslator(service: .deepL).parse(deepL) == TranslationResult(text: "Hello", source: "ja"))

    let microsoft = Data(#"[{"detectedLanguage":{"language":"zh-Hans","score":1.0},"translations":[{"text":"Xin chào","to":"vi"}]}]"#.utf8)
    #expect(try WebTranslator(service: .microsoft).parse(microsoft) == TranslationResult(text: "Xin chào", source: "zh-Hans"))

    #expect(throws: TranslationFailure.self) { try WebTranslator(service: .deepL).parse(Data("<html>".utf8)) }
}

@Test func requestsCarryTheKeyWhereEachServiceWantsIt() throws {
    let google = WebTranslator(service: .google).request(for: "a&b c", to: "zh-Hans")
    #expect(google.url?.absoluteString.contains("tl=zh-CN") == true)
    #expect(String(decoding: google.httpBody ?? Data(), as: UTF8.self) == "q=a%26b%20c")

    let free = WebTranslator(service: .deepL, key: " abc:fx ").request(for: "x", to: "vi")
    #expect(free.url?.host == "api-free.deepl.com")
    #expect(free.value(forHTTPHeaderField: "Authorization") == "DeepL-Auth-Key abc:fx")
    #expect(WebTranslator(service: .deepL, key: "abc").request(for: "x", to: "vi").url?.host == "api.deepl.com")

    let cloud = WebTranslator(service: .googleCloud, key: "K").request(for: "x", to: "ja")
    // In a header, never in the address.
    #expect(cloud.value(forHTTPHeaderField: "X-goog-api-key") == "K")
    #expect(cloud.url?.query == nil)

    let microsoft = WebTranslator(service: .microsoft, key: "K", region: "southeastasia").request(for: "x", to: "vi")
    #expect(microsoft.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key") == "K")
    #expect(microsoft.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Region") == "southeastasia")
    let body = try JSONSerialization.jsonObject(with: microsoft.httpBody ?? Data()) as? [[String: String]]
    #expect(body == [["Text": "x"]])
}

@Test func modelListsComeFromTheProviderWithoutModelsThatCantTranslate() {
    let gemini = WebTranslator(service: .gemini, key: "AIza")
    #expect(gemini.modelsRequest().value(forHTTPHeaderField: "x-goog-api-key") == "AIza")
    let geminiList = Data(#"{"models":[{"name":"models/gemini-3.5-flash-lite","supportedGenerationMethods":["generateContent"]},{"name":"models/gemini-3.8-flash","supportedGenerationMethods":["generateContent","countTokens"]},{"name":"models/gemini-embedding-001","supportedGenerationMethods":["embedContent"]},{"name":"models/gemini-3.8-flash-tts","supportedGenerationMethods":["generateContent"]}]}"#.utf8)
    #expect(gemini.parseModels(geminiList) == ["gemini-3.8-flash", "gemini-3.5-flash-lite"])

    let openAI = WebTranslator(service: .openAI, key: "sk")
    #expect(openAI.modelsRequest().url?.absoluteString == "https://api.openai.com/v1/models")
    #expect(openAI.modelsRequest().value(forHTTPHeaderField: "Authorization") == "Bearer sk")
    let openAIList = Data(#"{"data":[{"id":"gpt-4.1-nano"},{"id":"text-embedding-3-small"},{"id":"gpt-4o-mini-tts"},{"id":"whisper-1"},{"id":"gpt-5-mini"}]}"#.utf8)
    #expect(openAI.parseModels(openAIList) == ["gpt-5-mini", "gpt-4.1-nano"])

    let claude = WebTranslator(service: .claude, key: "sk-ant").modelsRequest()
    #expect(claude.url?.host == "api.anthropic.com" && claude.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
    #expect(claude.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
    #expect(WebTranslator(service: .deepSeek, key: "k").modelsRequest().url?.absoluteString == "https://api.deepseek.com/models")
    #expect(WebTranslator(service: .grok, key: "k").modelsRequest().url?.absoluteString == "https://api.x.ai/v1/models")
}

@Test func everyAIServiceSuggestsItsDefaultModelFirst() {
    for service in TranslationService.allCases {
        #expect(service.isAI == (service.defaultModel != nil))
        #expect(service.suggestedModels.first == service.defaultModel)
    }
}

@Test func aiServicesAreToldWhatToDoAndAnswerWithTextOnly() throws {
    func body(_ request: URLRequest) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    }

    let openAI = WebTranslator(service: .openAI, key: "sk").request(for: "Xin chào", to: "zh-Hans")
    #expect(openAI.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
    #expect(openAI.value(forHTTPHeaderField: "Authorization") == "Bearer sk")
    let openAIBody = try body(openAI)
    let messages = try #require(openAIBody["messages"] as? [[String: String]])
    #expect(openAIBody["model"] as? String == "gpt-4.1-nano")
    #expect(messages[0]["role"] == "system" && messages[0]["content"]?.contains("Simplified Chinese") == true)
    #expect(messages[1] == ["role": "user", "content": "Xin chào"])
    #expect(WebTranslator(service: .deepSeek, key: "k").request(for: "x", to: "vi").url?.host == "api.deepseek.com")
    #expect(WebTranslator(service: .grok, key: "k").request(for: "x", to: "vi").url?.host == "api.x.ai")

    // Haiku by default: fast and cheap, with no server-side fallback to ask for.
    let haiku = WebTranslator(service: .claude, key: "k").request(for: "x", to: "vi")
    let haikuBody = try body(haiku)
    #expect(haikuBody["model"] as? String == "claude-haiku-5-5")
    #expect(haiku.value(forHTTPHeaderField: "anthropic-beta") == nil && haikuBody["fallbacks"] == nil)
    #expect((haikuBody["output_config"] as? [String: String]) == ["effort": "low"])

    let claude = WebTranslator(service: .claude, key: "sk-ant", model: "claude-opus-5-5").request(for: "Hello", to: "vi")
    #expect(claude.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
    #expect(claude.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
    #expect(claude.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
    let claudeBody = try body(claude)
    #expect(claudeBody["model"] as? String == "claude-opus-5-5")
    #expect(claudeBody["fallbacks"] as? String == "default")
    #expect((claudeBody["output_config"] as? [String: String]) == ["effort": "low"])
    #expect(claudeBody["temperature"] == nil)
    // Older models take no effort setting.
    let olderBody = try body(WebTranslator(service: .claude, key: "k", model: "claude-haiku-4-5").request(for: "x", to: "vi"))
    #expect(olderBody["output_config"] == nil)

    let gemini = WebTranslator(service: .gemini, key: "AIza", model: " gemini-2.5-flash ").request(for: "x", to: "ja")
    #expect(gemini.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
    #expect(gemini.value(forHTTPHeaderField: "x-goog-api-key") == "AIza")

    let chat = Data(#"{"choices":[{"message":{"role":"assistant","content":"\nXin chào\n"}}]}"#.utf8)
    #expect(try WebTranslator(service: .openAI).parse(chat) == TranslationResult(text: "Xin chào", source: nil))
    let message = Data(#"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"Xin chào"}],"stop_reason":"end_turn"}"#.utf8)
    #expect(try WebTranslator(service: .claude).parse(message).text == "Xin chào")
    let refusal = Data(#"{"content":[],"stop_reason":"refusal"}"#.utf8)
    #expect(throws: TranslationFailure.self) { try WebTranslator(service: .claude).parse(refusal) }
    let candidates = Data(#"{"candidates":[{"content":{"parts":[{"text":"plan","thought":true},{"text":"こんにちは"}]}}]}"#.utf8)
    #expect(try WebTranslator(service: .gemini).parse(candidates).text == "こんにちは")
}

/// Answers every request with the next canned response, and records what was asked.
private final class CannedResponses: URLProtocol {
    nonisolated(unsafe) static var responses: [(Int, String)] = []
    nonisolated(unsafe) static var bodies: [String] = []
    /// When set, answers each request from its body instead of the queue (for requests sent together).
    nonisolated(unsafe) static var responder: ((String) -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            body = data
        }
        let text = String(decoding: body ?? Data(), as: UTF8.self)
        Self.bodies.append(text)
        let (status, json) = Self.responder?(text) ?? (Self.responses.isEmpty ? (500, "{}") : Self.responses.removeFirst())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CannedResponses.self]
        return URLSession(configuration: configuration)
    }
}

@Test func onlyTextAndTextInImagesAreTranslated() {
    #expect(ClipItem(kind: .text, text: "Hello").translatableText == "Hello")
    #expect(ClipItem(kind: .link, text: "https://example.com").translatableText == nil)
    var image = ClipItem(kind: .image)
    #expect(image.translatableText == nil)
    image.ocrText = "会議"
    #expect(image.translatableText == "会議")
}

@Test func translationSettingsDefaultToVietnameseFirstAndControlSpace() {
    let defaults = Scratch.defaults()
    let settings = AppSettings(defaults: defaults)
    #expect(settings.translationTargets == ["vi", "en", "ja", "zh-Hans"])
    #expect(settings.translationService == .google)
    #expect(settings.translateHotKey?.display == "⌃Space")
    #expect(settings.translateSelection && !settings.translateScreenText && settings.saveTranslations)
    #expect(settings.translationShowsOriginal)
    settings.translationService = .apple
    settings.translationTargets = ["en", "vi"]
    let reloaded = AppSettings(defaults: defaults)
    #expect(reloaded.translationService == .apple)
    #expect(reloaded.translationTargets == ["en", "vi"])
}

@Test func knowsWhenMacOSHasTheShortcut() {
    let inputSources: [String: Any] = [
        "60": ["enabled": true, "value": ["parameters": [32, 49, 262144], "type": "standard"]],
        "61": ["enabled": false, "value": ["parameters": [32, 49, 786432], "type": "standard"]],
    ]
    #expect(KeyCombo.translate.isUsedBySystem(inputSources))
    #expect(!KeyCombo(keyCode: 49, modifiers: KeyCombo.control | KeyCombo.option, keyName: "Space").isUsedBySystem(inputSources))
    #expect(!KeyCombo.openShelf.isUsedBySystem(inputSources))
    #expect(!KeyCombo.translate.isUsedBySystem([:]))
}

@Test func borrowedClipboardChangesAreNotSaved() {
    let dir = Scratch.folder()
    let pasteboard = Scratch.pasteboard()
    let store = ClipStore(directory: dir, pasteboard: pasteboard)
    store.captureSuspended = true
    pasteboard.clearContents()
    pasteboard.setString("selected text", forType: .string)
    pasteboard.clearContents()
    pasteboard.setString("clipboard put back", forType: .string)
    // Resuming before the next check still lets the borrowed changes go.
    store.captureSuspended = false
    store.poll()
    #expect(store.items.isEmpty)

    store.copyWithoutSaving("a translation")
    store.poll()
    #expect(store.items.isEmpty)
    #expect(pasteboard.string(forType: .string) == "a translation")
}

private let bingPage = """
    <script>_G={IG:"ABC123",EF:{}};</script><div id="rich_tta" data-iid="translator.5023"></div>
    <script>var params_AbusePreventionHelper = [1794844044396,"tok_EN",3600000];</script>
    """

@Test func readsBingsTokenFromItsPage() throws {
    let now = Date()
    let credentials = try #require(BingSession.credentials(inPage: bingPage, host: "www.bing.com", now: now))
    #expect(credentials.ig == "ABC123" && credentials.iid == "translator.5023")
    #expect(credentials.key == "1794844044396" && credentials.token == "tok_EN")
    #expect(credentials.refreshAfter == now.addingTimeInterval(1800))
    #expect(BingSession.credentials(inPage: "<html>captcha</html>", host: "www.bing.com", now: now) == nil)

    let request = WebTranslator(service: .bing).bingRequest(for: "a&b", to: "zh-Hans", with: credentials)
    #expect(request.url?.absoluteString == "https://www.bing.com/ttranslatev3?isVertical=1&IG=ABC123&IID=translator.5023")
    #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        == "fromLang=auto-detect&to=zh-Hans&text=a%26b&token=tok_EN&key=1794844044396")
}

/// These share `CannedResponses`, so they take turns.
@Suite(.serialized) struct ServiceAnswers {
    @Test func failuresSayWhatWentWrong() async throws {
        var deepL = WebTranslator(service: .deepL, key: "bad")
        deepL.session = CannedResponses.session()
        CannedResponses.responses = [(403, #"{"message":"Wrong endpoint"}"#)]
        await #expect(throws: TranslationFailure.badKey) { try await deepL.translate("Hello", to: "vi") }

        CannedResponses.responses = [(456, #"{"message":"Quota exceeded"}"#)]
        await #expect(throws: TranslationFailure.limited) { try await deepL.translate("Hello", to: "vi") }

        var cloud = WebTranslator(service: .googleCloud, key: "bad")
        cloud.session = CannedResponses.session()
        CannedResponses.responses = [(400, #"{"error":{"code":400,"message":"API key not valid. Please pass a valid API key."}}"#)]
        await #expect(throws: TranslationFailure.badKey) { try await cloud.translate("Hello", to: "vi") }

        var google = WebTranslator(service: .google)
        google.session = CannedResponses.session()
        CannedResponses.responses = [(429, "")]
        await #expect(throws: TranslationFailure.limited) { try await google.translate("Hello", to: "vi") }

        // A long text goes in pieces, sent together, and comes back joined in order.
        CannedResponses.bodies = []
        let text = (1...6).map { "Paragraph \($0) " + String(repeating: "x", count: 3000) }.joined(separator: "\n")
        CannedResponses.responder = { body in
            let n = (1...6).first { body.contains("Paragraph%20\($0)%20") } ?? 0
            return (200, #"{"sentences":[{"trans":"Đoạn \#(n)"}],"src":"en"}"#)
        }
        defer { CannedResponses.responder = nil }
        let result = try await google.translate(text, to: "vi")
        #expect(result == TranslationResult(text: (1...6).map { "Đoạn \($0)" }.joined(separator: "\n"), source: "en"))
        #expect(CannedResponses.bodies.count == 6)
    }

    @Test func bingGetsANewTokenWhenTheOldOneIsRefused() async throws {
        var bing = WebTranslator(service: .bing)
        bing.session = CannedResponses.session()
        bing.bing = BingSession()
        let answer = #"[{"translations":[{"text":"Xin chào","to":"vi"}],"detectedLanguage":{"language":"en"}}]"#
        CannedResponses.bodies = []
        CannedResponses.responses = [(200, bingPage), (200, #"{"ShowCaptcha":false}"#), (200, bingPage), (200, answer)]
        #expect(try await bing.translate("Hello", to: "vi") == TranslationResult(text: "Xin chào", source: "en"))
        #expect(CannedResponses.bodies.count == 4)

        // The token is kept for the next text, which is sent in pieces of at most 1,000 characters.
        CannedResponses.bodies = []
        CannedResponses.responses = [(200, answer), (200, answer)]
        let long = String(repeating: "a", count: 900) + "\n" + String(repeating: "b", count: 900)
        #expect(try await bing.translate(long, to: "vi").text == "Xin chào\nXin chào")
        #expect(CannedResponses.bodies.count == 2)

        CannedResponses.responses = [(401, ""), (200, bingPage), (401, "")]
        await #expect(throws: TranslationFailure.limited) { try await bing.translate("Hello", to: "vi") }
    }
}

@Test func translationsKeepTheOriginalsLineBreaks() {
    let original = "First line\nSecond line\nThird line"
    #expect(Translator.keepingLineBreaks(of: original, in: "Một\n\nHai\n\nBa") == "Một\nHai\nBa")
    // A blank line in the original is kept, and so is a translation that already matches.
    #expect(Translator.keepingLineBreaks(of: "A\n\nB", in: "Một\n\nHai") == "Một\n\nHai")
    #expect(Translator.keepingLineBreaks(of: original, in: "Một\nHai\nBa") == "Một\nHai\nBa")
}
