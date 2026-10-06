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

    // MARK: - Private

    private var fetchResult: PHFetchResult<PHAsset>?
    private var recentlyDeletedResult: PHFetchResult<PHAsset>?
    private let imageManager = PHCachingImageManager()
    private let duplicateDetector = DuplicateDetector()
    private let similarPhotoDetector = SimilarPhotoDetector()
    private var changeObserver: LibraryChangeObserver?
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

        let photos = allAssetsFlat.filter { $0.mediaType == .image }
        similarPhotoGroups = await similarPhotoDetector.findSimilarPhotos(in: photos)

        isScanningSimilarPhotos = false
        hasScannedSimilarPhotos = true
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

    func deleteAssets(_ identifiers: Set<String>) async throws {
        guard !identifiers.isEmpty else { return }
        let idArray = Array(identifiers)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: idArray, options: nil)
                PHAssetChangeRequest.deleteAssets(fetchResult)
            }) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
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

    private nonisolated func handleLibraryChangeSynchronously(_ change: PHChange) {
        // Re-fetch all assets safely without querying change details asynchronously
        Task { @MainActor in
            await self.loadAssets()
        }
    }
}

// MARK: - Library Change Observer

private final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    let handler: @Sendable (PHChange) -> Void

    init(handler: @escaping @Sendable (PHChange) -> Void) {
        self.handler = handler
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        handler(changeInstance)
    }
}
