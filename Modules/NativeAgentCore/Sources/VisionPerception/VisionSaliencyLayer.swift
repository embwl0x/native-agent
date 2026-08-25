import Foundation
import CoreGraphics
#if canImport(Vision)
import Vision
#endif

// MARK: - ELEMENT LAYER (c): saliency
//
// `VNGenerateAttentionBasedSaliencyImageRequest` does two jobs here, in the
// order the design gave them:
//   1. RANK: a colour region or text band the attention map also lights up is
//      more likely to be a thing a human would reach for. It raises `target`
//      confidence — never `role`, because saliency knows nothing about what a
//      region IS.
//   2. ADD: salient boxes that neither colour nor text found become candidates
//      in their own right, with LOW role confidence (AXUnknown) — this is the
//      only layer that can see a non-text iconic control.
//
// It is emphatically NOT a detector. A CoreML UI-element detector stays out of
// v0 by design; it must earn its way in with the MEASURED misses of (a)+(b).

public protocol VisionSalienceProviding: Sendable {
    /// Salient boxes in image pixel coordinates, most salient first, each with
    /// a 0…1 score.
    func salientRegions(in image: CGImage) throws -> [(rect: VisionRect, score: Double)]
}

public struct VisionSaliencyConfig: Sendable, Equatable {
    /// A candidate overlapping a salient box by at least this IoU is "seen by
    /// saliency" and gets the rank boost.
    public let matchIoU: Double
    /// A salient box smaller/larger than these fractions of frame area is not
    /// offered as a new candidate (a speck, or the whole window).
    public let minAreaFraction: Double
    public let maxAreaFraction: Double
    /// At most this many saliency-only candidates. Attention maps are blobby;
    /// an unbounded add would swamp the precise candidates with vague ones.
    public let maxAdded: Int

    public init(
        matchIoU: Double = 0.25,
        minAreaFraction: Double = 0.0004,
        maxAreaFraction: Double = 0.35,
        maxAdded: Int = 8
    ) {
        self.matchIoU = matchIoU
        self.minAreaFraction = minAreaFraction
        self.maxAreaFraction = maxAreaFraction
        self.maxAdded = maxAdded
    }

    public static let `default` = VisionSaliencyConfig()
}

public enum VisionSaliencyLayer {
    /// Rank existing candidates and add the ones only saliency saw.
    public static func fold(
        salient: [(rect: VisionRect, score: Double)],
        into candidates: [VisionCandidate],
        imageSize: VisionSize,
        config: VisionSaliencyConfig = .default
    ) -> [VisionCandidate] {
        guard !salient.isEmpty else { return candidates }
        let frameArea = imageSize.width * imageSize.height
        guard frameArea > 0 else { return candidates }

        var ranked = candidates.map { candidate -> VisionCandidate in
            let best = salient
                .filter { $0.rect.iou(candidate.rect) >= config.matchIoU }
                .map(\.score)
                .max()
            guard let best else { return candidate }
            return candidate.adding(source: .saliency, salience: best)
        }

        var added = 0
        for region in salient.sorted(by: { $0.score > $1.score }) {
            guard added < config.maxAdded else { break }
            let areaFraction = region.rect.area / frameArea
            guard areaFraction >= config.minAreaFraction,
                  areaFraction <= config.maxAreaFraction else { continue }
            let covered = ranked.contains { $0.rect.iou(region.rect) >= config.matchIoU }
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
        return ranked.sorted(by: VisionColorRegionLayer.readingOrder)
    }
}

#if canImport(Vision)
public struct VisionKitSalienceProvider: VisionSalienceProviding {
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

/// Deterministic provider for tests / replay.
public struct VisionStaticSalienceProvider: VisionSalienceProviding {
    public let regions: [(rect: VisionRect, score: Double)]

    public init(regions: [(rect: VisionRect, score: Double)]) {
        self.regions = regions
    }

    public func salientRegions(in image: CGImage) throws -> [(rect: VisionRect, score: Double)] {
        regions
    }
}
