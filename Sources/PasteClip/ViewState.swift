import SwiftUI

/// Local view state held through `@StateObject`.
///
/// Stands in for `@State`, which the macOS 27 SDK implements as a macro whose plugin ships
/// with Xcode but not with the Command Line Tools this project builds with.
/// Use `box.value` to read and `$box.value` for a binding.
final class ViewState<Value>: ObservableObject {
    @Published var value: Value

    init(_ value: Value) { self.value = value }
}
