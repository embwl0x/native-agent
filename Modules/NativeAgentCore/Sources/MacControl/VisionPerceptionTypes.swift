import Foundation
import CoreGraphics
// Blueprint: | `VisionPerceptionTypes.swift` | `VisionConfidence`, `VisionStateGuess`, `VisionEvidenceSource`, `VisionCandidate` |

// Pixel perception compiles CGImage into VisionPercept; fourVerbSupplement
// translates it into additive MacFourVerbsSupplement evidence and physical targets.
// Heuristics use colour, text geometry and saliency, never app identity or known strings.
// Every rendered row retains vision provenance and explicit abstention.
// Pixel perception is pure: CGImage in, percept out, with no capture or input injection.

// MARK: - Per-attribute confidence (the trust contract)

/// Confidence is per attribute; only target confidence gates acting.
public struct VisionConfidence: Sendable, Equatable {
    /// How precise are these bounds — did the region grow to a real edge?
    public let bounds: Double
    /// Target certainty incorporates role evidence and is capped by abstention.
    public let target: Double

    public init(bounds: Double, target: Double) {
        self.bounds = VisionConfidence.clamp(bounds)
        self.target = VisionConfidence.clamp(target)
    }

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, (value * 100).rounded() / 100))
    }
}

// MARK: - State guesses

/// One state guess, with its own confidence. NEVER a bare `Bool`: a boolean in
/// a percept reads as a fact, and "we think this button is enabled" is not a
/// fact — it is the single most dangerous guess this module makes.
public struct VisionStateFlag: Sendable, Equatable {
    public let value: Bool
    public let confidence: Double
    public init(value: Bool, confidence: Double) {
        self.value = value
        self.confidence = VisionConfidence.clamp(confidence)
    }
}

/// Each state is optional — absent means "we did not
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
