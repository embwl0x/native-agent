import Foundation
import CoreGraphics
#if canImport(Vision)
import Vision
// Blueprint: | `VisionTextLayer.swift` | `VisionTextLayerResult`, `VisionTextLayer`, `VisionKitTextRecognizer` |
#endif

// Whole-frame recognition refines only genuinely tiny or sparse text.

/// Text boxes and whether conditional OCR refinement ran.
public struct VisionTextLayerResult: Sendable, Equatable {
    public let boxes: [VisionTextBox]
    public let tiled: Bool
    /// Why tiling did or did not fire, in one phrase. Stated rather than
    /// inferred: "no tiny text (median 18.0px)" vs "tiny text (median 7.0px)".
    public let tilingReason: String
    /// Count thrown tile OCR passes so the compiler can report incomplete text recovery.
    public let tileFailures: Int

    public init(boxes: [VisionTextBox], tiled: Bool, tilingReason: String, tileFailures: Int = 0) {
        self.boxes = boxes
        self.tiled = tiled
        self.tilingReason = tilingReason
        self.tileFailures = tileFailures
    }
}

public enum VisionTextLayer {
    /// Relative frame-height threshold for median text height to trigger tiling.
    private static let tinyTextHeightFraction: Double = 0.009
    /// …and an absolute floor, because a small window full of ordinary 13 px
    /// text is not tiny text; it is a small window.
    private static let tinyTextHeightPixels: Double = 12
    /// Tiles per axis for conditional OCR refinement.
    private static let tileGrid: Int = 3
    /// Fractional overlap between adjacent tiles, so a string straddling a
    /// tile seam is whole in at least one tile.
    private static let tileOverlap: Double = 0.15
    /// Two boxes this close (IoU) with the same text are the same string seen
    /// twice by two tiles.
    private static let dedupeIoU: Double = 0.5

    /// Tiles only recognized text whose median height is below the tiny-text threshold.
    public static func tilingDecision(
        boxes: [VisionTextBox],
        imageHeight: Double
    ) -> (shouldTile: Bool, reason: String) {
        let heights = boxes.map(\.rect.h).filter { $0 > 0 }.sorted()
        guard !heights.isEmpty else {
            // No text at all is not evidence of TINY text — it is evidence of
            // no text (a game canvas, a photo). Tiling a blank frame is pure
            // waste, and a frame whose text OCR could not see at all is a
            // different problem than one whose text is small.
            return (false, "no text recognized — nothing to re-scan")
        }
        let median = heights[heights.count / 2]
        let threshold = max(tinyTextHeightPixels, imageHeight * tinyTextHeightFraction)
        let rounded = (median * 10).rounded() / 10
        if median < threshold {
            return (true, "tiny text (median \(rounded)px < \((threshold * 10).rounded() / 10)px)")
        }
        return (false, "no tiny text (median \(rounded)px)")
    }

    /// Tile rects for the conditional pass, in image pixel coordinates.
    public static func tiles(
        imageSize: VisionSize
    ) -> [VisionRect] {
        let n = max(1, tileGrid)
        let tileW = imageSize.width / Double(n)
        let tileH = imageSize.height / Double(n)
        let padX = tileW * tileOverlap
        let padY = tileH * tileOverlap
        var out: [VisionRect] = []
        for row in 0..<n {
            for column in 0..<n {
                let x = max(0, Double(column) * tileW - padX)
                let y = max(0, Double(row) * tileH - padY)
                let right = min(imageSize.width, Double(column + 1) * tileW + padX)
                let bottom = min(imageSize.height, Double(row + 1) * tileH + padY)
                out.append(VisionRect(x: x, y: y, w: right - x, h: bottom - y))
            }
        }
        return out
    }

    /// Local regions around the few strings a sparse canvas did expose. The
    /// crop makes neighboring HUD/status text large relative to Vision's input
    /// without manufacturing pixels or paying for a full 3×3 rescan. Heavily
    /// overlapping regions collapse to one recognition call.
    public static func sparseRecoveryRegions(
        boxes: [VisionTextBox],
        imageSize: VisionSize
    ) -> [VisionRect] {
        guard !boxes.isEmpty, boxes.count <= 3,
              imageSize.width > 0, imageSize.height > 0 else { return [] }
        var regions: [VisionRect] = []
        for box in boxes {
            let padX = max(box.rect.h * 4, imageSize.width * 0.02)
            let x = max(0, box.rect.x - padX)
            let y = max(0, box.rect.y - box.rect.h * 2)
            let right = min(
                imageSize.width,
                max(x + imageSize.width * 0.35, box.rect.x + box.rect.w + padX)
            )
            let bottom = min(
                imageSize.height,
                max(y + imageSize.height * 0.25, box.rect.y + box.rect.h * 10)
            )
            let candidate = VisionRect(x: x, y: y, w: right - x, h: bottom - y)
            guard candidate.w > 0, candidate.h > 0 else { continue }
            if let index = regions.firstIndex(where: { $0.iou(candidate) >= 0.5 }) {
                let existing = regions[index]
                let mergedX = min(existing.x, candidate.x)
                let mergedY = min(existing.y, candidate.y)
                let mergedRight = max(existing.x + existing.w, candidate.x + candidate.w)
                let mergedBottom = max(existing.y + existing.h, candidate.y + candidate.h)
                regions[index] = VisionRect(
                    x: mergedX, y: mergedY,
                    w: mergedRight - mergedX, h: mergedBottom - mergedY
                )
            } else {
                regions.append(candidate)
            }
        }
        return regions
    }

