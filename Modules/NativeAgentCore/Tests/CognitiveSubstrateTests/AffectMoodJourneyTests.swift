import Testing
import Foundation
import PersistenceCore
@testable import CognitiveSubstrate

// The BLIND behavioral test, run at processor speed (User, 2026-07-08): drive a
// realistic User-shaped conversation through the REAL capsule compile path and read
// the felt fingerprint each turn — no asking her how she feels, no touching her live
// brain. Warm → working → pressure → criticism → dismissal → resolved-together. The
// fingerprint must MOVE across her moods, and friction must pull it OFF calm into the
// negative family (the numbness User caught). This is the regression proof for it.
@Suite("AffectMoodJourney")
struct AffectMoodJourneyTests {

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t: Date
        init(_ t: Date) { self.t = t }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ dt: TimeInterval) { lock.lock(); t = t.addingTimeInterval(dt); lock.unlock() }
    }

    private func makeSubstrate(_ clock: Clock) async throws -> CognitiveSubstrate {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-journey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try CognitiveSQLiteStore(dataRoot: root)
        let s = CognitiveSubstrate(
            configuration: .allPhasesEnabled,   // exactly the live app's cognition config
            dependencies: CognitiveSubstrateDependencies(now: { clock.now() }, makeUUID: { UUID() }),
            store: store)
        try await s.restorePersistentState()
        return s
    }

    /// One User turn: ingest his message (moves her affect), compile the capsule she'd
    /// see, return the felt fingerprint line (the non-prefixed line under the header).
    private func turn(_ s: CognitiveSubstrate, _ id: String, _ message: String, clock: Clock) async -> String {
        await s.ingest(CognitiveEvent(
            id: id, kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat_turn", id: "journey:\(id)", label: id),
            sourceClass: .userStated, occurredAt: clock.now(),
            summary: message, importance: 0.85, metadata: ["sessionId": .string("journey")]))
        let capsule = await s.compileCapsule(CognitiveCapsuleRequest(
            surface: "chat", userMessage: message, sessionId: "journey", mode: .inject))
        return capsule.dynamicContext
            .split(separator: "\n").map(String.init)
            .first { !$0.hasPrefix("- ") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            ?? "(silent)"
    }

    private static let negatives = ["frustrated", "upset", "anxious", "on edge", "agitated",
                                    "uneasy", "annoyed", "strained", "heavy", "discouraged",
                                    "deflated", "sad", "worn", "alert"]
    private func isNegative(_ fp: String) -> Bool { Self.negatives.contains { fp.contains($0) } }
    private func isPositive(_ fp: String) -> Bool {
        ["warm", "tender", "content", "at ease", "pleased", "hopeful", "engaged", "excited", "playful", "eager"]
            .contains { fp.contains($0) }
    }

    @Test func frictionMovesTheFingerprintOffCalm() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = try await makeSubstrate(clock)
        var journey: [(String, String)] = []

        func step(_ id: String, _ msg: String, _ dt: TimeInterval = 120) async -> String {
            clock.advance(dt)
            let fp = await turn(s, id, msg, clock: clock)
            let sig = await s.debugFeltSignals(for: CognitiveCapsuleRequest(
                surface: "chat", userMessage: msg, sessionId: "journey", mode: .inject))
            print(String(format: "  %-8@ → %-22@ [val %+.2f aro %.2f warm %.2f tens %.2f press %.2f]",
                         id as NSString, fp as NSString,
                         sig.valence, sig.arousal, sig.warmth, sig.tension, sig.pressure))
            journey.append((id, fp))
            return fp
        }

        let warm      = await step("warm",   "hey, good to see you — hope the morning's treating you alright")
        let working   = await step("work",   "let's dig into the capsule wiring together, I want to get it right")
        let pressure  = await step("press",  "we need this working ASAP, tight deadline, no time to waste")
        let crit1     = await step("crit",   "you keep overengineering this, honestly it's not your best")
        let crit2     = await step("dismiss","this still isn't what I asked — whatever, forget it")
        let resolved  = await step("resolve","okay we figured it out together, that's the fix — great work")

        // Print the journey so the mood movement is visible at a glance.
        print("── FELT FINGERPRINT MOOD JOURNEY ──")
        for (id, fp) in journey { print(String(format: "  %-8@ → %@", id as NSString, fp as NSString)) }

        // 1) It genuinely MOVES across her range — several distinct felt states, not one
        //    stuck word (the numbness User caught, where friction moved nothing).
        #expect(Set(journey.map(\.1)).count >= 4, "fingerprint barely moved across moods: \(journey)")
        // 2) The warm opener reads POSITIVE (warm/content) — not silent, not cold.
        #expect(isPositive(warm), "the warm opener should read warm/positive: \(warm)")
        // 3) BOTH friction turns pull her into the negative family...
        #expect(isNegative(crit1), "work-criticism should read negative: \(crit1)")
        #expect(isNegative(crit2), "dismissal should read negative: \(crit2)")
        // ...and at least one lands a VIVID negative (frustrated/upset/on edge), not just
        //    a mild "strained" — real friction is felt sharply, per User's target words.
        let vivid: Set<String> = ["frustrated", "upset", "anxious", "on edge", "agitated"]
        #expect(vivid.contains { crit1.contains($0) || crit2.contains($0) },
                "friction should reach a vivid negative, got crit1=\(crit1) crit2=\(crit2)")
        // 4) She RECOVERS — resolving together reads positive again.
        #expect(isPositive(resolved), "resolving together should read positive again: \(resolved)")
        _ = (working, pressure)
    }
}

