import Foundation
import CoreGraphics
import NativeAgentCore
import PersistenceCore
import MacControl

// MARK: - FUSION: CGImage → the shared percept
//
// The whole pipeline, in one place and in one pass over the frame:
//
//   text layer (OCR, conditional tiling)
//        │
//        ├─ redaction (shared redactor + OCR-box caption geometry)
//        │
//   element layer  (a) colour regions   (b) y-band rows   (c) saliency
//        │
//   fusion → roles · states · handles · ABSTAIN · five confidences
//        │
//   MacLookPercept  +  the vision sidecar
//
// PURE: a CGImage in, a percept out. No capture, no injection, no mac_look
// wiring — that is the next step, after live capture. Which is also why every
// stage of this is testable headless, on real pixels.

public struct VisionPerceptionConfig: Sendable {
    public let text: VisionTextLayerConfig
    public let colorRegion: VisionColorRegionConfig
    public let textBand: VisionTextBandConfig
    public let saliency: VisionSaliencyConfig
    public let redaction: VisionRedactionConfig
    /// Two candidates overlapping by at least this IoU are ONE element seen by
    /// two layers — merged (sources unioned), not abstained on.
    public let mergeIoU: Double
    /// A colour region essentially coincident with an OCR box is the TEXT
    /// itself, not a control around it.
    public let glyphRunIoU: Double
    /// …and a region this much of which lies INSIDE one recognized string is
    /// glyph ink (a bold letter's counter, a bar of an "E").
    public let glyphInsetCoverage: Double
    /// A text box this much of whose area lies inside a candidate is that
    /// candidate's caption.
    public let containmentFraction: Double
    /// Readouts: a standalone text this many times the median text height is
    /// PROMINENT (the number a calculator shows, a headline).
    public let readoutProminence: Double
    public let maxReadouts: Int
    public let maxAffordances: Int

    public init(
        text: VisionTextLayerConfig = .default,
        colorRegion: VisionColorRegionConfig = .default,
        textBand: VisionTextBandConfig = .default,
        saliency: VisionSaliencyConfig = .default,
        redaction: VisionRedactionConfig = .default,
        mergeIoU: Double = 0.6,
        glyphRunIoU: Double = 0.5,
        glyphInsetCoverage: Double = 0.8,
        containmentFraction: Double = 0.6,
        readoutProminence: Double = 1.25,
        maxReadouts: Int = 8,
        maxAffordances: Int = 60
    ) {
        self.text = text
        self.colorRegion = colorRegion
        self.textBand = textBand
        self.saliency = saliency
        self.redaction = redaction
        self.mergeIoU = mergeIoU
        self.glyphRunIoU = glyphRunIoU
        self.glyphInsetCoverage = glyphInsetCoverage
        self.containmentFraction = containmentFraction
        self.readoutProminence = readoutProminence
        self.maxReadouts = maxReadouts
        self.maxAffordances = maxAffordances
    }

    public static let `default` = VisionPerceptionConfig()
}

public enum VisionPerceptionError: Error, LocalizedError {
    case undecodableImage

    public var errorDescription: String? {
        switch self {
        case .undecodableImage:
            return "The captured frame could not be decoded into pixels."
        }
    }
}

/// One candidate's working state between the element layer and the emitted
/// row. File-scoped rather than nested because `compile` is generic over the
/// recognizer and a generic function may not nest a type.
struct VisionRowDraft {
    let candidate: VisionCandidate
    let guess: VisionRoleGuess.Guess
    let containedText: [(box: VisionTextBox, redacted: VisionRedactedText)]
    let label: VisionRedactedText?
    let fill: Double?
    let captionContrast: Double?
}

public struct VisionPerceptionCompiler: Sendable {
    public let config: VisionPerceptionConfig
    /// Saliency is OPTIONAL — stage (c). Absent, the percept is (a)+(b) and
    /// says so through its evidence counts rather than pretending.
    public let salience: (any VisionSalienceProviding)?

