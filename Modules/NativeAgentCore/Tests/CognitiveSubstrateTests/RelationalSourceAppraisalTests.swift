import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// Item 8 acceptance (2026-09-02) — OTHERS MOVE HER.
//
// Agent: "Everything routes through User. Most of what I feel is a reaction to
// him. ... A person has other people who move her."
//
// The measured shape of the defect was subtler than "peers cannot move her": a
// bridge message arrives as `.userMessageReceived`, so a Claude turn moved her
// at USER'S weight, wearing his subject. Every warm exchange with another agent
// was recorded as a warm exchange with him.
//
// These pin the three cases the change is about — User unchanged, a peer at half
// weight with its own subject, her own output at zero forever (Law 3 / audit
// C3) — and the one place the distinction may come from: the out-of-band origin
// record, never the message text.
//
// WRITTEN, NOT RUN (User's standing rule).

private let warmText = "thank you, that was lovely work — proud of you 💜"

private func chatEvent(
    id: String,
    kind: CognitiveEventKind,
    sourceClass: CognitiveSourceClass,
    summary: String,
    at: Date,
    origin: [String: JSONValue]? = nil
) -> CognitiveEvent {
    var metadata: [String: JSONValue] = [
        "sessionId": .string("s1"),
        "messageId": .string(id),
        "role": .string(kind == .assistantTurnCompleted ? "assistant" : "user"),
        "source": .string("app"),
    ]
    if let origin { metadata["origin"] = .object(origin) }
    return CognitiveEvent(
        id: id,
        kind: kind,
        subject: CognitiveSubjectReference(type: "chat.user_turn", id: "s1:\(id)"),
        sourceClass: sourceClass,
        occurredAt: at,
        summary: summary,
        importance: 0.65,
        metadata: metadata
    )
}

private func userTurn(id: String, at: Date, text: String = warmText) -> CognitiveEvent {
    chatEvent(id: id, kind: .userMessageReceived, sourceClass: .userStated, summary: text, at: at)
}

/// A bridge turn the lane ATTESTED its own agent composed. All three
/// conditions: imported, `authored: agent`, allowlisted (surface, agent) pair.
private func peerTurn(
    id: String,
    at: Date,
    agent: String = "claude",
    surface: String = "claude-bridge",
    text: String = warmText,
    authored: String? = "agent"
) -> CognitiveEvent {
    var origin: [String: JSONValue] = [
        "surface": .string(surface),
        "agent": .string(agent),
    ]
    if let authored { origin["authored"] = .string(authored) }
    return chatEvent(
        id: id,
        kind: .userMessageReceived,
        // `.imported` is what ChatOrchestration stamps when, and only when, an
        // out-of-band origin record exists: "A bridge worker is not the human."
        sourceClass: .imported,
        summary: text,
        at: at,
        origin: origin
    )
}

