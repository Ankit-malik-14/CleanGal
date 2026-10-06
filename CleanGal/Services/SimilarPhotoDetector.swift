import Foundation
import Vision
import CoreGraphics

/// Detects visually similar photos by combining two signals:
///
/// 1. **Color histogram** (cheap): a 2x2 grid of 64-bin RGB histograms per photo.
///    Photos whose color distribution differs are rejected immediately.
/// 2. **Vision feature print** (semantic): `VNFeaturePrintObservation` distance.
///    Only photos that pass the color check are compared this way.
///
/// A pair must pass BOTH checks. Feature prints on their own describe *what is in*
/// a photo (food, a face, a street), so unrelated photos of the same kind of subject
/// can score as close. Requiring matching colors and layout removes most of those.
///
/// Grouping is anchor-based (no chaining): each group is built around its first photo,
/// and a candidate must match that anchor directly. The old union-find approach linked
/// A~B and B~C into one group even when A and C looked nothing alike.
///
/// Architecture: receives pre-loaded CGImages (no PhotoKit dependency). All
/// PHAsset / PHImageManager work stays in PhotoLibraryService (@MainActor).
actor SimilarPhotoDetector {

    // MARK: - Tunable thresholds

    /// Only photos taken within this window of a group's anchor can join it.
    /// PhotoLibraryService uses the same value to skip photos with no neighbours.
    nonisolated static let timeWindow: TimeInterval = 3600

    /// Vision feature print distance: smaller = more similar. Apple does not document the
    /// scale, so tune this on real data (lower = stricter, fewer and tighter groups).
    private let featurePrintThreshold: Float = 6.0

    /// Color histogram intersection, 0...1 (1 = identical color distribution and layout).
    /// Higher = stricter.
    private let minColorSimilarity: Float = 0.70

    // MARK: - Internal Storage

    private struct IndexedPrint {
        let identifier: String
        let date: Date
        let featurePrint: VNFeaturePrintObservation
        let color: [Float]
    }

    private var prints: [IndexedPrint] = []

    // MARK: - Public API

    /// Computes the color signature and Vision feature print for one photo and stores them.
    /// Call this once per image, then call `cluster()`.
    func addPhoto(identifier: String, date: Date, cgImage: CGImage) {
        guard let color = Self.makeColorSignature(from: cgImage) else { return }

        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
            if let fp = request.results?.first {
                prints.append(IndexedPrint(
                    identifier: identifier,
                    date: date,
                    featurePrint: fp,
                    color: color
                ))
            }
        } catch {
            // Skip photos that Vision can't process
        }
    }

    /// Groups stored photos by similarity.
    /// Returns arrays of asset identifiers, largest groups first.
    func cluster() -> [[String]] {
        guard prints.count > 1 else { return [] }

        // Sort by creation date for time-window optimization
        let sorted = prints.sorted { $0.date < $1.date }
        let n = sorted.count

        var assigned = Array(repeating: false, count: n)
        var groups: [[String]] = []

        for i in 0..<n where !assigned[i] {
            let anchor = sorted[i]
            var members = [anchor.identifier]

            for j in (i + 1)..<n {
                if sorted[j].date.timeIntervalSince(anchor.date) > Self.timeWindow { break }
                if assigned[j] { continue }

                if isSimilar(anchor, sorted[j]) {
                    assigned[j] = true
                    members.append(sorted[j].identifier)
                }
            }

            if members.count > 1 {
                assigned[i] = true
                groups.append(members)
            }
        }

        let result = groups.sorted { $0.count > $1.count }

        #if DEBUG
        print("[SimilarPhotos] photos=\(n) groups=\(result.count) largest=\(result.first?.count ?? 0)")
        #endif

        return result
    }

    /// Clears stored feature prints to free memory.
    func reset() {
        prints.removeAll()
    }

    // MARK: - Comparison

    private func isSimilar(_ a: IndexedPrint, _ b: IndexedPrint) -> Bool {
        // Cheap check first
        guard Self.colorSimilarity(a.color, b.color) >= minColorSimilarity else { return false }

        var distance: Float = 0
        do {
            try a.featurePrint.computeDistance(&distance, to: b.featurePrint)
        } catch {
            return false
        }
        return distance < featurePrintThreshold
    }

    // MARK: - Color Histogram

    private nonisolated static let histogramSide = 32          // image is downsampled to 32x32
    private nonisolated static let binsPerQuadrant = 64        // 4 levels per RGB channel
    private nonisolated static let quadrantCount = 4           // 2x2 spatial grid

    /// Builds a 2x2 grid of 64-bin RGB histograms (256 values). Each quadrant sums to 1,
    /// so the spatial layout of color is preserved, not just the overall palette.
    private nonisolated static func makeColorSignature(from cgImage: CGImage) -> [Float]? {
        let side = histogramSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)

        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }

            context.interpolationQuality = .low
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var histogram = [Float](repeating: 0, count: quadrantCount * binsPerQuadrant)
        let half = side / 2

        for y in 0..<side {
            for x in 0..<side {
                let offset = (y * side + x) * 4
                let r = Int(pixels[offset] >> 6)
                let g = Int(pixels[offset + 1] >> 6)
                let b = Int(pixels[offset + 2] >> 6)

                let quadrant = (y < half ? 0 : 2) + (x < half ? 0 : 1)
                histogram[quadrant * binsPerQuadrant + ((r << 4) | (g << 2) | b)] += 1
            }
        }

        let pixelsPerQuadrant = Float(half * half)
        for index in histogram.indices {
            histogram[index] /= pixelsPerQuadrant
        }
        return histogram
    }

    /// Histogram intersection averaged over the four quadrants. Range 0...1.
    private nonisolated static func colorSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var overlap: Float = 0
        for index in a.indices {
            overlap += min(a[index], b[index])
        }
        return overlap / Float(quadrantCount)
    }
}
