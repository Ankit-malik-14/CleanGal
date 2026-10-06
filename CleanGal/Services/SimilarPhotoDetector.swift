import Foundation
import Vision

/// Detects visually similar photos using Apple Vision's VNFeaturePrintObservation.
///
/// Architecture: This actor receives pre-loaded CGImages (no PhotoKit dependency),
/// generates feature prints via Vision, and clusters them by visual similarity.
/// All PHAsset / PHImageManager work stays in PhotoLibraryService (@MainActor).
///
/// Strategy:
/// 1. Generate a VNFeaturePrint (ML feature vector) per image from a 360px thumbnail.
/// 2. Compare feature prints within a 24-hour time window (O(N×W) not O(N²)).
/// 3. Cluster similar images using Union-Find (disjoint set).
actor SimilarPhotoDetector {

    // Apple Vision feature print distance reference:
    //   0    = identical
    //   < 5  = near-identical (bursts, minor edits)
    //   < 12 = visually similar (same scene, different angle)
    //   > 15 = different images
    private let distanceThreshold: Float = 10.0

    // Only compare images whose creation dates are within this window.
    private let timeWindow: TimeInterval = 24 * 3600

    // MARK: - Internal Storage

    private struct IndexedPrint {
        let identifier: String
        let date: Date
        let featurePrint: VNFeaturePrintObservation
    }

    private var prints: [IndexedPrint] = []

    // MARK: - Public API

    /// Generates and stores a Vision feature print for one photo.
    /// Call this once per image, then call `cluster()`.
    func addPhoto(identifier: String, date: Date, cgImage: CGImage) {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
            if let fp = request.results?.first {
                prints.append(IndexedPrint(
                    identifier: identifier,
                    date: date,
                    featurePrint: fp
                ))
            }
        } catch {
            // Skip photos that Vision can't process
        }
    }

    /// Clusters all stored feature prints into groups of similar photos.
    /// Returns arrays of asset identifiers, largest groups first.
    func cluster() -> [[String]] {
        guard prints.count > 1 else { return [] }

        // Sort by creation date for time-window optimization
        let sorted = prints.sorted { $0.date < $1.date }
        let n = sorted.count
        let uf = UnionFind(count: n)

        for i in 0..<n {
            for j in (i + 1)..<n {
                let gap = sorted[j].date.timeIntervalSince(sorted[i].date)
                if gap > timeWindow { break } // Sorted — no point checking further

                var distance: Float = 0
                do {
                    try sorted[i].featurePrint.computeDistance(&distance, to: sorted[j].featurePrint)
                    if distance < distanceThreshold {
                        uf.union(i, j)
                    }
                } catch {
                    continue
                }
            }
        }

        // Collect groups with >1 member
        var groups: [Int: [String]] = [:]
        for i in 0..<n {
            groups[uf.find(i), default: []].append(sorted[i].identifier)
        }

        return groups.values
            .filter { $0.count > 1 }
            .sorted { $0.count > $1.count }
    }

    /// Clears stored feature prints to free memory.
    func reset() {
        prints.removeAll()
    }
}

// MARK: - Union-Find (Disjoint Set)

/// Classic union-find with path compression and union by rank.
private final class UnionFind {
    private var parent: [Int]
    private var rank: [Int]

    init(count: Int) {
        parent = Array(0..<count)
        rank = Array(repeating: 0, count: count)
    }

    func find(_ x: Int) -> Int {
        // Iterative path compression (safe for large sets)
        var root = x
        while parent[root] != root {
            root = parent[root]
        }
        var current = x
        while current != root {
            let next = parent[current]
            parent[current] = root
            current = next
        }
        return root
    }

    func union(_ x: Int, _ y: Int) {
        let rootX = find(x)
        let rootY = find(y)
        guard rootX != rootY else { return }

        if rank[rootX] < rank[rootY] {
            parent[rootX] = rootY
        } else if rank[rootX] > rank[rootY] {
            parent[rootY] = rootX
        } else {
            parent[rootY] = rootX
            rank[rootX] += 1
        }
    }
}