    /// Merge a whole-frame pass with tile passes: the same string seen by two
    /// tiles is one string; the higher-confidence observation wins.
    public static func dedupe(
        _ boxes: [VisionTextBox]
    ) -> [VisionTextBox] {
        var kept: [VisionTextBox] = []
        for box in boxes.sorted(by: {
            $0.confidence == $1.confidence
                ? geometryPrecedes($0, $1)
                : $0.confidence > $1.confidence
        }) {
            let duplicate = kept.contains { existing in
                existing.text == box.text && existing.rect.iou(box.rect) >= dedupeIoU
            }
            if !duplicate { kept.append(box) }
        }
        return VisionRect.readingOrder(kept, rect: \.rect, tolerance: 1, geometryPrecedes: geometryPrecedes) {
            $0.text == $1.text ? geometryPrecedes($0, $1) : $0.text < $1.text
        }
    }

    private static func geometryPrecedes(_ lhs: VisionTextBox, _ rhs: VisionTextBox) -> Bool {
        if lhs.rect.y != rhs.rect.y { return lhs.rect.y < rhs.rect.y }
        if lhs.rect.x != rhs.rect.x { return lhs.rect.x < rhs.rect.x }
        if lhs.rect.w != rhs.rect.w { return lhs.rect.w < rhs.rect.w }
        if lhs.rect.h != rhs.rect.h { return lhs.rect.h < rhs.rect.h }
        if lhs.text != rhs.text { return lhs.text < rhs.text }
        return lhs.source < rhs.source
    }

    /// Whole-frame pass, plus a tiling pass ONLY when the text is genuinely
    /// tiny. Foreground-covered boxes do not trigger expensive refinement of
    /// another app's text. They remain in the result for whole-frame redaction
    /// context; the compiler owns exclusion from the published percept.
    #if canImport(Vision)
    public static func recognize(
        image: CGImage,
        using recognizer: VisionKitTextRecognizer,
        ignoredForRefinement: [VisionRect] = []
    ) throws -> VisionTextLayerResult {
        try Task.checkCancellation()
        let size = VisionSize(width: Double(image.width), height: Double(image.height))
        let whole = try recognizer.recognizeText(in: image, region: nil)
        try Task.checkCancellation()
        let relevant = whole.filter { box in
            !ignoredForRefinement.contains { $0.intersection(box.rect).area > 0 }
        }
        let decision = tilingDecision(boxes: relevant, imageHeight: size.height)
        let exclusionNote = relevant.count == whole.count
            ? "" : "; foreground-covered text ignored for refinement"
        let regions: [VisionRect]
        let reason: String
        if decision.shouldTile {
            regions = tiles(imageSize: size)
            reason = decision.reason + exclusionNote
        } else {
            regions = sparseRecoveryRegions(boxes: relevant, imageSize: size)
            reason = regions.isEmpty
                ? decision.reason + exclusionNote
                : "sparse text recovery (\(relevant.count) relevant whole-frame box(es), \(regions.count) local region(s))" + exclusionNote
        }
        guard !regions.isEmpty else {
            return VisionTextLayerResult(
                boxes: dedupe(whole),
                tiled: false,
                tilingReason: reason
            )
        }
        var all = whole
        var tileFailures = 0
        for tile in regions {
            try Task.checkCancellation()
            do {
                all.append(contentsOf: try recognizer.recognizeText(in: image, region: tile))
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                // Counted, never swallowed: the compiler surfaces this in notes.
                tileFailures += 1
            }
        }
        try Task.checkCancellation()
        return VisionTextLayerResult(
            boxes: dedupe(all),
            tiled: true,
            tilingReason: reason,
            tileFailures: tileFailures
        )
    }
    #endif
}

// MARK: - The real engine

#if canImport(Vision)
/// Native request execution and normalized-to-pixel observation conversion.
public struct VisionKitTextRecognizer: Sendable {
    public init() {}

    func recognizeText(in image: CGImage, request: VNRecognizeTextRequest,
        select: ([VNRecognizedTextObservation]) -> [VNRecognizedTextObservation] = { $0 }
    ) throws -> [VisionTextBox] {
        try Task.checkCancellation()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        try Task.checkCancellation()
        return select(request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return VisionTextBox(text: candidate.string,
                rect: VisionRect(x: box.minX * Double(image.width),
                    y: (1 - box.maxY) * Double(image.height),
                    w: box.width * Double(image.width), h: box.height * Double(image.height)),
                confidence: Double(candidate.confidence))
        }
    }

    public func recognizeText(in image: CGImage, region: VisionRect?) throws -> [VisionTextBox] {
        // A tile is cropped rather than passed as a regionOfInterest so the
        // recognizer sees the sub-image at full resolution — which is the
        // entire point of tiling for tiny text.
        var offset = (x: 0.0, y: 0.0)
        var target = image
        if let region {
            let rect = CGRect(
                x: region.x.rounded(.down),
                y: region.y.rounded(.down),
                width: region.w.rounded(),
                height: region.h.rounded()
            )
            guard rect.width >= 1, rect.height >= 1, let cropped = image.cropping(to: rect) else {
                return []
            }
            target = cropped
            offset = (Double(rect.origin.x), Double(rect.origin.y))
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // UI labels must not be rewritten as prose.
        request.usesLanguageCorrection = false
        let source = region == nil ? "whole_frame" : "tile"
        return try recognizeText(in: target, request: request).compactMap { box in
            guard box.confidence >= 0.3 else { return nil }
            let text = box.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return VisionTextBox(text: text,
                rect: VisionRect(x: offset.x + box.rect.x, y: offset.y + box.rect.y, w: box.rect.w, h: box.rect.h),
                confidence: box.confidence, source: source)
        }
    }
}
#endif
