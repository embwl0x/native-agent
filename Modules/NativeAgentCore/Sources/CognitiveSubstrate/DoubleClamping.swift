import Foundation

// Blueprint: | `DoubleClamping.swift` | `Double.clamped01` and `clampedSigned`: shared unit/signed clamps for substrate and organism magnitudes |

/// Share clamp definitions so all cognitive axes agree on their unsigned and signed bounds.
extension Double {
    /// Unsigned magnitudes stay within [0, 1].
    func clamped01() -> Double { Swift.min(1, Swift.max(0, self)) }

    /// Bipolar dimensions stay within [-1, 1].
    func clampedSigned() -> Double { Swift.min(1, Swift.max(-1, self)) }
}
