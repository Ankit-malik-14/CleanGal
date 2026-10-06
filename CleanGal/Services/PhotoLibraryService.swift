import Photos
import SwiftUI
import ImageIO
import CoreLocation
import AVFoundation
import UniformTypeIdentifiers

@Observable
@MainActor
final class PhotoLibraryService {

    // MARK: - Published State

    var authorizationStatus: PHAuthorizationStatus = .notDetermined
    var dateSections: [DateSection] = []
    var recentlyDeletedAssets: [PHAsset] = []
    var duplicatePhotoGroups: [DuplicateGroup] = []
    var duplicateVideoGroups: [DuplicateGroup] = []
    var isScanningPhotoDuplicates = false
    var isScanningVideoDuplicates = false
    var hasScannedPhotoDuplicates = false
    var hasScannedVideoDuplicates = false
    var similarPhotoGroups: [DuplicateGroup] = []
    var isScanningSimilarPhotos = false
    var hasScannedSimilarPhotos = false
    var largeVideos: [LargeVideo] = []
    var isLoadingLargeVideos = false
    var hasLoadedLargeVideos = false
    var systemAlbums: [LibraryAlbum] = []
    var userAlbums: [LibraryAlbum] = []
    var isLoadingAlbums = false
    var hasLoadedAlbums = false

    /// Set when a delete fails for a reason other than the user cancelling. Shown as an alert in ContentView.
    var deleteErrorMessage: String?

    // MARK: - Private

    private var fetchResult: PHFetchResult<PHAsset>?
    private var recentlyDeletedResult: PHFetchResult<PHAsset>?
    private let imageManager = PHCachingImageManager()
    private let duplicateDetector = DuplicateDetector()
    private let similarPhotoDetector = SimilarPhotoDetector()
    private var changeObserver: LibraryChangeObserver?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var videoSizeCache: [String: Int64] = [:]
    @ObservationIgnored private var shareFolders: [URL] = []
    /// Bounded by decoded size, and NSCache also evicts it automatically under memory pressure.
    @ObservationIgnored private let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    // MARK: - Types

    nonisolated struct DateSection: Identifiable, Sendable {
        let id: Date
        let title: String
        let assets: [PHAsset]
    }

    struct MediaInfo: Sendable {
        var cameraMake: String?
        var cameraModel: String?
        var lensModel: String?
        var focalLength: Double?
        var aperture: Double?
        var shutterSpeed: String?
        var iso: Int?
        var pixelWidth: Int
        var pixelHeight: Int
        var megapixels: Double
        var fileSize: Int64?
        var fileFormat: String?
        var creationDate: Date?
        var location: CLLocation?
        var colorSpace: String?
    }

    // MARK: - Initialization

    init() {
        imageManager.allowsCachingHighQualityImages = false
        setupChangeObserver()
        Self.removeStaleShareFiles()
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationStatus = status
        if status == .authorized || status == .limited {
            await loadAssets()
        }
    }

    // MARK: - Fetching

    func loadAssets() async {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeHiddenAssets = false

        let result = PHAsset.fetchAssets(with: options)
        fetchResult = result

        let sections = await Task.detached(priority: .userInitiated) {
            Self.groupByDate(result)
        }.value

        dateSections = sections
        pruneScanResults()

        if hasLoadedAlbums {
            await loadAlbums()
        }

        // TODO: Re-enable once stable
        // // Fetch Recently Deleted album
        // let trashCollections = PHAssetCollection.fetchAssetCollections(
        //     with: .smartAlbum,
        //     subtype: .any,
        //     options: nil
        // )
        // var foundTrash: PHAssetCollection?
        // trashCollections.enumerateObjects { collection, _, stop in
        //     if collection.assetCollectionSubtype == .smartAlbumRecentlyDeleted {
        //         foundTrash = collection
        //         stop.pointee = true
        //     }
        // }
        // if let trashAlbum = foundTrash {
        //     let trashOptions = PHFetchOptions()
        //     trashOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        //     let trashResult = PHAsset.fetchAssets(in: trashAlbum, options: trashOptions)
        //     recentlyDeletedResult = trashResult
        //     var deleted: [PHAsset] = []
        //     trashResult.enumerateObjects { asset, _, _ in
        //         deleted.append(asset)
        //     }
        //     recentlyDeletedAssets = deleted
        // }

        // TODO: Re-enable once stable
        // // Scan for duplicates asynchronously
        // Task {
        //     await scanForDuplicates()
        // }
    }

