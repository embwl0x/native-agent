import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - The emitted rows
//
// Vision rows retain provenance and per-attribute confidence for the shared
// screen/target adapter and JSON serializer.

public struct VisionAffordanceRow: Sendable, Equatable {
    public let handle: String
    public let handleAmbiguity: String?
    public let roleGuess: String
    public let roleRationale: String
    /// The OCR label, already redacted. nil when the region carried no text.
    public let label: VisionRedactedText?
    public let rect: VisionRect
    public let confidence: VisionConfidence
    public let state: VisionStateGuess
    public let evidence: [VisionEvidenceSource]
    /// Non-nil ⇒ this row ABSTAINS: we will not claim it is separately
    /// addressable. A first-class result, not an error.
    public let ambiguous: String?
    /// Irreversible-looking action. A caller must demand stronger
    /// confirmation for these regardless of how good the other numbers look.
    public let destructiveRisk: Bool
    public let salience: Double
    /// Pixel contrast against the sampled frame background. This describes
    /// visual prominence without inventing a semantic role.
    public let visualContrast: Double?
    /// Compact perceptual colour evidence such as yellow or blue. This never
    /// names what the object means.
    public let visualColor: String?
    /// Conservative connected-component silhouette: `round` or `square`.
    public let visualShape: String?

    public init(
        handle: String,
        handleAmbiguity: String?,
        roleGuess: String,
        roleRationale: String,
        label: VisionRedactedText?,
        rect: VisionRect,
        confidence: VisionConfidence,
        state: VisionStateGuess,
        evidence: [VisionEvidenceSource],
        ambiguous: String?,
        destructiveRisk: Bool,
        salience: Double,
        visualContrast: Double? = nil,
        visualColor: String? = nil,
        visualShape: String? = nil
    ) {
        self.handle = handle
        self.handleAmbiguity = handleAmbiguity
        self.roleGuess = roleGuess
        self.roleRationale = roleRationale
        self.label = label
        self.rect = rect
        self.confidence = confidence
        self.state = state
        self.evidence = evidence
        self.ambiguous = ambiguous
        self.destructiveRisk = destructiveRisk
        self.salience = salience
        self.visualContrast = visualContrast
        self.visualColor = visualColor
        self.visualShape = visualShape
    }

    /// The clear label, or nil when redaction withheld it / there was none.
    public var displayLabel: String? { label?.display }

    public func toJSON() -> JSONValue {
        var object: [String: JSONValue] = [
            "handle": .string(handle),
            // Never "vision-ish", never inferred by the reader: on the row.
            "provenance": .string("vision"),
            "role": .string(roleGuess),
            "role_rationale": .string(roleRationale),
            "label_source": .string("vision"),
            "bounds": rect.toJSON(),
            "action_point": .object([
                "x": .double(rect.actionPoint.x.rounded()),
                "y": .double(rect.actionPoint.y.rounded()),
            ]),
            "confidence": confidence.toJSON(),
            "evidence": .array(evidence.map { .string($0.rawValue) }),
        ]
        if let label { object["label"] = label.json }
        if let state = state.toJSON() { object["state"] = state }
        if let ambiguous {
            object["ambiguous"] = .bool(true)
            object["ambiguous_reason"] = .string(ambiguous)
        }
        if destructiveRisk { object["destructive_risk"] = .bool(true) }
        if let handleAmbiguity {
            object["handle_ambiguous"] = .bool(true)
            object["handle_ambiguity"] = .string(handleAmbiguity)
        }
        if salience > 0 { object["salience"] = .double(salience) }
        if let visualContrast { object["visual_contrast"] = .double(visualContrast) }
        if let visualColor { object["visual_color"] = .string(visualColor) }
        if let visualShape { object["visual_shape"] = .string(visualShape) }
        return .object(object)
    }
}

/// A prominent standalone value — the pixel channel's readout. Same job as the
/// AX lane's `MacLookReadout` (what the screen SAYS, as opposed to what it
/// offers), ranked the same way: prominence first.
public struct VisionReadoutRow: Sendable, Equatable {
    public let handle: String
    public let text: VisionRedactedText
    public let rect: VisionRect
    public let confidence: VisionConfidence

    public init(handle: String, text: VisionRedactedText, rect: VisionRect, confidence: VisionConfidence) {
        self.handle = handle
        self.text = text
        self.rect = rect
        self.confidence = confidence
    }

    public func toJSON() -> JSONValue {
        .object([
            "handle": .string(handle),
            "provenance": .string("vision"),
            "text": text.json,
            "bounds": rect.toJSON(),
            "confidence": confidence.toJSON(),
        ])
    }
}

// MARK: - The abstain metric

