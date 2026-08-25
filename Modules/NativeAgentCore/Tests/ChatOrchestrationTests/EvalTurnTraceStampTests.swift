import DreamREMCycle
import Foundation
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import Testing
@testable import ChatOrchestration

// Coverage-ledger fence `core.chat.persistence`:
//   * chat.persistence.turnTraceIdStamp (silent zero in two places at once)
//   * chat.persistence.turnReaction     (silent zero — VERIFIED DARK live:
//     zero `turn.reaction` rows across 14 days of turn traces)
//
// `metadata.turnTraceId` is the ONLY link between a persisted transcript row
// and its turn_traces rows. The Mac lifecycle reader skips any assistant row
// whose stamp does not match and returns `.absent` — so a MISSING stamp reads
// as "this turn never terminated" rather than "the stamp is gone". The same
// field decides whether a regenerate fires a `turn.reaction` at all, which is
// the mechanism behind the observed zero.
@Suite("eval: turn-trace stamp and regenerate reaction")
struct EvalTurnTraceStampTests {

    private func tempRoot(_ tag: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("eval-stamp-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func client(root: URL, bus: TurnTraceBus) -> SwiftNativeChatOrchestrationClient {
        let llm = MockLLMClient(scriptedResponses: ["unused"])
        let tools = MockToolDispatchClient()
        let engine = SwiftNativeTurnEngine(
            persona: hermeticPersona(root: root),
            memory: nil,
            router: MockProviderRoutingForGate(),
            trust: hermeticTrust(),
            llm: llm,
            tools: tools,
            memoryPromoter: nil,
            turnTraceBus: bus
        )
        return SwiftNativeChatOrchestrationClient(
            engine: engine,
            tools: tools,
            llm: llm,
            history: SessionHistoryReader(dataRoot: root),
            dataRoot: root,
            turnTraceBus: bus,
            trust: hermeticTrust()
        )
    }

    private func rows(_ root: URL, sessionId: String) -> [[String: Any]] {
        let path = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
            guard let d = String($0).data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
    }

    /// Collect `turn.reaction` events off a private bus for a bounded window.
    ///
    /// Emission is fire-and-forget through a process-wide bounded pump, so a
    /// FIXED sleep flakes under full-suite parallel load (observed: the
    /// expected row had not drained inside 600 ms on a loaded machine). Wait
    /// for the expected count under a deadline instead, then settle briefly so
    /// "exactly one" and "none" both stay real assertions rather than races.
    private func reactions(
        expecting: Int = 1,
        on bus: TurnTraceBus,
        while body: () async throws -> Void
    ) async rethrows -> [TurnTraceEvent] {
        let subscription = await bus.subscribe(capacity: 32)
        let box = EvalTraceEventBox()
        let drain = Task {
            for await event in subscription.stream where event.kind == "turn.reaction" {
                await box.append(event)
            }
        }
        try await body()
        if expecting > 0 {
            let started = ContinuousClock.now
            while await box.count() < expecting, ContinuousClock.now - started < .seconds(10) {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        // Settle window: give any EXTRA (unexpected) rows a chance to show up.
        try? await Task.sleep(for: .milliseconds(600))
        await bus.unsubscribe(subscription.id)
        _ = await drain.value
        return await box.all()
    }

    /// THE 1:1 INVARIANT nothing asserted. Every canonical assistant row must
    /// carry BOTH halves of the correlation and they must name the same turn.
    /// A row with an observation but no stamp resolves to `.absent` in the Mac
    /// lifecycle reader — a healthy-looking zero.
    @Test func everyCanonicalAssistantRowStampsExactlyOneTurnIdentity() async throws {
        let root = try tempRoot("stamp")
        defer { try? FileManager.default.removeItem(at: root) }
        let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: root))
        let subject = client(root: root, bus: bus)
        let session = "s-stamp"
        let turnIDs = ["turn-a", "turn-b", "turn-c"]

        for (index, turnID) in turnIDs.enumerated() {
            try await subject.appendMessage(
                sessionId: session, role: "user", content: "q\(index)",
                runId: "run-\(index)", attachments: []
            )
            try await TurnTraceContext.$turnId.withValue(turnID) {
                try await subject.appendMessage(
                    sessionId: session, role: "assistant", content: "a\(index)",
                    runId: "run-\(index)", attachments: [],
                    canonicalAssistantCompletion: true
                )
            }
        }

        let assistantRows = rows(root, sessionId: session).filter { $0["role"] as? String == "assistant" }
        #expect(assistantRows.count == turnIDs.count)

        var stamps: [String] = []
        for row in assistantRows {
            let metadata = try #require(row["metadata"] as? [String: Any])
            let stamp = try #require(metadata["turnTraceId"] as? String)
            let observation = try #require(metadata["outcomeObservation"] as? [String: Any])
            // Both halves, same identity — this is the join every downstream
            // reader assumes and nobody checked.
            #expect(observation["turnID"] as? String == stamp)
            #expect(observation["messageID"] as? String == row["id"] as? String)
            stamps.append(stamp)
        }
        #expect(stamps == turnIDs)
        #expect(Set(stamps).count == stamps.count, "stamps must be per-turn, not shared")
    }

    /// A regenerate over a STAMPED row fires exactly one reaction naming the
    /// replaced turn — the positive control for the lane.
    @Test func regeneratingAStampedRowFiresExactlyOneReaction() async throws {
        let root = try tempRoot("reaction-yes")
        defer { try? FileManager.default.removeItem(at: root) }
        let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: root))
        let subject = client(root: root, bus: bus)
        let session = "s-reaction-yes"

