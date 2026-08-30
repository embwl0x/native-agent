import Foundation
import CoreGraphics
#if canImport(Vision)
import Vision
#endif

// MARK: - The TEXT layer
//
// Spike v0/v1 (docs/build_plans/native-look.md) settled this half already:
//   • whole-frame `VNRecognizeTextRequest(.accurate)` recovers ~99% of normal
//     UI text up to at least 2560p — 142/144 strings on a dense 13pt grid — in
//     ~30–65 ms warm (~250 ms cold, one-time Vision model load);
//   • a 3×3 overlapped TILING pass on the same frame returned 145/144 (dedup
//     noise, +1–2 real strings) for ~1.7× the latency.
//
// So tiling is a CONDITIONAL tool for genuinely tiny text, not a stage. v0's
// "1/9 at 2560" was a scene artifact (that scene's text was proportionally
// tiny), not a general OCR ceiling. Building the tiling pipeline as a default
// would buy ~nothing and cost latency on every look — the measurement is the
// reason this code has a `shouldTile` predicate instead of a tiling stage.

/// The seam. Real OCR is a `VisionTextLayer`; tests inject a stub so the
/// element/fusion layers are provable without Vision in the loop (they are
/// also exercised against REAL Vision output on rendered scenes — the stub is
/// for pinning fusion logic exactly, not for avoiding the real engine).
public protocol VisionTextRecognizing: Sendable {
    /// - Parameter region: the sub-rect of `image` to recognize, in image
    ///   pixel coordinates; nil = the whole frame. Returned rects are always
    ///   in WHOLE-IMAGE pixel coordinates regardless.
    func recognizeText(in image: CGImage, region: VisionRect?) throws -> [VisionTextBox]
}

extension VisionTextRecognizing {
    public func recognizeText(in image: CGImage) throws -> [VisionTextBox] {
        try recognizeText(in: image, region: nil)
    }
}

public struct VisionTextLayerConfig: Sendable, Equatable {
    /// Median text height BELOW this fraction of the frame height triggers the
    /// conditional tiling pass. 0.9% of a 1440-tall frame ≈ 13 px — right at
    /// the point where the v1 measurement stops being reassuring.
    public let tinyTextHeightFraction: Double
    /// …and an absolute floor, because a small window full of ordinary 13 px
    /// text is not tiny text; it is a small window.
    public let tinyTextHeightPixels: Double
    /// Tiles per axis for the conditional pass (v1 measured 3×3 overlapped).
    public let tileGrid: Int
    /// Fractional overlap between adjacent tiles, so a string straddling a
    /// tile seam is whole in at least one tile.
    public let tileOverlap: Double
    /// Two boxes this close (IoU) with the same text are the same string seen
    /// twice by two tiles.
    public let dedupeIoU: Double
    /// Optional canvas/HUD recovery. A whole-frame pass that sees only a few
    /// large labels can miss smaller status lines beside them while still
    /// suppressing ordinary tiny-text tiling. Zero keeps the measured general
    /// UI default unchanged; visual-surface perception enables a small bound.
    public let sparseRecoveryMaxBoxes: Int

    public init(
        tinyTextHeightFraction: Double = 0.009,
        tinyTextHeightPixels: Double = 12,
        tileGrid: Int = 3,
        tileOverlap: Double = 0.15,
        dedupeIoU: Double = 0.5,
        sparseRecoveryMaxBoxes: Int = 0
    ) {
        self.tinyTextHeightFraction = tinyTextHeightFraction
        self.tinyTextHeightPixels = tinyTextHeightPixels
        self.tileGrid = tileGrid
        self.tileOverlap = tileOverlap
        self.dedupeIoU = dedupeIoU
        self.sparseRecoveryMaxBoxes = max(0, sparseRecoveryMaxBoxes)
    }

    public static let `default` = VisionTextLayerConfig()
}

/// The result of a text pass, including WHETHER tiling fired — a caller (and a
/// latency budget) must be able to tell a 40 ms look from a 700 ms one.
public struct VisionTextLayerResult: Sendable, Equatable {
    public let boxes: [VisionTextBox]
    public let tiled: Bool
    /// Why tiling did or did not fire, in one phrase. Stated rather than
    /// inferred: "no tiny text (median 18.0px)" vs "tiny text (median 7.0px)".
    public let tilingReason: String
    /// Tile OCR passes that threw. A failed tile silently dropping text made
    /// tiny-text recovery non-deterministic and unreportable (gpt-5.5 review);
    /// the failure count rides out so the compiler can say so.
    public let tileFailures: Int

