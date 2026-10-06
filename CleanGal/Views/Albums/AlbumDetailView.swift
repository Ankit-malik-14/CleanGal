import SwiftUI
import Photos

// MARK: - Album Kind Styling

extension LibraryAlbum.Kind {
    var symbolName: String {
        switch self {
        case .screenshots: "camera.viewfinder"
        case .videos: "video.fill"
        case .selfies: "person.crop.circle"
        case .livePhotos: "livephoto"
        case .portraits: "person.crop.rectangle"
        case .panoramas: "pano"
        case .slowMotion: "slowmo"
        case .timeLapse: "timelapse"
        case .favorites: "heart.fill"
        case .userAlbum: "rectangle.stack"
        }
    }

    var tint: Color {
        switch self {
        case .screenshots: .blue
        case .videos: .purple
        case .selfies: .pink
        case .livePhotos: .teal
        case .portraits: .indigo
        case .panoramas: .green
        case .slowMotion: .cyan
        case .timeLapse: .mint
        case .favorites: .red
        case .userAlbum: .gray
        }
    }
}

// MARK: - Album Detail

/// Shows every item in one album, newest first, with select and delete.
struct AlbumDetailView: View {
    let album: LibraryAlbum
    let namespace: Namespace.ID

    @Environment(PhotoLibraryService.self) private var photoService
    @State private var viewModel = LibraryViewModel()
    @State private var assets: [PHAsset] = []
    @State private var hasLoaded = false
    @State private var openedAssetID: String?

    private var cellSize: Double {
        let columns = Double(viewModel.columnCount)
        return (UIScreen.main.bounds.width - 1.5 * (columns - 1) - 3.0) / columns
    }

    var body: some View {
        Group {
            if !hasLoaded {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if assets.isEmpty {
                ContentUnavailableView {
                    Label(album.title, systemImage: album.kind.symbolName)
                } description: {
                    Text("Nothing in this album.")
                }
            } else {
                grid
            }
        }
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !assets.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(viewModel.isSelecting ? "Cancel" : "Select") {
                        if viewModel.isSelecting {
                            viewModel.clearSelection()
                        } else {
                            viewModel.startSelecting()
                        }
                    }
                }
            }

            if viewModel.isSelecting {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Select All") {
                        viewModel.selectedIdentifiers = Set(assets.map(\.localIdentifier))
                    }

                    Spacer()

                    Text(viewModel.selectedCount == 0 ? "Select items" : "\(viewModel.selectedCount) selected")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Spacer()

                    Button("Delete", systemImage: "trash", role: .destructive, action: deleteSelected)
                        .tint(.red)
                        .disabled(viewModel.selectedCount == 0)
                }
            }
        }
        .toolbar(viewModel.isSelecting ? .hidden : .visible, for: .tabBar)
        .navigationDestination(item: $openedAssetID) { assetID in
            MediaDetailView(
                allAssets: assets,
                initialAssetID: assetID,
                namespace: namespace
            )
        }
        // Re-runs when the library changes (items added or deleted).
        .task(id: photoService.totalAssetCount) {
            assets = await photoService.assets(in: album)
            hasLoaded = true
        }
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: viewModel.gridColumns, spacing: 1.5) {
                ForEach(assets) { asset in
                    ThumbnailView(
                        asset: asset,
                        size: cellSize,
                        isSelected: viewModel.isSelected(asset.localIdentifier),
                        isSelecting: viewModel.isSelecting
                    )
                    .matchedTransitionSource(id: asset.localIdentifier, in: namespace)
                    .onTapGesture {
                        if viewModel.isSelecting {
                            viewModel.toggleSelection(asset.localIdentifier)
                        } else {
                            openedAssetID = asset.localIdentifier
                        }
                    }
                }
            }
            .padding(.horizontal, 1.5)
        }
    }

    // MARK: - Actions

    private func deleteSelected() {
        let targets = viewModel.selectedIdentifiers
        guard !targets.isEmpty else { return }

        // Capture before the await so nothing is read from the environment mid-delete.
        let service = photoService
        let selection = viewModel

        Task {
            if (try? await service.deleteAssets(targets)) == true {
                assets.removeAll { targets.contains($0.localIdentifier) }
                selection.clearSelection()
            }
        }
    }
}
