import AppKit
import LinkPresentation

/// Fetches and remembers page titles, images and icons for link clips, for this session only.
final class LinkPreviews: ObservableObject {
    struct Preview {
        var title: String?
        /// The page's own picture (its preview image), if it has one.
        var image: NSImage?
        /// The site's icon.
        var icon: NSImage?
    }

    static let shared = LinkPreviews()

    @Published private(set) var previews: [String: Preview] = [:]
    private var loading = Set<String>()

    func preview(for link: String) -> Preview? { previews[link] }

    /// Starts a fetch unless one already ran for this link.
    func load(_ link: String) {
        guard previews[link] == nil, !loading.contains(link), let url = URL(string: link) else { return }
        loading.insert(link)
        let provider = LPMetadataProvider()
        provider.timeout = 10
        provider.startFetchingMetadata(for: url) { [weak self] metadata, _ in
            let preview = Box(Preview(title: metadata?.title))
            let group = DispatchGroup()
            if let imageProvider = metadata?.imageProvider {
                group.enter()
                imageProvider.loadObject(ofClass: NSImage.self) { image, _ in
                    preview.lock { $0.image = image as? NSImage }
                    group.leave()
                }
            }
            if let iconProvider = metadata?.iconProvider {
                group.enter()
                iconProvider.loadObject(ofClass: NSImage.self) { image, _ in
                    preview.lock { $0.icon = image as? NSImage }
                    group.leave()
                }
            }
            group.notify(queue: .main) { self?.finish(link, preview.value) }
        }
    }

    private func finish(_ link: String, _ preview: Preview) {
        DispatchQueue.main.async {
            self.loading.remove(link)
            self.previews[link] = preview
        }
    }

    /// The preview filled in from two callbacks that may run at once.
    private final class Box: @unchecked Sendable {
        private let mutex = NSLock()
        private(set) var value: Preview
        init(_ value: Preview) { self.value = value }
        func lock(_ change: (inout Preview) -> Void) {
            mutex.lock()
            change(&value)
            mutex.unlock()
        }
    }
}
