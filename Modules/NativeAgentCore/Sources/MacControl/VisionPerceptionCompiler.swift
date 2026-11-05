import Foundation
import CoreGraphics
import NativeAgentCore
import PersistenceCore
// Blueprint: | `VisionPerceptionCompiler.swift` | `VisionPerceptionError`, `VisionRowDraft`, `VisionPerceptionCompiler` |

// Pixel evidence compiles without owning capture or input, preserving the perception/effect boundary.

public enum VisionPerceptionError: Error, LocalizedError {
    case undecodableImage

    public var errorDescription: String? {
        switch self {
        case .undecodableImage:
            return "The captured frame could not be decoded into pixels."
        }
    }
}

struct VisionRowDraft {
    let candidate: VisionCandidate
    let guess: VisionRoleGuess.Guess
    let containedText: [(box: VisionTextBox, redacted: VisionRedactedText)]
    let label: VisionRedactedText?
    let fill: Double?
    let captionContrast: Double?
}

public struct VisionPerceptionCompiler: Sendable {
    private let mergeIoU = 0.6
    private let glyphRunIoU = 0.5
    private let glyphInsetCoverage = 0.8
    private let containmentFraction = 0.6
    private let readoutProminence = 1.25
    private let maxReadouts = 8
    private let maxAffordances = 60

    public init() {}

    #if canImport(Vision)
    public func compile(
        image: CGImage,
        excludedRegions: [VisionRect] = []
    ) throws -> VisionPercept {
        try Task.checkCancellation()
        let imageSize = VisionSize(width: Double(image.width), height: Double(image.height))
        // Exclude foreground-window pixels before fusion and temporal identity; they are not evidence about the captured app.
        func isVisible(_ rect: VisionRect) -> Bool {
            !excludedRegions.contains { $0.intersection(rect).area > 0 }
        }
        guard let grid = VisionPixelGrid.sample(
            image: image,
            longAxisSamples: VisionColorRegionLayer.gridLongAxisSamples
        ) else { throw VisionPerceptionError.undecodableImage }
        try Task.checkCancellation()

        var notes: [String] = []

        // Redact before any OCR string can enter a label, readout, fingerprint or glance.
        let textResult = try VisionTextLayer.recognize(
            image: image, using: VisionKitTextRecognizer(),
            ignoredForRefinement: excludedRegions
        )
        try Task.checkCancellation()
        if textResult.tileFailures > 0 {
            notes.append(
                "\(textResult.tileFailures) OCR tile pass(es) failed and their text was not "
                    + "recovered — tiny-text recall may be reduced this frame"
            )
        }
        let allRedactedTexts = VisionTextRedaction.redact(
            boxes: textResult.boxes, imageSize: imageSize
        )
        // Preserve whole-frame secret-caption context before excluding foreign-window text.
        let texts = Array(zip(textResult.boxes, allRedactedTexts)).filter { isVisible($0.0.rect) }
        let visibleTextBoxes = texts.map(\.0)
        let redactedTexts = texts.map(\.1)
        if redactedTexts.contains(where: \.secret) {
            notes.append("\(redactedTexts.filter(\.secret).count) recognized string(s) redacted")
        }

        let colorResult = VisionColorRegionLayer.candidates(grid: grid)
        if colorResult.capped {
            notes.append("colour-region layer hit its \(VisionColorRegionLayer.maxCandidates)-candidate cap")
        }
        let bandCandidates = VisionTextBandLayer.rowCandidates(
            from: visibleTextBoxes
        )

        // Regions inside recognized text are glyph ink, not controls; otherwise a letter’s enclosed counter can become a guessed checkbox.
        let colorCandidates = colorResult.candidates.filter { candidate in
            isVisible(candidate.rect) && !visibleTextBoxes.contains { box in
                box.rect.iou(candidate.rect) >= glyphRunIoU
                    || candidate.rect.coverage(by: box.rect) >= glyphInsetCoverage
            }
        }

        var candidates = merge(colorCandidates + bandCandidates.filter { isVisible($0.rect) })

        // Saliency adds only candidates absent from text and colour layers.
        try Task.checkCancellation()
        do {
            let regions = try VisionKitSalienceProvider().salientRegions(in: image).filter { isVisible($0.rect) }
            try Task.checkCancellation()
            candidates = VisionSaliencyLayer.fold(
                salient: regions, into: candidates, imageSize: imageSize
            )
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            // Saliency failure is a named gap while sibling evidence survives; cancellation forbids publishing the frame.
            notes.append("saliency layer failed (\(error.localizedDescription)); controls only it would find were not looked for")
        }
        candidates = candidates.filter { isVisible($0.rect) }
        if candidates.count > maxAffordances {
            notes.append(
                "\(candidates.count - maxAffordances) candidate(s) beyond the "
                    + "\(maxAffordances) cap were dropped"
            )
            candidates = Array(candidates.prefix(maxAffordances))
        }

        let drafts: [VisionRowDraft] = candidates.map { candidate in
            let contained = texts.filter {
                $0.0.rect.coverage(by: candidate.rect) >= containmentFraction
            }.map { (box: $0.0, redacted: $0.1) }
            let guess = VisionRoleGuess.guess(VisionRoleGuess.Inputs(
                rect: candidate.rect,
                imageSize: imageSize,
                sources: candidate.sources,
                containedText: contained.map(\.box)
            ))
            // Only approved clear text can seed labels or fingerprints; a digest-derived handle would still encode the secret.
            let visible = contained.filter { !$0.redacted.secret }
                .sorted { $0.box.rect.x < $1.box.rect.x }
                .map(\.redacted.raw)
            let label: VisionRedactedText?
            if visible.isEmpty {
                label = contained.isEmpty ? nil : contained.first?.redacted
            } else {
                let joined = visible.joined(separator: " ")
                label = VisionRedactedText(
                    raw: joined, json: .string(joined)
                )
            }
            let fill = candidate.fillLuminance ?? grid.meanLuminance(in: candidate.rect)
            // One live caption provides contrast evidence even if other runs are muted.
            let captionContrast = contained.isEmpty
                ? nil
                : contained.compactMap { grid.luminanceSpread(in: $0.box.rect) }.max()
            return VisionRowDraft(
                candidate: candidate,
                guess: guess,
                containedText: contained,
                label: label,
                fill: fill,
                captionContrast: captionContrast
            )
        }

        let rowFills = drafts.filter { $0.guess.role == VisionRoleGuess.row }
            .compactMap(\.fill).sorted()
        let rowFillBaseline: Double? = rowFills.count >= 2 ? rowFills[rowFills.count / 2] : nil

        // Retain each row’s abstention reason rather than dropping uncertainty.
        let abstainReasons = abstain(drafts.map { ($0.candidate.rect, $0.guess.role, $0.label?.display) })

        // Token collisions must lower confidence, including collisions between distinct hashes.
        let tokens = drafts.map { draft in
            VisionHandles.token(fingerprint: VisionHandles.fingerprint(
                roleGuess: draft.guess.role,
                label: draft.label?.display,
                rect: draft.candidate.rect,
                imageSize: imageSize
            ))
        }
        let tokenCounts = tokens.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }

