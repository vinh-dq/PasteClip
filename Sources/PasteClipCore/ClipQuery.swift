import Foundation

public enum TypeFilter: String, CaseIterable, Identifiable {
    case all, text, link, image, file, color
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "All Types"
        case .text: return "Text"
        case .link: return "Links"
        case .image: return "Images"
        case .file: return "Files"
        case .color: return "Colors"
        }
    }

    public func matches(_ item: ClipItem) -> Bool {
        switch self {
        case .all: return true
        case .text: return item.kind == .text
        case .link: return item.kind == .link
        case .image: return item.isImage
        case .file: return item.kind == .file
        case .color: return item.kind == .color
        }
    }
}

public enum DateRange: String, CaseIterable, Identifiable {
    case any, today, week, month
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .any: return "Any Time"
        case .today: return "Today"
        case .week: return "Last 7 Days"
        case .month: return "Last 30 Days"
        }
    }

    public func contains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .any: return true
        case .today: return calendar.isDate(date, inSameDayAs: now)
        case .week: return date >= now.addingTimeInterval(-7 * 86_400)
        case .month: return date >= now.addingTimeInterval(-30 * 86_400)
        }
    }
}

/// What the shelf is showing: history or one pinboard, narrowed by search and filters.
public struct ClipQuery: Equatable {
    public var text = ""
    public var type = TypeFilter.all
    public var sourceBundleID: String?
    public var dateRange = DateRange.any
    /// nil shows the whole history.
    public var pinboardID: UUID?

    public init() {}

    public var hasFilters: Bool { type != .all || sourceBundleID != nil || dateRange != .any }

    public func matches(_ item: ClipItem, now: Date = Date()) -> Bool {
        if let pinboardID, item.pinboardID != pinboardID { return false }
        guard type.matches(item), dateRange.contains(item.date, now: now) else { return false }
        if let sourceBundleID, item.sourceBundleID != sourceBundleID { return false }
        // Every word must appear somewhere, ignoring case and accents.
        let terms = text.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        let haystack = item.searchableText
        return terms.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    public func apply(_ items: [ClipItem]) -> [ClipItem] {
        let now = Date()
        let found = items.filter { matches($0, now: now) }
        // A pinboard keeps the order the user arranged; history stays newest first.
        guard pinboardID != nil else { return found }
        return found.enumerated()
            .sorted { ($0.element.boardKey, $0.offset) < ($1.element.boardKey, $1.offset) }
            .map(\.element)
    }
}
