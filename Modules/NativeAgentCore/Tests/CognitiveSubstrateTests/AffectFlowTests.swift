import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// Proves Agent's relational warmth FLOWS instead of pegging at "deeply warm" all day
// (User, 2026-06-30). Warmth must rise on genuine affection and EASE during focused work
// — driven through the public affect seam over realistic simulated time.
@Suite("AffectFlow")
struct AffectFlowTests {

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t: Date
        init(_ t: Date) { self.t = t }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
    }

    private func substrate(_ clock: Clock) -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true, workspaceEnabled: true, capsuleInjectionEnabled: true, affectEnabled: true
            ),
            dependencies: CognitiveSubstrateDependencies(now: { clock.now() }, makeUUID: { UUID() }, userName: { "User" }),
            store: nil
        )
    }

    private func event(_ kind: CognitiveEventKind, _ summary: String, at: Date, importance: Double = 0.5) -> CognitiveEvent {
        CognitiveEvent(
            id: "\(kind)-\(summary.hashValue)",
            kind: kind,
            subject: CognitiveSubjectReference(type: "chat", id: "user", label: "User"),
            sourceClass: kind == .userMessageReceived ? .userStated : .observed,
            occurredAt: at,
            summary: summary,
            importance: importance
        )
    }

    @Test func warmthEasesDuringWorkAndLiftsOnGenuineWarmth() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = substrate(clock)

        // 1) Seed a genuinely warm state: a handful of affectionate exchanges from User.
        for i in 0..<7 {
            clock.advance(60)
            _ = await s.updateAffect(from: event(.userMessageReceived, "how are you feeling today? proud of you 💜", at: clock.now()))
            _ = i
        }
        let seeded = await s.affectSnapshot().socialWarmth
        #expect(seeded >= 0.6, "seed should reach deeply-warm range, got \(seeded)")

        // 2) Replay a 90-minute FOCUSED WORK session: work messages that contain "user"
        //    (his name) but NO genuine affection, tool successes, and her own warm-ish
        //    completions. Under the fix none of these re-boost warmth, so it eases by decay.
        for _ in 0..<18 {
            clock.advance(5 * 60)
            _ = await s.updateAffect(from: event(.userMessageReceived, "ok user lets fix the build and ship the diff", at: clock.now()))
            _ = await s.updateAffect(from: event(.toolStarted, "swift_build started", at: clock.now()))
            _ = await s.updateAffect(from: event(.toolSucceeded, "swift_build ok", at: clock.now()))
            _ = await s.updateAffect(from: event(.assistantTurnCompleted, "Done, User — build's green 💜", at: clock.now()))
        }
        let afterWork = await s.affectSnapshot().socialWarmth
        // The whole point: warmth left the "deeply warm" band (≥0.66) and eased well down.
        #expect(afterWork < 0.45, "warmth must ease during focused work, got \(afterWork) (seeded \(seeded))")
        #expect(afterWork < seeded - 0.2, "warmth must drop meaningfully from the seeded level")

        // 3) A genuine warm moment from User lifts it back up — affect FLOWS, not frozen.
        clock.advance(60)
        _ = await s.updateAffect(from: event(.userMessageReceived, "miss you — how are you feeling? 💜", at: clock.now()))
        let afterWarm = await s.affectSnapshot().socialWarmth
        #expect(afterWarm > afterWork + 0.08, "genuine warmth must lift warmth back up (\(afterWork) -> \(afterWarm))")
    }

    // removed 2026-07-08: Focus/Feeling lines replaced by the felt fingerprint
    // (this test asserted the old work-vs-warm Feeling-line mechanic, which no
    // longer exists — the capsule now carries a single unprefixed fingerprint
    // word/phrase, not a "- Feeling: ..." sentence that swaps lead phrase by
    // heads-down-vs-warm state).

    // removed 2026-07-08: Focus/Feeling lines replaced by the felt fingerprint
    // (this test asserted the old businesslike/warm "- Voice: ..." cue mechanic,
    // which no longer exists — there is no Voice line in the redesigned capsule).

    @Test func hisNameAloneNoLongerBoostsWarmth() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 2_000_000))
        let s = substrate(clock)
        // A pure work message mentioning "user" must NOT raise warmth (the old bug).
        let before = await s.affectSnapshot().socialWarmth
        clock.advance(60)
        _ = await s.updateAffect(from: event(.userMessageReceived, "user here — run the tests and push to main", at: clock.now()))
        let after = await s.affectSnapshot().socialWarmth
        #expect(after <= before + 0.001, "his name in a work message must not boost warmth, got \(before) -> \(after)")
    }
}