/// CALIBRATED REFUSAL, measured.
///
/// Agent's close, verbatim: "confidence labels don't create trust; calibrated
/// refusal and verified effects do." The abstain rate is therefore a QUALITY
/// METRIC this module reports on every percept — not a number to drive to
/// zero. A vision lane that never abstains has not earned trust; it has just
/// stopped saying when it is guessing.
public struct VisionAbstainReport: Sendable, Equatable {
    /// Candidate regions the fusion considered — the EMITTED set the rate is
    /// honest over. Rows dropped by the affordance cap are NOT in here; they
    /// are counted separately below, because a dropped ambiguous row silently
    /// deflating the refusal rate is exactly the fabricated-confidence failure
    /// this report exists to prevent (gpt-5.5 vision-v0 review, 2026-08-22).
    public let considered: Int
    /// …of which this many are emitted as `ambiguous`.
    public let abstained: Int
    public let reasons: [String: Int]
    /// Candidates beyond `maxAffordances` that never became rows. Their
    /// ambiguity was never assessed — surfaced, not folded into the rate.
    public let droppedBeyondCap: Int

    public init(considered: Int, abstained: Int, reasons: [String: Int], droppedBeyondCap: Int = 0) {
        self.considered = considered
        self.abstained = abstained
        self.reasons = reasons
        self.droppedBeyondCap = droppedBeyondCap
    }

    public var rate: Double {
        guard considered > 0 else { return 0 }
        return (Double(abstained) / Double(considered) * 100).rounded() / 100
    }

    public func toJSON() -> JSONValue {
        .object([
            "considered": .int(Int64(considered)),
            "abstained": .int(Int64(abstained)),
            "rate": .double(rate),
            "reasons": .object(reasons.mapValues { .int(Int64($0)) }),
            "dropped_beyond_cap": .int(Int64(droppedBeyondCap)),
        ])
    }
}

// MARK: - The percept

public struct VisionRecognizedText: Sendable, Equatable {
    public let text: VisionRedactedText
    public let confidence: Double
    /// Source-frame geometry retained for spatial fusion with nearby visual
    /// evidence. Optional for synthetic callers that have text without a box.
    public let rect: VisionRect?

    public init(text: VisionRedactedText, confidence: Double, rect: VisionRect? = nil) {
        self.text = text
        self.confidence = VisionConfidence.clamp(confidence)
        self.rect = rect
    }

    public func toJSON() -> JSONValue {
        var value: [String: JSONValue] = [
            "text": text.json,
            "confidence": .double(confidence),
        ]
        if let rect { value["bounds"] = rect.toJSON() }
        return .object(value)
    }
}

public struct VisionPercept: Sendable, Equatable {
    public let rows: [VisionAffordanceRow]
    public let readouts: [VisionReadoutRow]
    public let abstain: VisionAbstainReport
    public let frameSize: VisionSize
    /// Did the conditional tiling pass fire, and why / why not.
    public let textTiled: Bool
    public let textTilingReason: String
    public let recognizedStrings: Int
    /// Every recognized string after source redaction, not only the subset
    /// promoted to a row label or prominent standalone readout.
    public let recognizedText: [VisionRecognizedText]
    /// Layer caps that bit. Never silent.
    public let notes: [String]

    public init(
        rows: [VisionAffordanceRow],
        readouts: [VisionReadoutRow],
        abstain: VisionAbstainReport,
        frameSize: VisionSize,
        textTiled: Bool,
        textTilingReason: String,
        recognizedStrings: Int,
        recognizedText: [VisionRecognizedText],
        notes: [String]
    ) {
        self.rows = rows
        self.readouts = readouts
        self.abstain = abstain
        self.frameSize = frameSize
        self.textTiled = textTiled
        self.textTilingReason = textTilingReason
        self.recognizedStrings = recognizedStrings
        self.recognizedText = recognizedText
        self.notes = notes
    }

    public var evidenceCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for row in rows {
            for source in row.evidence { counts[source.rawValue, default: 0] += 1 }
        }
        return counts
    }

    public func row(handle: String) -> VisionAffordanceRow? {
        rows.first { $0.handle == handle }
    }

    public func toJSON() -> JSONValue {
        var object: [String: JSONValue] = [
            "provenance": .string("vision"),
            "frame": .object([
                "w": .double(frameSize.width.rounded()),
                "h": .double(frameSize.height.rounded()),
            ]),
            "text_layer": .object([
                "strings": .int(Int64(recognizedStrings)),
                "tiled": .bool(textTiled),
                "tiling_reason": .string(textTilingReason),
            ]),
            "affordances": .array(rows.map { $0.toJSON() }),
            "readouts": .array(readouts.map { $0.toJSON() }),
            "recognized_text": .array(recognizedText.map { $0.toJSON() }),
            "abstain": abstain.toJSON(),
            "evidence_counts": .object(evidenceCounts.mapValues { .int(Int64($0)) }),
        ]
        if !notes.isEmpty { object["notes"] = .array(notes.map { .string($0) }) }
        return .object(object)
    }

}
