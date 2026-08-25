import CognitiveSubstrate
import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import ChatOrchestration

// Coverage-ledger fence `core.chat.persistence`:
//   * chat.trace.cognitiveMarkerGate (wrong value that reads as an absence)
//
// The snapshot's capsule gate parses the capsule's plain-text header
// (`run_id:` / `session_id:` / `surface:`). If the header AUTHOR changes shape,
// the gate rejects a capsule that WAS delivered: `containsCognitiveSubstrate`
// goes false, `cognitiveCapsuleBytes` goes 0, and the instrument then reports
// "capsule missing on N of M traced turns" pointing at the injection seams —
// the wrong three files. A false negative here manufactures a phantom bug in
// another subsystem.
//
// So this is an AUTHOR↔READER round trip: the header is produced by the real
// production author (`cognitiveRuntimeContext`), never hand-typed, and read
// back through the real emitter.
@Suite("eval: cognitive capsule marker gate")
struct EvalCognitiveMarkerGateTests {

    private func capsule(_ body: String) -> CognitiveCapsule {
        CognitiveCapsule(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            mode: .inject,
            stableKernel: body,
            dynamicContext: "",
            provenanceNodeIds: [],
            truncated: false
        )
    }

    private func context(systemPrompt: String) -> TurnContext {
        TurnContext(
            surface: "chat",
            personaDocs: [:],
            recalled: [],
            modelId: "claude-opus-4-8",
            reasoningEffort: "high",
            toolsAvailable: [],
            systemPrompt: systemPrompt,
            userMessage: "hello",
            toolSchemas: []
        )
    }

    /// Fire the real emitter on a private bus and return the snapshot payload.
    private func snapshotPayload(
        systemPrompt: String,
        runId: String?,
        sessionId: String?
    ) async throws -> [String: JSONValue] {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("eval-marker-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: root))
        let subscription = await bus.subscribe(capacity: 16)

        await TurnTraceContext.$turnId.withValue("turn-marker") {
            await TurnTraceContext.$bus.withValue(bus) {
                SwiftNativeTurnEngine.fireContextSnapshotEvent(
                    surface: "chat",
                    context: context(systemPrompt: systemPrompt),
                    sessionId: sessionId,
                    runId: runId
                )
            }
        }

        let drain = Task { () -> TurnTraceEvent? in
            for await event in subscription.stream where event.kind == "context.snapshot" {
                return event
            }
            return nil
        }
        let stopper = Task {
            try? await Task.sleep(for: .milliseconds(3_000))
            await bus.unsubscribe(subscription.id)
        }
        let event = await drain.value
        stopper.cancel()
        await bus.unsubscribe(subscription.id)
        guard case .object(let payload)? = event?.payload else {
            Issue.record("no context.snapshot payload")
            return [:]
        }
        return payload
    }

    /// A capsule assembled by the production header author is RECOGNISED, and
    /// the bytes it reports are the real capsule's own mass — not zero, and not
    /// the whole system prompt.
    @Test func aCapsuleFromTheRealHeaderAuthorIsRecognised() async throws {
        let inner = "- felt: steady, mid-arousal\n- holding: the eval wave"
        let runtime = try #require(SwiftNativeChatOrchestrationClient.cognitiveRuntimeContext(
            runId: "run-marker-1",
            sessionId: "session-marker-1",
            surface: "chat",
            fileAccess: "workspace",
            capsule: capsule(inner),
            posture: nil
        ))
        let system = "PERSONA MASS\n\n\(runtime)\n\nNativeAgent Swift tool protocol:\ntool text"

        let payload = try await snapshotPayload(
            systemPrompt: system, runId: "run-marker-1", sessionId: "session-marker-1"
        )

        #expect(payload["containsCognitiveSubstrate"] == .bool(true))
        guard case .int(let bytes)? = payload["cognitiveCapsuleBytes"] else {
            Issue.record("cognitiveCapsuleBytes missing"); return
        }
        // Envelope, not an exact byte count: the recognised region must contain
        // the capsule the substrate actually produced and must not swallow the
        // whole prompt (the tool-protocol tail is a stop marker).
        #expect(bytes >= Int64(inner.utf8.count))
        #expect(bytes <= Int64(runtime.utf8.count))
        #expect(bytes < Int64(system.utf8.count))
    }

    /// The header the author writes is also what the emitter reads its run and
    /// session identity back OUT of when the caller does not supply them. This
    /// is the round trip a format change breaks first.
    @Test func runAndSessionIdentityRoundTripThroughTheAuthoredHeader() async throws {
        let runtime = try #require(SwiftNativeChatOrchestrationClient.cognitiveRuntimeContext(
            runId: "run-roundtrip-9",
            sessionId: "session-roundtrip-9",
            surface: "telegram",
            fileAccess: "read_only",
            capsule: capsule("- felt: curious"),
            posture: nil
        ))

        let payload = try await snapshotPayload(
            systemPrompt: runtime, runId: nil, sessionId: nil
        )

        #expect(payload["containsCognitiveSubstrate"] == .bool(true))
        #expect(payload["runId"] == .string("run-roundtrip-9"))
        #expect(payload["sessionId"] == .string("session-roundtrip-9"))
    }

    /// The gate must still BITE: a capsule stamped with a different run — the
    /// stale one quoted back inside conversation history — is not this turn's
    /// capsule and must not be counted as delivered.
    @Test func aStaleRunIdIsRejectedRatherThanCounted() async throws {
        let stale = try #require(SwiftNativeChatOrchestrationClient.cognitiveRuntimeContext(
            runId: "run-from-yesterday",
            sessionId: "session-marker-2",
            surface: "chat",
            fileAccess: "workspace",
            capsule: capsule("- felt: from an older turn"),
            posture: nil
        ))

        let payload = try await snapshotPayload(
            systemPrompt: "history quoted below\n\n\(stale)",
            runId: "run-marker-2",
            sessionId: "session-marker-2"
        )

        #expect(payload["containsCognitiveSubstrate"] == .bool(false))
        #expect(payload["cognitiveCapsuleBytes"] == .int(0))
    }

    /// And the negative control for the gate itself: a system prompt with no
    /// capsule at all reports absence — so `false` means something.
    @Test func aPromptWithNoCapsuleReportsAbsence() async throws {
        let payload = try await snapshotPayload(
            systemPrompt: "just persona and history, no inner state",
            runId: "run-marker-3",
            sessionId: "session-marker-3"
        )
        #expect(payload["containsCognitiveSubstrate"] == .bool(false))
        #expect(payload["cognitiveCapsuleBytes"] == .int(0))
    }
}
