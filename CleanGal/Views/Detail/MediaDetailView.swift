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
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
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
            ToolbarItemGroup(placement: .bottomBar) {
                if showControls {
                    Button("Share", systemImage: "square.and.arrow.up", action: shareCurrentAsset)
                    Spacer()
                    Button("Info", systemImage: "info.circle") {
                        showInfo = true
                    }
                    Spacer()
                    // TODO: Re-enable once deletion is stable
                    // Button("Delete", systemImage: "trash", role: .destructive) {
                    //     showDeleteConfirmation = true
                    // }
                    // .tint(.red)
                }
            }
        }
        .toolbarVisibility(showControls ? .visible : .hidden, for: .bottomBar)
        .sheet(isPresented: $showInfo) {
            if let asset = currentAsset {
                MediaInfoView(asset: asset)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        // TODO: Re-enable once deletion is stable
        // .confirmationDialog(
        //     "Delete Photo",
        //     isPresented: $showDeleteConfirmation,
        //     titleVisibility: .visible
        // ) {
        //     Button("Delete", role: .destructive) {
        //         deleteCurrentAsset()
        //     }
        // } message: {
        //     Text("This item will be moved to Recently Deleted.")
        // }
        .navigationTransition(.zoom(sourceID: currentAssetID ?? initialAssetID, in: namespace))
        .statusBarHidden(!showControls)
    }

    private var currentAsset: PHAsset? {
        allAssets.first { $0.localIdentifier == currentAssetID }
    }

    private func shareCurrentAsset() {
        guard let asset = currentAsset else { return }
        Task {
            let loaded = await photoService.loadShareItems(for: [asset.localIdentifier])
            if !loaded.isEmpty {
                shareItems = loaded
                showShareSheet = true
            }
        }
    }

    private func deleteCurrentAsset() {
        guard let asset = currentAsset else { return }
        let targetID = asset.localIdentifier
        dismiss()
        Task {
            try? await photoService.deleteAssets([targetID])
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
