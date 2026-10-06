import SwiftUI
import Photos

// MARK: - Review Kind

enum DuplicateReviewKind {
    case duplicates
    case similar

    var hint: String {
        "Tap the circle on any item to choose what to keep. Each group always keeps at least one item."
    }
}

// MARK: - Duplicate Review

/// Shows groups of duplicate or similar items with their size and date, lets the user pick
/// which ones to keep, and deletes the rest. Used by Duplicate Images, Duplicate Videos
/// and Similar Photos.
struct DuplicateReviewView: View {
    let groups: [DuplicateGroup]
    let kind: DuplicateReviewKind
    let namespace: Namespace.ID

    @Environment(PhotoLibraryService.self) private var photoService

    /// Identifiers currently marked for deletion. Everything else is kept.
    @State private var toDelete: Set<String> = []
    @State private var sizes: [String: Int64] = [:]
    @State private var hasAutoSelected = false
    @State private var showDeleteConfirmation = false
    @State private var openedAssetID: String?
    @State private var blockedAttempts = 0

    private var assetIDs: [String] {
        groups.flatMap(\.assets).map(\.localIdentifier)
    }

    private var markedSize: Int64 {
        toDelete.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
    }

    private var summary: String {
        guard !toDelete.isEmpty else { return "Nothing selected" }
        let size = ByteCountFormatter.string(fromByteCount: markedSize, countStyle: .file)
        return "\(toDelete.count) selected · \(size)"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                Text(kind.hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                ForEach(groups) { group in
                    ReviewGroupCard(
                        group: group,
                        kind: kind,
                        sizes: sizes,
                        markedIDs: toDelete,
                        namespace: namespace,
                        onOpen: { openedAssetID = $0 },
                        onToggle: { toggle($0, in: group) }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Keep Best in Each Group", systemImage: "wand.and.stars", action: autoSelect)
                    Button("Deselect All", systemImage: "xmark.circle") {
                        toDelete.removeAll()
                    }
                    .disabled(toDelete.isEmpty)
                } label: {
                    Label("Options", systemImage: "ellipsis.circle")
                }
            }

            ToolbarItemGroup(placement: .bottomBar) {
                Text(summary)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                Button("Delete", systemImage: "trash", role: .destructive) {
                    showDeleteConfirmation = true
                }
                .tint(.red)
                .disabled(toDelete.isEmpty)
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(item: $openedAssetID) { assetID in
            MediaDetailView(
                allAssets: assets(inGroupContaining: assetID),
                initialAssetID: assetID,
                namespace: namespace
            )
        }
        .confirmationDialog(
            toDelete.count == 1 ? "Delete 1 item?" : "Delete \(toDelete.count) items?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: deleteMarked)
        } message: {
            Text("These items will be moved to Recently Deleted.")
        }
        .sensoryFeedback(.warning, trigger: blockedAttempts)
        // Measure sizes off the main thread, then pre-select the extras once they are known.
        .task(id: assetIDs) {
            await loadSizes()
        }
        .onChange(of: assetIDs) { _, newIDs in
            toDelete.formIntersection(Set(newIDs))
        }
    }

    // MARK: - Selection

    private func toggle(_ asset: PHAsset, in group: DuplicateGroup) {
        let id = asset.localIdentifier

        if toDelete.contains(id) {
            toDelete.remove(id)
            return
        }

        // Never let the user mark every item in a group.
        let wouldKeep = group.assets.filter {
            $0.localIdentifier != id && !toDelete.contains($0.localIdentifier)
        }
        guard !wouldKeep.isEmpty else {
            blockedAttempts += 1
            return
        }
        toDelete.insert(id)
    }

    /// Keeps one "best" item per group and marks the rest.
    private func autoSelect() {
        var marked: Set<String> = []
        for group in groups {
            guard let keeper = group.assets.max(by: { isWorse($0, than: $1) }) else { continue }
            for asset in group.assets where asset.localIdentifier != keeper.localIdentifier {
                marked.insert(asset.localIdentifier)
            }
        }
        toDelete = marked
    }

    /// Favorites win, then the larger file, then the earlier (original) one.
    private func isWorse(_ a: PHAsset, than b: PHAsset) -> Bool {
        if a.isFavorite != b.isFavorite { return !a.isFavorite }

        let sizeA = sizes[a.localIdentifier] ?? 0
        let sizeB = sizes[b.localIdentifier] ?? 0
        if sizeA != sizeB { return sizeA < sizeB }

        return (a.creationDate ?? .distantFuture) > (b.creationDate ?? .distantFuture)
    }

    // MARK: - Data

    private func loadSizes() async {
        let missing = groups.flatMap(\.assets).filter { sizes[$0.localIdentifier] == nil }

        if !missing.isEmpty {
            let measured = await Task.detached(priority: .userInitiated) {
                var result: [String: Int64] = [:]
                for asset in missing {
                    result[asset.localIdentifier] = AssetStorage.bytes(for: asset)
                }
                return result
            }.value
            sizes.merge(measured) { _, new in new }
        }

        if !hasAutoSelected, !groups.isEmpty {
            autoSelect()
            hasAutoSelected = true
        }
    }

    private func assets(inGroupContaining assetID: String) -> [PHAsset] {
        groups.first { group in
            group.assets.contains { $0.localIdentifier == assetID }
        }?.assets ?? []
    }

    // MARK: - Actions

    private func deleteMarked() {
        let targets = toDelete
        guard !targets.isEmpty else { return }

        // Capture before the await so nothing is read from the environment mid-delete.
        let service = photoService

        Task {
            if await service.deleteAssets(targets) {
                service.removeFromScanResults(targets)
                toDelete.subtract(targets)
            }
        }
    }
}

// MARK: - Group Card

private struct ReviewGroupCard: View {
    let group: DuplicateGroup
    let kind: DuplicateReviewKind
    let sizes: [String: Int64]
    let markedIDs: Set<String>
    let namespace: Namespace.ID
    let onOpen: (String) -> Void
    let onToggle: (PHAsset) -> Void

    private var title: String {
        switch kind {
        case .duplicates: "\(group.count) Duplicates"
        case .similar: "\(group.count) Similar Photos"
        }
    }

    private var totalSizeText: String? {
        let known = group.assets.compactMap { sizes[$0.localIdentifier] }
        guard known.count == group.count else { return nil }
        return ByteCountFormatter.string(fromByteCount: known.reduce(Int64(0), +), countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)

                Spacer()

                if let totalSizeText {
                    Text(totalSizeText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(group.assets) { asset in
                        ReviewItemCell(
                            asset: asset,
                            sizeText: sizeText(for: asset),
                            isMarked: markedIDs.contains(asset.localIdentifier),
                            namespace: namespace,
                            onOpen: { onOpen(asset.localIdentifier) },
                            onToggle: { onToggle(asset) }
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, 16, for: .scrollContent)
        }
        .padding(.vertical, 16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))
    }

    private func sizeText(for asset: PHAsset) -> String {
        guard let bytes = sizes[asset.localIdentifier], bytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Item Cell

private struct ReviewItemCell: View {
    let asset: PHAsset
    let sizeText: String
    let isMarked: Bool
    let namespace: Namespace.ID
    let onOpen: () -> Void
    let onToggle: () -> Void

    private let side: Double = 148

    private var dateText: String {
        asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown date"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThumbnailView(asset: asset, size: side)
                .clipShape(.rect(cornerRadius: 12, style: .continuous))
                .onTapGesture(perform: onOpen)
                .overlay {
                    if isMarked {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.red.opacity(0.22))
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if !isMarked {
                        keepBadge
                    }
                }
                .overlay(alignment: .topTrailing) {
                    toggleButton
                }
                .matchedTransitionSource(id: asset.localIdentifier, in: namespace)

            VStack(alignment: .leading, spacing: 2) {
                Text(sizeText)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text(dateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text("\(asset.pixelWidth) × \(asset.pixelHeight)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: side, alignment: .leading)
        }
    }

    private var keepBadge: some View {
        Label("Keep", systemImage: "checkmark")
            .font(.caption2)
            .fontWeight(.bold)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.green.gradient, in: .capsule)
            .padding(8)
            .allowsHitTesting(false)
    }

    private var toggleButton: some View {
        Button(action: onToggle) {
            ZStack {
                Circle()
                    .fill(isMarked ? Color.red : Color.black.opacity(0.35))
                    .frame(width: 26, height: 26)
                    .overlay {
                        Circle().strokeBorder(.white, lineWidth: 1.5)
                    }

                if isMarked {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMarked ? "Marked for deletion" : "Keeping")
        .accessibilityHint(isMarked ? "Double tap to keep this item" : "Double tap to mark for deletion")
    }
}

// MARK: - Storage Size

/// Total bytes an asset takes on disk. An edited item has both the original and the
/// rendered edit, and a Live Photo has its paired video, so every part counts.
nonisolated enum AssetStorage {
    private static let counted: Set<PHAssetResourceType> = [
        .photo, .fullSizePhoto, .video, .fullSizeVideo, .pairedVideo, .fullSizePairedVideo
    ]

    static func bytes(for asset: PHAsset) -> Int64 {
        PHAssetResource.assetResources(for: asset)
            .filter { counted.contains($0.type) }
            .reduce(Int64(0)) { total, resource in
                total + ((resource.value(forKey: "fileSize") as? Int64) ?? 0)
            }
    }
}

// MARK: - Scan Result Cleanup

extension PhotoLibraryService {
    /// Drops deleted items from the scan results right away, so the review screen updates
    /// without waiting for the library change notification. Groups left with fewer than
    /// two items disappear.
    func removeFromScanResults(_ identifiers: Set<String>) {
        func prune(_ groups: [DuplicateGroup]) -> [DuplicateGroup] {
            groups.compactMap { group in
                let remaining = group.assets.filter { !identifiers.contains($0.localIdentifier) }
                guard remaining.count > 1 else { return nil }
                return remaining.count == group.assets.count
                    ? group
                    : DuplicateGroup(id: group.id, assets: remaining)
            }
        }

        duplicatePhotoGroups = prune(duplicatePhotoGroups)
        duplicateVideoGroups = prune(duplicateVideoGroups)
        similarPhotoGroups = prune(similarPhotoGroups)
    }
}
