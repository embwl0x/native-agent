import Foundation
import CoreGraphics

// MARK: - ELEMENT LAYER (a): structure from pixels, no model
//
// Element-layer spike (a) v1 (docs/build_plans/native-look.md): colour-region
// growing alone produced 12 candidates in **1 ms** and recalled 8/11 targets —
// ALL filled borderless buttons (the case `VNDetectRectangles` missed
// entirely), ALL bordered fields, and the fill-contrast list rows. The misses
// were white-on-background rows, which is CORRECT behaviour for a colour
// heuristic and is what the y-band text clusterer exists for.
//
// The latency headroom is enormous (1 ms against a 150 ms/look budget), which
// is why the design layers text-banding and saliency on top instead of
// reaching for a CoreML detector. The detector stays contingent on MEASURED
// misses; it does not get to arrive on a hunch.

public struct VisionColorRegionConfig: Sendable, Equatable {
    /// Target sample count along the long axis. The scan is a COARSE GRID —
    /// this is what keeps it at ~1 ms on a 2560px frame.
    public let gridLongAxisSamples: Int
    /// Two colours within this squared RGB distance (channels 0…1) are "the
    /// same fill".
    public let colorTolerance: Double
    /// A region must differ from the background by at least this squared RGB
    /// distance to be a candidate at all.
    public let backgroundTolerance: Double
    /// Smallest candidate, as a fraction of frame area.
    public let minAreaFraction: Double
    /// Largest candidate, as a fraction of frame area — above this it is the
    /// window's own background or a full-bleed panel, not a control.
    public let maxAreaFraction: Double
    /// Smallest candidate in pixels on either axis.
    public let minSidePixels: Double
    /// Fraction of a candidate row/column that must match the seed colour for
    /// the region to absorb it. Below 1.0 on purpose — see the growth loop.
    public let growMatchFraction: Double
    /// Two candidates overlapping by at least this IoU are one candidate.
    public let dedupeIoU: Double
    /// Cap on emitted candidates; a texture-heavy frame (a game, a photo) can
    /// otherwise produce thousands. Reported when it bites — a silent cap
    /// reads as "that's all there was".
    public let maxCandidates: Int

    public init(
        gridLongAxisSamples: Int = 320,
        colorTolerance: Double = 0.02,
        backgroundTolerance: Double = 0.006,
        minAreaFraction: Double = 0.00015,
        maxAreaFraction: Double = 0.5,
        minSidePixels: Double = 8,
        growMatchFraction: Double = 0.65,
        dedupeIoU: Double = 0.55,
        maxCandidates: Int = 200
    ) {
        self.growMatchFraction = growMatchFraction
        self.gridLongAxisSamples = gridLongAxisSamples
        self.colorTolerance = colorTolerance
        self.backgroundTolerance = backgroundTolerance
        self.minAreaFraction = minAreaFraction
        self.maxAreaFraction = maxAreaFraction
        self.minSidePixels = minSidePixels
        self.dedupeIoU = dedupeIoU
        self.maxCandidates = maxCandidates
    }

    public static let `default` = VisionColorRegionConfig()
}

public struct VisionColorRegionResult: Sendable, Equatable {
    public let candidates: [VisionCandidate]
    /// The frame's dominant colour — the "background" every candidate differs
    /// from. Exposed because the disabled/greyed heuristic needs it.
    public let backgroundLuminance: Double
    /// True when `maxCandidates` bit. Never silent: a capped list that reads
    /// as complete is how "there are no more buttons" becomes a lie.
    public let capped: Bool

    public init(candidates: [VisionCandidate], backgroundLuminance: Double, capped: Bool) {
        self.candidates = candidates
        self.backgroundLuminance = backgroundLuminance
        self.capped = capped
    }
}

/// A frame's pixels, sampled once into a coarse grid. Shared by the region
/// grower and the state heuristics so a frame is decoded exactly once.
public struct VisionPixelGrid: Sendable {
    public let columns: Int
    public let rows: Int
    public let stepX: Double
    public let stepY: Double
    public let imageSize: VisionSize
    /// Row-major RGB triples, channels 0…1.
    public let samples: [SIMD3<Double>]

