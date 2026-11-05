import Foundation
// Blueprint: | `VisionRoleGuess.swift` | `VisionRoleGuess` |

// MARK: - Role and STATE guesses
// Roles are shape-based guesses in the shared AX vocabulary; unknown evidence stays AXUnknown with low confidence.

public enum VisionRoleGuess {
    public static let button = "AXButton"
    public static let textField = "AXTextField"
    public static let row = "AXRow"
    public static let checkBox = "AXCheckBox"
    public static let scrollArea = "AXScrollArea"
    public static let unknown = "AXUnknown"

    /// Only actionable roles create target ambiguity; overlapping decoration does not.
    public static let actionable: Set<String> = [button, textField, row, checkBox]

    public struct Guess: Sendable, Equatable {
        public let role: String
        public let confidence: Double

        public init(role: String, confidence: Double) {
            self.role = role
            self.confidence = VisionConfidence.clamp(confidence)
        }
    }

    public struct Inputs: Sendable {
        public let rect: VisionRect
        public let imageSize: VisionSize
        public let sources: [VisionEvidenceSource]
        public let containedText: [VisionTextBox]

        public init(
            rect: VisionRect,
            imageSize: VisionSize,
            sources: [VisionEvidenceSource],
            containedText: [VisionTextBox]
        ) {
            self.rect = rect
            self.imageSize = imageSize
            self.sources = sources
            self.containedText = containedText
        }

        var aspect: Double { rect.h > 0 ? rect.w / rect.h : 0 }
        var areaFraction: Double {
            let frame = imageSize.width * imageSize.height
            return frame > 0 ? rect.area / frame : 0
        }
        /// Centered captions suggest buttons while left-inset text suggests fields.
        var textIsCentred: Bool {
            guard let text = textBounds else { return false }
            let offset = abs(text.centerX - rect.centerX)
            return offset <= max(4, rect.w * 0.12)
        }
        var textIsLeftAligned: Bool {
            guard let text = textBounds else { return false }
            let inset = text.x - rect.x
            return inset >= 0 && inset <= rect.w * 0.25 && text.maxX < rect.maxX - rect.w * 0.1
        }
        var textBounds: VisionRect? {
            guard var bounds = containedText.first?.rect else { return nil }
            for box in containedText.dropFirst() { bounds = bounds.union(box.rect) }
            return bounds
        }
        var label: String {
            containedText.sorted { $0.rect.x < $1.rect.x }.map(\.text)
                .joined(separator: " ")
        }
    }

    public static func guess(_ inputs: Inputs) -> Guess {
        // Repeated multi-text bands already establish a row shape; later role guesses cannot overturn that evidence.
        if inputs.sources.contains(.textBand), !inputs.sources.contains(.colorRegion) {
            return Guess(role: row, confidence: 0.55)
        }
        if inputs.sources.contains(.textBand), inputs.sources.contains(.colorRegion) {
            return Guess(
                role: row,
                confidence: 0.65
            )
        }
        // Saliency alone cannot establish a semantic role.
        if inputs.sources == [.saliency] {
            return Guess(role: unknown, confidence: 0.2)
        }

        let aspect = inputs.aspect
        let short = inputs.label.count <= 28

        // Classify text-heavy content areas before controls because panels can share their wide shapes.
        if inputs.areaFraction >= 0.12, inputs.containedText.count >= 4 {
            return Guess(
                role: scrollArea,
                confidence: 0.45
            )
        }
        // Near-square regions with their own fill may indicate checkable controls.
        let minSide = min(inputs.rect.w, inputs.rect.h)
        if aspect >= 0.7, aspect <= 1.4, minSide <= max(28, inputs.imageSize.height * 0.05),
           inputs.containedText.isEmpty {
            return Guess(role: checkBox, confidence: 0.4)
        }
        // Centered short captions can identify filled borderless buttons that rectangle edges miss.
        if !inputs.containedText.isEmpty, short, inputs.textIsCentred, aspect >= 1.2, aspect <= 12 {
            return Guess(role: button, confidence: 0.6)
        }
        // Wide empty or left-inset regions suggest text entry.
        if aspect >= 2.5, inputs.containedText.isEmpty || inputs.textIsLeftAligned {
            return Guess(
                role: textField,
                confidence: 0.5
            )
        }
        if !inputs.containedText.isEmpty, short, aspect >= 1.2 {
            // Uncentered narrow captions justify only a lower-confidence role guess.
            return Guess(role: button, confidence: 0.35)
        }
        return Guess(role: unknown, confidence: 0.15)
    }

    // MARK: - State

    /// Use caption luminance spread: blended means can make white-on-dark and grey-on-grey captions indistinguishable. Between disabled and live contrast
    /// thresholds, publish no state rather than an invented false.
    public static let disabledContrast = 0.18
    public static let liveContrast = 0.30

    /// Every actionable row needs a confidence-bearing disabled guess so hopeful clicks cannot rely on a bare enabled boolean.
    public static func stateGuess(
        role: String,
        fillLuminance: Double?,
        captionContrast: Double?,
        backgroundLuminance: Double,
        rowFillBaseline: Double?
    ) -> VisionStateGuess {
        var disabled: VisionStateFlag?
        if actionable.contains(role), let contrast = captionContrast {
            if contrast < disabledContrast {
                disabled = VisionStateFlag(
                    value: true,
                    confidence: 0.45
                )
            } else if contrast >= liveContrast {
                disabled = VisionStateFlag(
                    value: false,
                    confidence: 0.5
                )
            }
            // Between thresholds, absence means unknown.
        }

        var selected: VisionStateFlag?
        if role == row, let fill = fillLuminance, let baseline = rowFillBaseline {
            let delta = abs(fill - baseline)
            if delta >= 0.08 {
                selected = VisionStateFlag(
                    value: true,
                    confidence: 0.4
                )
            }
        }

        var checked: VisionStateFlag?
        if role == checkBox, let fill = fillLuminance {
            let delta = abs(fill - backgroundLuminance)
            checked = VisionStateFlag(
                value: delta >= 0.2,
                confidence: 0.3
            )
        }

        return VisionStateGuess(selected: selected, checked: checked, disabled: disabled)
    }

    // MARK: - Destructive-action risk

    /// Irreversible verbs need stronger caller confirmation; retain a risk tag on the row rather than inventing a refusal here.
    public static let destructiveTokens: [String] = [
        "delete", "remove", "erase", "destroy", "wipe", "format", "reset",
        "discard", "revoke", "uninstall", "empty trash", "move to trash",
        "sign out", "log out", "deactivate", "unsubscribe", "purge", "clear all",
    ]

    public static func isDestructive(label: String) -> Bool {
        let text = label.lowercased()
        guard !text.isEmpty, text.count <= 48 else { return false }
        return destructiveTokens.contains { token in
            guard token.count > 5 || token.contains(" ") else {
                return text.split(whereSeparator: { !$0.isLetter }).contains { $0 == token }
            }
            return text.contains(token)
        }
    }
}
