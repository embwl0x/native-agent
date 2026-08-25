import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore
import ProviderRouting

// EVAL FENCE: core.chat.persistence
// Ledger row: chat.trace.contextStage.emitStage
//
// The stage row is consumed from the same turn-trace bus production uses. A
// negative timing/count is impossible evidence and must be clamped before it
// reaches the canonical record.
@Test func contextStageEmission_preservesNameAndClampsNegativeMeasurements() async throws {
    let events = try await withHermeticTraceBus(kinds: ["context.stage"]) { _ in
        ContextStageTrace.emitStage(
            name: .memoryPromotion,
            elapsedMs: -3,
            surface: "chat",
            counts: ["promoted": -1, "considered": 2],
            flags: ["configured": true]
        )
    }
    #expect(events.count == 1)
    let event = try #require(events.first)
    guard case .object(let payload) = event.payload else { Issue.record("missing stage payload"); return }
    #expect(payload["schema"] == .string("context.stage.v1"))
    #expect(payload["stage"] == .string("memory.promotion"))
    #expect(payload["elapsedMs"] == .int(0))
    #expect(payload["counts"] == .object(["promoted": .int(0), "considered": .int(2)]))
    #expect(payload["flags"] == .object(["configured": .bool(true)]))
}

private final class ContextStageReceiptPromoter: MemoryPromoting, @unchecked Sendable {
    func observeTurn(userMessage: String, assistantMessage: String, sessionId: String) async {}
}

private struct ContextStageReceiptRouting: ProviderRoutingProtocol {
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider {
        throw ProviderRoutingError.invalidRequest
    }
    func testProvider(id: String) async throws -> ProviderTestResult { .init(rawResponse: .null) }
    func getModelPreferences() async throws -> ModelPreferences { .init() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { .init() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        ["chat": .init(surface: "chat", model: "eval", reasoningEffort: "low")]
    }
}

private struct ContextStageReceiptLLM: LLMClient {
    func complete(prompt: String, system: String?, model: String?) async throws -> String { "unused" }
}

private func contextStageReceiptEngine(
    root: URL,
    promoter: (any MemoryPromoting)?
) -> SwiftNativeTurnEngine {
    SwiftNativeTurnEngine(
        persona: hermeticPersona(root: root),
        memory: nil,
        router: ContextStageReceiptRouting(),
        trust: hermeticTrust(),
        llm: ContextStageReceiptLLM(),
        tools: MockToolDispatchClient(),
        memoryPromoter: promoter
    )
}

// EVAL FENCE: core.chat.persistence
// Ledger row: chat.trace.contextStage.emitStage
//
// This drives the real post-turn producer rather than calling emitStage in
// isolation. Both terminal configurations must publish a receipt through the
// same task-local bus readers use; if either production emit call is removed,
// the missing row makes this exact two-receipt assertion fail.
@Test func memoryPromotion_terminalPaths_emitObservableContextStageReceipts() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("context-stage-receipt-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let withoutPromoter = contextStageReceiptEngine(root: root, promoter: nil)
    let withPromoter = contextStageReceiptEngine(
        root: root,
        promoter: ContextStageReceiptPromoter()
    )
    let events = try await withHermeticTraceBus(
        kinds: ["context.stage"],
        expecting: 2,
        waitDeadline: .seconds(3)
    ) { _ in
        await withoutPromoter.observeMemoryPromotion(
            userMessage: "remember this",
            assistantMessage: "I will",
            sessionId: "receipt-no-promoter",
            surface: "chat"
        )
        await withPromoter.observeMemoryPromotion(
            userMessage: "remember this too",
            assistantMessage: "I will too",
            sessionId: "receipt-with-promoter",
            surface: "telegram"
        )
    }

    #expect(events.count == 2, "each memory-promotion terminal path must emit one observable stage receipt")
    let payloads = try events.map { event -> [String: JSONValue] in
        guard case .object(let payload) = event.payload else {
            throw NSError(domain: "ContextStageReceipt", code: 1)
        }
        return payload
    }
    for payload in payloads {
        #expect(payload["schema"] == .string("context.stage.v1"))
        #expect(payload["stage"] == .string("memory.promotion"))
        #expect(payload["elapsedMs"] != nil)
        #expect(payload["counts"] != nil)
    }
    #expect(Set(events.compactMap(\.surface)) == ["chat", "telegram"])
    let configured = payloads.compactMap { payload -> Bool? in
        guard case .object(let flags)? = payload["flags"], case .bool(let value)? = flags["configured"] else {
            return nil
        }
        return value
    }
    #expect(Set(configured) == [false, true])
}

private final class DelayedContextStageReceiptPromoter: MemoryPromoting, @unchecked Sendable {
    func observeTurn(userMessage: String, assistantMessage: String, sessionId: String) async {
        try? await Task.sleep(for: .milliseconds(2))
    }
}

// EVAL FENCE: turn.contract
// Ledger row: turn.contract.ContextStageTrace.emitStage
//
// Exercise the sole production owner through the real post-turn path. The
// typed vocabulary prevents a colliding producer, while this measurement
// prevents the retained name from becoming a permanently-zero DARK lane.
@Test func contextStageEmissionHasClosedVocabularyAndANonzeroSample() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("context-stage-nonzero-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let engine = contextStageReceiptEngine(
        root: root,
        promoter: DelayedContextStageReceiptPromoter()
    )
    let events = try await withHermeticTraceBus(
        kinds: ["context.stage"],
        expecting: 1,
        waitDeadline: .seconds(3)
    ) { _ in
        await engine.observeMemoryPromotion(
            userMessage: "retain this outcome",
            assistantMessage: "Recorded.",
            sessionId: "nonzero-stage",
            surface: "chat"
        )
    }

