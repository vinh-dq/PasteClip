import Foundation
import Vision

/// Finds text in images on a background queue so image clips are searchable.
enum TextRecognizer {
    static func recognize(imageAt url: URL, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try? VNImageRequestHandler(url: url).perform([request])
            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            DispatchQueue.main.async { completion(text.isEmpty ? nil : text) }
        }
    }
}
