import SwiftUI
import Photos

struct LibraryView: View {
    @Environment(PhotoLibraryService.self) private var photoService
    @State private var viewModel = LibraryViewModel()
    @Namespace private var transitionNamespace

    var body: some View {
        NavigationStack(path: $viewModel.navigationPath) {
            Group {
                switch photoService.authorizationStatus {
                case .authorized, .limited:
                    galleryContent
                case .denied, .restricted:
                    PermissionDeniedView()
                default:
                    PermissionRequestView()
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: String.self) { identifier in
                MediaDetailView(
                    allAssets: photoService.allAssetsFlat,
                    initialAssetID: identifier,
                    namespace: transitionNamespace
                )
            }
        }
        .task {
            if photoService.authorizationStatus == .notDetermined {
                await photoService.requestAuthorization()
            }
        }
    }
}

// MARK: - Gallery Content

private struct GalleryGrid: View {
    let sections: [PhotoLibraryService.DateSection]
    let viewModel: LibraryViewModel
    let namespace: Namespace.ID

    @Environment(PhotoLibraryService.self) private var photoService

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: viewModel.gridColumns, spacing: 1.5) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.assets) { asset in
                                gridCell(for: asset)
                            }
                        } header: {
                            DateSectionHeader(title: section.title)
                        }
                    }
                }
                .padding(.horizontal, 1.5)
            }
            .task(id: sections.count) {
                if !sections.isEmpty {
                    scrollToBottom(proxy: proxy, sections: sections)
                }
            }
        }
    }

    @ViewBuilder
    private func gridCell(for asset: PHAsset) -> some View {
        let cellSize = cellWidth(columnCount: viewModel.gridColumns.count)
        ThumbnailView(
            asset: asset,
            size: cellSize,
            isSelected: viewModel.isSelected(asset.localIdentifier),
            isSelecting: viewModel.isSelecting
        )
        .matchedTransitionSource(id: asset.localIdentifier, in: namespace)
        .onTapGesture {
            handleTap(asset: asset)
        }
        .accessibilityLabel(asset.mediaType == .video ? "Video" : "Photo")
    }

    private func handleTap(asset: PHAsset) {
        if viewModel.isSelecting {
            viewModel.toggleSelection(asset.localIdentifier)
        } else {
            viewModel.navigationPath.append(asset.localIdentifier)
        }
    }

    private func cellWidth(columnCount: Int) -> Double {
        let screenWidth = UIScreen.main.bounds.width
        let totalSpacing = 1.5 * Double(columnCount - 1) + 3.0
        return (screenWidth - totalSpacing) / Double(columnCount)
    }

    private func scrollToBottom(proxy: ScrollViewProxy, sections: [PhotoLibraryService.DateSection]) {
        if let lastAsset = sections.last?.assets.last {
            proxy.scrollTo(lastAsset.localIdentifier, anchor: .bottom)
        }
    }
}

// MARK: - Date Section Header

private struct DateSectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
}

// MARK: - Permission Views

private struct PermissionRequestView: View {
    @Environment(PhotoLibraryService.self) private var photoService

    var body: some View {
        ContentUnavailableView {
            Label("Photo Access", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("CleanGal needs access to your photo library to help you manage your photos and videos.")
        } actions: {
            Button("Allow Access") {
                Task {
                    await photoService.requestAuthorization()
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private struct PermissionDeniedView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Access Denied", systemImage: "lock.fill")
        } description: {
            Text("Photo library access was denied. Please enable it in Settings to use CleanGal.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Selection Toolbar

private struct SelectionToolbarContent: View {
    let viewModel: LibraryViewModel
    let sections: [PhotoLibraryService.DateSection]

    @Environment(PhotoLibraryService.self) private var photoService
    @State private var shareRequest: ShareRequest?
    @State private var isPreparingShare = false
    @State private var showShareError = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack {
            if isPreparingShare {
                ProgressView()
            } else {
                Button("Share", systemImage: "square.and.arrow.up", action: shareSelected)
                    .disabled(viewModel.selectedCount == 0)
            }

            Spacer()

            Text("\(viewModel.selectedCount) Selected")
                .font(.subheadline)
                .fontWeight(.medium)

            Spacer()

            Button("Delete", systemImage: "trash", role: .destructive) {
                showDeleteConfirmation = true
            }
            .tint(.red)
            .disabled(viewModel.selectedCount == 0)
        }
        .sheet(item: $shareRequest) { request in
            ShareSheet(items: request.items, onComplete: { photoService.cleanUpShareFiles() })
        }
        .alert("Couldn't Prepare for Sharing", isPresented: $showShareError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("These items couldn't be exported. If they're stored in iCloud, check your connection and try again.")
        }
        .confirmationDialog(
            "Delete \(viewModel.selectedCount) items?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let targets = viewModel.selectedIdentifiers
                let service = photoService // capture before anything can tear this view down
                let selection = viewModel
                Task {
                    if await service.deleteAssets(targets) {
                        selection.clearSelection()
                    }
                }
            }
        } message: {
            Text("These items will be moved to Recently Deleted.")
        }
    }

    private func shareSelected() {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        let identifiers = viewModel.selectedIdentifiers

        Task {
            let loaded = await photoService.loadShareItems(for: identifiers)
            isPreparingShare = false
            if loaded.isEmpty {
                showShareError = true
            } else {
                shareRequest = ShareRequest(items: loaded)
            }
        }
    }
}

// MARK: - Gallery Content Extension

extension LibraryView {
    @ViewBuilder
    fileprivate var galleryContent: some View {
        GalleryGrid(
            sections: photoService.dateSections,
            viewModel: viewModel,
            namespace: transitionNamespace
        )
        .gesture(
            MagnifyGesture()
                .onEnded { value in
                    viewModel.handlePinchZoom(value.magnification)
                }
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(viewModel.isSelecting ? "Cancel" : "Select") {
                    if viewModel.isSelecting {
                        viewModel.clearSelection()
                    } else {
                        viewModel.startSelecting()
                    }
                }
            }

            if viewModel.isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Select All") {
                        viewModel.selectAll(from: photoService.dateSections)
                    }
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    SelectionToolbarContent(
                        viewModel: viewModel,
                        sections: photoService.dateSections
                    )
                }
            }
        }
        .toolbar(viewModel.isSelecting ? .hidden : .visible, for: .tabBar)
    }
}

// MARK: - Preview

#Preview {
    LibraryView()
        .environment(PhotoLibraryService())
}