    public init(
        config: VisionPerceptionConfig = .default,
        salience: (any VisionSalienceProviding)? = nil
    ) {
        self.config = config
        self.salience = salience
    }

    public func compile(
        image: CGImage,
        using recognizer: some VisionTextRecognizing,
        appName: String? = nil,
        windowTitle: String? = nil,
        excludedRegions: [VisionRect] = []
    ) throws -> VisionPercept {
        try Task.checkCancellation()
        let imageSize = VisionSize(width: Double(image.width), height: Double(image.height))
        // Foreground window pixels are not evidence about the captured app.
        // Remove them before text/colour/saliency fusion and temporal identity,
        // not merely from the final motor list. Coordinates are image-local.
        func isVisible(_ rect: VisionRect) -> Bool {
            !excludedRegions.contains { $0.intersection(rect).area > 0 }
        }
        guard let grid = VisionPixelGrid.sample(
            image: image,
            longAxisSamples: config.colorRegion.gridLongAxisSamples
        ) else { throw VisionPerceptionError.undecodableImage }
        try Task.checkCancellation()

        var notes: [String] = []

        // 1. TEXT + 2. REDACTION. Redaction happens HERE, before a single
        //    string can reach a label, a readout, a handle fingerprint or a
        //    glance line. There is no downstream path that sees raw OCR text.
        let textResult = try VisionTextLayer.recognize(
            image: image, using: recognizer, config: config.text,
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
            boxes: textResult.boxes, imageSize: imageSize, config: config.redaction
        )
        // Preserve redaction's whole-frame caption context before excluding
        // foreign-window text from the app's percept.
        let texts = Array(zip(textResult.boxes, allRedactedTexts)).filter { isVisible($0.0.rect) }
        let visibleTextBoxes = texts.map(\.0)
        let redactedTexts = texts.map(\.1)
        if redactedTexts.contains(where: \.secret) {
            notes.append("\(redactedTexts.filter(\.secret).count) recognized string(s) redacted")
        }

        // 3. ELEMENT LAYER (a) colour regions, (b) y-band rows.
        let colorResult = VisionColorRegionLayer.candidates(grid: grid, config: config.colorRegion)
        if colorResult.capped {
            notes.append("colour-region layer hit its \(config.colorRegion.maxCandidates)-candidate cap")
        }
        let bandCandidates = VisionTextBandLayer.rowCandidates(
            from: visibleTextBoxes, config: config.textBand
        )

        // A colour region that IS a recognized string, or that sits INSIDE
        // one, is glyph ink — the text layer already has it. Emitting it as a
        // control would invent an affordance out of a label, and the inside
        // case is not hypothetical: the counter of a bold 24 pt "A" is a
        // 9×9 filled near-square, which the role layer will happily read as a
        // checkbox unless it is dropped here.
        let colorCandidates = colorResult.candidates.filter { candidate in
            isVisible(candidate.rect) && !visibleTextBoxes.contains { box in
                box.rect.iou(candidate.rect) >= config.glyphRunIoU
                    || candidate.rect.coverage(by: box.rect) >= config.glyphInsetCoverage
            }
        }

        var candidates = merge(colorCandidates + bandCandidates.filter { isVisible($0.rect) })

        // 4. ELEMENT LAYER (c) saliency — rank, and add what (a)+(b) missed.
        try Task.checkCancellation()
        if let salience {
            do {
                let regions = try salience.salientRegions(in: image).filter { isVisible($0.rect) }
                try Task.checkCancellation()
                candidates = VisionSaliencyLayer.fold(
                    salient: regions, into: candidates, imageSize: imageSize, config: config.saliency
                )
            } catch {
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                // Saliency is additive: an ordinary failure retains text and
                // colour evidence, but cancellation must not publish a frame.
            }
        }
        candidates = candidates.filter { isVisible($0.rect) }
        let considered = candidates.count
        if candidates.count > config.maxAffordances {
            notes.append(
                "\(candidates.count - config.maxAffordances) candidate(s) beyond the "
                    + "\(config.maxAffordances) cap were dropped"
            )
            candidates = Array(candidates.prefix(config.maxAffordances))
        }

        // 5. ROLES, STATES, LABELS.
        let drafts: [VisionRowDraft] = candidates.map { candidate in
            let contained = texts.filter {
                $0.0.rect.coverage(by: candidate.rect) >= config.containmentFraction
            }.map { (box: $0.0, redacted: $0.1) }
            let guess = VisionRoleGuess.guess(VisionRoleGuess.Inputs(
                rect: candidate.rect,
                imageSize: imageSize,
                sources: candidate.sources,
                containedText: contained.map(\.box),
                fillLuminance: candidate.fillLuminance,
                backgroundLuminance: colorResult.backgroundLuminance
            ))
            // The LABEL is assembled from what redaction LET THROUGH. A
            // withheld string contributes nothing — not its characters, not a
            // digest — because the label goes on to seed the handle
            // fingerprint, and a handle keyed by a secret is a secret.
            let visible = contained.filter { !$0.redacted.secret }
                .sorted { $0.box.rect.x < $1.box.rect.x }
                .map(\.redacted.raw)
            let label: VisionRedactedText?
            if visible.isEmpty {
                label = contained.isEmpty ? nil : contained.first?.redacted
            } else {
                let joined = visible.joined(separator: " ")
                label = VisionRedactedText(
                    raw: joined, json: .string(joined), secret: false, reason: nil
                )
            }
            let fill = candidate.fillLuminance ?? grid.meanLuminance(in: candidate.rect)
            // The strongest spread among the region's text runs: one live
            // caption is enough to say the control is live.
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
            .compactMap(\.fill)

        // 6. ABSTAIN — computed BEFORE handles so the marker cannot be
        //    forgotten on a row that already has an identity.
        let abstainReasons = abstain(drafts.map { ($0.candidate.rect, $0.guess.role, $0.label?.display) })

        // 7. HANDLES.
        let fingerprints = drafts.map { draft in
            VisionHandles.fingerprint(
                roleGuess: draft.guess.role,
                label: draft.label?.display,
                rect: draft.candidate.rect,
                imageSize: imageSize
            )
        }
        let minted = VisionHandles.mint(fingerprints: fingerprints)

        // 8. ROWS with the five confidences.
        var rows: [VisionAffordanceRow] = []
        var reasonCounts: [String: Int] = [:]
        for (index, draft) in drafts.enumerated() {
            let state = VisionRoleGuess.stateGuess(
                role: draft.guess.role,
                fillLuminance: draft.fill,
                captionContrast: draft.captionContrast,
                backgroundLuminance: colorResult.backgroundLuminance,
                peerFillLuminances: draft.guess.role == VisionRoleGuess.row ? rowFills : []
            )
            let textConfidence = draft.containedText.map(\.box.confidence).max() ?? 0
            let ambiguous = abstainReasons[index]
            if let ambiguous {
                reasonCounts[abstainKind(ambiguous), default: 0] += 1
            }
            let target = targetPrior(
                bounds: draft.candidate.boundsConfidence,
                role: draft.guess.confidence,
                textConfidence: textConfidence,
                hasLabel: draft.label?.display?.isEmpty == false,
                salience: draft.candidate.salience,
                ambiguous: ambiguous != nil,
                handleAmbiguous: minted[index].ambiguity != nil
            )
            rows.append(VisionAffordanceRow(
                handle: minted[index].handle,
                handleAmbiguity: minted[index].ambiguity,
                roleGuess: draft.guess.role,
                roleRationale: draft.guess.rationale,
                label: draft.label,
                rect: draft.candidate.rect,
                confidence: VisionConfidence(
                    bounds: draft.candidate.boundsConfidence,
                    role: draft.guess.confidence,
                    state: state.aggregateConfidence,
                    text: textConfidence,
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

        // 9. READOUTS — prominent standalone values, i.e. text that is not
        //    inside any candidate and stands out by size. Same job as the AX
        //    lane's readouts: what the screen SAYS, ranked by prominence.
        let readoutsAll = self.readouts(
            texts: texts,
            claimed: drafts.flatMap { $0.containedText.map(\.box.rect) },
            imageSize: imageSize
        )
        let readouts = Array(readoutsAll.prefix(config.maxReadouts))

        // 10. The SHARED shape.
        let affordances = rows.map { row -> MacLookAffordance in
            MacLookAffordance(
                handle: row.handle,
                role: row.roleGuess,
                subrole: nil,
                label: row.displayLabel ?? "",
                labelSource: "vision",
                value: nil,
                secret: row.label?.secret ?? false,
                // The honest, per-attribute answer is in `state.disabled`;
                // this bare bool exists because the shared struct has one, and
                // it is set CONSERVATIVELY — believed-disabled reads disabled.
                enabled: !(row.state.disabled?.value ?? false),
                frame: row.rect.axFrame,
                // Pixels publish no AX path. The ordinal position in the
                // percept is the fallback address, and it is deliberately not
                // dressed up as a tree path.
                path: [index(of: row, in: rows)],
                labelJSON: row.label?.json,
                valueJSON: nil,
                handleAmbiguity: row.handleAmbiguity
            )
        }
        let percept = MacLookPercept(
            app: appName.map { MacAXAppInfo(name: $0, bundleIdentifier: nil, processIdentifier: 0) },
            windowTitle: windowTitle,
            focus: nil,
            modal: nil,
            landmarks: [],
            affordances: affordances,
            unlabeledByRole: unlabeledByRole(rows),
            affordancesOmitted: max(0, considered - rows.count),
            interactiveCount: rows.count,
            labeledCount: rows.filter { $0.displayLabel?.isEmpty == false }.count,
            truncated: considered > rows.count,
            truncationReasons: considered > rows.count ? ["vision_affordance_cap"] : [],
            skippedAtLeast: max(0, considered - rows.count),
            windowTitleJSON: windowTitle.map {
                MacScreenViewTextRedaction.redactedLegendString($0, valueChars: 120)
            },
            readouts: readouts.map {
                MacLookReadout(
                    handle: $0.handle,
                    role: "AXStaticText",
                    text: $0.text.display ?? "",
                    source: "vision",
                    path: [],
                    textJSON: $0.text.json
                )
            },
            // A capped readout list must not look complete (gpt-5.5 review).
            readoutsOmitted: max(0, readoutsAll.count - readouts.count),
            ambiguousHandles: rows.filter { $0.handleAmbiguity != nil }.count
        )

        try Task.checkCancellation()
        return VisionPercept(
            percept: percept,
            rows: rows,
            readouts: readouts,
            abstain: VisionAbstainReport(
                // The EMITTED set, so the rate cannot be deflated by rows the
                // cap dropped before their ambiguity was ever assessed.
                considered: rows.count,
                abstained: rows.filter { $0.ambiguous != nil }.count,
                reasons: reasonCounts,
                droppedBeyondCap: max(0, considered - rows.count)
            ),
            frameSize: imageSize,
            textTiled: textResult.tiled,
            textTilingReason: textResult.tilingReason,
            recognizedStrings: visibleTextBoxes.count,
            recognizedText: zip(redactedTexts, visibleTextBoxes).map {
                VisionRecognizedText(text: $0.0, confidence: $0.1.confidence, rect: $0.1.rect)
            },
            notes: notes
        )
    }

    // MARK: - Fusion helpers

    /// One element seen by two layers is ONE element. Merged largest-first so
    /// the surviving rect is the one with real edges, and the sources union so
    /// the row can say it was corroborated.
    func merge(_ candidates: [VisionCandidate]) -> [VisionCandidate] {
        var kept: [VisionCandidate] = []
        for candidate in candidates.sorted(by: { $0.rect.area > $1.rect.area }) {
            if let index = kept.firstIndex(where: { $0.rect.iou(candidate.rect) >= config.mergeIoU }) {
                var merged = kept[index]
                for source in candidate.sources {
                    merged = merged.adding(source: source, salience: candidate.salience)
                }
                kept[index] = VisionCandidate(
                    rect: merged.rect,
                    sources: merged.sources,
                    // Corroboration by a second layer is real evidence about
                    // the bounds; it is capped so it can never manufacture
                    // certainty out of two weak signals.
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
        return kept.sorted(by: VisionColorRegionLayer.readingOrder)
    }

    /// THE ABSTAIN RULE.
    ///
    /// Two candidates are ambiguous when each one's ACTION POINT falls inside
    /// the other. That is the precise statement of "we cannot address these
    /// separately": the point we would click for either lands in a region
    /// claimed by both, so a click carries no information about which one we
    /// meant. Partial overlap alone is NOT ambiguity — a button sitting inside
    /// a list row is perfectly clickable, and abstaining there would be the
    /// over-refusal that makes refusal meaningless.
    ///
    /// Both rows are marked. Marking only one would silently elect a winner.
    func abstain(_ items: [(rect: VisionRect, role: String, label: String?)]) -> [Int: String] {
        var out: [Int: String] = [:]
        for index in items.indices {
            let item = items[index]
            // Weak rows abstain on their own account: an unlabeled region we
            // could not even role-guess is not something to hand an actuator.
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

    func abstainKind(_ reason: String) -> String {
        reason.hasPrefix("overlapping") ? "overlapping_targets" : "unlabeled_unknown_role"
    }

    /// The `target` PRIOR: with no query, how separately addressable is this
    /// row? Bounds dominate because a target you cannot bound is a target you
    /// cannot hit; ambiguity caps it hard, because an abstaining row must not
    /// be able to clear an actuator's bar by having pretty numbers elsewhere.
    func targetPrior(
        bounds: Double,
        role: Double,
        textConfidence: Double,
        hasLabel: Bool,
        salience: Double,
        ambiguous: Bool,
        handleAmbiguous: Bool
    ) -> Double {
        var value = 0.45 * bounds + 0.3 * role + 0.15 * (hasLabel ? textConfidence : 0.1)
            + 0.1 * salience
        if !hasLabel { value *= 0.8 }
        if handleAmbiguous { value = min(value, 0.5) }
        if ambiguous { value = min(value, 0.25) }
        return value
    }

    func unlabeledByRole(_ rows: [VisionAffordanceRow]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for row in rows where row.displayLabel?.isEmpty != false {
            counts[row.roleGuess, default: 0] += 1
        }
        return counts
    }

    func index(of row: VisionAffordanceRow, in rows: [VisionAffordanceRow]) -> Int {
        rows.firstIndex { $0.handle == row.handle } ?? 0
    }

    /// Prominent standalone values: text nobody claimed as a control's caption,
    /// standing out by size. Ranked by prominence, capped, and every one of
    /// them redacted already.
    func readouts(
        texts: [(VisionTextBox, VisionRedactedText)],
        claimed: [VisionRect],
        imageSize: VisionSize
    ) -> [VisionReadoutRow] {
        let heights = texts.map(\.0.rect.h).filter { $0 > 0 }.sorted()
        guard !heights.isEmpty else { return [] }
        let median = heights[heights.count / 2]
        let free = texts.filter { entry in
            !claimed.contains { entry.0.rect.coverage(by: $0) >= config.containmentFraction }
        }
        let prominent = free.filter { $0.0.rect.h >= median * config.readoutProminence }
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
                    confidence: VisionConfidence(
                        bounds: 0.8,
                        role: 0.5,
                        state: 0,
                        text: box.confidence,
                        // A readout is not an act target. Saying otherwise
                        // would invite a click on a label.
                        target: 0.2
                    )
                )
            }
    }
}
