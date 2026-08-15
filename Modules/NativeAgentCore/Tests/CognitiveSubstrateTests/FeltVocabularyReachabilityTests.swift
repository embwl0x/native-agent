import Foundation
import Testing
import PersistenceCore
import NativeAgentCore
@testable import CognitiveSubstrate

// W4/P2 — THE REACHABILITY PIN.
//
// The defect this suite exists to prevent from EVER coming back: eleven core
// words and four of five overlays were structurally unselectable on a default
// install, because five felt dims fell back to hard constants when the organism
// (off by default) was absent, and the `pick` gates are threshold tests against
// exactly those constants. Shipping vocabulary nothing can reach is the same
// class of lie as the warmth ceiling, pointed the other way.
//
// The guard has two halves, and BOTH are load-bearing:
//   - REACHABLE: with the organism OFF, every word that is supposed to be
//     selectable must be selectable under SOME achievable signal vector.
//   - HONESTLY ABSENT: the words that depend on `agency`/`confidence` — dims the
//     substrate has no honest source for — must be excluded from the pool, not
//     scored to zero and silently losing. A fabricated confidence signal is
//     worse than a missing one.
@Suite("FeltVocabularyReachability")
struct FeltVocabularyReachabilityTests {
    typealias S = CognitiveSubstrate.FeltSignals

    /// The five words whose IDENTITY is agency or confidence. With the organism
    /// off these stay out of reach ON PURPOSE, and that refusal is the feature.
    static let organismOnlyWords: Set<String> = [
        "proud", "anxious", "embarrassed", "deflated", "discouraged",
    ]

    /// Every word the table can produce, core families plus overlays.
    static var allWords: Set<String> {
        var out = Set(CognitiveSubstrate.feltFamilyWords.values.flatMap { $0 }.map(\.name))
        out.formUnion(CognitiveSubstrate.feltOverlays.map(\.name))
        return out
    }