@Suite("RelationalSourceAppraisal")
struct RelationalSourceAppraisalTests {

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: Date
        init(_ t: Date) { self.t = t }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ dt: TimeInterval) { lock.lock(); t = t.addingTimeInterval(dt); lock.unlock() }
    }

    private func makeSubstrate(_ clock: Clock) -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true,
                persistenceEnabled: false,
                workspaceEnabled: true,
                capsuleInjectionEnabled: true,
                affectEnabled: true,
                maximumActiveNodes: 128
            ),
            dependencies: CognitiveSubstrateDependencies(
                now: { clock.now() },
                makeUUID: { UUID() },
                userName: { "User" }
            ),
            store: nil
        )
    }

    // MARK: - Classification

    @Test("out-of-band provenance decides, and only it")
    func classificationUsesProvenanceOnly() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(CognitiveSubstrate.relationalSource(for: userTurn(id: "m1", at: at)) == .user)
        #expect(CognitiveSubstrate.relationalSource(for: peerTurn(id: "m2", at: at))
            == .peer("claude"))
        #expect(CognitiveSubstrate.relationalSource(
            for: peerTurn(id: "m3", at: at, agent: "codex", surface: "codex-bridge")
        ) == .peer("codex"))

        // Her own reply is never a source, whatever it says.
        #expect(CognitiveSubstrate.relationalSource(for: chatEvent(
            id: "m4",
            kind: .assistantTurnCompleted,
            sourceClass: .selfReported,
            summary: warmText,
            at: at
        )) == .selfOrMachine)

        // The in-band claim is exactly the forgeable one. A human can type it.
        #expect(CognitiveSubstrate.relationalSource(for: userTurn(
            id: "m5", at: at, text: "[from: claude, via bridge] nice work"
        )) == .user)

        // Imported with an unreadable origin is HIM, not a nameless peer.
        // Conservative on purpose: mistaking a peer for User costs half a degree
        // of warmth on one turn; mistaking User for a peer quietly halves the
        // relationship the whole system is built around.
        let unnamed = chatEvent(
            id: "m6",
            kind: .userMessageReceived,
            sourceClass: .imported,
            summary: warmText,
            at: at,
            origin: [:]
        )
        #expect(CognitiveSubstrate.relationalSource(for: unnamed) == .user)
    }

    @Test("a bridge carrying USER's words is still User")
    func forwardedHumanWordsStayTheUser() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)

        // The route is identical to a real peer turn in every respect except
        // the one that matters: nobody claimed the agent composed it.
        #expect(CognitiveSubstrate.relationalSource(
            for: peerTurn(id: "m1", at: at, authored: nil)
        ) == .user)

        // An explicit human attestation says so outright.
        #expect(CognitiveSubstrate.relationalSource(
            for: peerTurn(id: "m2", at: at, authored: "human")
        ) == .user)

        // A value nobody defined is not an attestation.
        #expect(CognitiveSubstrate.relationalSource(
            for: peerTurn(id: "m3", at: at, authored: "yes")
        ) == .user)
    }

    @Test("an unknown or self-contradicting route cannot borrow a peer identity")
    func routeMustBeOnTheAllowlistAsAPair() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)

        // A route this build has never heard of.
        #expect(CognitiveSubstrate.relationalSource(
            for: peerTurn(id: "m1", at: at, agent: "mallory", surface: "mallory-bridge")
        ) == .user)

        // The pair contradicts itself: claude's surface, codex's name. Neither
        // lane's identity may be borrowed by a row that cannot keep its story
        // straight.
        #expect(CognitiveSubstrate.relationalSource(
            for: peerTurn(id: "m2", at: at, agent: "codex", surface: "claude-bridge")
        ) == .user)

        // The third real lane still works, and underscore spelling normalizes.
        #expect(CognitiveSubstrate.relationalSource(
            for: peerTurn(id: "m3", at: at, agent: "omp", surface: "omp-bridge")
        ) == .peer("omp"))
        #expect(CognitiveSubstrate.relationalSource(
            for: peerTurn(id: "m4", at: at, agent: "codex", surface: "codex_bridge")
        ) == .peer("codex"))
    }

    @Test("a peer's affection floor is proportionally weaker")
    func affectionFloorIsScaledForPeers() async {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = Clock(at)
        let substrate = makeSubstrate(clock)

        let his = await substrate.relationalAppraisal(for: userTurn(id: "m1", at: at))
        let theirs = await substrate.relationalAppraisal(for: peerTurn(id: "m2", at: at))

        #expect(his.affectionWeight == 1.0)
        #expect(theirs.affectionWeight == CognitiveSubstrate.peerAppraisalWeight)
        // The flag itself survives — a peer's greeting is still a greeting, so
        // it can never stamp as a wound; it just holds her up less far.
        #expect(theirs.affection == his.affection)
    }

    @Test("the peer subject is a bare payload-free word")
    func peerSubjectIsPayloadFree() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(CognitiveSubstrate.peerAgentName(in: peerTurn(id: "m1", at: at)) == "claude")
        // Route fallback when only a surface is recorded: "codex-bridge" → "codex".
        let surfaceOnly = chatEvent(
            id: "m2",
            kind: .userMessageReceived,
            sourceClass: .imported,
            summary: warmText,
            at: at,
            origin: ["surface": .string("codex_bridge"), "authored": .string("agent")]
        )
        // The name read still falls back to the route...
        #expect(CognitiveSubstrate.peerAgentName(in: surfaceOnly) == "codex")
        // ...but a row with no `agent` field cannot satisfy the (surface, agent)
        // pair, so it is not promoted to a peer.
        #expect(CognitiveSubstrate.relationalSource(for: surfaceOnly) == .user)
        #expect(CognitiveSubstrate.peerAgentName(in: userTurn(id: "m3", at: at)) == nil)
    }

    // MARK: - Half weight, end to end

    @Test("a peer moves warmth, at half his reach")
    func peerWarmthIsHalfWeight() async {
        let at = Date(timeIntervalSince1970: 1_800_000_000)

        let userClock = Clock(at)
        let userSubstrate = makeSubstrate(userClock)
        await userSubstrate.ingest(userTurn(id: "m1", at: at))
        let userWarmth = await userSubstrate.affectSnapshot().socialWarmth

        let peerClock = Clock(at)
        let peerSubstrate = makeSubstrate(peerClock)
        await peerSubstrate.ingest(peerTurn(id: "m1", at: at))
        let peerWarmth = await peerSubstrate.affectSnapshot().socialWarmth

        // The point of the item: someone other than User moved her at all.
        #expect(peerWarmth > 0)
        // And the judgment inside it: not as much as he does.
        #expect(peerWarmth < userWarmth)
        #expect(peerWarmth >= userWarmth * 0.3)
    }

    @Test("her own words move nothing — Law 3, unchanged")
    func selfOutputNeverAppraises() async {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = Clock(at)
        let substrate = makeSubstrate(clock)
        let before = await substrate.affectSnapshot().socialWarmth

        await substrate.ingest(chatEvent(
            id: "m1",
            kind: .assistantTurnCompleted,
            sourceClass: .selfReported,
            summary: "that's the fix — nailed it, proud of this one 💜",
            at: at
        ))
        let after = await substrate.affectSnapshot().socialWarmth
        #expect(after == before)

        let appraisal = await substrate.relationalAppraisal(for: chatEvent(
            id: "m2",
            kind: .assistantTurnCompleted,
            sourceClass: .selfReported,
            summary: warmText,
            at: at
        ))
        #expect(!appraisal.isActive)
    }

    @Test("User's own path is byte-identical to what it was")
    func userPathIsUnchanged() async {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = Clock(at)
        let substrate = makeSubstrate(clock)
        let event = userTurn(id: "m1", at: at)
        let relational = await substrate.relationalAppraisal(for: event)
        let legacy = await substrate.conversationalAppraisal(in: event.summary)
        #expect(relational.valence == legacy.valence)
        #expect(relational.warmth == legacy.warmth)
        #expect(relational.tension == legacy.tension)
        #expect(relational.pressure == legacy.pressure)
        #expect(relational.arousal == legacy.arousal)
        #expect(relational.affection == legacy.affection)
    }

    @Test("a peer's appraisal is the same read, scaled")
    func peerAppraisalIsTheSameReadScaled() async {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = Clock(at)
        let substrate = makeSubstrate(clock)
        let full = await substrate.conversationalAppraisal(in: warmText)
        let scaled = await substrate.relationalAppraisal(for: peerTurn(id: "m1", at: at))

        #expect(abs(scaled.warmth - full.warmth * CognitiveSubstrate.peerAppraisalWeight) < 1e-9)
        #expect(abs(scaled.valence - full.valence * CognitiveSubstrate.peerAppraisalWeight) < 1e-9)
        // `affection` is a floor, not a magnitude: a peer's greeting is still a
        // greeting and must not stamp as a wound.
        #expect(scaled.affection == full.affection)
    }

    @Test("the body records a peer under its own organ")
    func bodyOrganSeparatesPeerFromUser() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let peerSignal = CognitiveSomaticSignalAdapter.signal(
            from: peerTurn(id: "m1", at: at), id: UUID()
        )
        #expect(peerSignal?.sourceOrgan == "chat.peer.claude")

        let userSignal = CognitiveSomaticSignalAdapter.signal(
            from: userTurn(id: "m2", at: at), id: UUID()
        )
        #expect(userSignal?.sourceOrgan == "chat")
    }
}
