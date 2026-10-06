import SwiftUI
import Photos

struct ThumbnailView: View {
    let asset: PHAsset
    let size: Double
    var isSelected: Bool = false
    var isSelecting: Bool = false

    @Environment(PhotoLibraryService.self) private var photoService
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            thumbnailImage
            videoDurationBadge
            selectionOverlay
        }
        .frame(width: size, height: size)
        .clipShape(.rect)
        .task(id: asset.localIdentifier) {
            image = await photoService.loadThumbnail(
                for: asset,
                size: CGSize(width: size, height: size)
            )
        }
    }
}

// MARK: - Subviews

private struct ThumbnailImage: View {
    let image: UIImage?
    let size: Double

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipped()
        } else {
            Rectangle()
                .fill(Color(.systemGray5))
                .frame(width: size, height: size)
        }
    }
}

private struct VideoDurationBadge: View {
    let duration: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "play.fill")
                .font(.system(size: 9))
            Text(duration)
                .font(.caption2)
                .fontWeight(.medium)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }
}

private struct SelectionCheckmark: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.accentColor : Color.white.opacity(0.6))
                .frame(width: 24, height: 24)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .padding(4)
    }
}

// MARK: - Computed Subviews

extension ThumbnailView {
    private var thumbnailImage: some View {
        ThumbnailImage(image: image, size: size)
    }

    @ViewBuilder
    private var videoDurationBadge: some View {
        if asset.mediaType == .video {
            VideoDurationBadge(duration: asset.formattedDuration)
        }
    }

    @ViewBuilder
    private var selectionOverlay: some View {
        if isSelecting {
            ZStack(alignment: .topTrailing) {
                if isSelected {
                    Color.accentColor.opacity(0.2)
                }
                SelectionCheckmark(isSelected: isSelected)
            }
            .frame(width: size, height: size)
        }
    }
}

// MARK: - Preview

#Preview {
    ThumbnailView(
        asset: PHAsset(),
        size: 120,
        isSelected: true,
        isSelecting: true
    )
    .environment(PhotoLibraryService())
}
