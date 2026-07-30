import Foundation

/// The one place the `[0, 1]` and `[-1, 1]` clamps live for this module.
///
/// Before this, the same `min(1, max(0, x))` was hand-inlined dozens of times
/// and re-declared as `OrganismNode.clamp01`, `CognitivePhase*.clamp`, and
/// `ContinuityField.clamp` (audit C10). Those local helpers now delegate here so
/// the clamp has a single definition; the inline sites call these directly.
extension Double {
    /// Clamp to the unit interval `[0, 1]` (unsigned magnitudes: arousal,
    /// warmth, importance, scores…).
    func clamped01() -> Double { Swift.min(1, Swift.max(0, self)) }

    /// Clamp to the signed interval `[-1, 1]` (valence and other bipolar dims).
    func clampedSigned() -> Double { Swift.min(1, Swift.max(-1, self)) }
}
