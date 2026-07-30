import Foundation
import Testing
import PersistenceCore
@testable import CognitiveSubstrate

// Mind-into-circulation (2026-07-10, fence A): the CognitiveSubstrate side of
// `attentionSignals(at:)` — a bounded, PURE read of what she is holding, shaped
// for Fluid Context's dormant NeedSignal inputs. These pin the four sources
// (terms / unresolvedQuestion / memoryActivation) and the two inert contracts
// (disabled → nil, empty mind → nil, never an empty struct).
@Suite("AttentionSignals")
struct AttentionSignalsTests {

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t: Date
        init(_ t: Date) { self.t = t }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ dt: TimeInterval) { lock.lock(); t = t.addingTimeInterval(dt); lock.unlock() }
    }

    private func makeSubstrate(_ clock: Clock, enabled: Bool = true) -> CognitiveSubstrate {
        CognitiveSubstrate(
            configuration: CognitiveConfiguration(
                enabled: enabled, workspaceEnabled: true,
                capsuleInjectionEnabled: true, affectEnabled: true,
                maximumActiveNodes: 64),
            dependencies: CognitiveSubstrateDependencies(now: { clock.now() }, makeUUID: { UUID() }))
    }

    /// A human-topic focus node (subject type "topic") — the shape that should
    /// survive cleaning and become a lexical term.
    private func topicTurn(
        _ id: String, topic: String, text: String, session: String = "a1", at now: Date
    ) -> CognitiveEvent {
        CognitiveEvent(
            id: "chat:\(session):\(id)", kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "topic", id: topic),
            sourceClass: .userStated, occurredAt: now,
            summary: text, importance: 0.7,
            metadata: ["sessionId": .string(session)])
    }

    /// A per-turn user subject exactly as ChatOrchestration mints it — machine-keyed.
    private func userTurn(_ id: String, _ text: String, session: String = "a1", at now: Date) -> CognitiveEvent {
        CognitiveEvent(
            id: "chat:\(session):\(id)", kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat.user_turn", id: "\(session):\(id)"),
            sourceClass: .userStated, occurredAt: now,
            summary: text, importance: 0.65,
            metadata: ["sessionId": .string(session)])
    }

    private func completion(_ id: String, session: String = "a1", at now: Date) -> CognitiveEvent {
        CognitiveEvent(
            id: "chat:\(session):\(id)", kind: .assistantTurnCompleted,
            subject: CognitiveSubjectReference(type: "chat.assistant_turn", id: "\(session):\(id)"),
            sourceClass: .selfReported, occurredAt: now,
            summary: "Rewrote the decoder and the suite is green.", importance: 0.55,
            metadata: ["sessionId": .string(session)])
    }

    // MARK: - (a) hot workspace subject → cleaned term with sane weight

    @Test func hotWorkspaceSubjectSurfacesAsCleanedTerm() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        await s.ingest(topicTurn("m1", topic: "Rome Trip", text: "planning the trip to Rome", at: clock.now()))

        let signals = try #require(await s.attentionSignals(at: clock.now()))
        let weight = try #require(signals.terms["rome trip"], "cleaned topic subject should be a term")
        #expect(weight > 0, "term weight should be the item's positive selection score")
        #expect(weight <= 1, "term weight must be clamped 0…1")
    }

    // MARK: - (b) machine-keyed subjects never leak as terms

    @Test func machineKeyedSubjectsNeverLeakAsTerms() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        await s.ingest(userTurn("m1", "hey there, quick question", at: clock.now()))
        await s.ingest(completion("m2", at: clock.now()))
        // A tool observation node — subject type "tool", id/label = tool name.
        await s.ingest(CognitiveEvent(
            id: "chat-tool:a1:m3", kind: .toolSucceeded,
            subject: CognitiveSubjectReference(type: "tool", id: "read_file", label: "read_file"),
            sourceClass: .observed, occurredAt: clock.now(),
            summary: "read_file ok", importance: 0.55,
            metadata: ["sessionId": .string("a1")]))

        let signals = await s.attentionSignals(at: clock.now())
        // Refined contract (live-battery finding, 2026-07-10): machine-keyed
        // SUBJECTS never become terms, but their summaries' CONTENT WORDS do —
        // in production every subject is machine-keyed (256/256 in her live
        // store), so summaries are the only live topic source. What must never
        // leak: routing handles, composite ids, tool names, subject types.
        let terms = signals?.terms ?? [:]
        #expect(terms["a1:m1"] == nil, "composite handle leaked: \(terms)")
        #expect(terms["read_file"] == nil, "tool name leaked: \(terms)")
        #expect(terms["chat"] == nil && terms["tool"] == nil, "subject type leaked: \(terms)")
        for key in terms.keys {
            #expect(!key.contains(":"), "machine composite in terms: \(key)")
        }
        // The human content DOES surface ("quick question" from the user turn).
        #expect(terms.keys.contains("question"), "summary content should surface: \(terms)")
    }

    // MARK: - (c) pendingCompletion → unresolvedQuestion; absent slot → nil

    @Test func openCompletionProducesUnresolvedQuestion() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        await s.ingest(completion("m1", at: clock.now()))

        let signals = try #require(await s.attentionSignals(at: clock.now()))
        let question = try #require(signals.unresolvedQuestion, "an open completion should phrase an unresolved question")
        #expect(question.contains("Rewrote the decoder"), "the question should be grounded in her last turn: \(question)")
    }

    @Test func absentPendingSlotYieldsNoQuestion() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        // A user turn opens no completion slot; a topic keeps the read non-empty
        // so we isolate that unresolvedQuestion specifically is nil.
        await s.ingest(topicTurn("m1", topic: "weekend plans", text: "what are we doing this weekend", at: clock.now()))

        let signals = try #require(await s.attentionSignals(at: clock.now()))
        #expect(signals.unresolvedQuestion == nil, "no pending completion → no unresolved question")
    }

    @Test func stalePendingSlotYieldsNoQuestion() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        await s.ingest(completion("m1", at: clock.now()))
        // Age the read past the pendingCompletion window — a completion gone
        // quiet is no longer a live question, even without an intervening ingest.
        clock.advance(CognitiveSubstrate.pendingCompletionMaxAge + 60)

        let signals = await s.attentionSignals(at: clock.now())
        #expect(signals?.unresolvedQuestion == nil, "a stale completion should not surface as an open question")
    }

    // MARK: - (d) memory-referencing node → record id in memoryActivation

    @Test func memoryReferencingNodeYieldsRecordActivation() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        await s.ingest(CognitiveEvent(
            id: "chat:a1:m1", kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "topic", id: "the cabin"),
            sourceClass: .userStated, occurredAt: clock.now(),
            summary: "remember when we talked about the cabin", importance: 0.7,
            metadata: [
                "sessionId": .string("a1"),
                "memoryRecordIds": .array([.string("rec-abc"), .string("rec-def")]),
            ]))

        let signals = try #require(await s.attentionSignals(at: clock.now()))
        let activation = try #require(signals.memoryActivation["rec-abc"], "record id should map to node activation")
        #expect(activation > 0 && activation <= 1, "memory activation must be clamped 0…1")
        #expect(signals.memoryActivation["rec-def"] != nil, "all referenced record ids surface")
        #expect(signals.workingMemoryRecordIDs.contains("rec-abc"))
        #expect(signals.workingMemoryRecordIDs.contains("rec-def"))
    }

    @Test func memorySubjectNodeYieldsRecordActivation() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        // The subject-shaped convention: a node whose subject IS a memory record.
        await s.ingest(CognitiveEvent(
            id: "mem:a1:m1", kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "memory_record", id: "rec-xyz"),
            sourceClass: .userStated, occurredAt: clock.now(),
            summary: "a remembered fact", importance: 0.7,
            metadata: ["sessionId": .string("a1")]))

        let signals = try #require(await s.attentionSignals(at: clock.now()))
        #expect(signals.memoryActivation["rec-xyz"] != nil, "memory_record subject id should surface as a record")
        // And it must NOT leak as a lexical term (record ids aren't topics).
        #expect(signals.terms["rec-xyz"] == nil)
    }

    // MARK: - (e) disabled substrate → nil

    @Test func disabledSubstrateReturnsNil() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock, enabled: false)
        // Ingest is a no-op while disabled, but assert the gate directly too.
        await s.ingest(topicTurn("m1", topic: "anything", text: "hello", at: clock.now()))
        let signals = await s.attentionSignals(at: clock.now())
        #expect(signals == nil, "disabled cognition must add nothing")
    }

    // MARK: - (f) empty mind → nil (NOT an empty struct)

    @Test func emptyMindReturnsNilNotEmptyStruct() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        let signals = await s.attentionSignals(at: clock.now())
        #expect(signals == nil, "an empty mind returns nil so the default inert path stays byte-identical")
    }

    // MARK: - Summary keywords (live-battery finding, 2026-07-10)

    /// In production EVERY node subject is machine-keyed (verified: 256/256
    /// in her live store), so terms must come from node SUMMARIES — the human
    /// prose of what she's thinking about.
    @Test func summaryKeywordsExtractContentWordsNotNoise() async throws {
        let words = CognitiveSubstrate.summaryKeywords(
            from: "[from: claude, via bridge] I was thinking about the morning brief you sent User today — did the reflexes review feel different?")
        #expect(words.contains("morning"))
        #expect(words.contains("brief"))
        #expect(!words.contains("claude"), "routing prefix must be stripped")
        #expect(!words.contains("the"))
        #expect(words.count <= 4)
    }

    @Test func machineSubjectNodesStillYieldSummaryTerms() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        // A chat.user_turn node — machine subject, human summary.
        await s.ingest(CognitiveEvent(
            id: "chat:s1:m1",
            kind: .userMessageReceived,
            subject: CognitiveSubjectReference(type: "chat.user_turn", id: "s1:m1"),
            sourceClass: .userStated,
            occurredAt: clock.now(),
            summary: "Planning the greenhouse irrigation schedule for the tomatoes",
            importance: 0.7,
            metadata: [:]
        ))
        let signals = try #require(await s.attentionSignals(at: clock.now()))
        #expect(signals.terms.keys.contains("greenhouse"),
                "summary keywords must fire even when every subject is machine-keyed: \(signals.terms)")
        #expect(signals.terms.keys.contains("irrigation"))
        #expect(!signals.terms.keys.contains("chat"), "no machine shrapnel")
    }

    /// 2026-07-21 audit: .system-turn nodes (tool receipts, felt
    /// resolutions) carry machine status text in their summaries. The
    /// summary-keyword path must not tokenize them into contextualTerms —
    /// the same live-only gate capsuleEligibleWorkspaceNode applies.
    @Test func systemTurnNodesNeverYieldSummaryTerms() async throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let s = makeSubstrate(clock)
        // The ONLY hot node is a .system tool observation whose summary is
        // machine text with a distinctive token.
        await s.ingest(CognitiveEvent(
            id: "tool:s1:t1",
            kind: .toolSucceeded,
            subject: CognitiveSubjectReference(type: "tool", id: "xcodebuild"),
            sourceClass: .observed,
            occurredAt: clock.now(),
            summary: "Exact tool receipt says zqxvbuildmarker succeeded.",
            importance: 0.9,
            turnKind: .system,
            metadata: ["toolName": .string("xcodebuild")]
        ))
        let signals = await s.attentionSignals(at: clock.now())
        let terms = signals?.terms ?? [:]
        #expect(!terms.keys.contains("zqxvbuildmarker"),
                "system-turn machine summary leaked into terms: \(terms)")
        #expect(!terms.keys.contains("xcodebuild"),
                "machine tool handle leaked into terms: \(terms)")
    }
}
