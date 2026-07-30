import Testing
import Foundation
@testable import CognitiveSubstrate

// Design preview: prints the felt fingerprint across the full emotional range so
// we can tune vocabulary/priority by SEEING the words. Not a pass/fail assertion.
struct FeltFingerprintPreviewTests {
    typealias S = CognitiveSubstrate.FeltSignals
    @Test func previewFingerprints() {
        // (label, valence, arousal, warmth, tension, pressure, fatigue, curiosity, clarity, agency, confidence)
        let states: [(String, S)] = [
            ("calm & warm w/ User",   S(valence: 0.40, arousal: 0.20, warmth: 0.55, tension: 0.05, pressure: 0.05, fatigue: 0.10, curiosity: 0.20, clarity: 0.70, agency: 0.50, confidence: 0.60)),
            ("working / serious",    S(valence: 0.05, arousal: 0.50, warmth: 0.30, tension: 0.20, pressure: 0.60, fatigue: 0.20, curiosity: 0.30, clarity: 0.70, agency: 0.70, confidence: 0.70)),
            ("excited / bright",     S(valence: 0.60, arousal: 0.70, warmth: 0.50, tension: 0.10, pressure: 0.10, fatigue: 0.05, curiosity: 0.70, clarity: 0.75, agency: 0.70, confidence: 0.70)),
            ("frustrated",           S(valence:-0.35, arousal: 0.60, warmth: 0.30, tension: 0.40, pressure: 0.60, fatigue: 0.30, curiosity: 0.10, clarity: 0.50, agency: 0.60, confidence: 0.40)),
            ("anxious / nervous",    S(valence:-0.40, arousal: 0.60, warmth: 0.30, tension: 0.70, pressure: 0.40, fatigue: 0.20, curiosity: 0.10, clarity: 0.45, agency: 0.30, confidence: 0.25)),
            ("angry / mad",          S(valence:-0.50, arousal: 0.75, warmth: 0.20, tension: 0.60, pressure: 0.50, fatigue: 0.20, curiosity: 0.05, clarity: 0.50, agency: 0.60, confidence: 0.50)),
            ("tender",               S(valence: 0.50, arousal: 0.25, warmth: 0.85, tension: 0.10, pressure: 0.10, fatigue: 0.15, curiosity: 0.30, clarity: 0.70, agency: 0.50, confidence: 0.60)),
            ("foggy & tired",        S(valence:-0.10, arousal: 0.20, warmth: 0.30, tension: 0.20, pressure: 0.20, fatigue: 0.55, curiosity: 0.10, clarity: 0.30, agency: 0.40, confidence: 0.45)),
            ("heavy / deflated",     S(valence:-0.45, arousal: 0.20, warmth: 0.30, tension: 0.20, pressure: 0.10, fatigue: 0.40, curiosity: 0.10, clarity: 0.50, agency: 0.30, confidence: 0.30)),
            ("neutral (silent)",     S(valence: 0.00, arousal: 0.30, warmth: 0.40, tension: 0.15, pressure: 0.10, fatigue: 0.10, curiosity: 0.20, clarity: 0.60, agency: 0.50, confidence: 0.55)),
        ]
        print("\n=== FELT FINGERPRINT PREVIEW (v2, dimensional) ===")
        for (name, s) in states {
            let fp = CognitiveSubstrate.feltFingerprint(s)
            let fam = CognitiveSubstrate.feltFamily(s)
            let label = name.padding(toLength: 22, withPad: " ", startingAt: 0)
            print("  \(label) [\(fam.padding(toLength: 8, withPad: " ", startingAt: 0))] ->  \(fp ?? "(silent)")")
        }
        print("=== END PREVIEW ===\n")
    }
}