        try await subject.appendMessage(
            sessionId: session, role: "user", content: "question",
            runId: "run-user", attachments: []
        )
        try await TurnTraceContext.$turnId.withValue("turn-old") {
            try await subject.appendMessage(
                sessionId: session, role: "assistant", content: "old",
                runId: "run-old", attachments: [], canonicalAssistantCompletion: true
            )
        }
        let oldID = try #require(rows(root, sessionId: session).last?["id"] as? String)

        let fired = try await reactions(on: bus) {
            try await TurnTraceContext.$turnId.withValue("turn-retry") {
                try await ChatPersistenceContext.$replacementAssistantMessageID.withValue(oldID) {
                    try await subject.appendMessage(
                        sessionId: session, role: "assistant", content: "new",
                        runId: "run-new", attachments: [], canonicalAssistantCompletion: true
                    )
                }
            }
        }

        #expect(fired.count == 1)
        let event = try #require(fired.first)
        #expect(event.turnId == "turn-retry")
        guard case .object(let payload) = event.payload else {
            Issue.record("reaction payload missing"); return
        }
        #expect(payload["targetTurnId"] == .string("turn-old"))
        #expect(payload["controlAuthority"] == .bool(false))
        #expect(payload["reaction"] == .string("explicit_retry"))
    }

    /// THE SILENT ZERO, pinned. Replacing a row that carries NO stamp still
    /// succeeds — the transcript is rewritten, the user sees the new answer —
    /// and the reaction lane emits nothing at all. No error, no marker row, no
    /// "target unknown" receipt: indistinguishable from "the user never
    /// retried", which is exactly what 14 days of empty `turn.reaction` looks
    /// like from the outside.
    @Test func regeneratingAnUnstampedRowIsSilentNotObservable() async throws {
        let root = try tempRoot("reaction-no")
        defer { try? FileManager.default.removeItem(at: root) }
        let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: root))
        let subject = client(root: root, bus: bus)
        let session = "s-reaction-no"

        try await subject.appendMessage(
            sessionId: session, role: "user", content: "question",
            runId: "run-user", attachments: []
        )
        // No bound turn id AND no runId → no outcome observation → no stamp.
        // This is the shape a bridge/telegram completion writes.
        try await subject.appendMessage(
            sessionId: session, role: "assistant", content: "old",
            runId: nil, attachments: [], canonicalAssistantCompletion: true
        )
        let oldRow = try #require(rows(root, sessionId: session).last)
        let oldID = try #require(oldRow["id"] as? String)
        let oldMetadata = oldRow["metadata"] as? [String: Any] ?? [:]
        #expect(oldMetadata["turnTraceId"] == nil, "precondition: the row must be unstamped")

        let fired = try await reactions(expecting: 0, on: bus) {
            try await TurnTraceContext.$turnId.withValue("turn-retry") {
                try await ChatPersistenceContext.$replacementAssistantMessageID.withValue(oldID) {
                    try await subject.appendMessage(
                        sessionId: session, role: "assistant", content: "new",
                        runId: "run-new", attachments: [], canonicalAssistantCompletion: true
                    )
                }
            }
        }

        // The replacement itself worked...
        let after = rows(root, sessionId: session)
        #expect(after.count == 2)
        #expect(after.last?["content"] as? String == "new")
        // ...and the metacognition lane learned nothing, silently.
        #expect(fired.isEmpty)
    }
}
