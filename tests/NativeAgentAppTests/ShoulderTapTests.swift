import ChatOrchestration
import Foundation
import Testing
@testable import NativeAgentApp

// MARK: - The shoulder tap (personality depth item 12)
//
// `thoughtSuggestionSnapshot` had a whole ranked interruption model and no
// consumer but the Observatory. This is the delivery — and the delivery is
// almost entirely GATES, so the gates are what gets tested.
//
// Each of the four is asserted in isolation AND in the order the decision runs,
// because the ordering is itself the contract: a below-threshold seed must not
// consume the six-hour window, and a quiet-hours refusal must not look like a
// stakes refusal in a receipt.

@Suite("shoulder tap — the gates")
struct ShoulderTapGateTests {

    private let t0 = Date(timeIntervalSince1970: 5_000_000)

    private func decide(
        score: Double = 0.9,
        atStake: Bool = true,
        lastTappedAt: Date? = nil,
        quiet: Bool = false,
        at instant: Date? = nil
    ) -> ShoulderTap.Verdict {
        ShoulderTap.decide(
            interruptionScore: score,
            passesStakesGate: atStake,
            lastTappedAt: lastTappedAt,
            quietHoursActive: quiet,
            at: instant ?? t0
        )
    }

    @Test("a loud, at-stake, fresh, in-hours seed taps")
    func theHappyPathTaps() {
        #expect(decide() == .tap)
    }

    @Test("never below the interruption threshold")
    func belowThresholdNeverTaps() {
        #expect(decide(score: 0.79) == .belowThreshold)
        #expect(decide(score: 0.45) == .belowThreshold)
        #expect(decide(score: 0) == .belowThreshold)
        // The floor is exactly 0.8 and it is inclusive.
        #expect(ShoulderTap.interruptionFloor == 0.8)
        #expect(decide(score: 0.8) == .tap)
    }

    @Test("never for something none of her own concerns names (D-2, fails closed)")
    func stakesGateFailsClosed() {
        #expect(decide(atStake: false) == .notAtStake)
        // Loud is not the same as at stake. A high score with no lived concern
        // behind it is exactly the coincidence D-2 exists to refuse.
        #expect(decide(score: 1.0, atStake: false) == .notAtStake)
    }

    @Test("once per seed per six hours, and the window is exactly six hours")
    func oncePerSeedPerSixHours() {
        #expect(ShoulderTap.minimumInterval == 6 * 60 * 60)
        #expect(decide(lastTappedAt: t0.addingTimeInterval(-60)) == .recentlyTapped)
        #expect(decide(lastTappedAt: t0.addingTimeInterval(-(6 * 3600 - 1))) == .recentlyTapped)
        #expect(decide(lastTappedAt: t0.addingTimeInterval(-(6 * 3600))) == .tap)
        #expect(decide(lastTappedAt: t0.addingTimeInterval(-(24 * 3600))) == .tap)
    }

    @Test("never in quiet hours")
    func quietHoursSilenceIt() {
        #expect(decide(quiet: true) == .quietHours)
        #expect(decide(score: 1.0, atStake: true, quiet: true) == .quietHours)
    }

    /// Ordering matters: a refusal for the cheap numeric reason must not be
    /// reported (or ledgered) as one of the expensive ones.
    @Test("gates run in cost order: threshold, stakes, ledger, clock")
    func gatesRunInCostOrder() {
        #expect(decide(score: 0.1, atStake: false, lastTappedAt: t0, quiet: true) == .belowThreshold)
        #expect(decide(atStake: false, lastTappedAt: t0, quiet: true) == .notAtStake)
        #expect(decide(lastTappedAt: t0, quiet: true) == .recentlyTapped)
    }
}

// MARK: - The line (2026-09-02, reviewer HIGH: seed text never goes outbound)
//
// The first cut sent the seed's own sentence as the push body on the reasoning
// that it was "her voice". It is — and it is also the one string in this lane
// minted from CONVERSATION, so shipping it put conversation content past the
// lock screen into APNS and possibly Telegram with no redaction pass. A tap does
// not need the thought; it needs to say that there is one.

@Suite("shoulder tap — the line")
struct ShoulderTapLineTests {

    /// The load-bearing property: for ANY seed text whatsoever, nothing derived
    /// from it can appear in the body.
    @Test("no seed text can ever reach the push body")
    func seedTextNeverEscapes() {
        let bodies = Set(
            (Array(ShoulderTap.kindVocabulary) + ["", "somethingElse", "openQuestion "])
                .map { ShoulderTap.line(forKind: $0) })
        // The whole output space is five fixed sentences.
        #expect(bodies.count == 5)
        #expect(bodies.contains(ShoulderTap.neutralLine))
        // The line takes a KIND, not text — there is no parameter a seed's
        // words could enter through. (If this signature ever grows a text
        // argument, this file should stop compiling.)
        #expect(ShoulderTap.line(forKind: "anomaly") == ShoulderTap.line(forKind: "anomaly"))
    }