    let samples = try events.map { event -> (String, Int64) in
        guard case .object(let payload) = event.payload,
              case .string(let stage)? = payload["stage"],
              case .int(let elapsedMs)? = payload["elapsedMs"]
        else { throw NSError(domain: "ContextStageEmission", code: 1) }
        return (stage, elapsedMs)
    }
    let grouped = Dictionary(grouping: samples, by: \.0)
    #expect(!grouped.isEmpty, "context.stage must emit at least one named stage")
    #expect(Set(grouped.keys) == Set(ContextStageEmissionName.allCases.map(\.rawValue)))
    for (stage, stageSamples) in grouped {
        #expect(
            stageSamples.contains { $0.1 > 0 },
            "context.stage `\(stage)` emitted only zero elapsedMs samples and is DARK"
        )
    }
}

@Test func preloadCap_isDeterministicAndNeverLeaksFourthMatchedGroup() throws {
    let prompt = "read the file, search the web news, inspect git status, and check my calendar and mailbox"
    let first = try #require(ToolPreloadHeuristics.predict(userMessage: prompt))
    let second = try #require(ToolPreloadHeuristics.predict(userMessage: prompt))
    #expect(first == second, "ranking must not vary between turns")
    #expect(first.groups.count == ToolPreloadHeuristics.maxGroupsPerTurn)
    #expect(first.groups.count == 3)
    #expect(Set(first.groupNames).count == first.groupNames.count)
    #expect(!first.candidateTools.isEmpty)
}

// EVAL FENCE: core.chat.persistence
// Ledger row: chat.trace.contextSnapshot.payloadBound
//
// The production snapshot emitter intentionally includes bounded previews,
// while the canonical TurnTrace row has a smaller hard byte limit. Exercise
// that real producer-to-store boundary and assert that the compact row still
// carries the scalar facts an inspector needs to interpret the trace.
@Test func oversizedContextSnapshot_retainsInspectableScalarFacts() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("context-snapshot-bound-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let largePersona = String(repeating: "persona continuity ", count: 1_500)
    let cognitive = String(repeating: "felt focus ", count: 1_500)
    let schema = LLMToolSchema(
        name: "inspect_workspace",
        description: String(repeating: "schema description ", count: 300),
        parametersJSON: Data("{\"type\":\"object\"}".utf8)
    )
    let context = TurnContext(
        surface: "chat",
        personaDocs: ["canonical": largePersona],
        recalled: [],
        modelId: "claude-opus-4-8",
        reasoningEffort: "high",
        toolsAvailable: [schema.name],
        systemPrompt: "\(largePersona)\n\nCognitive substrate:\n\(cognitive)",
        userMessage: "inspect the persisted trace",
        toolSchemas: [schema]
    )

    let bus = TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: root))
    let subscription = await bus.subscribe(capacity: 8)
    let turnID = TurnTraceContext.mintTurnId()
    let liveEvent = Task { () -> TurnTraceEvent? in
        for await event in subscription.stream
        where event.turnId == turnID && event.kind == "context.snapshot" {
            return event
        }
        return nil
    }
    TurnTraceContext.$bus.withValue(bus) {
        TurnTraceContext.$turnId.withValue(turnID) {
        SwiftNativeTurnEngine.fireContextSnapshotEvent(
            surface: "chat",
            context: context,
            sessionId: "snapshot-bound-session",
            runId: "snapshot-bound-run",
            marksProviderDispatch: false
        )
        }
    }

    let reader = TurnTraceRecentReader(dataRootOverride: root)
    var persistedEvent: TurnTraceEvent?
    var persistedSource: URL?
    for _ in 0..<200 {
        let snapshot = try await reader.read()
        persistedSource = snapshot.sourceURL
        persistedEvent = snapshot.events.first {
            $0.turnId == turnID && $0.kind == "context.snapshot"
        }
        if persistedEvent != nil { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    await bus.unsubscribe(subscription.id)
    let emittedEvent = try #require(await liveEvent.value)
    let event = try #require(persistedEvent, "context.snapshot never reached its canonical JSONL reader")
    guard case .object(let payload) = event.payload else {
        Issue.record("missing canonical context.snapshot payload")
        return
    }
    let persistedLineBytes = try event.jsonRow.serializedData(pretty: false).count + 1
    #expect(persistedLineBytes <= TurnTraceEvent.maxPayloadBytes)
    #expect(payload["_truncated"] == .bool(true))
    guard case .object(let emittedPayload) = emittedEvent.payload else {
        Issue.record("live emitter payload was not an object")
        return
    }
    #expect(payload["_originalBytes"] == emittedPayload["_originalBytes"])
    #expect(payload["_sha256"] == emittedPayload["_sha256"])
    guard case .int(let originalBytes)? = payload["_originalBytes"] else {
        Issue.record("missing original byte count")
        return
    }
    #expect(originalBytes > Int64(TurnTraceEvent.maxPayloadBytes))
    guard case .string(let digest)? = payload["_sha256"] else {
        Issue.record("missing payload digest")
        return
    }
    #expect(digest.count == 64)
    #expect(digest.unicodeScalars.allSatisfy {
        CharacterSet(charactersIn: "0123456789abcdef").contains($0)
    })
    #expect(payload["schema"] == .string("context.snapshot.v1"))
    #expect(payload["model"] == .string("claude-opus-4-8"))
    let requiredScalars: Set<String> = [
        "containsCognitiveSubstrate", "cognitiveCapsuleBytes",
        "toolSchemaCount", "toolSchemaParameterBytes", "toolSchemaMaterialBytes",
        "toolSchemaFingerprintSHA256", "promptFingerprintSHA256", "systemTotalBytes",
        "stableBytes", "dynamicBytes", "userMessageBytes", "promptTextBytes",
        "imagePayloadBytes", "segmented",
    ]
    #expect(requiredScalars.allSatisfy { payload[$0] != nil })
    #expect(payload["toolSchemaCount"] == .int(1))

    // One damaged tail row must not erase the valid bounded record that
    // preceded it. The canonical reader skips malformed JSONL and continues.
    let source = try #require(persistedSource)
    let handle = try FileHandle(forWritingTo: source)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{not-json}\n".utf8))
    try handle.close()
    let afterDamage = try await reader.read()
    #expect(afterDamage.events.contains { $0.turnId == turnID && $0.payload == event.payload })
}

