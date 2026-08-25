import Foundation

// MARK: - Role and STATE guesses
//
// Everything here is a GUESS and is emitted as one. An unknown role is
// `AXUnknown` with a low role confidence — never a guessed `AXButton` at 1.0.
// The roles are the AX lane's vocabulary on purpose: a consumer must not need
// a second branch to read a vision row.
//
// Shapes only. There is no rule in this file that could not be written by
// someone who had never seen the app under the cursor.

public enum VisionRoleGuess {
    /// The AX-vocabulary role names this layer can produce.
    public static let button = "AXButton"
    public static let textField = "AXTextField"
    public static let row = "AXRow"
    public static let checkBox = "AXCheckBox"
    public static let scrollArea = "AXScrollArea"
    public static let unknown = "AXUnknown"

    /// Roles a caller can meaningfully ACT on with a click/type. Used by the
    /// abstain rule: two overlapping decorative regions are not a dilemma.
    public static let actionable: Set<String> = [button, textField, row, checkBox]

    public struct Guess: Sendable, Equatable {
        public let role: String
        public let confidence: Double
        /// The shape fact that produced it, in one phrase, so a reader can
        /// disagree with the reasoning and not just the answer.
        public let rationale: String

        public init(role: String, confidence: Double, rationale: String) {
            self.role = role
            self.confidence = VisionConfidence.clamp(confidence)
            self.rationale = rationale
        }
    }

    public struct Inputs: Sendable {
        public let rect: VisionRect
        public let imageSize: VisionSize
        public let sources: [VisionEvidenceSource]
        /// OCR boxes whose area is mostly inside `rect`.
        public let containedText: [VisionTextBox]
        public let fillLuminance: Double?
        public let backgroundLuminance: Double

        public init(
            rect: VisionRect,
            imageSize: VisionSize,
            sources: [VisionEvidenceSource],
            containedText: [VisionTextBox],
            fillLuminance: Double?,
            backgroundLuminance: Double
        ) {
            self.rect = rect
            self.imageSize = imageSize
            self.sources = sources
            self.containedText = containedText
            self.fillLuminance = fillLuminance
            self.backgroundLuminance = backgroundLuminance
        }

        var aspect: Double { rect.h > 0 ? rect.w / rect.h : 0 }
        var areaFraction: Double {
            let frame = imageSize.width * imageSize.height
            return frame > 0 ? rect.area / frame : 0
        }
        /// Is the contained text CENTRED in the region? The single most useful
        /// button/field discriminator there is: a button's caption is centred,
        /// a field's content starts at its left inset.
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
        // A band candidate IS a row by construction — that is what the y-band
        // clusterer detected (a repeated multi-text band), and no pixel fact
        // is going to overturn it.
        if inputs.sources.contains(.textBand), !inputs.sources.contains(.colorRegion) {
            return Guess(role: row, confidence: 0.55, rationale: "repeated multi-text y-band")
        }
        if inputs.sources.contains(.textBand), inputs.sources.contains(.colorRegion) {
            return Guess(
                role: row,
                confidence: 0.65,
                rationale: "repeated y-band with a matching filled region"
            )
        }
        // A saliency-only blob is exactly as unknown as it sounds.
        if inputs.sources == [.saliency] {
            return Guess(role: unknown, confidence: 0.2, rationale: "attention blob only")
        }

        let aspect = inputs.aspect
        let short = inputs.label.count <= 28

