import SwiftUI
import LinkPresentation

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    /// Called when the sheet finishes, whether the user shared or cancelled.
    var onComplete: (() -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onComplete?()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// What the share sheet presents. Using `.sheet(item:)` with this guarantees the sheet is
/// built with exactly these items, instead of reading separate state that may not have
/// updated yet on the very first presentation.
struct ShareRequest: Identifiable {
    let id = UUID()
    let items: [Any]
}

/// Wraps an exported file URL and hands the share sheet its title and thumbnail up front.
/// Without this, the sheet generates the preview of a large photo or video itself, which can
/// make the first presentation feel stuck.
final class ShareItemSource: NSObject, UIActivityItemSource {
    private let url: URL
    private let thumbnail: UIImage?

    init(url: URL, thumbnail: UIImage?) {
        self.url = url
        self.thumbnail = thumbnail
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        url
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = url.lastPathComponent
        metadata.originalURL = url
        metadata.url = url
        if let thumbnail {
            let provider = NSItemProvider(object: thumbnail)
            metadata.imageProvider = provider
            metadata.iconProvider = provider
        }
        return metadata
    }
}