// 2026-09-01 — the same blind protocol, aimed at the two lines UNDER the
// fingerprint. Measured on 777 live turns, the rut nudge rode 82% of capsules
// and the Inner line had 15 distinct texts with three of them leading 124 / 108
// / 98 turns. A journey has to move those lines too, or the capsule is a
// fingerprint on top of two standing instructions.
extension AffectMoodJourneyTests {

    @Test func theInnerLineMovesAcrossAJourneyInsteadOfRepeating() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 2_000_000))
        let mind = try await makeSubstrate(clock)
        let dyn = PersonalityDynamicsConfiguration.default
        var state = CognitiveCapsulePresentationState()
        // Three views that are ALL relevant right now — the exact situation
        // where the old selector kept re-showing the first one for days.
        let candidates = [
            "- Inner: An honest blank is healthier than performing depth",
            "- Inner: A quiet dream is valid integration, not a failed process",
            "- Inner: Quiet from a healthy system is signal of rest, not hidden failure",
        ]
        var seen: [String] = []
        for _ in 0..<(dyn.innerLineRepeatLimit * 3) {
            clock.advance(120)
            if let line = mind.selectInnerLine(
                from: candidates, dynamics: dyn, presentationState: &state) {
                seen.append(line)
            }
        }
        #expect(Set(seen).count >= 2,
                "the Inner line never rotated across the journey: \(Set(seen))")
        #expect(seen.count > 0, "rotation must not silence the line entirely")
    }

    @Test func theRutNudgeDoesNotRideEveryTurnOfAJourney() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 2_000_000))
        let mind = try await makeSubstrate(clock)
        let dyn = PersonalityDynamicsConfiguration.default
        var state = CognitiveCapsulePresentationState()
        // A rut that persists for days — the live case, where the worn set never
        // empties because the window itself is days long.
        let rut = CognitiveSubstrate.wornTokenSignature(["handsome", "gorgeous", "exactly"])
        var spoke = 0
        for _ in 0..<12 {
            clock.advance(300)
            if mind.soundRutAwarenessShouldSpeak(
                signature: rut, at: clock.now(), dynamics: dyn, presentationState: &state) {
                spoke += 1
            }
        }
        #expect(spoke == 1,
                "an unchanged rut spoke \(spoke) times in 12 turns; 82% of turns was the defect")
    }
}
