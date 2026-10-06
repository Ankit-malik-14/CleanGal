import SwiftUI
import Photos

struct AlbumsView: View {
    @Environment(PhotoLibraryService.self) private var photoService
    @Namespace private var transitionNamespace

    var body: some View {
        NavigationStack {
            List {
                Section("Media Cleaners") {
                    NavigationLink {
                        DuplicatesView(
                            title: "Duplicate Images",
                            mediaType: .image,
                            namespace: transitionNamespace
                        )
                    } label: {
                        AlbumRow(
                            title: "Duplicate Images",
                            iconName: "doc.on.doc",
                            iconColor: .blue,
                            count: photoService.duplicatePhotoGroups.reduce(0) { $0 + $1.count }
                        )
                    }

                    NavigationLink {
                        DuplicatesView(
                            title: "Duplicate Videos",
                            mediaType: .video,
                            namespace: transitionNamespace
                        )
                    } label: {
                        AlbumRow(
                            title: "Duplicate Videos",
                            iconName: "video.badge.plus",
                            iconColor: .purple,
                            count: photoService.duplicateVideoGroups.reduce(0) { $0 + $1.count }
                        )
                    }

                    NavigationLink {
                        SimilarPhotosView(namespace: transitionNamespace)
                    } label: {
                        AlbumRow(
                            title: "Similar Photos",
                            iconName: "square.stack.3d.down.right",
                            iconColor: .orange,
                            count: photoService.similarPhotoGroups.reduce(0) { $0 + $1.count }
                        )
                    }

                    NavigationLink {
                        LargeVideosView(namespace: transitionNamespace)
                    } label: {
                        AlbumRow(
                            title: "Large Videos",
                            iconName: "film.stack",
                            iconColor: .red,
                            count: photoService.largeVideos.count,
                            subtitle: largeVideosSubtitle
                        )
                    }
                }

                // Section("Utilities") {
                //     NavigationLink {
                //         RecentlyDeletedView(namespace: transitionNamespace)
                //     } label: {
                //         AlbumRow(
                //             title: "Recently Deleted",
                //             iconName: "trash",
                //             iconColor: .red,
                //             count: photoService.recentlyDeletedAssets.count
                //         )
                //     }
                // }
            }
            .navigationTitle("Albums")
        }
    }

    /// Describes the row before it has loaded, then shows count and total size.
    private var largeVideosSubtitle: String {
        guard photoService.hasLoadedLargeVideos else { return "Biggest videos first" }
        let total = photoService.largeVideos.reduce(Int64(0)) { $0 + $1.fileSize }
        let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return "\(photoService.largeVideos.count) videos · \(size)"
    }
}

// MARK: - Reusable Album Row

private struct AlbumRow: View {
    let title: String
    let iconName: String
    let iconColor: Color
    let count: Int
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 32, height: 32)
                .background(iconColor.opacity(0.12))
                .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                Group {
                    if let subtitle {
                        Text(subtitle)
                    } else {
                        Text("^[\(count) item](inflect: true)")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
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
