import SwiftUI
import Photos

struct MediaDetailView: View {
    let allAssets: [PHAsset]
    let initialAssetID: String
    let namespace: Namespace.ID

    @Environment(PhotoLibraryService.self) private var photoService
    @Environment(\.dismiss) private var dismiss

    @State private var currentAssetID: String?
    @State private var showControls = true
    @State private var showInfo = false
    @State private var shareRequest: ShareRequest?
    @State private var isPreparingShare = false
    @State private var showShareError = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(allAssets) { asset in
                    MediaPageView(
                        asset: asset,
                        isActive: currentAssetID == asset.localIdentifier,
                        showControls: $showControls
                    )
                    .containerRelativeFrame(.horizontal, count: 1, spacing: 0)
                    .id(asset.localIdentifier)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentAssetID)
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
        .background(.black)
        .onAppear {
            currentAssetID = initialAssetID
            photoService.updatePreloadCache(currentAssetID: initialAssetID, allAssets: allAssets, windowSize: 4)
        }
        .onChange(of: currentAssetID) { _, newID in
            if let newID {
                photoService.updatePreloadCache(currentAssetID: newID, allAssets: allAssets, windowSize: 4)
            }
        }
        .onDisappear {
            photoService.stopAllPreloadCaching()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(showControls ? .visible : .hidden, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isPreparingShare {
                    ProgressView()
                } else {
                    Button("Share", systemImage: "square.and.arrow.up", action: shareCurrentAsset)
                }

                Button("Info", systemImage: "info.circle") {
                    showInfo = true
                }

                Button("Delete", systemImage: "trash", role: .destructive) {
                    showDeleteConfirmation = true
                }
                .tint(.red)
            }
        }
        // The viewer is full screen and has no bottom bar any more, so keep the tab bar out of the way.
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $showInfo) {
            if let asset = currentAsset {
                MediaInfoView(asset: asset)
            }
        }
        .sheet(item: $shareRequest) { request in
            ShareSheet(items: request.items, onComplete: { photoService.cleanUpShareFiles() })
        }
        .alert("Couldn't Prepare for Sharing", isPresented: $showShareError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This item couldn't be exported. If it's stored in iCloud, check your connection and try again.")
        }
        .confirmationDialog(
            "Delete Item",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteCurrentAsset()
            }
        } message: {
            Text("This item will be moved to Recently Deleted.")
        }
        .navigationTransition(.zoom(sourceID: currentAssetID ?? initialAssetID, in: namespace))
        .statusBarHidden(!showControls)
    }

    /// Falls back to the opened item, so Share and Info work even before the pager reports a position.
    private var currentAsset: PHAsset? {
        let id = currentAssetID ?? initialAssetID
        return allAssets.first { $0.localIdentifier == id }
    }

    private func shareCurrentAsset() {
        guard let asset = currentAsset, !isPreparingShare else { return }
        isPreparingShare = true

        Task {
            let loaded = await photoService.loadShareItems(for: [asset.localIdentifier])
            isPreparingShare = false
            if loaded.isEmpty {
                showShareError = true
            } else {
                shareRequest = ShareRequest(items: loaded)
            }
        }
    }

    private func deleteCurrentAsset() {
        guard let targetID = currentAssetID else { return }
        let service = photoService // capture before the view can be dismissed
        let dismissAction = dismiss
        Task {
            if await service.deleteAssets([targetID]) {
                dismissAction()
            }
        }
    }
}

// MARK: - Media Page View

private struct MediaPageView: View {
    let asset: PHAsset
    let isActive: Bool
    @Binding var showControls: Bool

    var body: some View {
        if asset.mediaType == .video {
            VideoPlayerView(asset: asset, isActive: isActive, showControls: $showControls)
        } else {
            ZoomableImageView(asset: asset, onSingleTap: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showControls.toggle()
                }
            })
        }
    }
}
