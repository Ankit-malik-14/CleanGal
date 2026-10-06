import SwiftUI
import Photos

struct AlbumsView: View {
    @Environment(PhotoLibraryService.self) private var photoService
    @Namespace private var transitionNamespace

    private let horizontalPadding: CGFloat = 16
    private let gridSpacing: CGFloat = 16

    private var twoColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: gridSpacing, alignment: .top),
            GridItem(.flexible(), spacing: gridSpacing, alignment: .top)
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    utilitiesSection

                    if !photoService.systemAlbums.isEmpty {
                        albumSection(title: "Media Types", albums: photoService.systemAlbums)
                    }

                    if !photoService.userAlbums.isEmpty {
                        albumSection(title: "My Albums", albums: photoService.userAlbums)
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Albums")
            .task {
                await photoService.loadAlbums()
            }
        }
    }

    // MARK: - Utilities

    private var utilitiesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Utilities")

            LazyVGrid(columns: twoColumns, spacing: gridSpacing) {
                NavigationLink {
                    DuplicatesView(
                        title: "Duplicate Images",
                        mediaType: .image,
                        namespace: transitionNamespace
                    )
                } label: {
                    UtilityTile(
                        title: "Duplicate Images",
                        subtitle: subtitle(
                            hasScanned: photoService.hasScannedPhotoDuplicates,
                            count: photoService.duplicatePhotoGroups.reduce(0) { $0 + $1.count }
                        ),
                        iconName: "doc.on.doc",
                        tint: .blue
                    )
                }

                NavigationLink {
                    DuplicatesView(
                        title: "Duplicate Videos",
                        mediaType: .video,
                        namespace: transitionNamespace
                    )
                } label: {
                    UtilityTile(
                        title: "Duplicate Videos",
                        subtitle: subtitle(
                            hasScanned: photoService.hasScannedVideoDuplicates,
                            count: photoService.duplicateVideoGroups.reduce(0) { $0 + $1.count }
                        ),
                        iconName: "video.badge.plus",
                        tint: .purple
                    )
                }

                NavigationLink {
                    SimilarPhotosView(namespace: transitionNamespace)
                } label: {
                    UtilityTile(
                        title: "Similar Photos",
                        subtitle: subtitle(
                            hasScanned: photoService.hasScannedSimilarPhotos,
                            count: photoService.similarPhotoGroups.reduce(0) { $0 + $1.count }
                        ),
                        iconName: "square.stack.3d.down.right",
                        tint: .orange
                    )
                }

                NavigationLink {
                    LargeVideosView(namespace: transitionNamespace)
                } label: {
                    UtilityTile(
                        title: "Large Videos",
                        subtitle: largeVideosSubtitle,
                        iconName: "film.stack",
                        tint: .red
                    )
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Album Grid

    private func albumSection(title: String, albums: [LibraryAlbum]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)

            LazyVGrid(columns: twoColumns, spacing: 20) {
                ForEach(albums) { album in
                    NavigationLink {
                        AlbumDetailView(album: album, namespace: transitionNamespace)
                    } label: {
                        AlbumCard(album: album)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Subtitles

    private func subtitle(hasScanned: Bool, count: Int) -> String {
        guard hasScanned else { return "Tap to scan" }
        return count == 1 ? "1 item" : "\(count) items"
    }

    /// Describes the tile before it has loaded, then shows count and total size.
    private var largeVideosSubtitle: String {
        guard photoService.hasLoadedLargeVideos else { return "Biggest first" }
        let total = photoService.largeVideos.reduce(Int64(0)) { $0 + $1.fileSize }
        let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        let count = photoService.largeVideos.count
        return "\(count) \(count == 1 ? "video" : "videos") · \(size)"
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title2)
            .fontWeight(.bold)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Album Card

/// Large square cover with the title and item count underneath, like the Photos app.
/// Sizes itself to the column width, so no manual measuring is needed.
private struct AlbumCard: View {
    let album: LibraryAlbum

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cover
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.black.opacity(0.06), lineWidth: 0.5)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(album.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(album.count.formatted())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(album.title)
        .accessibilityValue("^[\(album.count) item](inflect: true)")
    }

    @ViewBuilder
    private var cover: some View {
        if let coverAsset = album.coverAsset {
            AlbumCover(asset: coverAsset)
        } else {
            Color(album.kind.tint.opacity(0.12))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: album.kind.symbolName)
                        .font(.system(size: 40))
                        .foregroundStyle(album.kind.tint)
                }
        }
    }
}

/// Square cover that fills whatever width its column gives it.
private struct AlbumCover: View {
    let asset: PHAsset

    @Environment(PhotoLibraryService.self) private var photoService
    @State private var image: UIImage?

    var body: some View {
        Color(.systemGray5)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .task(id: asset.localIdentifier) {
                image = await photoService.loadThumbnail(
                    for: asset,
                    size: CGSize(width: 220, height: 220)
                )
            }
    }
}

// MARK: - Utility Tile

/// Rounded tile with a tinted icon, used for the media cleaners.
private struct UtilityTile: View {
    let title: String
    let subtitle: String
    let iconName: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: iconName)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(tint.gradient, in: .rect(cornerRadius: 11, style: .continuous))

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 16)

            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))
        .contentShape(.rect(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Duplicates View

struct DuplicatesView: View {
    let title: String
    let mediaType: PHAssetMediaType
    let namespace: Namespace.ID

    @Environment(PhotoLibraryService.self) private var photoService
    @State private var viewModel = LibraryViewModel()

    private var isScanning: Bool {
        mediaType == .image
            ? photoService.isScanningPhotoDuplicates
            : photoService.isScanningVideoDuplicates
    }

    private var hasScanned: Bool {
        mediaType == .image
            ? photoService.hasScannedPhotoDuplicates
            : photoService.hasScannedVideoDuplicates
    }

    private var groups: [DuplicateGroup] {
        mediaType == .image
            ? photoService.duplicatePhotoGroups
            : photoService.duplicateVideoGroups
    }

    var body: some View {
        Group {
            if isScanning {
                ScanningLoadingView(
                    headline: "Scanning for duplicates…",
                    subheadline: "Comparing \(mediaType == .image ? "photos" : "videos") in your library"
                )
            } else if hasScanned && groups.isEmpty {
                ContentUnavailableView {
                    Label(
                        "No Duplicates Found",
                        systemImage: mediaType == .video ? "video.slash" : "photo.on.rectangle.angled"
                    )
                } description: {
                    Text("No duplicate \(mediaType == .video ? "videos" : "photos") were found in your library.")
                }
            } else if hasScanned {
                resultsView
            } else {
                ScanningLoadingView(
                    headline: "Scanning for duplicates…",
                    subheadline: "Comparing \(mediaType == .image ? "photos" : "videos") in your library"
                )
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !hasScanned, !isScanning else { return }
            await photoService.scanForDuplicates(mediaType: mediaType)
        }
    }

    private var resultsView: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                ForEach(groups) { group in
                    AssetGroupSection(
                        group: group,
                        viewModel: viewModel,
                        namespace: namespace
                    )
                }
            }
            .padding(.vertical, 16)
        }
    }
}

