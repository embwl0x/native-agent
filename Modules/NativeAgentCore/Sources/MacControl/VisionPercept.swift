import Foundation
// Blueprint: | `VisionPercept.swift` | `VisionAffordanceRow`, `VisionReadoutRow`, `VisionRecognizedText`, `VisionPercept` |

// MARK: - The emitted rows
//
// Vision rows retain provenance and per-attribute confidence for the shared
// screen/target adapter.

public struct VisionAffordanceRow: Sendable, Equatable {
    public let handle: String
    public let handleAmbiguity: String?
    public let roleGuess: String
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
}

public struct VisionPercept: Sendable, Equatable {
    public let rows: [VisionAffordanceRow]
    public let readouts: [VisionReadoutRow]
    /// Candidates beyond the affordance cap, retained for total-row reporting.
    public let droppedBeyondCap: Int
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
        droppedBeyondCap: Int,
        frameSize: VisionSize,
        textTiled: Bool,
        textTilingReason: String,
        recognizedStrings: Int,
        recognizedText: [VisionRecognizedText],
        notes: [String]
    ) {
        self.rows = rows
        self.readouts = readouts
        self.droppedBeyondCap = droppedBeyondCap
        self.frameSize = frameSize
        self.textTiled = textTiled
        self.textTilingReason = textTilingReason
        self.recognizedStrings = recognizedStrings
        self.recognizedText = recognizedText
        self.notes = notes
    }
}