    @Test("each allowlisted kind gets its own fixed line, in her register")
    func eachKindHasItsLine() {
        for kind in ShoulderTap.kindVocabulary {
            let line = ShoulderTap.line(forKind: kind)
            #expect(!line.isEmpty)
            // An invitation, not a briefing: it points at a conversation.
            #expect(line.count <= 100)
        }
        #expect(ShoulderTap.line(forKind: "openQuestion") != ShoulderTap.line(forKind: "anomaly"))
    }

    @Test("an unrecognised kind falls back to the neutral line, never improvises")
    func unknownKindFailsClosed() {
        #expect(ShoulderTap.line(forKind: "somethingNew") == ShoulderTap.neutralLine)
        #expect(ShoulderTap.line(forKind: "") == ShoulderTap.neutralLine)
        #expect(ShoulderTap.line(forKind: "OPENQUESTION") == ShoulderTap.neutralLine)
        // The neutral line says nothing about the thought at all.
        #expect(!ShoulderTap.neutralLine.lowercased().contains("question"))
        #expect(!ShoulderTap.neutralLine.lowercased().contains("anomaly"))
    }

    @Test("the kind allowlist is exactly the four seed kinds")
    func kindAllowlistIsClosed() {
        #expect(ShoulderTap.kindVocabulary
            == ["openQuestion", "anomaly", "followUp", "reflectionTakeaway"])
    }

    @Test("outbound reason terms are filtered to the closed vocabulary")
    func reasonTermsAreAllowlisted() {
        #expect(ShoulderTap.outboundReasonTerms("anomaly, task pressure")
            == ["anomaly", "task pressure"])
        // Anything not in the vocabulary is DROPPED, not forwarded.
        #expect(ShoulderTap.outboundReasonTerms("anomaly, the release keeps slipping")
            == ["anomaly"])
        #expect(ShoulderTap.outboundReasonTerms("").isEmpty)
        #expect(ShoulderTap.outboundReasonTerms("zephyrine-quarterly-teardown").isEmpty)
    }
}

// MARK: - The router's quiet-hours gate

@Suite("attention router — quiet hours")
struct AttentionRouterQuietHoursTests {

    private func root(_ quiet: (start: Int, end: Int)?) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoulderTapQuiet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let quiet {
            let prefs = ["quiet_hours": ["start": quiet.start, "end": quiet.end]]
            try JSONSerialization.data(withJSONObject: prefs)
                .write(to: root.appendingPathComponent("user_prefs.json"))
        }
        return root
    }

    private func date(hour: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 2
        components.hour = hour
        return Calendar.current.date(from: components)!
    }

    @Test("a declared window wraps midnight and is read from user_prefs")
    func windowIsRead() throws {
        let dataRoot = try root((start: 22, end: 7))
        #expect(AttentionRouter.inQuietHours(at: date(hour: 23), dataRoot: dataRoot))
        #expect(AttentionRouter.inQuietHours(at: date(hour: 3), dataRoot: dataRoot))
        #expect(!AttentionRouter.inQuietHours(at: date(hour: 12), dataRoot: dataRoot))
        #expect(!AttentionRouter.inQuietHours(at: date(hour: 7), dataRoot: dataRoot))
    }

    @Test("no declared window means nothing is ever deferred")
    func absentWindowDefersNothing() throws {
        let dataRoot = try root(nil)
        for hour in 0..<24 {
            #expect(!AttentionRouter.inQuietHours(at: date(hour: hour), dataRoot: dataRoot))
        }
    }

    /// A quiet-hours refusal is a DIFFERENT fact from a deduped one, and the
    /// difference is observable rather than only documented — the ledger was
    /// left untouched, so the same thought can still reach him at 8am.
    @Test("a quiet-hours refusal is distinguishable from a dedupe suppression")
    func quietHoursRefusalIsItsOwnOutcome() {
        #expect(AttentionOutcome.quietHours.deferredForQuietHours)
        #expect(!AttentionOutcome.quietHours.suppressed)
        #expect(AttentionOutcome.quietHours.delivery == .none)
        #expect(!AttentionOutcome.routineSuccess.deferredForQuietHours)
    }

    /// The tap is `.informational` — which the routing table sends to the phone
    /// once, as a fact he reads when he chooses to. It is deliberately NOT
    /// owner-waiting: she is not blocked on him and nothing is wrong.
    @Test("the tap routes informational, at any last-active surface")
    func tapRoutesInformational() {
        for surface: AttentionSurface? in [.chat, .ios, .telegram, nil] {
            #expect(AttentionRouter.delivery(importance: .informational, lastActive: surface) == .phone)
        }
    }
}