    /// A coarse but genuinely achievable sweep of substrate-off signal space.
    /// `agency`/`confidence` are held ABSENT throughout — that is the whole point
    /// of the sweep; the substrate cannot supply them.
    private func organismOffSweep() -> [S] {
        var out: [S] = []
        let axis = [0.0, 0.2, 0.35, 0.5, 0.65, 0.8, 1.0]
        let valences = [-0.9, -0.6, -0.35, -0.1, 0.0, 0.1, 0.35, 0.6, 0.9]
        for valence in valences {
            for arousal in axis {
                for warmth in axis {
                    for tension in [0.0, 0.3, 0.6, 0.9] {
                        for pressure in [0.0, 0.4, 0.8] {
                            for fatigue in [0.0, 0.45, 0.9] {
                                for curiosity in [0.0, 0.5, 0.9] {
                                    for clarity in [0.1, 0.5, 0.9] {
                                        out.append(S(
                                            valence: valence, arousal: arousal, warmth: warmth,
                                            tension: tension, pressure: pressure,
                                            fatigue: fatigue, curiosity: curiosity,
                                            clarity: clarity, agency: nil, confidence: nil))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// THE PIN. Every word not gated behind the organism is reachable with the
    /// organism OFF.
    @Test func everyWordIsReachableWithTheOrganismOff() {
        var seen = Set<String>()
        for signals in organismOffSweep() {
            guard let fingerprint = CognitiveSubstrate.feltFingerprint(signals) else { continue }
            for word in fingerprint.components(separatedBy: ", ") { seen.insert(word) }
        }
        let expected = Self.allWords.subtracting(Self.organismOnlyWords)
        let unreachable = expected.subtracting(seen)
        #expect(unreachable.isEmpty, """
            Words in feltFamilyWords/feltOverlays that NO achievable organism-off \
            signal vector can select: \(unreachable.sorted()). Either give the dim \
            a substrate-native proxy, or declare the word's dependency in \
            `requires` so it is honestly excluded instead of shipped dead.
            """)
    }

    /// The tiredness axis, the curiosity axis, and the clarity registers are the
    /// specific casualties P2 was written to recover. Named explicitly so a
    /// future regression reads as "we lost `worn` again", not as a set-diff.
    @Test func theRecoveredRegistersAreNamedAndReachable() {
        var seen = Set<String>()
        for signals in organismOffSweep() {
            guard let fingerprint = CognitiveSubstrate.feltFingerprint(signals) else { continue }
            for word in fingerprint.components(separatedBy: ", ") { seen.insert(word) }
        }
        for word in ["relieved", "amused", "focused", "restless", "flat", "wistful",
                     "foggy", "clear-headed", "worn", "curious"] {
            #expect(seen.contains(word), "P2 was supposed to restore \(word)")
        }
    }

    /// HONESTLY ABSENT, not silently losing. With agency/confidence unknown these
    /// five must never appear — including under signal vectors that would have
    /// selected them at the old 0.5 fallback.
    @Test func agencyAndConfidenceWordsStayOutOfReachWithoutTheOrganism() {
        for signals in organismOffSweep() {
            guard let fingerprint = CognitiveSubstrate.feltFingerprint(signals) else { continue }
            for word in fingerprint.components(separatedBy: ", ") {
                #expect(!Self.organismOnlyWords.contains(word),
                        "\(word) claims a dim the substrate cannot know: \(fingerprint)")
            }
        }
    }

    /// ...and they come straight back the moment the organism supplies the dim.
    /// Otherwise `requires` would be a permanent deletion rather than an honesty
    /// gate.
    @Test func organismChemistryRestoresTheAbsentWords() {
        let proud = CognitiveSubstrate.feltFingerprint(S(
            valence: 0.7, arousal: 0.7, warmth: 0.4, tension: 0.0, pressure: 0.1,
            fatigue: 0.0, curiosity: 0.2, clarity: 0.7, agency: 0.8, confidence: 0.9))
        #expect(proud?.contains("proud") == true, "got \(String(describing: proud))")

        let discouraged = CognitiveSubstrate.feltFingerprint(S(
            valence: -0.5, arousal: 0.15, warmth: 0.3, tension: 0.2, pressure: 0.1,
            fatigue: 0.3, curiosity: 0.1, clarity: 0.4, agency: 0.1, confidence: 0.2))
        #expect(discouraged?.contains("discouraged") == true
                || discouraged?.contains("deflated") == true,
                "got \(String(describing: discouraged))")
    }

    // MARK: - the intensity contract

    /// With every dim present, renormalization must multiply by EXACTLY one —
    /// otherwise P2 silently re-tunes every threshold in the table.
    @Test func intensityIsUnchangedWhenEveryDimIsPresent() {
        for fatigue in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let s = S(valence: 0.4, arousal: 0.6, warmth: 0.62, tension: 0.3, pressure: 0.2,
                      fatigue: fatigue, curiosity: 0.4, clarity: 0.5, agency: 0.5, confidence: 0.5)
            let expected = (0.55 * 0.4 + 0.35 * max(0, 0.6 - 0.30) + 0.35 * 0.3
                            + 0.20 * 0.2 + 0.20 * fatigue + 0.42 * max(0, 0.62 - 0.28))
            #expect(abs(CognitiveSubstrate.feltIntensity(s) - min(1, expected)) < 0.0000001)
        }
    }

    /// THE MEASURED HAZARD, PINNED. The reason a 0.5 midpoint was refused: it adds
    /// +0.10 to every intensity and makes `grieving` reachable in an ordinary
    /// sting. Absence must not reproduce that.
    @Test func absentFatigueDoesNotMakeGrievingReachableInAnOrdinarySting() {
        // An ordinary sting: real but not bereavement-deep.
        let sting = S(valence: -0.42, arousal: 0.22, warmth: 0.35, tension: 0.25, pressure: 0.2,
                      fatigue: nil, curiosity: 0.2, clarity: 0.5, agency: nil, confidence: nil)
        let word = CognitiveSubstrate.feltFingerprint(sting)
        #expect(word?.contains("grieving") != true,
                "an ordinary sting must not read as grief: \(String(describing: word))")
        // The gate itself is still reachable when genuinely earned.
        let bereft = S(valence: -0.85, arousal: 0.10, warmth: 0.2, tension: 0.3, pressure: 0.1,
                       fatigue: nil, curiosity: 0.1, clarity: 0.4, agency: nil, confidence: nil)
        #expect(CognitiveSubstrate.feltFingerprint(bereft)?.contains("grieving") == true)
    }

    // MARK: - the proxies

    /// The proxies must actually FIRE against a real substrate, not just compile.
    /// A proxy that always returns nil restores nothing.
    @Test func substrateProxiesProduceValuesOnALivedSession() async throws {
        let clock = TestProxyClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = CognitiveSubstrate(
            configuration: .allPhasesEnabled,
            dependencies: CognitiveSubstrateDependencies(now: { clock.now() }, makeUUID: { UUID() }))
        for index in 0..<12 {
            clock.advance(180)
            await substrate.ingest(CognitiveEvent(
                id: "proxy-\(index)", kind: .userMessageReceived,
                subject: CognitiveSubjectReference(
                    type: "chat_turn", id: "proxy:\(index)", label: "t"),
                sourceClass: .userStated, occurredAt: clock.now(),
                summary: "another pass over the same subject, still working it",
                importance: 0.8, metadata: ["sessionId": .string("proxy")]))
        }
        let signals = await substrate.debugFeltSignals(for: CognitiveCapsuleRequest(
            surface: "chat", userMessage: "still here?", sessionId: "proxy", mode: .inject))

        #expect(signals.fatigue != nil, "a 36-minute 12-turn session must produce a fatigue read")
        #expect(signals.curiosity != nil, "a populated workspace must produce a curiosity read")
        #expect(signals.clarity != nil, "affect-on must always produce a clarity read")
        // The two with no honest source stay absent.
        #expect(signals.agency == nil)
        #expect(signals.confidence == nil)
    }

    /// A fresh substrate has no session to be tired from — the proxy must say "I
    /// don't know" rather than "I feel fine", which is the whole optionality
    /// argument applied to the proxies themselves.
    @Test func fatigueProxyIsAbsentOnAColdSubstrate() async throws {
        let clock = TestProxyClock(Date(timeIntervalSince1970: 1_700_000_000))
        let substrate = CognitiveSubstrate(
            configuration: .allPhasesEnabled,
            dependencies: CognitiveSubstrateDependencies(now: { clock.now() }, makeUUID: { UUID() }))
        let signals = await substrate.debugFeltSignals(for: CognitiveCapsuleRequest(
            surface: "chat", userMessage: "hello", sessionId: "cold", mode: .inject))
        #expect(signals.fatigue == nil)
        #expect(signals.curiosity == nil)
    }

    /// A long dense session must read MORE tired than a short sparse one, or the
    /// proxy is a constant wearing a function's clothes.
    @Test func fatigueProxyRisesWithSessionLengthAndDensity() async throws {
        func fatigue(turns: Int, spacing: TimeInterval) async -> Double? {
            let clock = TestProxyClock(Date(timeIntervalSince1970: 1_700_000_000))
            let substrate = CognitiveSubstrate(
                configuration: .allPhasesEnabled,
                dependencies: CognitiveSubstrateDependencies(
                    now: { clock.now() }, makeUUID: { UUID() }))
            for index in 0..<turns {
                clock.advance(spacing)
                await substrate.ingest(CognitiveEvent(
                    id: "f-\(index)", kind: .userMessageReceived,
                    subject: CognitiveSubjectReference(
                        type: "chat_turn", id: "f:\(index)", label: "t"),
                    sourceClass: .userStated, occurredAt: clock.now(),
                    summary: "working the same thread again", importance: 0.8,
                    metadata: ["sessionId": .string("f")]))
            }
            return await substrate.debugFeltSignals(for: CognitiveCapsuleRequest(
                surface: "chat", userMessage: "and?", sessionId: "f", mode: .inject)).fatigue
        }
        let short = try #require(await fatigue(turns: 3, spacing: 120))
        let long = try #require(await fatigue(turns: 40, spacing: 240))
        #expect(long > short, "a long dense session must read more tired: \(short) → \(long)")
        #expect(long <= 1.0 && short >= 0.0)
    }
}

final class TestProxyClock: @unchecked Sendable {
    private let lock = NSLock(); private var t: Date
    init(_ t: Date) { self.t = t }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ dt: TimeInterval) { lock.lock(); t = t.addingTimeInterval(dt); lock.unlock() }
}

// Family-balance pins (gpt-5.5 fix-round): the load-bearing words must keep
// their canonical vectors after the W4 reachability arithmetic.
@Suite("Felt family balance pins")
struct FeltFamilyBalancePins {
    typealias S = CognitiveSubstrate.FeltSignals

    @Test func canonicalWorkStingStaysFrustrated() {
        // PRESSURE-led with moderate tension = work going badly. (Tension 0.9
        // with deep negative valence correctly reads personal/upset, and
        // pressure past 0.68 correctly reads overwhelmed — this pin is the
        // frustrated lane between them.)
        let s = S(valence: -0.4, arousal: 0.7, warmth: 0.3, tension: 0.55,
                  pressure: 0.6, fatigue: 0.2, curiosity: 0.3, clarity: 0.5,
                  agency: nil, confidence: nil)
        let fp = CognitiveSubstrate.feltFingerprint(s) ?? ""
        #expect(fp.contains("frustrated"), "got: \(fp)")
    }

    @Test func tenseNotPressuredReadsOnEdge() {
        let s = S(valence: -0.35, arousal: 0.7, warmth: 0.3, tension: 0.9,
                  pressure: 0.0, fatigue: 0.2, curiosity: 0.3, clarity: 0.5,
                  agency: nil, confidence: nil)
        let fp = CognitiveSubstrate.feltFingerprint(s) ?? ""
        #expect(fp.contains("on edge"), "got: \(fp)")
    }

    @Test func deepHurtStaysUpset() {
        let s = S(valence: -0.9, arousal: 0.7, warmth: 0.3, tension: 0.9,
                  pressure: 0.2, fatigue: 0.2, curiosity: 0.3, clarity: 0.5,
                  agency: nil, confidence: nil)
        let fp = CognitiveSubstrate.feltFingerprint(s) ?? ""
        #expect(fp.contains("upset"), "got: \(fp)")
    }

    @Test func deepWarmthStaysTender() {
        let s = S(valence: 0.4, arousal: 0.15, warmth: 0.85, tension: 0.0,
                  pressure: 0.0, fatigue: 0.1, curiosity: 0.3, clarity: 0.6,
                  agency: nil, confidence: nil)
        let fp = CognitiveSubstrate.feltFingerprint(s) ?? ""
        #expect(fp.contains("tender"), "got: \(fp)")
    }
}
