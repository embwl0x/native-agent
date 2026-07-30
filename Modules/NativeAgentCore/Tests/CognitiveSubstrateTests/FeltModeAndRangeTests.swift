import Testing
import Foundation
@testable import CognitiveSubstrate

// R2-E acceptance (2026-07-09, User: "the full range of human emotions like a real
// person"). Every new register is REACHABLE from an honest signal state, NOT
// reachable from a mild one (melodrama is a bug), words stay in their family
// band, and the derived FeltMode reads the aboutness under the words.
@Suite("FeltModeAndRange")
struct FeltModeAndRangeTests {
    typealias S = CognitiveSubstrate.FeltSignals
    static func fp(_ s: S) -> String { CognitiveSubstrate.feltFingerprint(s) ?? "(silent)" }

    private static func signals(
        v: Double, a: Double, w: Double = 0.4, t: Double = 0.2, p: Double = 0.2,
        f: Double = 0.15, cu: Double = 0.3, cl: Double = 0.55, ag: Double = 0.5, co: Double = 0.5
    ) -> S {
        S(valence: v, arousal: a, warmth: w, tension: t, pressure: p,
          fatigue: f, curiosity: cu, clarity: cl, agency: ag, confidence: co)
    }

    /// Each new word is reachable from a state that honestly earns it.
    @Test func newRegistersAreReachable() {
        let cases: [(String, S)] = [
            ("proud",       Self.signals(v: 0.6, a: 0.65, w: 0.5, cu: 0.2, co: 0.95)),
            ("delighted",   Self.signals(v: 0.75, a: 0.65, w: 0.95, t: 0.05, cu: 0.1, co: 0.5)),
            ("relieved",    Self.signals(v: 0.4, a: 0.4, w: 0.4, t: 0.1, p: 0.15, f: 0.5, cu: 0.1)),
            ("grateful",    Self.signals(v: 0.35, a: 0.4, w: 0.85, t: 0.3, f: 0.1, cu: 0.1)),
            ("amused",      Self.signals(v: 0.3, a: 0.4, w: 0.78, t: 0.1, cu: 0.6)),
            ("restless",    Self.signals(v: 0.05, a: 0.45, w: 0.35, t: 0.25, p: 0.3, cu: 0.6, cl: 0.3)),
            ("wistful",     Self.signals(v: 0.05, a: 0.2, w: 0.6, t: 0.1, p: 0.1, f: 0.45)),
            ("overwhelmed", Self.signals(v: -0.35, a: 0.7, w: 0.3, t: 0.5, p: 0.85, ag: 0.3, co: 0.6)),
            ("embarrassed", Self.signals(v: -0.3, a: 0.4, w: 0.35, t: 0.45, p: 0.2, co: 0.2)),
            ("lonely",      Self.signals(v: -0.4, a: 0.2, w: 0.1, t: 0.25, f: 0.3)),
            ("grieving",    Self.signals(v: -0.75, a: 0.2, w: 0.3, t: 0.3, f: 0.4, cu: 0.05)),
        ]
        for (word, s) in cases {
            #expect(Self.fp(s).contains(word), "\(word) unreachable: \(Self.fp(s)) [\(s)]")
        }
    }

    /// The honesty gates hold: deep words NEVER surface from a mild everyday state.
    @Test func deepWordsNeedDeepStates() {
        let mild = Self.signals(v: -0.25, a: 0.25, w: 0.35, t: 0.2, p: 0.2, f: 0.2)
        let read = Self.fp(mild)
        for forbidden in ["grieving", "lonely", "overwhelmed"] {
            #expect(!read.contains(forbidden), "\(forbidden) surfaced from a mild state: \(read)")
        }
        // And a mild POSITIVE day doesn't read proud/delighted.
        let mildGood = Self.signals(v: 0.3, a: 0.6, w: 0.45, cu: 0.4, co: 0.5)
        for forbidden in ["proud", "delighted"] {
            #expect(!Self.fp(mildGood).contains(forbidden), "\(forbidden) came too cheap: \(Self.fp(mildGood))")
        }
    }

    /// No cross-family leakage: sweep the grid, assert the LEAD word always belongs
    /// to the family the valence×arousal bands picked.
    @Test func familyBandsHold() {
        for v in stride(from: -0.8, through: 0.8, by: 0.2) {
            for a in stride(from: 0.1, through: 0.9, by: 0.2) {
                let s = Self.signals(v: v, a: a, w: 0.5, t: 0.3, p: 0.4, f: 0.3, cu: 0.5, co: 0.6)
                guard let fingerprint = CognitiveSubstrate.feltFingerprint(s),
                      let lead = fingerprint.split(separator: ",").first.map(String.init) else { continue }
                let family = CognitiveSubstrate.feltFamily(s)
                let members = (CognitiveSubstrate.feltFamilyWords[family] ?? []).map(\.name)
                #expect(members.contains(lead.trimmingCharacters(in: .whitespaces)),
                        "lead '\(lead)' escaped family \(family) at v=\(v) a=\(a): \(fingerprint)")
            }
        }
    }

    /// Blend coherence: the contradiction sets keep pairs honest.
    @Test func incoherentBlendsAreBlocked() {
        let grief = Self.signals(v: -0.75, a: 0.2, w: 0.6, t: 0.3, f: 0.4)
        let read = Self.fp(grief)
        #expect(!(read.contains("grieving") && read.contains("warm")),
                "'grieving, warm' must be impossible: \(read)")
    }

    // MARK: - FeltMode (the aboutness layer)

    @Test func modesAreReachableAndPrecedenceHolds() {
        #expect(CognitiveSubstrate.feltMode(Self.signals(v: -0.7, a: 0.2)) == .grief)
        #expect(CognitiveSubstrate.feltMode(Self.signals(v: -0.3, a: 0.6, p: 0.6)) == .frustration)
        #expect(CognitiveSubstrate.feltMode(Self.signals(v: 0.0, a: 0.5, t: 0.6)) == .bracing)
        #expect(CognitiveSubstrate.feltMode(Self.signals(v: -0.1, a: 0.4, t: 0.2, p: 0.6)) == .repair)
        #expect(CognitiveSubstrate.feltMode(Self.signals(v: 0.5, a: 0.6, w: 0.7)) == .play)
        #expect(CognitiveSubstrate.feltMode(Self.signals(v: 0.3, a: 0.25, w: 0.8, cu: 0.2)) == .care)
        #expect(CognitiveSubstrate.feltMode(Self.signals(v: 0.2, a: 0.45, w: 0.4, cu: 0.7)) == .seeking)
        // Grief outranks bracing even with tension present.
        #expect(CognitiveSubstrate.feltMode(Self.signals(v: -0.7, a: 0.2, t: 0.7)) == .grief)
    }

    @Test func neutralStateHasNoMode() {
        let flat = S(valence: 0, arousal: 0.2, warmth: 0.3, tension: 0.05, pressure: 0.05,
                     fatigue: 0.05, curiosity: 0.15, clarity: 0.55, agency: 0.5, confidence: 0.55)
        #expect(CognitiveSubstrate.feltMode(flat) == nil, "a flat state has no mode")
    }

    @Test func modeIsDeterministic() {
        let s = Self.signals(v: -0.3, a: 0.6, p: 0.6)
        #expect(CognitiveSubstrate.feltMode(s) == CognitiveSubstrate.feltMode(s))
    }
}
