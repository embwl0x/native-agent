import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// Ledger rows `substrate.serialization.sessionIdVocabulary` and
// `serialization.sessionIdSnakeCaseBranch` (fence core.substrate.field).
//
// `sessionIdString` (CognitiveSubstrate+Serialization.swift:129) accepts BOTH
// `sessionId` and `session_id`. That tolerance makes the reader LOOK safe while
// the real risk points the other way: a producer that stamps NEITHER key yields
// a nil session id, which silently turns two behaviours into no-ops rather than
// errors —
//   1. the per-session live user-turn cap (Workspace.swift:279), and
//   2. the cross-session verification eviction (Workspace.swift:742).
// Neither degradation raises anything. Nothing asserted that live nodes carry a
// session id, or that the two vocabularies behave identically.
//
// This suite pins the reader contract, then proves the two BEHAVIOURS actually
// key off it — including the silent-disable case, which is the shape 85% of the
// live field is in.
@Suite("SessionIdVocabulary")
struct SessionIdVocabularyTests {

    private static let at = Date(timeIntervalSince1970: 1_700_000_000)

    private func substrate(maximumWorkspaceItems: Int = 12) -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: true,
                workspaceEnabled: true,
                maximumWorkspaceItems: maximumWorkspaceItems
            ),
            dependencies: CognitiveSubstrateDependencies(now: { Self.at })
        )
    }

    private func node(metadata: [String: JSONValue]) -> CognitiveNode {
        CognitiveNode(
            id: UUID(),
            kind: .conversationFocus,
            subjectReference: CognitiveSubjectReference(type: "chat.user_turn", id: "turn-1"),
            activation: 0.7, salience: 0.7, confidence: 0.85,
            sourceClass: .userStated,
            createdAt: Self.at, lastActivatedAt: Self.at, decayHalfLife: 3_600,
            summary: "a turn", metadata: metadata
        )
    }

    private func turn(
        id: String,
        subjectID: String,
        subjectType: String = "chat.user_turn",
        turnKind: CognitiveTurnKind = .live,
        sessionKey: String? = "sessionId",
        session: String? = "session-a"
    ) -> CognitiveEvent {
        var metadata: [String: JSONValue] = [:]
        if let sessionKey, let session { metadata[sessionKey] = .string(session) }
        return CognitiveEvent(
            id: id,
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: subjectType, id: subjectID),
            sourceClass: .userStated,
            occurredAt: Self.at,
            summary: "turn \(subjectID)",
            importance: 0.6,
            turnKind: turnKind,
            metadata: metadata
        )
    }

    // MARK: - reader contract

    @Test("both vocabularies read, camelCase wins, blank and absent read as nil")
    func readerAcceptsBothVocabulariesAndRejectsBlanks() {
        #expect(node(metadata: ["sessionId": .string("s-1")]).sessionId == "s-1")
        #expect(node(metadata: ["session_id": .string("s-1")]).sessionId == "s-1")
        // Precedence must be deterministic — a node carrying both keys cannot
        // resolve differently on different reads.
        #expect(node(metadata: [
            "sessionId": .string("camel"), "session_id": .string("snake"),
        ]).sessionId == "camel")
        // Surrounding whitespace is trimmed, an empty/blank id is NOT a session.
        #expect(node(metadata: ["sessionId": .string("  s-1  ")]).sessionId == "s-1")
        #expect(node(metadata: ["sessionId": .string("   ")]).sessionId == nil)
        #expect(node(metadata: ["sessionId": .string("")]).sessionId == nil)
        // A non-string value is not a session id (no coercion).
        #expect(node(metadata: ["sessionId": .int(7)]).sessionId == nil)
        #expect(node(metadata: [:]).sessionId == nil)
        // The event reader is the same law — the two must never drift apart,
        // since the eviction gate compares one against the other.
        #expect(turn(id: "e", subjectID: "t", session: "s-1").sessionId == "s-1")
        #expect(turn(id: "e", subjectID: "t", sessionKey: "session_id", session: "s-1").sessionId == "s-1")
        #expect(turn(id: "e", subjectID: "t", sessionKey: nil, session: nil).sessionId == nil)
    }

    // MARK: - behaviour 1: cross-session verification eviction

    /// Ingest one verification turn, then one live turn, and report whether the
    /// verification node survived.
    private func verificationSurvives(
        verificationSessionKey: String?,
        verificationSession: String?,
        liveSessionKey: String?,
        liveSession: String?
    ) async -> Bool {
        let mind = substrate()
        await mind.ingest(turn(
            id: "verify-1", subjectID: "verify-turn", turnKind: .verification,
            sessionKey: verificationSessionKey, session: verificationSession))
        #expect(await mind.snapshot().nodes.contains { $0.turnKind == .verification })
        await mind.ingest(turn(
            id: "live-1", subjectID: "live-turn", turnKind: .live,
            sessionKey: liveSessionKey, session: liveSession))
        return await mind.snapshot().nodes.contains { $0.turnKind == .verification }
    }

    @Test("cross-session verification eviction behaves identically in both vocabularies")
    func verificationEvictionIsVocabularyAgnostic() async {
        for key in ["sessionId", "session_id"] {
            // Different session → the spent verification node is evicted.
            #expect(await verificationSurvives(
                verificationSessionKey: key, verificationSession: "session-a",
                liveSessionKey: key, liveSession: "session-b") == false,
                "\(key): a stale verification node survived a new session")
            // Same session → it stays (it is not yet spent).
            #expect(await verificationSurvives(
                verificationSessionKey: key, verificationSession: "session-a",
                liveSessionKey: key, liveSession: "session-a") == true,
                "\(key): a same-session verification node was evicted early")
        }
        // …and MIXED vocabularies still compare as the same session: this is the
        // two-vocabulary seam, where an id compare silently fails open.
        #expect(await verificationSurvives(
            verificationSessionKey: "session_id", verificationSession: "session-a",
            liveSessionKey: "sessionId", liveSession: "session-b") == false)
        #expect(await verificationSurvives(
            verificationSessionKey: "session_id", verificationSession: "session-a",
            liveSessionKey: "sessionId", liveSession: "session-a") == true)
    }

    @Test("an unstamped session id silently DISABLES the eviction, in both directions")
    func missingSessionIdDisablesEvictionSilently() async {
        // The live turn carries no session → the gate returns before doing any
        // work, so even a genuinely stale verification node survives.
        #expect(await verificationSurvives(
            verificationSessionKey: "sessionId", verificationSession: "session-a",
            liveSessionKey: nil, liveSession: nil) == true)
        // The verification node carries no session → it can only be aged out
        // (6h), never recognized as belonging to another session.
        #expect(await verificationSurvives(
            verificationSessionKey: nil, verificationSession: nil,
            liveSessionKey: "sessionId", liveSession: "session-b") == true)
    }

    // MARK: - behaviour 2: the per-session live user-turn cap

    private func workspaceSessionCounts(
        sessionKey: String?,
        sessions: [String?]
    ) async -> (kept: Int, perSession: [String: Int]) {
        let mind = substrate()
        var index = 0
        for session in sessions {
            index += 1
            await mind.ingest(turn(
                id: "turn-\(index)", subjectID: "turn-\(index)",
                sessionKey: sessionKey, session: session))
        }
        let items = await mind.workspaceSnapshot().items
        var counts: [String: Int] = [:]
        for item in items {
            let key = item.node.sessionId ?? "unknown"
            counts[key, default: 0] += 1
        }
        return (items.count, counts)
    }

    @Test("live user turns are capped at two PER SESSION, not two overall")
    func userTurnCapIsPerSession() async {
        let result = await workspaceSessionCounts(
            sessionKey: "sessionId",
            sessions: ["session-a", "session-a", "session-a", "session-b", "session-b", "session-b"])
        // Three turns in each of two sessions → two survive from each. The cap
        // exists so one long conversation cannot fill the whole workspace.
        #expect(result.perSession["session-a"] == 2)
        #expect(result.perSession["session-b"] == 2)
        #expect(result.kept == 4)
    }

    @Test("unstamped user turns all share ONE cap bucket — the silent-disable shape")
    func unstampedUserTurnsShareOneBucket() async {
        // This is what 85% of the live field looks like: no session key at all.
        // Every such turn falls into the same "unknown" bucket, so the cap stops
        // being per-session and becomes a global two-item cap on user turns.
        let result = await workspaceSessionCounts(sessionKey: nil, sessions: [nil, nil, nil, nil])
        #expect(result.perSession["unknown"] == 2)
        #expect(result.kept == 2)
    }

    @Test("the cap only applies to chat.user_turn subjects")
    func capIsScopedToUserTurnSubjects() async {
        let mind = substrate()
        for index in 0..<4 {
            await mind.ingest(turn(
                id: "assistant-\(index)", subjectID: "assistant-\(index)",
                subjectType: "chat.assistant_turn", session: "session-a"))
        }
        // A negative control for the cap itself: were it keyed on something
        // broader, these four would be trimmed to two as well.
        #expect(await mind.workspaceSnapshot().items.count == 4)
    }
}
