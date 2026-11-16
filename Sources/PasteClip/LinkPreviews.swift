import AppKit
import LinkPresentation

/// Fetches and remembers page titles and images for link clips, for this session only.
final class LinkPreviews: ObservableObject {
    struct Preview {
        var title: String?
        var image: NSImage?
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
            let title = metadata?.title
            guard let imageProvider = metadata?.imageProvider ?? metadata?.iconProvider else {
                self?.finish(link, Preview(title: title))
                return
            }
            imageProvider.loadObject(ofClass: NSImage.self) { image, _ in
                self?.finish(link, Preview(title: title, image: image as? NSImage))
            }
        }
    }

    private func finish(_ link: String, _ preview: Preview) {
        DispatchQueue.main.async {
            self.loading.remove(link)
            self.previews[link] = preview
        }
    }
}