    func scanForDuplicates(mediaType: PHAssetMediaType) async {
        let isAlreadyScanning = mediaType == .image ? isScanningPhotoDuplicates : isScanningVideoDuplicates
        guard !isAlreadyScanning else { return }

        if mediaType == .image {
            isScanningPhotoDuplicates = true
        } else {
            isScanningVideoDuplicates = true
        }

        let all = allAssetsFlat
        let groups = await duplicateDetector.findDuplicates(in: all, forMediaType: mediaType)

        if mediaType == .image {
            duplicatePhotoGroups = groups
            isScanningPhotoDuplicates = false
            hasScannedPhotoDuplicates = true
        } else {
            duplicateVideoGroups = groups
            isScanningVideoDuplicates = false
            hasScannedVideoDuplicates = true
        }
    }

    func scanForSimilarPhotos() async {
        guard !isScanningSimilarPhotos else { return }
        isScanningSimilarPhotos = true
        defer { isScanningSimilarPhotos = false }

        let photos = allAssetsFlat.filter { $0.mediaType == .image }
        let groups = await findSimilarPhotos(in: photos)

        // If the user left the screen mid-scan, don't publish partial results
        // or mark the scan as done, so it runs again next time.
        guard !Task.isCancelled else { return }

        similarPhotoGroups = groups
        hasScannedSimilarPhotos = true
    }

    // MARK: - Similar Photos Pipeline

    /// Shared with the detector. Photos with no neighbour inside this window
    /// can never be grouped, so we skip them entirely.
    private static let similarTimeWindow: TimeInterval = SimilarPhotoDetector.timeWindow
    private static let similarThumbnailSide: CGFloat = 360
    private static let maxConcurrentThumbnailLoads = 4

    /// Loads a small thumbnail per candidate, feeds it to the detector, clusters,
    /// then maps the resulting identifiers back to PHAssets.
    private func findSimilarPhotos(in photos: [PHAsset]) async -> [DuplicateGroup] {
        let candidates = Self.filterByTimeNeighbors(photos, window: Self.similarTimeWindow)
        guard candidates.count > 1 else { return [] }

        await similarPhotoDetector.reset()

        // Bounded concurrency: a few thumbnails load while the detector
        // (a separate actor, off the main thread) runs Vision on earlier ones.
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            for asset in candidates {
                if Task.isCancelled { break }

                if inFlight >= Self.maxConcurrentThumbnailLoads {
                    await group.next()
                    inFlight -= 1
                }

                group.addTask { [self] in
                    await self.addFeaturePrint(for: asset)
                }
                inFlight += 1
            }
            await group.waitForAll()
        }

        guard !Task.isCancelled else {
            await similarPhotoDetector.reset()
            return []
        }

        let identifierGroups = await similarPhotoDetector.cluster()
        await similarPhotoDetector.reset() // free feature prints

