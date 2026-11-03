import Foundation
// Blueprint: | `Expectation.swift` | `Expectation`: shared Wilson confidence, simultaneous-prediction correction, rule-of-succession withholding and measured-cost standing for expectations |

/// Deliberation is the price of surprise: an expectation pays instead of the model while it stands.
public enum Expectation {
    /// The chance that any simultaneously tested prediction stands by luck.
    private static let alpha = 0.05

    /// Union-bound Gaussian confidence; not an anytime guarantee.
    public static func z(among predictions: Int) -> Double {
        (2 * log(Double(max(1, predictions)) / alpha)).squareRoot()
    }

    /// Wilson's lower hit-rate bound; the default is the per-claim 95% interval.
    public static func lowerBound(hits: Int, tries: Int, z: Double = 1.959964) -> Double {
        guard tries > 0 else { return 0 }
        let n = Double(tries), p = Double(min(max(0, hits), tries)) / n, z2 = z * z
        let center = p + z2 / (2 * n)
        let margin = z * (p * (1 - p) / n + z2 / (4 * n * n)).squareRoot()
        return max(0, (center - margin) / (1 + z2 / n))
    }

    /// Withhold at the rule-of-succession miss rate to measure unshown outcomes.
    public static func withholding(tries: Int, hits: Int) -> Double {
        (Double(tries - hits) + 1) / (Double(tries) + 2)
    }

    /// Both measured costs are required. `among` corrects simultaneous predictions;
    /// nil preserves a single claim's per-look 95% interval, without that correction.
    public static func stands(hits: Int, tries: Int, cHit: Double?, cMiss: Double?, among: Int? = nil)
        -> (stands: Bool, lower: Double, bar: Double?) {
        let lower = lowerBound(hits: hits, tries: tries, z: among.map { z(among: $0) } ?? 1.959964)
        guard let cHit, let cMiss, cHit.isFinite, cMiss.isFinite, cHit > 0, cMiss >= 0 else {
            return (false, lower, nil)
        }
        let bar = cMiss / (cMiss + cHit)
        return (lower > bar, lower, bar)
    }
}