    public init(boxes: [VisionTextBox], tiled: Bool, tilingReason: String, tileFailures: Int = 0) {
        self.boxes = boxes
        self.tiled = tiled
        self.tilingReason = tilingReason
        self.tileFailures = tileFailures
    }
}

public enum VisionTextLayer {
    /// The conditional-tiling decision, isolated so it can be pinned without
    /// running Vision at all.
    ///
    /// Returns nil when tiling should NOT fire. The whole point of the v1
    /// measurement is that this returns nil for typical UI.
    public static func tilingDecision(
        boxes: [VisionTextBox],
        imageHeight: Double,
        config: VisionTextLayerConfig = .default
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
        let threshold = max(config.tinyTextHeightPixels, imageHeight * config.tinyTextHeightFraction)
        let rounded = (median * 10).rounded() / 10
        if median < threshold {
            return (true, "tiny text (median \(rounded)px < \((threshold * 10).rounded() / 10)px)")
        }
        return (false, "no tiny text (median \(rounded)px)")
    }

    /// Tile rects for the conditional pass, in image pixel coordinates.
    public static func tiles(
        imageSize: VisionSize,
        config: VisionTextLayerConfig = .default
    ) -> [VisionRect] {
        let n = max(1, config.tileGrid)
        let tileW = imageSize.width / Double(n)
        let tileH = imageSize.height / Double(n)
        let padX = tileW * config.tileOverlap
        let padY = tileH * config.tileOverlap
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
        imageSize: VisionSize,
        config: VisionTextLayerConfig
    ) -> [VisionRect] {
        let cap = config.sparseRecoveryMaxBoxes
        guard cap > 0, !boxes.isEmpty, boxes.count <= cap,
              imageSize.width > 0, imageSize.height > 0 else { return [] }
        var regions: [VisionRect] = []
        for box in boxes.prefix(cap) {
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
        _ boxes: [VisionTextBox],
        config: VisionTextLayerConfig = .default
    ) -> [VisionTextBox] {
        var kept: [VisionTextBox] = []
        for box in boxes.sorted(by: {
            $0.confidence == $1.confidence
                ? geometryPrecedes($0, $1)
                : $0.confidence > $1.confidence
        }) {
            let duplicate = kept.contains { existing in
                existing.text == box.text && existing.rect.iou(box.rect) >= config.dedupeIoU
            }
            if !duplicate { kept.append(box) }
        }
        // Reading order: top-to-bottom, then left-to-right. Deterministic
        // output is a contract — the same frame must compile to the same
        // handles in the same order, in this launch and the next.
        // A tolerance inside a pairwise comparator is not transitive: nearby
        // A/B and B/C can each tie while A/C do not. Anchor each 1px group to
        // its first coordinate after strict sorting instead, then order groups.
        let rows = toleranceGroups(kept.sorted(by: geometryPrecedes), coordinate: { $0.rect.y })
        return rows.flatMap { row in
            let byX = row.sorted {
                $0.rect.x == $1.rect.x ? geometryPrecedes($0, $1) : $0.rect.x < $1.rect.x
            }
            return toleranceGroups(byX, coordinate: { $0.rect.x }).flatMap { column in
                column.sorted {
                    $0.text == $1.text ? geometryPrecedes($0, $1) : $0.text < $1.text
                }
            }
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

    private static func toleranceGroups(
        _ boxes: [VisionTextBox],
        coordinate: (VisionTextBox) -> Double
    ) -> [[VisionTextBox]] {
        var groups: [[VisionTextBox]] = []
        for box in boxes {
            if let anchor = groups.last?.first, coordinate(box) - coordinate(anchor) <= 1 {
                groups[groups.count - 1].append(box)
            } else {
                groups.append([box])
            }
        }
        return groups
    }

    /// Whole-frame pass, plus a tiling pass ONLY when the text is genuinely
    /// tiny. Foreground-covered boxes do not trigger expensive refinement of
    /// another app's text. They remain in the result for whole-frame redaction
    /// context; the compiler owns exclusion from the published percept.
    public static func recognize(
        image: CGImage,
        using recognizer: some VisionTextRecognizing,
        config: VisionTextLayerConfig = .default,
        ignoredForRefinement: [VisionRect] = []
    ) throws -> VisionTextLayerResult {
        try Task.checkCancellation()
        let size = VisionSize(width: Double(image.width), height: Double(image.height))
        let whole = try recognizer.recognizeText(in: image, region: nil)
        try Task.checkCancellation()
        let relevant = whole.filter { box in
            !ignoredForRefinement.contains { $0.intersection(box.rect).area > 0 }
        }
        let decision = tilingDecision(boxes: relevant, imageHeight: size.height, config: config)
        let exclusionNote = relevant.count == whole.count
            ? "" : "; foreground-covered text ignored for refinement"
        let regions: [VisionRect]
        let reason: String
        if decision.shouldTile {
            regions = tiles(imageSize: size, config: config)
            reason = decision.reason + exclusionNote
        } else {
            regions = sparseRecoveryRegions(boxes: relevant, imageSize: size, config: config)
            reason = regions.isEmpty
                ? decision.reason + exclusionNote
                : "sparse text recovery (\(relevant.count) relevant whole-frame box(es), \(regions.count) local region(s))" + exclusionNote
        }
        guard !regions.isEmpty else {
            return VisionTextLayerResult(
                boxes: dedupe(whole, config: config),
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
            boxes: dedupe(all, config: config),
            tiled: true,
            tilingReason: reason,
            tileFailures: tileFailures
        )
    }
}

// MARK: - The real engine

#if canImport(Vision)
/// `VNRecognizeTextRequest(.accurate)` — the measured path.
public struct VisionKitTextRecognizer: VisionTextRecognizing {
    public let minimumConfidence: Double
    /// `usesLanguageCorrection` is OFF: UI strings are labels, not prose, and
    /// language correction rewrites things like "AC" and "0x1F" into words.
    public let usesLanguageCorrection: Bool

    public init(minimumConfidence: Double = 0.3, usesLanguageCorrection: Bool = false) {
        self.minimumConfidence = minimumConfidence
        self.usesLanguageCorrection = usesLanguageCorrection
    }

    public func recognizeText(in image: CGImage, region: VisionRect?) throws -> [VisionTextBox] {
        let width = Double(image.width)
        let height = Double(image.height)
        // A tile is cropped rather than passed as a regionOfInterest so the
        // recognizer sees the sub-image at full resolution — which is the
        // entire point of tiling for tiny text.
        var offset = (x: 0.0, y: 0.0)
        var target = image
        var targetWidth = width
        var targetHeight = height
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
            targetWidth = Double(cropped.width)
            targetHeight = Double(cropped.height)
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = usesLanguageCorrection
        let handler = VNImageRequestHandler(cgImage: target, options: [:])
        try handler.perform([request])

        let source = region == nil ? "whole_frame" : "tile"
        return (request.results ?? []).compactMap { observation -> VisionTextBox? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let confidence = Double(candidate.confidence)
            guard confidence >= minimumConfidence else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // Vision boxes are normalized with a BOTTOM-LEFT origin; every
            // rect in this module is top-left image pixels. Convert once, here.
            let box = observation.boundingBox
            let rect = VisionRect(
                x: offset.x + Double(box.minX) * targetWidth,
                y: offset.y + (1 - Double(box.maxY)) * targetHeight,
                w: Double(box.width) * targetWidth,
                h: Double(box.height) * targetHeight
            )
            return VisionTextBox(text: text, rect: rect, confidence: confidence, source: source)
        }
    }
}
#endif

/// A deterministic recognizer for tests and for replaying a captured text
/// layer. Region-aware so the tiling path is exercisable without Vision.
public struct VisionStaticTextRecognizer: VisionTextRecognizing {
    public let boxes: [VisionTextBox]
    /// Boxes returned ONLY when a region (tile) is requested — how a test
    /// models "tiling recovered strings the whole-frame pass missed".
    public let tileOnlyBoxes: [VisionTextBox]

    public init(boxes: [VisionTextBox], tileOnlyBoxes: [VisionTextBox] = []) {
        self.boxes = boxes
        self.tileOnlyBoxes = tileOnlyBoxes
    }

    public func recognizeText(in image: CGImage, region: VisionRect?) throws -> [VisionTextBox] {
        guard let region else { return boxes }
        return (boxes + tileOnlyBoxes).filter { $0.rect.coverage(by: region) > 0.5 }
            .map { VisionTextBox(text: $0.text, rect: $0.rect, confidence: $0.confidence, source: "tile") }
    }
}
