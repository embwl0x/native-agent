import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore

@Suite("Fluid Context FC0 trace telemetry")
struct FluidContextFC0TraceTests {
    @Test func lifecycle_contract_emits_all_named_milestones() async throws {
        let milestones = TurnLifecycleMilestone.allCases
        let events = await collectEvents(expectedCount: milestones.count) {
            let startNs = DispatchTime.now().uptimeNanoseconds
            for milestone in milestones {
                TurnLifecycleTelemetry.emit(
                    milestone,
                    surface: "chat",
                    sessionId: "session-fc0",
                    observedBy: "fc0.test",
                    since: startNs,
                    counts: ["bytes": -1],
                    flags: ["supported": true]
                )
            }
        }

        #expect(Set(events.map(\.kind)) == Set(milestones.map(\.rawValue)))
        for event in events {
            guard case .object(let payload) = event.payload else {
                Issue.record("expected lifecycle object payload")
                continue
            }
            #expect(payload["schema"] == .string("turn.lifecycle.v1"))
            #expect(payload["milestone"] == .string(event.kind))
            #expect(payload["observedBy"] == .string("fc0.test"))
            #expect(payload["elapsedMs"] != nil)
            #expect(payload["counts"] == .object(["bytes": .int(0)]))
            #expect(payload["flags"] == .object(["supported": .bool(true)]))
        }
    }

