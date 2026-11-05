import Foundation
// Blueprint: | `VisionPercept.swift` | `VisionAffordanceRow`, `VisionReadoutRow`, `VisionRecognizedText`, `VisionPercept` |

// MARK: - The emitted rows
// Retain provenance and confidence per attribute so the shared adapter can weigh uncertain evidence.

public struct VisionAffordanceRow: Sendable, Equatable {
    public let roleGuess: String
    /// Labels are already redacted; missing text remains nil.
    public let label: VisionRedactedText?
    public let rect: VisionRect
    public let confidence: VisionConfidence
    public let state: VisionStateGuess
    public let evidence: [VisionEvidenceSource]
    /// Abstention is visible evidence that a row is not independently addressable, rather than an error to hide.
    public let ambiguous: String?
    /// Irreversible-looking actions need stronger confirmation regardless of other confidence scores.
    public let destructiveRisk: Bool
    public let salience: Double
    /// Background contrast measures prominence, never semantic role.
    public let visualContrast: Double?
    /// Colour names describe perception rather than object meaning.
    public let visualColor: String?
    public let visualShape: String?

    public init(
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

    public var displayLabel: String? { label?.display }
}

/// Prominent standalone values are readouts, ranked like AX by what the screen says rather than offers.
public struct VisionReadoutRow: Sendable, Equatable {
    public let handle: String
    public let text: VisionRedactedText
    public let rect: VisionRect
    public let confidence: Double

    public init(handle: String, text: VisionRedactedText, rect: VisionRect, confidence: Double) {
        self.handle = handle
        self.text = text
        self.rect = rect
        self.confidence = VisionConfidence.clamp(confidence)
    }
}

// MARK: - The percept

public struct VisionRecognizedText: Sendable, Equatable {
    public let text: VisionRedactedText
    public let confidence: Double
    /// Retain source geometry for fusion; text-only callers may lack boxes.
    public let rect: VisionRect?

    public init(text: VisionRedactedText, confidence: Double, rect: VisionRect? = nil) {
        self.text = text
        self.confidence = confidence
        self.rect = rect
    }
}

public struct VisionPercept: Sendable, Equatable {
    public let rows: [VisionAffordanceRow]
    public let readouts: [VisionReadoutRow]
    public let frameSize: VisionSize
    /// Report whether and why conditional tiling ran.
    public let textTiled: Bool
    public let textTilingReason: String
    public let recognizedStrings: Int
    /// Keep all redacted recognition, not only the subset ranked into rows or readouts.
    public let recognizedText: [VisionRecognizedText]
    /// Report every layer cap so partial evidence cannot appear complete.
    public let notes: [String]

    public init(
        rows: [VisionAffordanceRow],
        readouts: [VisionReadoutRow],
        frameSize: VisionSize,
        textTiled: Bool,
        textTilingReason: String,
        recognizedStrings: Int,
        recognizedText: [VisionRecognizedText],
        notes: [String]
    ) {
        self.rows = rows
        self.readouts = readouts
        self.frameSize = frameSize
        self.textTiled = textTiled
        self.textTilingReason = textTilingReason
        self.recognizedStrings = recognizedStrings
        self.recognizedText = recognizedText
        self.notes = notes
    }
}
