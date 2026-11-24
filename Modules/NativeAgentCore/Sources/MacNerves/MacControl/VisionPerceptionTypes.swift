import Foundation
import CoreGraphics
// Blueprint: | `VisionPerceptionTypes.swift` | `VisionConfidence`, `VisionStateGuess`, `VisionEvidenceSource`, `VisionCandidate` |

// Pixel perception is capture- and input-free; its adapter adds physical evidence without inventing app-specific semantics. Every row retains vision provenance
// and explicit abstention.

// MARK: - Per-attribute confidence (the trust contract)

/// Confidence is per attribute; only target confidence gates acting.
public struct VisionConfidence: Sendable, Equatable {
    /// Bounds confidence reflects observed edges rather than semantic role.
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

/// State guesses need confidence; bare booleans would turn uncertain enabled state into a fact.
public struct VisionStateFlag: Sendable, Equatable {
    public let value: Bool
    public let confidence: Double
    public init(value: Bool, confidence: Double) {
        self.value = value
        self.confidence = VisionConfidence.clamp(confidence)
    }
}

/// Absent state means unobserved, never false.
public struct VisionStateGuess: Sendable, Equatable {
    public let selected: VisionStateFlag?
    public let checked: VisionStateFlag?
    /// Report disabled-state uncertainty so a caller can refuse hopeful clicks that may have no effect.
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

/// Layer provenance lets callers distinguish bounded colour evidence from vague saliency.
public enum VisionEvidenceSource: String, Sendable, Equatable, CaseIterable {
    case colorRegion = "color_region"
    case textBand = "text_band"
    case saliency = "saliency"
}

// MARK: - Candidates (the element layer's output, pre-fusion)

/// Colour facts remain perceptual; a semantic label such as quest marker would be invented.
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

public struct VisionCandidate: Sendable, Equatable {
    public let rect: VisionRect
    public let sources: [VisionEvidenceSource]
    public let boundsConfidence: Double
    /// Missing luminance samples remain nil rather than inventing disabled-state evidence.
    public let fillLuminance: Double?
    /// Keep saliency contribution distinct from bounds and role confidence.
    public let salience: Double
    public let fillColor: VisionColorSample?
    /// Limit silhouettes to conservative connected-component geometry rather than invented object shapes.
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
