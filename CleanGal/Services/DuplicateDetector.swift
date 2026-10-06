import Photos
import Foundation
import CryptoKit

// MARK: - Duplicate Group Model

struct DuplicateGroup: Identifiable, Sendable {
    let id: String
    let assets: [PHAsset]

    var count: Int {
        assets.count
    }
}

// MARK: - Duplicate Detector

actor DuplicateDetector {

    /// Detects exact duplicate groups for images or videos.
    /// Uses a 2-pass approach:
    /// Pass 1: Fast grouping by dimensions + exact file size (+ duration for videos). Zero I/O.
    /// Pass 2: SHA256 fingerprint of three samples of the raw data (start, middle, end).
    ///
    /// Items whose file size can't be read are skipped, because without it they can't be
    /// verified safely.
    func findDuplicates(in assets: [PHAsset], forMediaType targetType: PHAssetMediaType) async -> [DuplicateGroup] {
        let filtered = assets.filter { $0.mediaType == targetType }
        guard filtered.count > 1 else { return [] }

        // Pass 1: Structural bucketing (no I/O)
        var buckets: [String: [PHAsset]] = [:]
        var sizes: [String: Int64] = [:]
        for asset in filtered {
            guard let size = Self.fileSize(for: asset), size > 0 else { continue }
            sizes[asset.localIdentifier] = size

            let key: String
            if targetType == .video {
                key = "\(asset.pixelWidth)x\(asset.pixelHeight)_\(Int(asset.duration))_\(size)"
            } else {
                key = "\(asset.pixelWidth)x\(asset.pixelHeight)_\(size)"
            }
            buckets[key, default: []].append(asset)
        }

        let candidates = buckets.filter { $0.value.count > 1 }
        guard !candidates.isEmpty else { return [] }

        // Pass 2: fingerprint verification. Hashes are only compared inside one bucket.
        var result: [DuplicateGroup] = []
        for (bucketKey, candidateGroup) in candidates {
            var hashGroups: [String: [PHAsset]] = [:]
            for asset in candidateGroup {
                guard let totalSize = sizes[asset.localIdentifier],
                      let fingerprint = await generateFingerprint(for: asset, totalSize: totalSize)
                else { continue }
                hashGroups[fingerprint, default: []].append(asset)
            }

            for (fingerprint, groupAssets) in hashGroups where groupAssets.count > 1 {
                result.append(DuplicateGroup(id: "\(bucketKey)_\(fingerprint)", assets: groupAssets))
            }
        }
        return result
    }

    // MARK: - Private

    /// Streams the asset's primary resource and returns a SHA256 hex string of its start,
    /// middle and end. Skips iCloud-only assets (isNetworkAccessAllowed = false) to avoid
    /// long downloads.
    private func generateFingerprint(for asset: PHAsset, totalSize: Int64) async -> String? {
        guard let resource = Self.primaryResource(for: asset) else { return nil }

        return await withCheckedContinuation { continuation in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = false // Skip iCloud-only assets

            let hasher = SampledHasher(totalSize: Int(totalSize))
            var didResume = false

            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { data in
                    hasher.consume(data)
                },
                completionHandler: { error in
                    guard !didResume else { return }
                    didResume = true

                    if error != nil {
                        // Asset unavailable locally — skip it
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: hasher.finalize())
                    }
                }
            )
        }
    }

    /// The original photo or video resource. Size and fingerprint must use the same one.
    private static func primaryResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first { $0.type == .photo || $0.type == .video } ?? resources.first
    }

    /// Returns the file size from asset resource metadata (no I/O).
    private static func fileSize(for asset: PHAsset) -> Int64? {
        guard let resource = primaryResource(for: asset) else { return nil }
        return resource.value(forKey: "fileSize") as? Int64
    }
}

// MARK: - Sampled Hasher

/// Hashes three 256 KB windows (start, middle, end) of a stream that arrives in order.
/// Files of 768 KB or less are hashed completely.
/// Photos delivers the data on a single serial queue, so no locking is needed.
nonisolated private final class SampledHasher: @unchecked Sendable {
    private var hash = SHA256()
    private var offset = 0
    private let windows: [Range<Int>]

    init(totalSize: Int) {
        let window = 256 * 1024
        if totalSize <= window * 3 {
            windows = [0..<totalSize]
        } else {
            let middleStart = totalSize / 2 - window / 2
            windows = [
                0..<window,
                middleStart..<(middleStart + window),
                (totalSize - window)..<totalSize
            ]
        }
    }

    func consume(_ data: Data) {
        let chunk = offset..<(offset + data.count)
        for window in windows {
            let overlap = window.clamped(to: chunk)
            guard !overlap.isEmpty else { continue }
            hash.update(data: data.subdata(in: (overlap.lowerBound - offset)..<(overlap.upperBound - offset)))
        }
        offset += data.count
    }

    func finalize() -> String {
        hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