    @Test func snapshot_reports_utf8_bytes_sources_schemas_and_dispatch_boundary() async throws {
        let stable = "Soul: caf\u{00E9}"
        let dynamic = """
        [CognitiveSubstrate]
        run_id: run-fc0
        session_id: session-fc0
        surface: chat
        State: \u{1F642}
        """
        let segments = SystemPromptSegments(stable: stable, dynamic: dynamic)
        let parameters = Data(#"{"type":"object","properties":{}}"#.utf8)
        let schema = LLMToolSchema(
            name: "tool_caf\u{00E9}",
            description: "Returns \u{1F642}",
            parametersJSON: parameters
        )
        let context = TurnContext(
            surface: "chat",
            personaDocs: ["VOICE.md": "plain", "SOUL.md": "\u{00E9}"],
            recalled: [],
            modelId: "test-model",
            reasoningEffort: "low",
            toolsAvailable: [schema.name],
            systemPrompt: segments.combined,
            userMessage: "Hello \u{1F642}",
            toolSchemas: [schema],
            systemSegments: segments
        )

        let events = await collectEvents(expectedCount: 3) {
            SwiftNativeTurnEngine.fireContextSnapshotEvent(
                surface: "chat",
                context: context,
                sessionId: "session-fc0",
                runId: "run-fc0",
                memoryRecallOutcome: .succeeded(hitCount: 0)
            )
        }

        #expect(events.contains { $0.kind == TurnLifecycleMilestone.contextReady.rawValue })
        #expect(events.contains { $0.kind == TurnLifecycleMilestone.providerRequestStarted.rawValue })
        let snapshot = try #require(events.first { $0.kind == "context.snapshot" })
        guard case .object(let payload) = snapshot.payload else {
            Issue.record("expected snapshot object payload")
            return
        }

        #expect(payload["personaSourceBytes"] == .int(Int64("plain".utf8.count + "\u{00E9}".utf8.count)))
        #expect(payload["systemTotalBytes"] == .int(Int64(segments.combined.utf8.count)))
        #expect(payload["stableBytes"] == .int(Int64(stable.utf8.count)))
        #expect(payload["dynamicBytes"] == .int(Int64(dynamic.utf8.count)))
        #expect(payload["userMessageBytes"] == .int(Int64("Hello \u{1F642}".utf8.count)))
        #expect(payload["promptTextBytes"] == .int(Int64(
            segments.combined.utf8.count + "Hello \u{1F642}".utf8.count
        )))
        #expect(payload["cognitiveCapsuleBytes"] == .int(Int64(dynamic.utf8.count)))
        #expect(payload["toolSchemaParameterBytes"] == .int(Int64(parameters.count)))
        #expect(payload["toolSchemaMaterialBytes"] == .int(Int64(
            schema.name.utf8.count + schema.description.utf8.count + parameters.count
        )))

        guard case .array(let sources)? = payload["personaSources"],
              case .object(let soul)? = sources.first else {
            Issue.record("expected sorted persona source byte rows")
            return
        }
        #expect(soul["source"] == .string("SOUL.md"))
        #expect(soul["chars"] == .int(1))
        #expect(soul["bytes"] == .int(2))

        guard case .array(let schemas)? = payload["toolSchemaBytes"],
              case .object(let schemaBytes)? = schemas.first else {
            Issue.record("expected tool schema byte rows")
            return
        }
        #expect(schemaBytes["name"] == .string(schema.name))
        #expect(schemaBytes["parameterBytes"] == .int(Int64(parameters.count)))

        guard case .string(let promptFingerprint)? = payload["promptFingerprintSHA256"],
              case .string(let schemaFingerprint)? = payload["toolSchemaFingerprintSHA256"] else {
            Issue.record("expected SHA-256 fingerprints")
            return
        }
        #expect(promptFingerprint.count == 64)
        #expect(schemaFingerprint.count == 64)
        #expect(!promptFingerprint.contains("caf\u{00E9}"))
    }

    @Test func memory_error_is_distinct_from_legitimate_zero_hits() async throws {
        let context = TurnContext(
            surface: "chat",
            personaDocs: [:],
            recalled: [],
            modelId: "test-model",
            reasoningEffort: "low",
            toolsAvailable: [],
            systemPrompt: "system",
            userMessage: "hello"
        )

        let events = await collectEvents(expectedCount: 4) {
            SwiftNativeTurnEngine.fireContextSnapshotEvent(
                surface: "chat",
                context: context,
                memoryRecallOutcome: .succeeded(hitCount: 0),
                marksProviderDispatch: false
            )
            SwiftNativeTurnEngine.fireContextSnapshotEvent(
                surface: "chat",
                context: context,
                memoryRecallOutcome: .failed(errorType: "MemoryStoreUnavailable"),
                marksProviderDispatch: false
            )
        }.filter { $0.kind == "context.snapshot" }

        let outcomes = events.compactMap { event -> [String: JSONValue]? in
            guard case .object(let payload) = event.payload,
                  case .object(let memory)? = payload["memoryRecall"] else { return nil }
            return memory
        }
        #expect(outcomes.contains { $0["outcome"] == .string("zeroHits") })
        #expect(outcomes.contains { $0["outcome"] == .string("error") })
        #expect(outcomes.contains { $0["errorType"] == .string("MemoryStoreUnavailable") })

        let fingerprints = events.compactMap { event -> String? in
            guard case .object(let payload) = event.payload,
                  case .string(let fingerprint)? = payload["promptFingerprintSHA256"] else {
                return nil
            }
            return fingerprint
        }
        #expect(Set(fingerprints).count == 1, "telemetry outcome must not alter prompt bytes")
    }

    @Test func context_summary_preserves_memory_zero_hits_and_error_outcomes() async throws {
        let events = await collectEvents(expectedCount: 2) {
            var zeroHitTrace = ContextStageTrace()
            zeroHitTrace.setCount("memory.recallHits", 0)
            zeroHitTrace.setMemoryRecallOutcome(.succeeded(hitCount: 0))
            zeroHitTrace.emit(kind: "context.summary", surface: "chat")

            var errorTrace = ContextStageTrace()
            errorTrace.setCount("memory.recallHits", 0)
            errorTrace.setMemoryRecallOutcome(.failed(errorType: "MemoryStoreUnavailable"))
            errorTrace.emit(kind: "context.summary", surface: "chat")
        }

        let outcomes = events.compactMap { event -> [String: JSONValue]? in
            guard event.kind == "context.summary",
                  case .object(let payload) = event.payload,
                  case .object(let memory)? = payload["memoryRecall"] else { return nil }
            return memory
        }
        #expect(outcomes.contains { $0["outcome"] == .string("zeroHits") })
        #expect(outcomes.contains { $0["outcome"] == .string("error") })
        #expect(outcomes.contains { $0["errorType"] == .string("MemoryStoreUnavailable") })
    }

    private func collectEvents(
        expectedCount: Int,
        _ body: @escaping () -> Void
    ) async -> [TurnTraceEvent] {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fluid-context-fc0-\(UUID().uuidString)", isDirectory: true)
        let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: root))
        let subscription = await bus.subscribe(capacity: max(8, expectedCount * 2))
        let drain = Task { () -> [TurnTraceEvent] in
            var events: [TurnTraceEvent] = []
            for await event in subscription.stream {
                events.append(event)
                if events.count >= expectedCount { break }
            }
            return events
        }
        let turnId = TurnTraceContext.mintTurnId()
        TurnTraceContext.$bus.withValue(bus) {
            TurnTraceContext.$turnId.withValue(turnId) {
                body()
            }
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(3))
            await bus.unsubscribe(subscription.id)
        }
        let events = await drain.value
        timeout.cancel()
        await bus.unsubscribe(subscription.id)
        try? FileManager.default.removeItem(at: root)
        return events.filter { $0.turnId == turnId }
    }
}
