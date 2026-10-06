import SwiftUI
import Photos

/// Lists every video in the library, biggest first, so the user can free up space quickly.
struct LargeVideosView: View {
    let namespace: Namespace.ID

    @Environment(PhotoLibraryService.self) private var photoService
    @State private var viewModel = LibraryViewModel()
    @State private var openedVideoID: String?

    private var videos: [LargeVideo] { photoService.largeVideos }
    private var largestSize: Int64 { videos.first?.fileSize ?? 1 }
    private var totalSize: Int64 { videos.reduce(0) { $0 + $1.fileSize } }

    private var selectedSize: Int64 {
        videos.reduce(0) { $0 + (viewModel.isSelected($1.id) ? $1.fileSize : 0) }
    }

    var body: some View {
        Group {
            if !photoService.hasLoadedLargeVideos {
                loadingView
            } else if videos.isEmpty {
                ContentUnavailableView {
                    Label("No Videos", systemImage: "video.slash")
                } description: {
                    Text("There are no videos in your library.")
                }
            } else {
                videoList
            }
        }
        .navigationTitle("Large Videos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !videos.isEmpty {
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
                    Text(selectionSummary)
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
        .navigationDestination(item: $openedVideoID) { videoID in
            MediaDetailView(
                allAssets: videos.map(\.asset),
                initialAssetID: videoID,
                namespace: namespace
            )
        }
        // Runs every time the screen appears. Sizes are cached, so repeat visits are fast
        // and only new videos get measured.
        .task {
            await photoService.loadLargeVideos()
        }
    }

    // MARK: - Subviews

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)

            Text("Finding your largest videos…")
                .font(.headline)

            Text("Checking how much space each video uses")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var videoList: some View {
        List {
            Section {
                ForEach(videos) { video in
                    LargeVideoRow(
                        video: video,
                        largestSize: largestSize,
                        isSelecting: viewModel.isSelecting,
                        isSelected: viewModel.isSelected(video.id),
                        namespace: namespace
                    )
                    .onTapGesture {
                        if viewModel.isSelecting {
                            viewModel.toggleSelection(video.id)
                        } else {
                            openedVideoID = video.id
                        }
                    }
                }
            } header: {
                Text("^[\(videos.count) video](inflect: true) · \(Self.format(totalSize))")
                    .textCase(nil)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
        }
        .listStyle(.plain)
    }

    private var selectionSummary: String {
        viewModel.selectedCount == 0
            ? "Select videos"
            : "\(viewModel.selectedCount) selected · \(Self.format(selectedSize))"
    }

    // MARK: - Actions

    private func deleteSelected() {
        let targets = viewModel.selectedIdentifiers
        guard !targets.isEmpty else { return }

        // Capture before the await so nothing is read from the environment mid-delete.
        let service = photoService
        let selection = viewModel

        Task {
            if await service.deleteAssets(targets) {
                service.removeLargeVideos(withIdentifiers: targets)
                selection.clearSelection()
            }
        }
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Row

private struct LargeVideoRow: View {
    let video: LargeVideo
    let largestSize: Int64
    let isSelecting: Bool
    let isSelected: Bool
    let namespace: Namespace.ID

    private var sizeText: String {
        video.fileSize > 0
            ? ByteCountFormatter.string(fromByteCount: video.fileSize, countStyle: .file)
            : "Unknown size"
    }

    private var detailText: String {
        let resolution = "\(video.asset.pixelWidth)×\(video.asset.pixelHeight)"
        guard let date = video.asset.creationDate else { return resolution }
        return "\(resolution) · \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(
                asset: video.asset,
                size: 76,
                isSelected: isSelected,
                isSelecting: isSelecting
            )
            .clipShape(.rect(cornerRadius: 8))
            .matchedTransitionSource(id: video.id, in: namespace)

            VStack(alignment: .leading, spacing: 4) {
                Text(sizeText)
                    .font(.headline)

                Text(detailText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                SizeBar(fraction: Double(video.fileSize) / Double(max(largestSize, 1)))
            }

            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .padding(.vertical, 2)
    }
}

/// Thin bar showing this video's size relative to the largest one.
private struct SizeBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.15))
            .frame(height: 5)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(Color.red.gradient)
                        .frame(width: max(5, geometry.size.width * min(max(fraction, 0), 1)))
                }
            }
    }
}
