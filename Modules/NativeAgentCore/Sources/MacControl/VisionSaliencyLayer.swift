import Foundation
import CoreGraphics
#if canImport(Vision)
import Vision
// Blueprint: | `VisionSaliencyLayer.swift` | `VisionSaliencyLayer`, `VisionKitSalienceProvider` |
#endif

// MARK: - ELEMENT LAYER (c): saliency
//
// `VNGenerateAttentionBasedSaliencyImageRequest` ranks and adds pixel candidates:
//   1. RANK: a colour region or text band the attention map also lights up is
//      more likely to be a thing a human would reach for. It raises `target`
//      confidence — never `role`, because saliency knows nothing about what a
//      region IS.
//   2. ADD: salient boxes that neither colour nor text found become candidates
//      in their own right, with LOW role confidence (AXUnknown) — this is the
//      only layer that can see a non-text iconic control.

public enum VisionSaliencyLayer {
    /// A candidate overlapping a salient box by at least this IoU is "seen by
    /// saliency" and gets the rank boost.
    private static let matchIoU: Double = 0.25
    /// A salient box smaller/larger than these fractions of frame area is not
    /// offered as a new candidate (a speck, or the whole window).
    private static let minAreaFraction: Double = 0.0004
    private static let maxAreaFraction: Double = 0.35
    /// At most this many saliency-only candidates. Attention maps are blobby;
    /// an unbounded add would swamp the precise candidates with vague ones.
    private static let maxAdded: Int = 8

    /// Attention bounds are deliberately soft. A glow, shadow, or focus halo
    /// can make the saliency box several times larger than the precise colour
    /// region at its centre, leaving their IoU below the ordinary overlap
    /// threshold even though both layers saw the same physical object.
    ///
    /// Accept tight, centre-aligned containment as corroboration, but cap the
    /// area ratio so a broad panel cannot swallow a distinct control merely
    /// because the control happens to sit inside it.
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

    /// Rank existing candidates and add the ones only saliency saw.
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
            // Saliency bounds are BLOBBY — the attention map is coarse and the
            // box is a heat-region, not an edge. 0.35 is the honest number and
            // it is why these rows will rarely clear an act's target bar.
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
            // Normalized, bottom-left origin → top-left image pixels.
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