// MARK: - Similar Photos View

struct SimilarPhotosView: View {
    let namespace: Namespace.ID

    @Environment(PhotoLibraryService.self) private var photoService
    @State private var viewModel = LibraryViewModel()

    var body: some View {
        Group {
            if photoService.isScanningSimilarPhotos {
                ScanningLoadingView(
                    headline: "Finding similar photos…",
                    subheadline: "Analyzing your photos with Vision AI"
                )
            } else if photoService.hasScannedSimilarPhotos && photoService.similarPhotoGroups.isEmpty {
                ContentUnavailableView {
                    Label("No Similar Photos", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("No groups of similar photos were found in your library.")
                }
            } else if photoService.hasScannedSimilarPhotos {
                resultsView
            } else {
                ScanningLoadingView(
                    headline: "Finding similar photos…",
                    subheadline: "Analyzing your photos with Vision AI"
                )
            }
        }
        .navigationTitle("Similar Photos")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !photoService.hasScannedSimilarPhotos,
                  !photoService.isScanningSimilarPhotos
            else { return }
            await photoService.scanForSimilarPhotos()
        }
    }

    private var resultsView: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                ForEach(photoService.similarPhotoGroups) { group in
                    AssetGroupSection(
                        group: group,
                        viewModel: viewModel,
                        namespace: namespace
                    )
                }
            }
            .padding(.vertical, 16)
        }
    }
}

// MARK: - Shared: Scanning Loading View

private struct ScanningLoadingView: View {
    let headline: String
    let subheadline: String

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)

            Text(headline)
                .font(.headline)
                .foregroundStyle(.primary)

            Text(subheadline)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shared: Asset Group Section

private struct AssetGroupSection: View {
    let group: DuplicateGroup
    let viewModel: LibraryViewModel
    let namespace: Namespace.ID

    @Environment(PhotoLibraryService.self) private var photoService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("^[\(group.count) item](inflect: true)")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 16)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                ForEach(group.assets) { asset in
                    ThumbnailView(
                        asset: asset,
                        size: (UIScreen.main.bounds.width - 36) / 3,
                        isSelected: viewModel.isSelected(asset.localIdentifier),
                        isSelecting: viewModel.isSelecting
                    )
                    .clipShape(.rect(cornerRadius: 8))
                    .onTapGesture {
                        if viewModel.isSelecting {
                            viewModel.toggleSelection(asset.localIdentifier)
                        } else {
                            viewModel.navigationPath.append(asset.localIdentifier)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

#Preview {
    AlbumsView()
        .environment(PhotoLibraryService())
}