        // Keep target and state confidence separate so one cannot imply certainty about another.
        var rows: [VisionAffordanceRow] = []
        for (index, draft) in drafts.enumerated() {
            let state = VisionRoleGuess.stateGuess(
                role: draft.guess.role,
                fillLuminance: draft.fill,
                captionContrast: draft.captionContrast,
                backgroundLuminance: colorResult.backgroundLuminance,
                rowFillBaseline: rowFillBaseline
            )
            let textConfidence = draft.containedText.map(\.box.confidence).max() ?? 0
            let ambiguous = abstainReasons[index]
            let target = targetPrior(
                bounds: draft.candidate.boundsConfidence,
                role: draft.guess.confidence,
                textConfidence: textConfidence,
                hasLabel: draft.label?.display?.isEmpty == false,
                salience: draft.candidate.salience,
                ambiguous: ambiguous != nil,
                tokenCollision: (tokenCounts[tokens[index]] ?? 0) > 1
            )
            rows.append(VisionAffordanceRow(
                roleGuess: draft.guess.role,
                label: draft.label,
                rect: draft.candidate.rect,
                confidence: VisionConfidence(
                    bounds: draft.candidate.boundsConfidence,
                    target: target
                ),
                state: state,
                evidence: draft.candidate.sources,
                ambiguous: ambiguous,
                destructiveRisk: VisionRoleGuess.isDestructive(label: draft.label?.display ?? ""),
                salience: draft.candidate.salience,
                visualContrast: draft.fill.map { abs($0 - colorResult.backgroundLuminance) },
                visualColor: draft.candidate.fillColor?.name,
                visualShape: draft.candidate.visualShape
            ))
        }

        // Rank standalone unclaimed text by prominence as the pixel counterpart to AX readouts.
        let readoutsAll = self.readouts(
            texts: texts,
            claimed: drafts.flatMap { $0.containedText.map(\.box.rect) },
            imageSize: imageSize
        )
        let readouts = Array(readoutsAll.prefix(maxReadouts))

