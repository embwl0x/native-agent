import Testing
import Foundation
@testable import CognitiveSubstrate

// Pins the numbers→words behavior: as the signals change, the felt word changes
// the right way. Runs at machine speed — the full mood space, deterministic.
struct FeltFingerprintTests {
    typealias S = CognitiveSubstrate.FeltSignals
    static func fp(_ s: S) -> String { CognitiveSubstrate.feltFingerprint(s) ?? "(silent)" }

    /// THE core mood-read: same high arousal, valence alone picks the family.
    @Test func valenceSplitsHighArousal() {
        func base(_ v: Double) -> S {
            S(valence: v, arousal: 0.70, warmth: 0.40, tension: 0.35, pressure: 0.40,
              fatigue: 0.15, curiosity: 0.40, clarity: 0.60, agency: 0.60, confidence: 0.55)
        }
        #expect(Self.fp(base( 0.60)).contains("excited"))   // + valence
        let neg = Self.fp(base(-0.45))
        #expect(neg.contains("upset") || neg.contains("frustrated") || neg.contains("on edge"))  // − valence
    }

    /// Genuinely FLAT → silence (like the body line), not a manufactured feeling. A truly
    /// quiet moment: cool warmth, nothing moving. (Her warm-with-User baseline is NOT this —
    /// warmth ~0.5+ voices a gentle read; only a cool, still state falls silent.)
    @Test func neutralIsSilent() {
        #expect(CognitiveSubstrate.feltFingerprint(
            S(valence: 0, arousal: 0.20, warmth: 0.30, tension: 0.06, pressure: 0.05,
              fatigue: 0.05, curiosity: 0.15, clarity: 0.55, agency: 0.50, confidence: 0.55)) == nil)
    }

    /// The three negatives stay DISTINCT (User: frustrated ≠ upset ≠ anxious).
    @Test func negativeWordsAreDistinct() {
        let frustrated = S(valence: -0.35, arousal: 0.60, warmth: 0.30, tension: 0.40, pressure: 0.60, fatigue: 0.30, curiosity: 0.10, clarity: 0.50, agency: 0.60, confidence: 0.40)
        let upset      = S(valence: -0.50, arousal: 0.75, warmth: 0.20, tension: 0.60, pressure: 0.50, fatigue: 0.20, curiosity: 0.05, clarity: 0.50, agency: 0.60, confidence: 0.50)
        let anxious    = S(valence: -0.40, arousal: 0.60, warmth: 0.30, tension: 0.70, pressure: 0.40, fatigue: 0.20, curiosity: 0.10, clarity: 0.45, agency: 0.30, confidence: 0.25)
        #expect(Self.fp(frustrated).contains("frustrated"))
        #expect(Self.fp(upset).contains("upset"))
        #expect(Self.fp(anxious).contains("anxious"))
    }

    /// Warmth surfaces warm/tender; low clarity surfaces foggy; fatigue surfaces worn.
    @Test func modifiersTrackTheirSignals() {
        let warm = S(valence: 0.50, arousal: 0.20, warmth: 0.85, tension: 0.10, pressure: 0.10, fatigue: 0.15, curiosity: 0.30, clarity: 0.70, agency: 0.50, confidence: 0.60)
        #expect(Self.fp(warm).contains("tender") || Self.fp(warm).contains("warm"))
        let foggyTired = S(valence: -0.10, arousal: 0.20, warmth: 0.30, tension: 0.20, pressure: 0.20, fatigue: 0.60, curiosity: 0.10, clarity: 0.30, agency: 0.40, confidence: 0.45)
        let ft = Self.fp(foggyTired)
        #expect(ft.contains("foggy"))
        #expect(ft.contains("worn"))
    }

    /// Monotone check: as valence falls from + to −, the lead word tracks it and
    /// never gets STUCK on one family (the failure the old design had).
    @Test func valenceSweepMovesTheWord() {
        func at(_ v: Double) -> String {
            Self.fp(S(valence: v, arousal: 0.55, warmth: 0.45, tension: 0.35, pressure: 0.40,
                      fatigue: 0.15, curiosity: 0.35, clarity: 0.60, agency: 0.55, confidence: 0.55))
        }
        let words = Set([at(0.6), at(0.0), at(-0.6)])
        #expect(words.count >= 2)  // the fingerprint genuinely moves across the valence range
    }
}