    public init(
        columns: Int,
        rows: Int,
        stepX: Double,
        stepY: Double,
        imageSize: VisionSize,
        samples: [SIMD3<Double>]
    ) {
        self.columns = columns
        self.rows = rows
        self.stepX = stepX
        self.stepY = stepY
        self.imageSize = imageSize
        self.samples = samples
    }

    public func color(column: Int, row: Int) -> SIMD3<Double> {
        samples[row * columns + column]
    }

    public func rect(fromColumn c0: Int, toColumn c1: Int, fromRow r0: Int, toRow r1: Int) -> VisionRect {
        let x = Double(c0) * stepX
        let y = Double(r0) * stepY
        let right = min(imageSize.width, Double(c1 + 1) * stepX)
        let bottom = min(imageSize.height, Double(r1 + 1) * stepY)
        return VisionRect(x: x, y: y, w: max(0, right - x), h: max(0, bottom - y))
    }

    /// Mean linear-ish luminance over an image-pixel rect (Rec. 709 weights on
    /// the sampled grid — good enough to tell a greyed control from a live one,
    /// which is all it is used for).
    public func meanLuminance(in rect: VisionRect) -> Double? {
        let c0 = max(0, Int(rect.x / stepX))
        let c1 = min(columns - 1, Int((rect.maxX - 1) / stepX))
        let r0 = max(0, Int(rect.y / stepY))
        let r1 = min(rows - 1, Int((rect.maxY - 1) / stepY))
        guard c0 <= c1, r0 <= r1 else { return nil }
        var total = 0.0
        var count = 0
        for row in r0...r1 {
            for column in c0...c1 {
                let rgb = color(column: column, row: row)
                total += 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return total / Double(count)
    }

    /// Luminance SPREAD (max − min) over an image-pixel rect. The greyed-out
    /// signal: a live caption has dark and light cells inside one small box, a
    /// greyed one has neither. See `VisionRoleGuess.disabledContrast`.
    public func luminanceSpread(in rect: VisionRect) -> Double? {
        let c0 = max(0, Int(rect.x / stepX))
        let c1 = min(columns - 1, Int((rect.maxX - 1) / stepX))
        let r0 = max(0, Int(rect.y / stepY))
        let r1 = min(rows - 1, Int((rect.maxY - 1) / stepY))
        guard c0 <= c1, r0 <= r1 else { return nil }
        var lowest = Double.greatestFiniteMagnitude
        var highest = -Double.greatestFiniteMagnitude
        for row in r0...r1 {
            for column in c0...c1 {
                let rgb = color(column: column, row: row)
                let luminance = 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
                lowest = min(lowest, luminance)
                highest = max(highest, luminance)
            }
        }
        guard highest >= lowest else { return nil }
        return highest - lowest
    }

    /// Decode a CGImage into the coarse grid. One decode per frame.
    public static func sample(
        image: CGImage,
        longAxisSamples: Int
    ) -> VisionPixelGrid? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let longAxis = max(width, height)
        let stride = max(1, Int((Double(longAxis) / Double(max(1, longAxisSamples))).rounded()))
        let columns = max(1, width / stride)
        let rows = max(1, height / stride)

        // Draw once into a known RGBA8 buffer: a CGImage can be any colour
        // space / bit depth / alpha layout, and reading `dataProvider` bytes
        // directly would be a silent misparse on the first frame that is not
        // what we assumed.
        let bytesPerRow = columns * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * rows)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: columns,
                      height: rows,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: space,
                      bitmapInfo: info
                  ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }
        guard drawn else { return nil }

        var samples = [SIMD3<Double>](repeating: .zero, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let offset = row * bytesPerRow + column * 4
                samples[row * columns + column] = SIMD3(
                    Double(buffer[offset]) / 255,
                    Double(buffer[offset + 1]) / 255,
                    Double(buffer[offset + 2]) / 255
                )
            }
        }
        return VisionPixelGrid(
            columns: columns,
            rows: rows,
            stepX: Double(width) / Double(columns),
            stepY: Double(height) / Double(rows),
            imageSize: VisionSize(width: Double(width), height: Double(height)),
            samples: samples
        )
    }
}

