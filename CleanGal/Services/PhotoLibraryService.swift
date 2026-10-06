import Photos
import SwiftUI
import ImageIO
import CoreLocation
import AVFoundation

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

    // MARK: - Private

    private var fetchResult: PHFetchResult<PHAsset>?
    private var recentlyDeletedResult: PHFetchResult<PHAsset>?
    private let imageManager = PHCachingImageManager()
    private let duplicateDetector = DuplicateDetector()
    private let similarPhotoDetector = SimilarPhotoDetector()
    private var changeObserver: LibraryChangeObserver?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var videoSizeCache: [String: Int64] = [:]
    private(set) var thumbnailCache: [String: UIImage] = [:]

    // MARK: - Types

    struct DateSection: Identifiable, Sendable {
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
            await Self.groupByDate(result)
        }.value

        dateSections = sections
        pruneScanResults()

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
        if let cached = thumbnailCache[asset.localIdentifier] {
            return cached
        }

        let scale = UIScreen.main.scale
        let scaledSize = CGSize(width: size.width * scale, height: size.height * scale)

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
            thumbnailCache[asset.localIdentifier] = image
        }
        return image
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
    /// - Returns: `true` if the assets were deleted, `false` if the user cancelled the system prompt.
    @discardableResult
    func deleteAssets(_ identifiers: Set<String>) async throws -> Bool {
        guard !identifiers.isEmpty else { return false }

        do {
            try await Self.performDelete(Array(identifiers))
            return true
        } catch let error as PHPhotosError where error.code == .userCancelled {
            return false
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

    func loadShareItems(for identifiers: Set<String>) async -> [Any] {
        var items: [Any] = []

        for identifier in identifiers {
            let fetchResult = PHAsset.fetchAssets(
                withLocalIdentifiers: [identifier],
                options: nil
            )
            guard let asset = fetchResult.firstObject else { continue }

            if asset.mediaType == .image {
                if let image = await loadFullImage(for: asset) {
                    items.append(image)
                }
            } else if asset.mediaType == .video {
                if let url = await loadVideoURL(for: asset) {
                    items.append(url)
                }
            }
        }

        return items
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

    private func loadVideoURL(for asset: PHAsset) async -> URL? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let videoResource = resources.first(where: { $0.type == .video || $0.type == .pairedVideo }) else {
            return nil
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(videoResource.originalFilename.components(separatedBy: ".").last ?? "mov")

        return await withCheckedContinuation { continuation in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            PHAssetResourceManager.default().writeData(
                for: videoResource,
                toFile: tempURL,
                options: options
            ) { error in
                if error == nil {
                    continuation.resume(returning: tempURL)
                } else {
                    continuation.resume(returning: nil)
                }
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

    private static func groupByDate(_ fetchResult: PHFetchResult<PHAsset>) -> [DateSection] {
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

    private static func formatSectionDate(_ date: Date) -> String {
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
