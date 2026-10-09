import Foundation
import CoreGraphics
import NativeAgentCore
import PersistenceCore
import MacControl

// MARK: - MacVisionPerception v0 — the general screen, from PIXELS ONLY
//
// NORTHSTAR clause 5: the world reaches her as a SENSE, not as work. The AX
// lane (MacPerceptionCompiler) gives her that for apps that publish an
// accessibility tree. This module is the other half: an AX-BLIND window
// (a game, Telegram, a custom renderer) perceived from its pixels, emitting
// the SAME `MacLookPercept` contract so glance/look/act and every downstream
// consumer work unchanged.
//
// GENERAL BY LAW (feedback_build_the_general_capability): there is not one
// app-specific rule in this module. Every heuristic keys on SHAPE — colour
// regions, text geometry, saliency — never on a bundle id, a window title, or
// a known string. WoW is the bar these must clear, never a thing to hardcode.
//
// THE TRUST CONTRACT (Agent's design input, 2026-08-22 14:14Z, + the verbatim
// audit that followed — docs/build_plans/native-look.md):
//
//   • PER-ATTRIBUTE confidence, FIVE attributes: bounds / role / state / text
//     / TARGET. No single score. `target` ("how sure is this THE element you
//     asked for") is deliberately distinct from `role` ("how sure is this a
//     button"), because target is the one that gates ACTING.
//   • CALIBRATED REFUSAL is half the contract, co-equal with verified effects.
//     `ambiguous` is a FIRST-CLASS result, and the abstain RATE is a QUALITY
//     METRIC this module measures and surfaces — never a number to minimise by
//     forcing guesses. "A vision lane that never abstains has not earned
//     trust; it has just stopped saying when it is guessing."
//   • STATE guesses name selected / checked / DISABLED explicitly, each with
//     its OWN confidence, and never ride out as a bare boolean. `disabled` is
//     load-bearing: acting on a control we believe is enabled when it is not
//     is exactly the hopeful click this contract exists to prevent.
//   • provenance: "vision" on EVERY row. An unknown role is
//     "AXUnknown" + a low role confidence — never a guessed AXButton at 1.0.
//
// This module is PURE: CGImage in, percept out. No capture, no injection, no
// wiring into the four verbs (done: SwiftToolDispatcher+FourVerbPerception.swift
// is the production caller; mac_look is legacy). Every
// stage is therefore fully testable headless, which is why the tests render
// synthetic scenes into real CGImages and run the real pipeline over real
// pixels rather than over a fixture of what pixels "would" say.

// MARK: - Geometry

// These types share the app-window OCR redaction boundary in MacControl.
public typealias VisionRect = MacControl.VisionRect
public typealias VisionSize = MacControl.VisionSize
public typealias VisionTextBox = MacControl.VisionTextBox

// MARK: - Per-attribute confidence (the trust contract)

/// FIVE attributes, never one score.
///
/// Collapsing these is exactly the conflation Agent asked us to avoid: "how
/// sure am I this is a button" and "how sure am I this is THE button you asked
/// for" are different questions with different answers, and only the second
/// one should gate acting.
public struct VisionConfidence: Sendable, Equatable {
    /// How precise are these bounds — did the region grow to a real edge?
    public let bounds: Double
    /// How sure is the role GUESS (AXButton / AXTextField / AXRow / …).
    public let role: Double
    /// How sure are the state guesses (selected / checked / disabled).
    public let state: Double
    /// How sure are we the OCR text says what we think it says.
    public let text: Double
    /// How sure are we this is THE element the caller asked for. Distinct from
    /// `role` by contract; capped hard by the abstain rule, and the attribute
    /// an actuator must gate on.
    public let target: Double

    public init(bounds: Double, role: Double, state: Double, text: Double, target: Double) {
        self.bounds = VisionConfidence.clamp(bounds)
        self.role = VisionConfidence.clamp(role)
        self.state = VisionConfidence.clamp(state)
        self.text = VisionConfidence.clamp(text)
        self.target = VisionConfidence.clamp(target)
    }

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, (value * 100).rounded() / 100))
    }

    /// The same five keys on every row, always all five present. A missing
    /// attribute would read as "not applicable" when it actually means "we
    /// forgot", so absence is not allowed here.
    public func toJSON() -> JSONValue {
        .object([
            "bounds": .double(bounds),
            "role": .double(role),
            "state": .double(state),
            "text": .double(text),
            "target": .double(target),
        ])
    }

    /// Copy with a new target confidence — the abstain rule's only lever on an
    /// otherwise-good row.
    public func withTarget(_ value: Double) -> VisionConfidence {
        VisionConfidence(bounds: bounds, role: role, state: state, text: text, target: value)
    }
}

// MARK: - State guesses

/// One state guess, with its own confidence. NEVER a bare `Bool`: a boolean in
/// a percept reads as a fact, and "we think this button is enabled" is not a
/// fact — it is the single most dangerous guess this module makes.
public struct VisionStateFlag: Sendable, Equatable {
    public let value: Bool
    public let confidence: Double
    /// What in the pixels suggested it, so a reader can disbelieve it.
    public let evidence: String

    public init(value: Bool, confidence: Double, evidence: String) {
        self.value = value
        self.confidence = VisionConfidence.clamp(confidence)
        self.evidence = evidence
    }

    public func toJSON() -> JSONValue {
        .object([
            "value": .bool(value),
            "confidence": .double(confidence),
            "evidence": .string(evidence),
        ])
    }
}