        // A big region holding a lot of text is a CONTENT AREA — the
        // scrollable-region candidate Agent asked for. Checked before the
        // control shapes because a panel can also be wide.
        if inputs.areaFraction >= 0.12, inputs.containedText.count >= 4 {
            return Guess(
                role: scrollArea,
                confidence: 0.45,
                rationale: "large region containing \(inputs.containedText.count) text runs"
            )
        }
        // Small and near-square with a fill of its own: a checkbox/toggle.
        let minSide = min(inputs.rect.w, inputs.rect.h)
        if aspect >= 0.7, aspect <= 1.4, minSide <= max(28, inputs.imageSize.height * 0.05),
           inputs.containedText.isEmpty {
            return Guess(role: checkBox, confidence: 0.4, rationale: "small square filled region, no caption")
        }
        // Centred short caption inside a filled box: the classic button, and
        // the case rectangle detection misses entirely when the button is
        // filled and borderless (spike v0).
        if !inputs.containedText.isEmpty, short, inputs.textIsCentred, aspect >= 1.2, aspect <= 12 {
            return Guess(role: button, confidence: 0.6, rationale: "filled region with centred short caption")
        }
        // Wide, and either empty or left-inset: a text entry candidate.
        if aspect >= 2.5, inputs.containedText.isEmpty || inputs.textIsLeftAligned {
            return Guess(
                role: textField,
                confidence: 0.5,
                rationale: inputs.containedText.isEmpty
                    ? "wide empty region" : "wide region with left-inset text"
            )
        }
        if !inputs.containedText.isEmpty, short, aspect >= 1.2 {
            // It has a caption but the caption is not centred and it is not
            // wide enough to read as a field. Lower confidence, honest role.
            return Guess(role: button, confidence: 0.35, rationale: "captioned region, off-centre caption")
        }
        return Guess(role: unknown, confidence: 0.15, rationale: "no matching shape")
    }

    // MARK: - State

    /// CAPTION CONTRAST is the luminance SPREAD inside the caption's box —
    /// max minus min over the sampled cells. Spread, not "mean caption vs mean
    /// fill": the mean of a text box is glyphs blended with the fill behind
    /// them, so a white caption on a dark button and a grey caption on a grey
    /// button can land at the same mean and the greyed control reads live.
    /// Spread separates them the way an eye does — a live label has dark and
    /// light cells in the same small box; a greyed one has neither.
    ///
    /// Below `disabledContrast` reads greyed, at or above `liveContrast` reads
    /// live, and BETWEEN THE TWO we form no view at all, which is a different
    /// and more honest answer than `false`.
    public static let disabledContrast = 0.18
    public static let liveContrast = 0.30

    /// `disabled` is the load-bearing guess: a confident click on a control
    /// that is actually greyed out is the hopeful click this contract exists
    /// to prevent. So it gets computed for every actionable row, both ways,
    /// and it is never a bare boolean.
    public static func stateGuess(
        role: String,
        fillLuminance: Double?,
        captionContrast: Double?,
        backgroundLuminance: Double,
        peerFillLuminances: [Double]
    ) -> VisionStateGuess {
        var disabled: VisionStateFlag?
        if actionable.contains(role), let contrast = captionContrast {
            let rounded = (contrast * 100).rounded() / 100
            if contrast < disabledContrast {
                disabled = VisionStateFlag(
                    value: true,
                    confidence: 0.45,
                    evidence: "caption luminance spread \(rounded) — reads greyed"
                )
            } else if contrast >= liveContrast {
                disabled = VisionStateFlag(
                    value: false,
                    confidence: 0.5,
                    evidence: "caption luminance spread \(rounded) — reads live"
                )
            }
            // Between the two thresholds: no flag. We do not know.
        }

        var selected: VisionStateFlag?
        if role == row, let fill = fillLuminance, peerFillLuminances.count >= 2 {
            let sorted = peerFillLuminances.sorted()
            let median = sorted[sorted.count / 2]
            let delta = abs(fill - median)
            if delta >= 0.08 {
                selected = VisionStateFlag(
                    value: true,
                    confidence: 0.4,
                    evidence: "row fill differs from its peers by \((delta * 100).rounded() / 100)"
                )
            }
        }

        var checked: VisionStateFlag?
        if role == checkBox, let fill = fillLuminance {
            let delta = abs(fill - backgroundLuminance)
            checked = VisionStateFlag(
                value: delta >= 0.2,
                confidence: 0.3,
                evidence: "box fill differs from background by \((delta * 100).rounded() / 100)"
            )
        }

        return VisionStateGuess(selected: selected, checked: checked, disabled: disabled)
    }

    // MARK: - Destructive-action risk

    /// Verbs whose action a caller cannot take back. Agent asked for
    /// destructive-action risk tagging; this is the general, label-shaped
    /// version of it — a tag on the row, never a refusal invented here.
    /// Irreversible acts need stronger confirmation than a reversible one,
    /// and the row is where that fact belongs.
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