@Test func turnTracePersistedLine_capsFourMultibyteEnvelopeFieldsByBytes() throws {
    let multibyte = String(repeating: "🧠", count: 5_000)
    let event = TurnTraceEvent(
        turnId: multibyte,
        kind: multibyte,
        sessionId: multibyte,
        surface: multibyte,
        payload: .object([
            "schema": .string("context.snapshot.v1"),
            "model": .string("hostile-envelope-model"),
            "containsCognitiveSubstrate": .bool(true),
            "cognitiveCapsuleBytes": .int(123),
            "toolSchemaCount": .int(7),
            "toolSchemaParameterBytes": .int(456),
            "toolSchemaMaterialBytes": .int(789),
            "toolSchemaFingerprintSHA256": .string(String(repeating: "a", count: 64)),
            "promptFingerprintSHA256": .string(String(repeating: "b", count: 64)),
            "systemTotalBytes": .int(1_000),
            "stableBytes": .int(500),
            "dynamicBytes": .int(500),
            "userMessageBytes": .int(40),
            "promptTextBytes": .int(960),
            "imagePayloadBytes": .int(0),
            "segmented": .bool(true),
            "body": .array((0..<200).map { index in
                .string("\(index):" + String(repeating: "payload", count: 20))
            }),
        ])
    )

    #expect(event.turnId.utf8.count <= 480)
    #expect(event.kind.utf8.count <= 480)
    #expect((event.sessionId?.utf8.count ?? Int.max) <= 480)
    #expect((event.surface?.utf8.count ?? Int.max) <= 480)
    let persistedLineBytes = try event.jsonRow.serializedData(pretty: false).count + 1
    #expect(persistedLineBytes <= TurnTraceEvent.maxPayloadBytes)
    guard case .object(let payload) = event.payload else {
        Issue.record("adversarial envelope lost its bounded payload object")
        return
    }
    #expect(payload["_truncated"] == .bool(true))
    #expect(payload["_originalBytes"] != nil)
    #expect(payload["_sha256"] != nil)
    #expect(payload["schema"] == .string("context.snapshot.v1"))
    #expect(payload["model"] == .string("hostile-envelope-model"))
    let requiredManifest = [
        "containsCognitiveSubstrate", "cognitiveCapsuleBytes", "toolSchemaCount",
        "toolSchemaParameterBytes", "toolSchemaMaterialBytes",
        "toolSchemaFingerprintSHA256", "promptFingerprintSHA256", "systemTotalBytes",
        "stableBytes", "dynamicBytes", "userMessageBytes", "promptTextBytes",
        "imagePayloadBytes", "segmented",
    ]
    #expect(requiredManifest.allSatisfy { payload[$0] != nil })
}
