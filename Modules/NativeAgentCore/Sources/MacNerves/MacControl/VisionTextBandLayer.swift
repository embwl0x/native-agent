import Foundation
// Blueprint: | `VisionTextBandLayer.swift` | `VisionTextBand`, `VisionTextBandLayer` |

// Repeated text pitch identifies rows even when fill contrast is absent.

public struct VisionTextBand: Sendable, Equatable {
    public internal(set) var rect: VisionRect
    public internal(set) var texts: [VisionTextBox]

    public init(rect: VisionRect, texts: [VisionTextBox]) {
        self.rect = rect
        self.texts = texts
    }
}

public enum VisionTextBandLayer {
    /// Measure vertical overlap against the shorter box so differently sized text can share a band.
    private static let verticalOverlapFraction: Double = 0.5
    /// Require multiple texts so a lone heading cannot become a row.
    private static let minTextsPerBand: Int = 2
    /// Three bands are the minimum evidence of repeated pitch rather than one gap.
    private static let minRepeatedBands: Int = 3
    /// Pitch tolerance permits ordinary layout variation without treating unrelated bands as a list.
    private static let pitchTolerance: Double = 0.28
    /// Widen rows to the run’s common extent because a row’s hit area exceeds its text.
    private static let bandPaddingFraction: Double = 0.35

    /// Cluster independently of columns so aligned labels and values can form rows.
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

    /// Shorter-extent overlap keeps tall labels and short badges in the same row.
    static func overlapFraction(_ lhs: VisionRect, _ rhs: VisionRect) -> Double {
        let top = max(lhs.y, rhs.y)
        let bottom = min(lhs.maxY, rhs.maxY)
        let overlap = bottom - top
        guard overlap > 0 else { return 0 }
        let shorter = min(lhs.h, rhs.h)
        guard shorter > 0 else { return 0 }
        return overlap / shorter
    }

    /// Require repeated pitch across multi-text bands; adjacent labeled fields alone are not a list.
    public static func rowCandidates(
        from boxes: [VisionTextBox]
    ) -> [VisionCandidate] {
        let all = bands(from: boxes)
        let multi = all.filter { $0.texts.count >= minTextsPerBand }
        guard multi.count >= minRepeatedBands else { return [] }

        // Use the longest regular-pitch run to distinguish lists from unrelated text stacks.
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
            // Inferred row edges need modest confidence because text does not reveal the complete hit area.
            return VisionCandidate(
                rect: rect,
                sources: [.textBand],
                boundsConfidence: 0.55,
                fillLuminance: nil
            )
        }
    }
}