        try Task.checkCancellation()
        return VisionPercept(
            rows: rows,
            readouts: readouts,
            frameSize: imageSize,
            textTiled: textResult.tiled,
            textTilingReason: textResult.tilingReason,
            recognizedStrings: visibleTextBoxes.count,
            recognizedText: zip(redactedTexts, visibleTextBoxes).map {
                VisionRecognizedText(text: $0.0, confidence: VisionConfidence.clamp($0.1.confidence), rect: $0.1.rect)
            },
            notes: notes
        )
    }

    #endif

    // MARK: - Fusion helpers

    /// Merge largest first to retain observed edges and union provenance for corroboration.
    func merge(_ candidates: [VisionCandidate]) -> [VisionCandidate] {
        var kept: [VisionCandidate] = []
        for candidate in candidates.sorted(by: { $0.rect.area > $1.rect.area }) {
            if let index = kept.firstIndex(where: { $0.rect.iou(candidate.rect) >= mergeIoU }) {
                var merged = kept[index]
                for source in candidate.sources {
                    merged = merged.adding(source: source, salience: candidate.salience)
                }
                kept[index] = VisionCandidate(
                    rect: merged.rect,
                    sources: merged.sources,
                    // Cap corroboration so two weak signals cannot manufacture certainty.
                    boundsConfidence: min(0.9, max(merged.boundsConfidence, candidate.boundsConfidence) + 0.08),
                    fillLuminance: merged.fillLuminance ?? candidate.fillLuminance,
                    salience: max(merged.salience, candidate.salience),
                    fillColor: merged.fillColor ?? candidate.fillColor,
                    visualShape: merged.visualShape ?? candidate.visualShape
                )
            } else {
                kept.append(candidate)
            }
        }
        return VisionColorRegionLayer.readingOrder(kept)
    }

    /// Abstain on both rows when each action point falls inside the other; a one-sided verdict would silently elect a winner. Partial overlap alone is valid,
    /// as for a button inside a list row.
    func abstain(_ items: [(rect: VisionRect, role: String, label: String?)]) -> [Int: String] {
        var out: [Int: String] = [:]
        for index in items.indices {
            let item = items[index]
            // Weak unlabeled regions need their own abstention before reaching an actuator.
            if item.role == VisionRoleGuess.unknown, item.label?.isEmpty != false {
                out[index] = "unlabeled region with no role guess — not separately addressable"
            }
        }
        for lhs in items.indices {
            guard VisionRoleGuess.actionable.contains(items[lhs].role) else { continue }
            for rhs in items.indices where rhs > lhs {
                guard VisionRoleGuess.actionable.contains(items[rhs].role) else { continue }
                let a = items[lhs].rect
                let b = items[rhs].rect
                let aPointInB = b.intersection(VisionRect(x: a.centerX, y: a.centerY, w: 1, h: 1)).area > 0
                let bPointInA = a.intersection(VisionRect(x: b.centerX, y: b.centerY, w: 1, h: 1)).area > 0
                guard aPointInB, bPointInA else { continue }
                let reason = "overlapping candidate — action points coincide; targets are not separable"
                out[lhs] = out[lhs] ?? reason
                out[rhs] = out[rhs] ?? reason
            }
        }
        return out
    }

    /// Bounds dominate target confidence; hard abstention caps cannot be outweighed by attractive scores elsewhere.
    func targetPrior(
        bounds: Double,
        role: Double,
        textConfidence: Double,
        hasLabel: Bool,
        salience: Double,
        ambiguous: Bool,
        tokenCollision: Bool
    ) -> Double {
        var value = 0.45 * bounds + 0.3 * role + 0.15 * (hasLabel ? textConfidence : 0.1)
            + 0.1 * salience
        if !hasLabel { value *= 0.8 }
        if tokenCollision { value = min(value, 0.5) }
        if ambiguous { value = min(value, 0.25) }
        return value
    }

    /// Standalone values need prominence ranking and bounds even after source redaction.
    func readouts(
        texts: [(VisionTextBox, VisionRedactedText)],
        claimed: [VisionRect],
        imageSize: VisionSize
    ) -> [VisionReadoutRow] {
        let heights = texts.map(\.0.rect.h).filter { $0 > 0 }.sorted()
        guard !heights.isEmpty else { return [] }
        let median = heights[heights.count / 2]
        let free = texts.filter { entry in
            !claimed.contains { entry.0.rect.coverage(by: $0) >= containmentFraction }
        }
        let prominent = free.filter { $0.0.rect.h >= median * readoutProminence }
        return prominent
            .sorted { lhs, rhs in
                if abs(lhs.0.rect.h - rhs.0.rect.h) > 0.5 { return lhs.0.rect.h > rhs.0.rect.h }
                if abs(lhs.0.rect.y - rhs.0.rect.y) > 1 { return lhs.0.rect.y < rhs.0.rect.y }
                return lhs.0.rect.x < rhs.0.rect.x
            }
            .map { box, redacted in
                let fingerprint = VisionHandles.fingerprint(
                    roleGuess: "AXStaticText",
                    label: redacted.display,
                    rect: box.rect,
                    imageSize: imageSize
                )
                return VisionReadoutRow(
                    handle: VisionHandles.token(fingerprint: fingerprint),
                    text: redacted,
                    rect: box.rect,
                    confidence: box.confidence
                )
            }
    }
}