        let lookup = Dictionary(
            candidates.map { ($0.localIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return identifierGroups.compactMap { identifiers in
            let assets = identifiers.compactMap { lookup[$0] }
            guard assets.count > 1, let groupID = identifiers.min() else { return nil }
            return DuplicateGroup(id: groupID, assets: assets)
        }
    }

    private func addFeaturePrint(for asset: PHAsset) async {
        guard let cgImage = await loadCGImage(for: asset, side: Self.similarThumbnailSide) else { return }
        await similarPhotoDetector.addPhoto(
            identifier: asset.localIdentifier,
            date: asset.creationDate ?? .distantPast,
            cgImage: cgImage
        )
    }

    /// Small local-only thumbnail. iCloud-only photos are skipped rather than downloaded.
    private func loadCGImage(for asset: PHAsset, side: CGFloat) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat // single callback, never degraded
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false

            imageManager.requestImage(
                for: asset,
                targetSize: CGSize(width: side, height: side),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image?.cgImage)
            }
        }
    }

    /// Keeps only photos that have at least one other photo within `window` of them.
    private nonisolated static func filterByTimeNeighbors(_ photos: [PHAsset], window: TimeInterval) -> [PHAsset] {
        let sorted = photos.sorted {
            ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
        }
        guard sorted.count > 1 else { return [] }

        var keep = Array(repeating: false, count: sorted.count)
        for i in 1..<sorted.count {
            let previous = sorted[i - 1].creationDate ?? .distantPast
            let current = sorted[i].creationDate ?? .distantPast
            if current.timeIntervalSince(previous) <= window {
                keep[i - 1] = true
                keep[i] = true
            }
        }

        return zip(sorted, keep).filter(\.1).map(\.0)
    }

    var allAssetsFlat: [PHAsset] {
        dateSections.flatMap(\.assets)
    }

    var totalAssetCount: Int {
        fetchResult?.count ?? 0
    }

    // MARK: - Image Loading

    func loadThumbnail(for asset: PHAsset, size: CGSize) async -> UIImage? {
        let scale = UIScreen.main.scale
        let scaledSize = CGSize(width: size.width * scale, height: size.height * scale)
        let requestedSide = max(scaledSize.width, scaledSize.height)

        // Only reuse a cached image if it is big enough for this request. Otherwise a small
        // thumbnail loaded first (e.g. in a list row) would be reused blurry in a larger grid.
        let cacheKey = asset.localIdentifier as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey),
           Self.longestSide(of: cached) >= requestedSide * 0.9 {
            return cached
        }

        let image = await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.resizeMode = .exact

            imageManager.requestImage(
                for: asset,
                targetSize: scaledSize,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }

        if let image {
            // Keep the largest version we have seen for this asset.
            let existingSide = thumbnailCache.object(forKey: cacheKey).map(Self.longestSide(of:)) ?? 0
            if Self.longestSide(of: image) > existingSide {
                thumbnailCache.setObject(image, forKey: cacheKey, cost: Self.decodedCost(of: image))
            }
        }
        return image
    }

    private static func longestSide(of image: UIImage) -> CGFloat {
        max(image.size.width, image.size.height) * image.scale
    }

    /// Approximate decoded bytes (4 bytes per pixel), used as the NSCache cost.
    private static func decodedCost(of image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }

    /// Returns a thumbnail that was already loaded, if it is still cached.
    func cachedThumbnail(for identifier: String) -> UIImage? {
        thumbnailCache.object(forKey: identifier as NSString)
    }

    func loadFullImage(for asset: PHAsset) async -> UIImage? {
        let targetSize = CGSize(width: asset.pixelWidth, height: asset.pixelHeight)

        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.resizeMode = .none

            var didResume = false
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                guard !didResume else { return }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !isDegraded || image != nil {
                    didResume = true
                    continuation.resume(returning: image)
                }
            }
        }
    }

    // MARK: - Preloading & Memory Management

    private var currentlyCachedAssets: [PHAsset] = []

    func updatePreloadCache(currentAssetID: String, allAssets: [PHAsset], windowSize: Int = 5) {
        guard let currentIndex = allAssets.firstIndex(where: { $0.localIdentifier == currentAssetID }) else { return }

        let startIndex = max(0, currentIndex - windowSize)
        let endIndex = min(allAssets.count - 1, currentIndex + windowSize)

        let newTargetAssets = Array(allAssets[startIndex...endIndex])

        let screenSize = UIScreen.main.bounds.size
        let scale = UIScreen.main.scale
        let targetSize = CGSize(width: screenSize.width * scale, height: screenSize.height * scale)

        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        let assetsToStop = currentlyCachedAssets.filter { oldAsset in
            !newTargetAssets.contains(where: { $0.localIdentifier == oldAsset.localIdentifier })
        }

        if !assetsToStop.isEmpty {
            imageManager.stopCachingImages(for: assetsToStop, targetSize: targetSize, contentMode: .aspectFit, options: options)
        }

        imageManager.startCachingImages(for: newTargetAssets, targetSize: targetSize, contentMode: .aspectFit, options: options)
        currentlyCachedAssets = newTargetAssets
    }

    func stopAllPreloadCaching() {
        imageManager.stopCachingImagesForAllAssets()
        currentlyCachedAssets.removeAll()
    }

    // MARK: - Video

    func loadPlayerItem(for asset: PHAsset) async -> AVPlayerItem? {
        await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .automatic

            imageManager.requestPlayerItem(
                forVideo: asset,
                options: options
            ) { playerItem, _ in
                continuation.resume(returning: playerItem)
            }
        }
    }

    // MARK: - Albums

    /// Loads the system smart albums (Screenshots, Videos, Selfies, ...) and the user's own
    /// Photos albums. These are plain system fetches, so this is fast and needs no scan.
    func loadAlbums() async {
        guard !isLoadingAlbums else { return }
        isLoadingAlbums = true
        defer { isLoadingAlbums = false }

        let loaded = await Task.detached(priority: .userInitiated) {
            Self.fetchAlbums()
        }.value

        systemAlbums = loaded.system
        userAlbums = loaded.user
        hasLoadedAlbums = true
    }

    /// All assets in an album, newest first. Enumerated off the main thread.
    func assets(in album: LibraryAlbum) async -> [PHAsset] {
        let collection = album.collection
        return await Task.detached(priority: .userInitiated) {
            Self.enumerateAssets(in: collection)
        }.value
    }

    private nonisolated static func fetchAlbums() -> (system: [LibraryAlbum], user: [LibraryAlbum]) {
        let specs: [(PHAssetCollectionSubtype, LibraryAlbum.Kind)] = [
            (.smartAlbumScreenshots, .screenshots),
            (.smartAlbumVideos, .videos),
            (.smartAlbumSelfPortraits, .selfies),
            (.smartAlbumLivePhotos, .livePhotos),
            (.smartAlbumDepthEffect, .portraits),
            (.smartAlbumPanoramas, .panoramas),
            (.smartAlbumSlomoVideos, .slowMotion),
            (.smartAlbumTimelapses, .timeLapse),
            (.smartAlbumFavorites, .favorites)
        ]

        var system: [LibraryAlbum] = []
        for (subtype, kind) in specs {
            let collections = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum,
                subtype: subtype,
                options: nil
            )
            if let collection = collections.firstObject,
               let album = Self.makeAlbum(collection, kind: kind) {
                system.append(album)
            }
        }

        var user: [LibraryAlbum] = []
        let userCollections = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: nil
        )
        userCollections.enumerateObjects { collection, _, _ in
            if let album = Self.makeAlbum(collection, kind: .userAlbum) {
                user.append(album)
            }
        }
        user.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        return (system, user)
    }

    /// Returns nil for empty albums so they don't clutter the list.
    private nonisolated static func makeAlbum(_ collection: PHAssetCollection, kind: LibraryAlbum.Kind) -> LibraryAlbum? {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let result = PHAsset.fetchAssets(in: collection, options: options)
        guard result.count > 0 else { return nil }

        return LibraryAlbum(
            collection: collection,
            kind: kind,
            title: collection.localizedTitle ?? "Untitled",
            count: result.count,
            coverAsset: result.lastObject // newest item
        )
    }

    private nonisolated static func enumerateAssets(in collection: PHAssetCollection) -> [PHAsset] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let result = PHAsset.fetchAssets(in: collection, options: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    // MARK: - Large Videos

    /// Fetches all videos, measures their storage size, and publishes them biggest-first.
    /// Sizes are cached per asset, so re-entering the screen (or reloading after a library
    /// change) only measures videos it hasn't seen before. All measuring happens off the main thread.
    func loadLargeVideos() async {
        guard !isLoadingLargeVideos else { return }
        isLoadingLargeVideos = true
        defer { isLoadingLargeVideos = false }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        options.includeHiddenAssets = false
        let result = PHAsset.fetchAssets(with: options)

        let knownSizes = videoSizeCache
        let measured = await Task.detached(priority: .userInitiated) {
            Self.measureVideos(result, knownSizes: knownSizes)
        }.value

        videoSizeCache.merge(measured.sizes) { _, new in new }

        // The user left the screen mid-load: keep the cache, skip publishing.
        guard !Task.isCancelled else { return }

        largeVideos = measured.videos.sorted { $0.fileSize > $1.fileSize }
        hasLoadedLargeVideos = true
    }

    /// Removes videos from the list immediately after a successful delete,
    /// without waiting for the library change notification.
    func removeLargeVideos(withIdentifiers identifiers: Set<String>) {
        largeVideos.removeAll { identifiers.contains($0.id) }
    }

    private nonisolated static func measureVideos(
        _ result: PHFetchResult<PHAsset>,
        knownSizes: [String: Int64]
    ) -> (videos: [LargeVideo], sizes: [String: Int64]) {
        var videos: [LargeVideo] = []
        var newSizes: [String: Int64] = [:]
        videos.reserveCapacity(result.count)

        result.enumerateObjects { asset, _, _ in
            let id = asset.localIdentifier
            let size: Int64
            if let known = knownSizes[id] {
                size = known
            } else {
                size = Self.storageBytes(for: asset)
                if size > 0 { newSizes[id] = size } // never cache a failed (zero) lookup
            }
            videos.append(LargeVideo(asset: asset, fileSize: size))
        }

        return (videos, newSizes)
    }

    /// Total bytes of the video's resources. An edited video has both the original and the
    /// rendered edit on disk, so both count toward the space it takes up.
    private nonisolated static func storageBytes(for asset: PHAsset) -> Int64 {
        PHAssetResource.assetResources(for: asset)
            .filter { $0.type == .video || $0.type == .fullSizeVideo }
            .reduce(Int64(0)) { total, resource in
                total + ((resource.value(forKey: "fileSize") as? Int64) ?? 0)
            }
    }

    // MARK: - EXIF / Media Info

    func loadMediaInfo(for asset: PHAsset) async -> MediaInfo {
        var info = MediaInfo(
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            megapixels: Double(asset.pixelWidth * asset.pixelHeight) / 1_000_000.0,
            creationDate: asset.creationDate,
            location: asset.location
        )

        let resources = PHAssetResource.assetResources(for: asset)
        if let resource = resources.first {
            info.fileFormat = resource.uniformTypeIdentifier
            if let size = resource.value(forKey: "fileSize") as? Int64 {
                info.fileSize = size
            }
        }

        if asset.mediaType == .image {
            if let data = await loadImageData(for: asset) {
                extractEXIF(from: data, into: &info)
            }
        }

        return info
    }

    // MARK: - Operations

    /// Deletes the given assets.
    /// - Returns: `true` if the assets were deleted. `false` if the user cancelled the system
    ///   prompt, or if the delete failed (in which case `deleteErrorMessage` is set).
    @discardableResult
    func deleteAssets(_ identifiers: Set<String>) async -> Bool {
        guard !identifiers.isEmpty else { return false }

        do {
            try await Self.performDelete(Array(identifiers))
            return true
        } catch let error as PHPhotosError where error.code == .userCancelled {
            return false
        } catch {
            deleteErrorMessage = Self.deletionMessage(for: error)
            return false
        }
    }

    private nonisolated static func deletionMessage(for error: Error) -> String {
        guard let code = (error as? PHPhotosError)?.code else {
            return "The selected items couldn't be deleted. Please try again."
        }

        switch code {
        case .accessUserDenied, .accessRestricted:
            return "CleanGal isn't allowed to change your photo library. You can update this in Settings."
        case .networkAccessRequired, .networkError:
            return "Some of these items are stored in iCloud and need an internet connection to be deleted. Check your connection and try again."
        default:
            return "The selected items couldn't be deleted. Please try again."
        }
    }

    /// Runs the Photos change off the main actor. Photos invokes the change block on a
    /// background queue, so it must not inherit the class's @MainActor isolation.
    private nonisolated static func performDelete(_ identifiers: [String]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    /// Exports each item's original file to a temporary folder and returns the file URLs.
    /// Sharing URLs avoids holding full-resolution images in memory. Call
    /// `cleanUpShareFiles()` once the share sheet finishes.
    func loadShareItems(for identifiers: Set<String>) async -> [Any] {
        let directory = Self.shareDirectory
        var items: [Any] = []

        for identifier in identifiers {
            let fetchResult = PHAsset.fetchAssets(
                withLocalIdentifiers: [identifier],
                options: nil
            )
            guard let asset = fetchResult.firstObject,
                  let url = await exportForSharing(asset, into: directory)
            else { continue }

            items.append(ShareItemSource(url: url, thumbnail: cachedThumbnail(for: identifier)))
        }

        return items
    }

    /// Deletes the files exported for the share that just finished. Only folders created by
    /// this session are removed, so it can never delete a share that is still being prepared.
    func cleanUpShareFiles() {
        let folders = shareFolders
        shareFolders.removeAll()
        guard !folders.isEmpty else { return }

        Task.detached(priority: .utility) {
            for folder in folders {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    /// Runs once at launch, synchronously, so it always finishes before the first share.
    private nonisolated static func removeStaleShareFiles() {
        try? FileManager.default.removeItem(at: shareDirectory)
    }

    private nonisolated static var shareDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CleanGalShare", isDirectory: true)
    }

    // MARK: - Private Helpers

    private func loadImageData(for asset: PHAsset) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.version = .current

            imageManager.requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /// Writes the best version of the asset (the edit if there is one) into its own
    /// subfolder, keeping the original file name so recipients see a sensible name.
    private func exportForSharing(_ asset: PHAsset, into directory: URL) async -> URL? {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferredTypes: [PHAssetResourceType] = asset.mediaType == .video
            ? [.fullSizeVideo, .video]
            : [.fullSizePhoto, .photo]

        var chosen: PHAssetResource?
        for type in preferredTypes {
            if let match = resources.first(where: { $0.type == type }) {
                chosen = match
                break
            }
        }
        guard let resource = chosen else { return nil }

        let original = resources.first { $0.type == .photo || $0.type == .video } ?? resource
        let baseName = URL(fileURLWithPath: original.originalFilename)
            .deletingPathExtension()
            .lastPathComponent
        let fileExtension = UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension
            ?? URL(fileURLWithPath: resource.originalFilename).pathExtension

        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        shareFolders.append(folder)

        var fileURL = folder.appendingPathComponent(baseName)
        if !fileExtension.isEmpty {
            fileURL = fileURL.appendingPathExtension(fileExtension)
        }
        let destination = fileURL

        return await withCheckedContinuation { continuation in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: destination,
                options: options
            ) { error in
                continuation.resume(returning: error == nil ? destination : nil)
            }
        }
    }

    private nonisolated func extractEXIF(from data: Data, into info: inout MediaInfo) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return }

        if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            info.aperture = exif[kCGImagePropertyExifFNumber as String] as? Double
            info.iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first
            info.focalLength = exif[kCGImagePropertyExifFocalLength as String] as? Double
            info.lensModel = exif[kCGImagePropertyExifLensModel as String] as? String

            if let exposureTime = exif[kCGImagePropertyExifExposureTime as String] as? Double {
                if exposureTime >= 1 {
                    info.shutterSpeed = "\(exposureTime) s"
                } else {
                    let denominator = Int(round(1.0 / exposureTime))
                    info.shutterSpeed = "1/\(denominator) s"
                }
            }
        }

        if let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            info.cameraMake = tiff[kCGImagePropertyTIFFMake as String] as? String
            info.cameraModel = tiff[kCGImagePropertyTIFFModel as String] as? String
        }

        info.colorSpace = properties[kCGImagePropertyColorModel as String] as? String
    }

    private nonisolated static func groupByDate(_ fetchResult: PHFetchResult<PHAsset>) -> [DateSection] {
        var sections: [(date: Date, assets: [PHAsset])] = []
        let calendar = Calendar.current

        fetchResult.enumerateObjects { asset, _, _ in
            let date = calendar.startOfDay(for: asset.creationDate ?? Date.distantPast)

            if let lastIndex = sections.indices.last, sections[lastIndex].date == date {
                sections[lastIndex].assets.append(asset)
            } else {
                sections.append((date: date, assets: [asset]))
            }
        }

        return sections.map { item in
            DateSection(
                id: item.date,
                title: formatSectionDate(item.date),
                assets: item.assets
            )
        }
    }

    private nonisolated static func formatSectionDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else if calendar.isDate(date, equalTo: Date.now, toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        } else {
            return date.formatted(.dateTime.month(.wide).day().year())
        }
    }

    private func setupChangeObserver() {
        changeObserver = LibraryChangeObserver { [weak self] change in
            guard let self else { return }
            self.handleLibraryChangeSynchronously(change)
        }
        if let observer = changeObserver {
            PHPhotoLibrary.shared().register(observer)
        }
    }

    /// Called by Photos on a background queue.
    private nonisolated func handleLibraryChangeSynchronously(_ change: PHChange) {
        Task { @MainActor [weak self] in
            self?.scheduleReload()
        }
    }

    /// Photos often fires several change notifications for one action (e.g. a delete).
    /// Coalesce them into a single reload instead of racing several full re-fetches.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            await self.loadAssets()
        }
    }

    /// Drops deleted assets from cached scan results so the album screens
    /// never show (or try to load) assets that no longer exist.
    private func pruneScanResults() {
        let live = Set(allAssetsFlat.map(\.localIdentifier))

        func prune(_ groups: [DuplicateGroup]) -> [DuplicateGroup] {
            groups.compactMap { group in
                let remaining = group.assets.filter { live.contains($0.localIdentifier) }
                guard remaining.count > 1 else { return nil }
                return remaining.count == group.assets.count
                    ? group
                    : DuplicateGroup(id: group.id, assets: remaining)
            }
        }

        duplicatePhotoGroups = prune(duplicatePhotoGroups)
        duplicateVideoGroups = prune(duplicateVideoGroups)
        similarPhotoGroups = prune(similarPhotoGroups)
        largeVideos.removeAll { !live.contains($0.id) }
    }
}

// MARK: - Library Album Model

nonisolated struct LibraryAlbum: Identifiable, Sendable {
    nonisolated enum Kind: Sendable {
        case screenshots, videos, selfies, livePhotos, portraits
        case panoramas, slowMotion, timeLapse, favorites
        case userAlbum
    }

    let collection: PHAssetCollection
    let kind: Kind
    let title: String
    let count: Int
    let coverAsset: PHAsset?

    var id: String { collection.localIdentifier }
}

// MARK: - Large Video Model

nonisolated struct LargeVideo: Identifiable, Sendable {
    let asset: PHAsset
    let fileSize: Int64

    var id: String { asset.localIdentifier }
}

// MARK: - Library Change Observer

/// Photos calls `photoLibraryDidChange` on an arbitrary background queue, so this class
/// must NOT be main-actor isolated (the project may default unannotated types to @MainActor).
nonisolated private final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    let handler: @Sendable (PHChange) -> Void

    init(handler: @escaping @Sendable (PHChange) -> Void) {
        self.handler = handler
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        handler(changeInstance)
    }
}