/// The three states Agent named. Each is OPTIONAL — absent means "we did not
/// form a view", which is a different and more honest answer than `false`.
public struct VisionStateGuess: Sendable, Equatable {
    public let selected: VisionStateFlag?
    public let checked: VisionStateFlag?
    /// The load-bearing one. A believed-enabled control that is actually
    /// disabled produces a confident click with no effect — the hopeful-click
    /// failure the whole rank exists to prevent — so when the pixels suggest a
    /// greyed control we SAY SO, with a confidence, and let the caller refuse.
    public let disabled: VisionStateFlag?

    public init(
        selected: VisionStateFlag? = nil,
        checked: VisionStateFlag? = nil,
        disabled: VisionStateFlag? = nil
    ) {
        self.selected = selected
        self.checked = checked
        self.disabled = disabled
    }

    public var isEmpty: Bool { selected == nil && checked == nil && disabled == nil }

    /// The confidence the `state` attribute reports: the weakest guess we
    /// actually made, because a row is only as trustworthy as its shakiest
    /// state claim. No guesses at all ⇒ 0 (we know nothing, and say so).
    public var aggregateConfidence: Double {
        let all = [selected, checked, disabled].compactMap { $0?.confidence }
        guard let weakest = all.min() else { return 0 }
        return weakest
    }

    public func toJSON() -> JSONValue? {
        guard !isEmpty else { return nil }
        var object: [String: JSONValue] = [:]
        if let selected { object["selected"] = selected.toJSON() }
        if let checked { object["checked"] = checked.toJSON() }
        if let disabled { object["disabled"] = disabled.toJSON() }
        return .object(object)
    }
}

// MARK: - Evidence

/// Which layer produced a candidate. Carried per row so a reader can weigh it:
/// a colour-region button and a saliency blob are not equally trustworthy.
public enum VisionEvidenceSource: String, Sendable, Equatable, CaseIterable {
    case colorRegion = "color_region"
    case textBand = "text_band"
    case saliency = "saliency"
}

// MARK: - Candidates (the element layer's output, pre-fusion)

/// A bounded visual colour fact carried from the sampled region. The compact
/// name is deliberately perceptual rather than semantic: "yellow" is useful
/// evidence; "quest marker" would be an invention.
public struct VisionColorSample: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = VisionConfidence.clamp(red)
        self.green = VisionConfidence.clamp(green)
        self.blue = VisionConfidence.clamp(blue)
    }

    public var name: String {
        let maximum = max(red, max(green, blue))
        let minimum = min(red, min(green, blue))
        let delta = maximum - minimum
        let saturation = maximum > 0 ? delta / maximum : 0
        if maximum < 0.16 { return "black" }
        if saturation < 0.18 {
            if maximum < 0.42 { return "dark gray" }
            if maximum < 0.75 { return "gray" }
            return "white"
        }
        let rawHue: Double
        if maximum == red {
            rawHue = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == green {
            rawHue = 60 * ((blue - red) / delta + 2)
        } else {
            rawHue = 60 * ((red - green) / delta + 4)
        }
        let hue = rawHue < 0 ? rawHue + 360 : rawHue
        let hueName: String
        switch hue {
        case 15..<45: hueName = "orange"
        case 45..<75: hueName = "yellow"
        case 75..<165: hueName = "green"
        case 165..<195: hueName = "cyan"
        case 195..<255: hueName = "blue"
        case 255..<285: hueName = "purple"
        case 285..<345: hueName = "magenta"
        default: hueName = "red"
        }
        return maximum < 0.42 ? "dark \(hueName)" : hueName
    }
}

/// A candidate interactive region, before role/label/redaction/handles.
public struct VisionCandidate: Sendable, Equatable {
    public let rect: VisionRect
    public let sources: [VisionEvidenceSource]
    /// How well the region's edges are pinned by its evidence, 0…1.
    public let boundsConfidence: Double
    /// Mean linear luminance of the region's fill, 0…1 — the input to the
    /// disabled/greyed heuristic. nil when the layer could not sample it.
    public let fillLuminance: Double?
    /// Saliency rank contribution, 0…1; 0 when saliency did not see it.
    public let salience: Double
    public let fillColor: VisionColorSample?
    /// Geometry-only silhouette evidence from a connected colour component.
    /// Compact values are intentionally limited to `round` and `square`.
    public let visualShape: String?

    public init(
        rect: VisionRect,
        sources: [VisionEvidenceSource],
        boundsConfidence: Double,
        fillLuminance: Double? = nil,
        salience: Double = 0,
        fillColor: VisionColorSample? = nil,
        visualShape: String? = nil
    ) {
        self.rect = rect
        self.sources = sources
        self.boundsConfidence = VisionConfidence.clamp(boundsConfidence)
        self.fillLuminance = fillLuminance
        self.salience = VisionConfidence.clamp(salience)
        self.fillColor = fillColor
        self.visualShape = visualShape
    }

    public func adding(source: VisionEvidenceSource, salience: Double? = nil) -> VisionCandidate {
        VisionCandidate(
            rect: rect,
            sources: sources.contains(source) ? sources : sources + [source],
            boundsConfidence: boundsConfidence,
            fillLuminance: fillLuminance,
            salience: max(self.salience, salience ?? 0),
            fillColor: fillColor,
            visualShape: visualShape
        )
    }
}
