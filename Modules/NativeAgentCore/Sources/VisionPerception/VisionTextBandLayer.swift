import Foundation

// MARK: - ELEMENT LAYER (b): rows by Y-BAND clustering
//
// The element-layer spike close-out (v2) earned this the hard way. Clustering
// OCR text by LEFT-X + pitch recovered the wrong thing: on a synthetic list it
// grouped the right-hand VALUE COLUMN ("12 pts", "9 pts", …) into "rows" and
// missed the actual rows, because each row's main text merged differently in
// OCR and never shared a left edge.
//
//   "Rows should be formed by Y-BAND grouping — cluster ALL text boxes by
//    vertical overlap into bands, then a band with ≥2 texts and repeated pitch
//    across ≥3 bands = list rows, row rect = band bounding box. Column-first
//    grouping is the wrong primitive."
//
// That is what this file implements. It is the half of the element layer that
// covers what a colour heuristic correctly cannot see: white-on-white rows,
// which have no fill contrast at all and are visible only as REPETITION.

public struct VisionTextBandConfig: Sendable, Equatable {
    /// Two text boxes belong to the same band when their vertical extents
    /// overlap by at least this fraction of the SHORTER box.
    public let verticalOverlapFraction: Double
    /// A band needs at least this many texts to be a row candidate (a lone
    /// heading is not a list row).
    public let minTextsPerBand: Int
    /// Repeated pitch has to be visible across at least this many bands —
    /// three is the smallest number that can show a REPEAT rather than a gap.
    public let minRepeatedBands: Int
    /// Consecutive band pitches within this fraction of each other count as
    /// "the same pitch".
    public let pitchTolerance: Double
    /// A row candidate's rect is the band's bounding box, widened to the
    /// common left/right extent of the run by this padding fraction of the
    /// band height — a row's hit area is not the text's hit area.
    public let bandPaddingFraction: Double

    public init(
        verticalOverlapFraction: Double = 0.5,
        minTextsPerBand: Int = 2,
        minRepeatedBands: Int = 3,
        pitchTolerance: Double = 0.28,
        bandPaddingFraction: Double = 0.35
    ) {
        self.verticalOverlapFraction = verticalOverlapFraction
        self.minTextsPerBand = minTextsPerBand
        self.minRepeatedBands = minRepeatedBands
        self.pitchTolerance = pitchTolerance
        self.bandPaddingFraction = bandPaddingFraction
    }

    public static let `default` = VisionTextBandConfig()
}

/// A horizontal band of text — the primitive rows are built from.
public struct VisionTextBand: Sendable, Equatable {
    public let rect: VisionRect
    public let texts: [VisionTextBox]

    public init(rect: VisionRect, texts: [VisionTextBox]) {
        self.rect = rect
        self.texts = texts
    }
}

public enum VisionTextBandLayer {
    /// Cluster ALL text boxes by vertical overlap. Column-agnostic by
    /// construction — this is the primitive the close-out named.
    public static func bands(
        from boxes: [VisionTextBox],
        config: VisionTextBandConfig = .default
    ) -> [VisionTextBand] {
        let ordered = boxes.sorted { $0.rect.y < $1.rect.y }
        var bands: [[VisionTextBox]] = []
        for box in ordered {
            let index = bands.firstIndex { band in
                guard let rect = bandRect(band) else { return false }
                return overlapFraction(rect, box.rect) >= config.verticalOverlapFraction
            }
            if let index {
                bands[index].append(box)
            } else {
                bands.append([box])
            }
        }
        return bands.compactMap { band in
            guard let rect = bandRect(band) else { return nil }
            return VisionTextBand(
                rect: rect,
                texts: band.sorted { $0.rect.x < $1.rect.x }
            )
        }.sorted { $0.rect.y < $1.rect.y }
    }

    static func bandRect(_ boxes: [VisionTextBox]) -> VisionRect? {
        guard var rect = boxes.first?.rect else { return nil }
        for box in boxes.dropFirst() { rect = rect.union(box.rect) }
        return rect
    }

    /// Vertical overlap as a fraction of the SHORTER extent. Using the shorter
    /// one is what lets a tall row label and a short badge in the same row
    /// cluster together.
    static func overlapFraction(_ lhs: VisionRect, _ rhs: VisionRect) -> Double {
        let top = max(lhs.y, rhs.y)
        let bottom = min(lhs.maxY, rhs.maxY)
        let overlap = bottom - top
        guard overlap > 0 else { return 0 }
        let shorter = min(lhs.h, rhs.h)
        guard shorter > 0 else { return 0 }
        return overlap / shorter
    }

    /// Bands with ≥ `minTextsPerBand` texts AND a pitch that repeats across
    /// ≥ `minRepeatedBands` bands ⇒ list rows. Row rect = band bounding box,
    /// padded vertically and widened to the run's common horizontal extent.
    ///
    /// The pitch requirement is doing real work: two adjacent labelled fields
    /// are also two multi-text bands, and without a REPEAT they are not a list.
    public static func rowCandidates(
        from boxes: [VisionTextBox],
        config: VisionTextBandConfig = .default
    ) -> [VisionCandidate] {
        let all = bands(from: boxes, config: config)
        let multi = all.filter { $0.texts.count >= config.minTextsPerBand }
        guard multi.count >= config.minRepeatedBands else { return [] }

        // Longest run of consecutive bands whose centre-to-centre pitch stays
        // within tolerance. A list's rows are evenly spaced; a stack of
        // unrelated multi-text bands is not.
        var bestRun: [VisionTextBand] = []
        var index = 0
        while index < multi.count - 1 {
            var run = [multi[index], multi[index + 1]]
            var pitch = multi[index + 1].rect.centerY - multi[index].rect.centerY
            var cursor = index + 1
            while cursor < multi.count - 1 {
                let next = multi[cursor + 1].rect.centerY - multi[cursor].rect.centerY
                guard pitch > 0, abs(next - pitch) <= pitch * config.pitchTolerance else { break }
                run.append(multi[cursor + 1])
                pitch = (pitch + next) / 2
                cursor += 1
            }
            if run.count > bestRun.count { bestRun = run }
            index = max(index + 1, cursor)
        }
        guard bestRun.count >= config.minRepeatedBands else { return [] }

        let left = bestRun.map(\.rect.x).min() ?? 0
        let right = bestRun.map(\.rect.maxX).max() ?? 0
        return bestRun.map { band in
            let pad = band.rect.h * config.bandPaddingFraction
            let rect = VisionRect(
                x: left,
                y: max(0, band.rect.y - pad),
                w: max(0, right - left),
                h: band.rect.h + pad * 2
            )
            // Bounds confidence is deliberately MODEST: a row's true hit area
            // extends past its text and we are inferring the edges from the
            // run, not seeing them. Saying 0.9 here would be the fabricated
            // certainty the contract forbids.
            return VisionCandidate(
                rect: rect,
                sources: [.textBand],
                boundsConfidence: 0.55,
                fillLuminance: nil
            )
        }
    }
}
