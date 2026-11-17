import AppKit
import UniformTypeIdentifiers

public enum ClipKind: String, Codable, CaseIterable {
    case text, link, image, file, color

    public var label: String {
        switch self {
        case .text: return "Text"
        case .link: return "Link"
        case .image: return "Image"
        case .file: return "File"
        case .color: return "Color"
        }
    }

    public var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        case .color: return "paintpalette"
        }
    }

    /// Kind for a copied string: a hex colour, a single web link, or plain text.
    public static func detect(_ string: String) -> ClipKind {
        if RGBA(hex: string) != nil { return .color }
        if isLink(string) { return .link }
        return .text
    }

    static func isLink(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(where: \.isWhitespace), let url = URL(string: t) else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }
}

public struct ClipItem: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var kind: ClipKind
    public var text: String?
    /// User-given name, shown instead of the kind on the card.
    public var title: String?
    public var imageFile: String?
    public var filePaths: [String]?
    /// File in the store's `rich` folder holding the formatted version of `text`.
    public var richFile: String?
    /// `rtf` or `html`.
    public var richType: String?
    /// File in the store's `rich` folder holding everything the source app put on the pasteboard,
    /// including its own formats (Slack, VS Code, Office…), so pasting gives that app its formatting back.
    public var pasteboardFile: String?
    /// Text found in an image by Vision.
    public var ocrText: String?
    /// Where on screen (in points) a screenshot taken by PasteClip was, so it floats back over
    /// that spot.
    public var screenFrame: CGRect?
    public var sourceBundleID: String?
    public var sourceName: String?
    public var date = Date()
    public var pinned = false
    public var pinboardID: UUID?
    /// Position on its pinboard, lower first. nil sorts by date, newest first (see `boardKey`).
    public var boardOrder: Double?

    public init(kind: ClipKind, text: String? = nil, imageFile: String? = nil, filePaths: [String]? = nil,
                sourceBundleID: String? = nil, sourceName: String? = nil) {
        self.kind = kind
        self.text = text
        self.imageFile = imageFile
        self.filePaths = filePaths
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
    }

    /// Pinned and pinboard clips are never trimmed from history.
    public var isKept: Bool { pinned || pinboardID != nil }

    public var isTextual: Bool { kind == .text || kind == .link || kind == .color }

    public var hasFormatting: Bool { richFile != nil || pasteboardFile != nil }

    /// A single image file copied in Finder or by a screenshot app, which can be marked up and
    /// floated like an image clip.
    public var copiedImagePath: String? {
        guard kind == .file, let paths = filePaths, paths.count == 1, let path = paths.first,
              let type = UTType(filenameExtension: (path as NSString).pathExtension), type.conforms(to: .image)
        else { return nil }
        return path
    }

    /// An image clip, or a copied image file.
    public var isImage: Bool { kind == .image || copiedImagePath != nil }

    /// What makes two clips "the same" for de-duplication.
    public var contentKey: String {
        switch kind {
        case .text, .link, .color: return text ?? ""
        case .file: return (filePaths ?? []).joined(separator: "\n")
        case .image: return imageFile ?? id.uuidString
        }
    }

    /// Everything search looks at.
    public var searchableText: String {
        [title, text, filePaths?.joined(separator: "\n"), ocrText, sourceName]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    public var summary: String {
        switch kind {
        case .text:
            let n = text?.count ?? 0
            return "\(n) character\(n == 1 ? "" : "s")"
        case .link:
            return URL(string: text ?? "")?.host ?? "Link"
        case .image:
            return ocrText == nil ? "Image" : "Image · has text"
        case .file:
            let n = filePaths?.count ?? 0
            return "\(n) file\(n == 1 ? "" : "s")"
        case .color:
            return text?.uppercased() ?? "Color"
        }
    }
}

/// A colour parsed from `#RGB`, `#RRGGBB` or `#RRGGBBAA`.
public struct RGBA: Equatable {
    public var r, g, b, a: Double

    public init?(hex: String) {
        let t = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("#") else { return nil }
        var digits = String(t.dropFirst())
        guard [3, 6, 8].contains(digits.count), let value = UInt64(digits, radix: 16) else { return nil }
        if digits.count == 3 {
            digits = digits.map { "\($0)\($0)" }.joined()
            guard let v = UInt64(digits, radix: 16) else { return nil }
            self.init(value: v << 8 | 0xFF)
        } else if digits.count == 6 {
            self.init(value: value << 8 | 0xFF)
        } else {
            self.init(value: value)
        }
    }

    private init(value: UInt64) {
        r = Double((value >> 24) & 0xFF) / 255
        g = Double((value >> 16) & 0xFF) / 255
        b = Double((value >> 8) & 0xFF) / 255
        a = Double(value & 0xFF) / 255
    }
}

extension ClipItem {
    /// Sort key on a pinboard. Clips never reordered fall back to their date, newest first,
    /// on the same scale, so a clip added later still lands at the front.
    public var boardKey: Double { boardOrder ?? -date.timeIntervalSince1970 }
}
