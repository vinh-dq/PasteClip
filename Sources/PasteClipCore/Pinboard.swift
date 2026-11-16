import Foundation

/// A named collection of clips that the user keeps around.
public struct Pinboard: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var name: String
    /// Index into the app's pinboard colour palette.
    public var colorIndex: Int
    public var created = Date()

    public init(name: String, colorIndex: Int) {
        self.name = name
        self.colorIndex = colorIndex
    }
}
