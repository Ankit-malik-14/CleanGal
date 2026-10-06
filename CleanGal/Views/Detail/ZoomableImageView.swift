import SwiftUI
import Photos

struct ZoomableImageView: View {
    let asset: PHAsset
    var onSingleTap: (() -> Void)?

    @Environment(PhotoLibraryService.self) private var photoService
    @State private var displayImage: UIImage?

    var body: some View {
        ZStack {
            Color.black

            if let displayImage {
                ZoomableImage(image: displayImage, onSingleTap: onSingleTap)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .onAppear {
            if displayImage == nil {
                displayImage = photoService.cachedThumbnail(for: asset.localIdentifier)
            }
        }
        .task(id: asset.localIdentifier) {
            // Stage 1: Display crisp cached thumbnail during zoom transition
            if displayImage == nil, let thumb = await photoService.loadThumbnail(for: asset, size: CGSize(width: 400, height: 400)) {
                displayImage = thumb
            }
            // Stage 2: Instant swap to full resolution asset as soon as loaded
            if let fullImage = await photoService.loadFullImage(for: asset) {
                displayImage = fullImage
            }
        }
    }
}

// MARK: - UIKit Zoomable Image

private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    var onSingleTap: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onSingleTap: onSingleTap)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 5.0
        scrollView.minimumZoomScale = 1.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap)
        )
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard let imageView = context.coordinator.imageView else { return }
        if imageView.image != image {
            imageView.image = image
            imageView.frame = scrollView.bounds
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        var onSingleTap: (() -> Void)?

        init(onSingleTap: (() -> Void)?) {
            self.onSingleTap = onSingleTap
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let imageView else { return }
            let offsetX = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
            let offsetY = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0)
            imageView.center = CGPoint(
                x: scrollView.contentSize.width / 2 + offsetX,
                y: scrollView.contentSize.height / 2 + offsetY
            )
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let location = gesture.location(in: scrollView.subviews.first)
                let zoomRect = CGRect(
                    x: location.x - 50,
                    y: location.y - 50,
                    width: 100,
                    height: 100
                )
                scrollView.zoom(to: zoomRect, animated: true)
            }
        }

        @objc func handleSingleTap() {
            onSingleTap?()
        }
    }
}
