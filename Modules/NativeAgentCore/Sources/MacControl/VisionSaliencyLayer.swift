import Foundation
import CoreGraphics
#if canImport(Vision)
import Vision
// Blueprint: | `VisionSaliencyLayer.swift` | `VisionSaliencyLayer`, `VisionKitSalienceProvider` |
#endif

// MARK: - ELEMENT LAYER (c): saliency
// Saliency may improve target confidence but knows no semantic role; saliency-only candidates therefore remain low-confidence AXUnknown.

public enum VisionSaliencyLayer {
    /// Overlap establishes corroboration for the target-rank boost.
    private static let matchIoU: Double = 0.25
    /// Exclude specks and whole-window saliency boxes from new candidates.
    private static let minAreaFraction: Double = 0.0004
    private static let maxAreaFraction: Double = 0.35
    /// Bound vague saliency additions so they cannot swamp more precise candidates.
    private static let maxAdded: Int = 8

    /// Soft halos may contain precise colour cores despite low IoU; require aligned centres and bounded area ratio to avoid merging panels.
    static func corroborates(
        _ salient: VisionRect,
        _ candidate: VisionRect
    ) -> Bool {
        if salient.iou(candidate) >= matchIoU { return true }
        let smaller = salient.area <= candidate.area ? salient : candidate
        let larger = salient.area <= candidate.area ? candidate : salient
        guard smaller.area > 0,
              larger.area / smaller.area <= 9,
              smaller.coverage(by: larger) >= 0.8 else { return false }
        let dx = abs(salient.centerX - candidate.centerX)
        let dy = abs(salient.centerY - candidate.centerY)
        return dx <= max(smaller.w, 1) * 0.5
            && dy <= max(smaller.h, 1) * 0.5
    }

    /// Preserve precise candidates while adding evidence only saliency sees.
    public static func fold(
        salient: [(rect: VisionRect, score: Double)],
        into candidates: [VisionCandidate],
        imageSize: VisionSize
    ) -> [VisionCandidate] {
        guard !salient.isEmpty else { return candidates }
        let frameArea = imageSize.width * imageSize.height
        guard frameArea > 0 else { return candidates }

        var ranked = candidates.map { candidate -> VisionCandidate in
            let best = salient
                .filter { corroborates($0.rect, candidate.rect) }
                .map(\.score)
                .max()
            guard let best else { return candidate }
            return candidate.adding(source: .saliency, salience: best)
        }

        var added = 0
        for region in salient.sorted(by: { $0.score > $1.score }) {
            guard added < maxAdded else { break }
            let areaFraction = region.rect.area / frameArea
            guard areaFraction >= minAreaFraction,
                  areaFraction <= maxAreaFraction else { continue }
            let covered = ranked.contains {
                corroborates(region.rect, $0.rect)
            }
            if covered { continue }
            // Heat-map bounds are coarse rather than real edges; 0.35 confidence prevents them from claiming precise action geometry.
            ranked.append(VisionCandidate(
                rect: region.rect,
                sources: [.saliency],
                boundsConfidence: 0.35,
                fillLuminance: nil,
                salience: region.score
            ))
            added += 1
        }
        return VisionColorRegionLayer.readingOrder(ranked)
    }
}

#if canImport(Vision)
public struct VisionKitSalienceProvider: Sendable {
    public init() {}

    public func salientRegions(in image: CGImage) throws -> [(rect: VisionRect, score: Double)] {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first as? VNSaliencyImageObservation,
              let objects = observation.salientObjects else { return [] }
        let width = Double(image.width)
        let height = Double(image.height)
        return objects.map { object in
            let box = object.boundingBox
            // Convert normalized bottom-left coordinates once into top-left image pixels.
            let rect = VisionRect(
                x: Double(box.minX) * width,
                y: (1 - Double(box.maxY)) * height,
                w: Double(box.width) * width,
                h: Double(box.height) * height
            )
            return (rect, Double(object.confidence))
        }
    }
}
#endif
