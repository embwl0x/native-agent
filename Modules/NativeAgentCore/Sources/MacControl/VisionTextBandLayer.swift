import Foundation
// Blueprint: | `VisionTextBandLayer.swift` | `VisionTextBand`, `VisionTextBandLayer` |

// Vertical overlap forms text bands; repeated pitch across multi-text bands
// identifies rows even when their pixels have no fill contrast.

/// A horizontal band of text — the primitive rows are built from.
public struct VisionTextBand: Sendable, Equatable {
    public internal(set) var rect: VisionRect
    public internal(set) var texts: [VisionTextBox]

    public init(rect: VisionRect, texts: [VisionTextBox]) {
        self.rect = rect
        self.texts = texts
    }
}

public enum VisionTextBandLayer {
    /// Two text boxes belong to the same band when their vertical extents
    /// overlap by at least this fraction of the SHORTER box.
    private static let verticalOverlapFraction: Double = 0.5
    /// A band needs at least this many texts to be a row candidate (a lone
    /// heading is not a list row).
    private static let minTextsPerBand: Int = 2
    /// Repeated pitch has to be visible across at least this many bands —
    /// three is the smallest number that can show a REPEAT rather than a gap.
    private static let minRepeatedBands: Int = 3
    /// Consecutive band pitches within this fraction of each other count as
    /// "the same pitch".
    private static let pitchTolerance: Double = 0.28
    /// A row candidate's rect is the band's bounding box, widened to the
    /// common left/right extent of the run by this padding fraction of the
    /// band height — a row's hit area is not the text's hit area.
    private static let bandPaddingFraction: Double = 0.35

    /// Cluster all text boxes by vertical overlap, independently of columns.
    public static func bands(
        from boxes: [VisionTextBox]
    ) -> [VisionTextBand] {
        let ordered = boxes.sorted { $0.rect.y < $1.rect.y }
        var bands: [VisionTextBand] = []
        for box in ordered {
            let index = bands.firstIndex { band in
                overlapFraction(band.rect, box.rect) >= verticalOverlapFraction
            }
            if let index {
                bands[index].rect = bands[index].rect.union(box.rect)
                bands[index].texts.append(box)
            } else {
                bands.append(VisionTextBand(rect: box.rect, texts: [box]))
            }
        }
        for index in bands.indices { bands[index].texts.sort { $0.rect.x < $1.rect.x } }
        return bands.sorted { $0.rect.y < $1.rect.y }
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
        from boxes: [VisionTextBox]
    ) -> [VisionCandidate] {
        let all = bands(from: boxes)
        let multi = all.filter { $0.texts.count >= minTextsPerBand }
        guard multi.count >= minRepeatedBands else { return [] }

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
                guard pitch > 0, abs(next - pitch) <= pitch * pitchTolerance else { break }
                run.append(multi[cursor + 1])
                pitch = (pitch + next) / 2
                cursor += 1
            }
            if run.count > bestRun.count { bestRun = run }
            index = max(index + 1, cursor)
        }
        guard bestRun.count >= minRepeatedBands else { return [] }

        let left = bestRun.map(\.rect.x).min() ?? 0
        let right = bestRun.map(\.rect.maxX).max() ?? 0
        return bestRun.map { band in
            let pad = band.rect.h * bandPaddingFraction
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
