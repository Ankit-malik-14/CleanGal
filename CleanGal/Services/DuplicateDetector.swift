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
    /// Uses an industry-standard 2-pass approach:
    /// Pass 1: Fast grouping by dimensions + file size / duration (zero I/O).
    /// Pass 2: CryptoKit SHA256 fingerprint of the first 512KB of raw data.
    func findDuplicates(in assets: [PHAsset], forMediaType targetType: PHAssetMediaType) async -> [DuplicateGroup] {
        let filtered = assets.filter { $0.mediaType == targetType }
        guard filtered.count > 1 else { return [] }

        // Pass 1: Structural bucketing (no I/O)
        var buckets: [String: [PHAsset]] = [:]
        for asset in filtered {
            let key: String
            if targetType == .video {
                key = "\(asset.pixelWidth)x\(asset.pixelHeight)_\(Int(asset.duration))"
            } else {
                // Include file size for tighter bucketing on images
                let fileSize = Self.fileSize(for: asset) ?? 0
                key = "\(asset.pixelWidth)x\(asset.pixelHeight)_\(fileSize)"
            }
            buckets[key, default: []].append(asset)
        }

        let candidates = buckets.values.filter { $0.count > 1 }
        guard !candidates.isEmpty else { return [] }

        // Pass 2: SHA256 fingerprint verification
        var hashGroups: [String: [PHAsset]] = [:]
        for candidateGroup in candidates {
            for asset in candidateGroup {
                if let fingerprint = await generateFingerprint(for: asset) {
                    hashGroups[fingerprint, default: []].append(asset)
                }
            }
        }

        return hashGroups.compactMap { (key, groupAssets) in
            guard groupAssets.count > 1 else { return nil }
            return DuplicateGroup(id: key, assets: groupAssets)
        }
    }

    // MARK: - Private

    /// Reads the first 512KB of the asset's primary resource and returns a SHA256 hex string.
    /// Skips iCloud-only assets (isNetworkAccessAllowed = false) to avoid long downloads.
    private func generateFingerprint(for asset: PHAsset) async -> String? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first else { return nil }

        return await withCheckedContinuation { continuation in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = false // Skip iCloud-only assets

            var hash = SHA256()
            var bytesRead = 0
            let maxBytes = 512 * 1024
            var didResume = false

            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { data in
                    if bytesRead < maxBytes {
                        let chunk = data.prefix(maxBytes - bytesRead)
                        hash.update(data: chunk)
                        bytesRead += chunk.count
                    }
                },
                completionHandler: { error in
                    guard !didResume else { return }
                    didResume = true

                    if error != nil {
                        // Asset unavailable locally — skip it
                        continuation.resume(returning: nil)
                    } else {
                        let digest = hash.finalize()
                        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
                        continuation.resume(returning: hex)
                    }
                }
            )
        }
    }

    /// Returns the file size from asset resource metadata (no I/O).
    private static func fileSize(for asset: PHAsset) -> Int64? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first else { return nil }
        return resource.value(forKey: "fileSize") as? Int64
    }
}