public enum VisionColorRegionLayer {
    static func distanceSquared(_ lhs: SIMD3<Double>, _ rhs: SIMD3<Double>) -> Double {
        let delta = lhs - rhs
        return (delta * delta).sum()
    }

    /// Coarse-grid scan → similar-colour box growth → dedupe. The spike's
    /// approach, ported properly.
    public static func candidates(
        grid: VisionPixelGrid,
        config: VisionColorRegionConfig = .default
    ) -> VisionColorRegionResult {
        let frameArea = grid.imageSize.width * grid.imageSize.height
        guard frameArea > 0 else {
            return VisionColorRegionResult(candidates: [], backgroundLuminance: 0, capped: false)
        }

        // 1. BACKGROUND = the most common quantized colour on the grid. Not
        //    "the corner pixel": a full-bleed image or a sidebar makes the
        //    corner a lie, and the modal colour degrades gracefully into "the
        //    biggest flat area" on a frame with no background at all.
        var histogram: [SIMD3<Int>: Int] = [:]
        for sample in grid.samples {
            let key = SIMD3(Int(sample.x * 16), Int(sample.y * 16), Int(sample.z * 16))
            histogram[key, default: 0] += 1
        }
        let dominant = histogram.max { lhs, rhs in
            lhs.value == rhs.value
                ? (lhs.key.x, lhs.key.y, lhs.key.z) > (rhs.key.x, rhs.key.y, rhs.key.z)
                : lhs.value < rhs.value
        }?.key ?? SIMD3(0, 0, 0)
        let background = SIMD3(
            (Double(dominant.x) + 0.5) / 16,
            (Double(dominant.y) + 0.5) / 16,
            (Double(dominant.z) + 0.5) / 16
        )
        let backgroundLuminance = 0.2126 * background.x + 0.7152 * background.y + 0.0722 * background.z

        // 2. GROW: every non-background cell seeds a rectangular region that
        //    expands while its neighbours keep the seed's colour. Rectangular
        //    (not free-form flood) on purpose — a control's ACTION POINT and
        //    its bounds have to be a box, and a box that grew to real edges is
        //    the bounds confidence signal.
        var visited = [Bool](repeating: false, count: grid.columns * grid.rows)
        var raw: [VisionCandidate] = []
        var capped = false

        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                let index = row * grid.columns + column
                if visited[index] { continue }
                let seed = grid.color(column: column, row: row)
                guard distanceSquared(seed, background) > config.backgroundTolerance else {
                    visited[index] = true
                    continue
                }

                var c0 = column, c1 = column, r0 = row, r1 = row
                // A candidate row/column is absorbed when MOST of it matches
                // the seed, not all of it. All-match was the first version and
                // it was wrong in the case that matters most: a filled button
                // with a caption. Growing down from the button's top edge, the
                // first row containing glyphs fails an all-match test, so the
                // region stops at the text and the emitted candidate is a
                // strip above the label instead of the button. Glyphs are a
                // MINORITY of a control's row; a real boundary (a border, the
                // window background) fails across the whole span at once and
                // still stops the growth.
                // A cell belongs to the region when it is BOTH close enough to
                // the seed AND closer to the seed than to the background.
                //
                // The second clause is not decoration. `colorTolerance` is an
                // absolute distance, and on a light UI the gap between a white
                // field and a light-grey window background (0.015 in squared
                // RGB) is SMALLER than a tolerance loose enough to survive
                // anti-aliasing (0.02) — so the absolute test alone let a white
                // field absorb the entire window and the field then vanished
                // through the max-area filter. Nearest-centroid is scale-free
                // and cannot make that mistake: a background-coloured cell is
                // by definition closest to the background.
                func belongs(_ column: Int, _ row: Int) -> Bool {
                    let cell = grid.color(column: column, row: row)
                    let toSeed = distanceSquared(cell, seed)
                    guard toSeed <= config.colorTolerance else { return false }
                    return toSeed < distanceSquared(cell, background)
                }
                func matchFraction(rowIndex r: Int, from a: Int, to b: Int) -> Double {
                    var matches = 0
                    for c in a...b where belongs(c, r) { matches += 1 }
                    return Double(matches) / Double(b - a + 1)
                }
                func matchFraction(columnIndex c: Int, from a: Int, to b: Int) -> Double {
                    var matches = 0
                    for r in a...b where belongs(c, r) { matches += 1 }
                    return Double(matches) / Double(b - a + 1)
                }
                func rowMatches(_ r: Int, from a: Int, to b: Int) -> Bool {
                    guard r >= 0, r < grid.rows else { return false }
                    return matchFraction(rowIndex: r, from: a, to: b) >= config.growMatchFraction
                }
                func columnMatches(_ c: Int, from a: Int, to b: Int) -> Bool {
                    guard c >= 0, c < grid.columns else { return false }
                    return matchFraction(columnIndex: c, from: a, to: b) >= config.growMatchFraction
                }
                var growing = true
                while growing {
                    growing = false
                    if columnMatches(c1 + 1, from: r0, to: r1) { c1 += 1; growing = true }
                    if columnMatches(c0 - 1, from: r0, to: r1) { c0 -= 1; growing = true }
                    if rowMatches(r1 + 1, from: c0, to: c1) { r1 += 1; growing = true }
                    if rowMatches(r0 - 1, from: c0, to: c1) { r0 -= 1; growing = true }
                }
                for r in r0...r1 {
                    for c in c0...c1 { visited[r * grid.columns + c] = true }
                }

                let rect = grid.rect(fromColumn: c0, toColumn: c1, fromRow: r0, toRow: r1)
                guard rect.w >= config.minSidePixels, rect.h >= config.minSidePixels else { continue }
                let areaFraction = rect.area / frameArea
                guard areaFraction >= config.minAreaFraction,
                      areaFraction <= config.maxAreaFraction else { continue }

                // BOUNDS CONFIDENCE: a region that stopped growing well inside
                // the frame, on all four sides, has real edges. One that ran
                // into the frame edge is a crop, and says so with less
                // confidence rather than the same confidence.
                let touchesEdge = c0 == 0 || r0 == 0 || c1 == grid.columns - 1 || r1 == grid.rows - 1
                let contrast = min(1, distanceSquared(seed, background) / 0.08)
                let boundsConfidence = (touchesEdge ? 0.45 : 0.75) + 0.2 * contrast
                let luminance = 0.2126 * seed.x + 0.7152 * seed.y + 0.0722 * seed.z
                raw.append(VisionCandidate(
                    rect: rect,
                    sources: [.colorRegion],
                    boundsConfidence: boundsConfidence,
                    fillLuminance: luminance
                ))
            }
        }

        // 3. DEDUPE, largest first: a bordered field yields both the border
        //    ring and its interior; the outer box is the control.
        var kept: [VisionCandidate] = []
        for candidate in raw.sorted(by: { $0.rect.area > $1.rect.area }) {
            let duplicate = kept.contains { existing in
                existing.rect.iou(candidate.rect) >= config.dedupeIoU
                    || candidate.rect.coverage(by: existing.rect) >= 0.9
            }
            if duplicate { continue }
            if kept.count >= config.maxCandidates { capped = true; break }
            kept.append(candidate)
        }

        return VisionColorRegionResult(
            candidates: kept.sorted(by: readingOrder),
            backgroundLuminance: backgroundLuminance,
            capped: capped
        )
    }

    /// Deterministic reading order. Two frames of the same scene must compile
    /// to the same rows in the same order or handles are not stable.
    static func readingOrder(_ lhs: VisionCandidate, _ rhs: VisionCandidate) -> Bool {
        if abs(lhs.rect.y - rhs.rect.y) > 2 { return lhs.rect.y < rhs.rect.y }
        if abs(lhs.rect.x - rhs.rect.x) > 2 { return lhs.rect.x < rhs.rect.x }
        return lhs.rect.area > rhs.rect.area
    }
}
