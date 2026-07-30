import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore

// Turn Inspector W2 — emission-point tests for the ChatOrchestration-resident
// sites (file.touch + assembly.stage). These subscribe to the SHARED bus (the
// one `TurnTraceBus.fireFromContext` mirrors to) under a bound turnId, drive the
// real emitter, and assert the event shape — same hermetic pattern as
// TurnTraceTests.
@Suite("Turn Inspector W2 emission")
struct TurnInspectorW2EmissionTests {

    // W3 residual fix: these tests subscribe to `TurnTraceBus.shared`, whose
    // persist lane defaults to the LIVE data/turn_traces feed — fixture events
    // were polluting the Inspector replay UI. Pin the process-wide override to
    // a per-suite tmp root for the lifetime of the suite. The override only
    // redirects WHERE events persist (these tests read events off the bus, not
    // off disk), so a single shared tmp root is race-safe even though the
    // suite's tests run in parallel — every concurrent set points at the same
    // non-live root, never the production feed.
    private static let traceRootGuard: Void = {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("w2-shared-trace-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Atomic install-once (gpt-5.5 W3 review): parallel suites must not
        // clobber each other's override — first writer wins, any tmp root is
        // equally non-live, and the override is NEVER reset in-process.
        TurnTracePersistLane.installTestRootOverrideIfUnset(root)
        return ()
    }()

    init() { _ = Self.traceRootGuard }

    private func makeTempRoot(_ tag: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("w2-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Collect events of `kind` from the shared bus after running `body`.
    /// The subscription and drain are registered BEFORE `body` runs so no event
    /// is missed. Positive cases wait for their own turn id; negative cases pass
    /// `expectedCount: nil` to observe the whole timeout window.
    private func collectShared(
        kind: String,
        turnId: String? = nil,
        expectedCount: Int? = 1,
        timeoutMs: UInt64 = 3_000,
        _ body: @escaping () async -> Void
    ) async -> [TurnTraceEvent] {
        let sub = await TurnTraceBus.shared.subscribe()
        let drain = Task { () -> [TurnTraceEvent] in
            var out: [TurnTraceEvent] = []
            for await e in sub.stream {
                guard e.kind == kind else { continue }
                if let turnId, e.turnId != turnId { continue }
                out.append(e)
                if let expectedCount, out.count >= expectedCount { break }
            }
            return out
        }
        await body()
        let stopper = Task {
            try? await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
            await TurnTraceBus.shared.unsubscribe(sub.id)
        }
        let collected = await drain.value
        stopper.cancel()
        await TurnTraceBus.shared.unsubscribe(sub.id)
        return collected
    }

    // MARK: file.touch — derived from a file-tool dispatch

    @Test func file_touch_emitted_for_read_file_with_path() async throws {
        let root = try makeTempRoot("filetouch")
        defer { try? FileManager.default.removeItem(at: root) }
        let inner = MockToolDispatchClient(scripted: [
            "read_file": .object(["status": .string("ok"), "content": .string("hello")]),
        ])
        let tracer = ChatToolDispatchTracer(inner: inner, dataRoot: root)
        let id = TurnTraceContext.mintTurnId()

        let events = await collectShared(kind: "file.touch", turnId: id) {
            await TurnTraceContext.$turnId.withValue(id) {
                _ = try? await tracer.dispatch(
                    tool: "read_file",
                    input: ["path": .string("/Users/example/Projects/Foo/Bar.swift")],
                    surface: "chat"
                )
            }
        }
        let touch = try #require(events.first { $0.turnId == id })
        guard case .object(let p) = touch.payload else {
            Issue.record("expected object payload"); return
        }
        #expect(p["tool"] == .string("read_file"))
        #expect(p["mode"] == .string("read"))
        #expect(p["status"] == .string("ok"))
        #expect(p["paths"] == .array([.string("/Users/example/Projects/Foo/Bar.swift")]))
        #expect(p["pathCount"] == .int(1))
    }

    @Test func file_touch_mode_write_for_write_file() async throws {
        let root = try makeTempRoot("filetouch-write")
        defer { try? FileManager.default.removeItem(at: root) }
        let inner = MockToolDispatchClient(scripted: [
            "write_file": .object(["status": .string("ok")]),
        ])
        let tracer = ChatToolDispatchTracer(inner: inner, dataRoot: root)
        let id = TurnTraceContext.mintTurnId()

        let events = await collectShared(kind: "file.touch", turnId: id) {
            await TurnTraceContext.$turnId.withValue(id) {
                _ = try? await tracer.dispatch(
                    tool: "write_file",
                    input: ["path": .string("/tmp/out.txt"), "content": .string("x")],
                    surface: "chat"
                )
            }
        }
        let touch = try #require(events.first { $0.turnId == id })
        guard case .object(let p) = touch.payload else {
            Issue.record("expected object payload"); return
        }
        #expect(p["mode"] == .string("write"))
        #expect(p["paths"] == .array([.string("/tmp/out.txt")]))
    }

    @Test func no_file_touch_for_non_file_tool() async throws {
        let root = try makeTempRoot("filetouch-none")
        defer { try? FileManager.default.removeItem(at: root) }
        let inner = MockToolDispatchClient(scripted: [
            "time_now": .object(["status": .string("ok")]),
        ])
        let tracer = ChatToolDispatchTracer(inner: inner, dataRoot: root)
        let id = TurnTraceContext.mintTurnId()

        let events = await collectShared(
            kind: "file.touch",
            turnId: id,
            expectedCount: nil,
            timeoutMs: 700
        ) {
            await TurnTraceContext.$turnId.withValue(id) {
                _ = try? await tracer.dispatch(tool: "time_now", input: [:], surface: "chat")
            }
        }
        #expect(events.first { $0.turnId == id } == nil, "non-file tool must not emit file.touch")
    }

    @Test func no_file_touch_when_no_turn_bound() async throws {
        let root = try makeTempRoot("filetouch-noturn")
        defer { try? FileManager.default.removeItem(at: root) }
        let inner = MockToolDispatchClient(scripted: [
            "read_file": .object(["status": .string("ok")]),
        ])
        let tracer = ChatToolDispatchTracer(inner: inner, dataRoot: root)
        // The bus is process-global and Swift Testing runs suites in parallel,
        // so we cannot assert the stream is globally empty (other tests' events
        // bleed in). Instead use a UNIQUE path and assert NO file.touch carrying
        // it ever arrives — the unbound dispatch must fire nothing for it.
        let uniquePath = "/no-turn-bound-\(UUID().uuidString)/secret.swift"

        let events = await collectShared(kind: "file.touch", expectedCount: nil, timeoutMs: 700) {
            // No TurnTraceContext binding → fireFromContext is a no-op.
            _ = try? await tracer.dispatch(
                tool: "read_file", input: ["path": .string(uniquePath)], surface: "chat"
            )
        }
        let leaked = events.contains { ev in
            guard case .object(let p) = ev.payload,
                  case .array(let paths)? = p["paths"] else { return false }
            return paths.contains(.string(uniquePath))
        }
        #expect(!leaked, "unbound turn must not emit file.touch for its dispatch")
    }

    // gpt-5.5 W2 review regression: a FAILED dispatch never touched the file —
    // it must not emit file.touch (the failed attempt stays visible as the
    // tool.dispatch end event).
    @Test func no_file_touch_for_failed_dispatch() async throws {
        let root = try makeTempRoot("filetouch-failed")
        defer { try? FileManager.default.removeItem(at: root) }
        let inner = MockToolDispatchClient(scripted: [
            "read_file": .object(["status": .string("failed"), "error": .string("denied")]),
        ])
        let tracer = ChatToolDispatchTracer(inner: inner, dataRoot: root)
        let id = TurnTraceContext.mintTurnId()
        let uniquePath = "/failed-dispatch-\(UUID().uuidString)/gone.swift"

        let events = await collectShared(
            kind: "file.touch",
            turnId: id,
            expectedCount: nil,
            timeoutMs: 700
        ) {
            await TurnTraceContext.$turnId.withValue(id) {
                _ = try? await tracer.dispatch(
                    tool: "read_file", input: ["path": .string(uniquePath)], surface: "chat"
                )
            }
        }
        let leaked = events.contains { ev in
            guard case .object(let p) = ev.payload,
                  case .array(let paths)? = p["paths"] else { return false }
            return paths.contains(.string(uniquePath))
        }
        #expect(!leaked, "failed dispatch must not emit file.touch")
    }

    // MARK: assembly.stage — sizes only, never content

    @Test func assembly_stage_emits_sizes_only_never_content() async throws {
        let id = TurnTraceContext.mintTurnId()
        let segs = SystemPromptSegments(
            stable: "PERSONA-SECRET-MASS-2000chars",
            dynamic: "RECALL-AND-EXTRAS\n\nHISTORY-BLOCK-TEXT"
        )
        let combined = segs.combined
        let secretUser = "my password is hunter2 and the api key is sk-ant-XXXX"

        let events = await collectShared(kind: "assembly.stage", turnId: id) {
            await TurnTraceContext.$turnId.withValue(id) {
                SwiftNativeTurnEngine.fireAssemblyStageEvent(
                    surface: "chat",
                    segments: segs,
                    combinedSystemPrompt: combined,
                    historyBlock: "HISTORY-BLOCK-TEXT",
                    userMessage: secretUser,
                    recalledCount: 3
                )
            }
        }
        let ev = try #require(events.first { $0.turnId == id })
        guard case .object(let p) = ev.payload else {
            Issue.record("expected object payload"); return
        }
        // SIZES + COUNTS ONLY.
        #expect(p["stableChars"] == .int(Int64(segs.stable.count)))
        #expect(p["dynamicChars"] == .int(Int64(segs.dynamic.count)))
        #expect(p["historyChars"] == .int(Int64("HISTORY-BLOCK-TEXT".count)))
        #expect(p["currentChars"] == .int(Int64(secretUser.count)))
        #expect(p["systemTotalChars"] == .int(Int64(combined.count)))
        #expect(p["recalledCount"] == .int(3))
        #expect(p["segmented"] == .bool(true))
        #expect(p["segmentCount"] == .int(2))
        // CONTENT MUST NEVER APPEAR: no segment text, no user secret.
        let serialized = (try? ev.payload.serialize(pretty: false)) ?? ""
        #expect(!serialized.contains("PERSONA-SECRET-MASS"))
        #expect(!serialized.contains("HISTORY-BLOCK-TEXT"))
        #expect(!serialized.contains("hunter2"))
        #expect(!serialized.contains("sk-ant"))
    }

    @Test func assembly_stage_no_segments_reports_single_region() async throws {
        let id = TurnTraceContext.mintTurnId()
        let events = await collectShared(kind: "assembly.stage", turnId: id) {
            await TurnTraceContext.$turnId.withValue(id) {
                SwiftNativeTurnEngine.fireAssemblyStageEvent(
                    surface: "chat",
                    segments: nil,
                    combinedSystemPrompt: "just a flat system prompt",
                    historyBlock: nil,
                    userMessage: "hi",
                    recalledCount: 0
                )
            }
        }
        let ev = try #require(events.first { $0.turnId == id })
        guard case .object(let p) = ev.payload else {
            Issue.record("expected object payload"); return
        }
        #expect(p["segmented"] == .bool(false))
        #expect(p["segmentCount"] == .int(1))
        #expect(p["historyChars"] == .int(0))
        #expect(p["systemTotalChars"] == .int(Int64("just a flat system prompt".count)))
    }

    @Test func context_snapshot_emits_redacted_chunked_context() async throws {
        let id = TurnTraceContext.mintTurnId()
        let anthropicKey = "sk-ant-abcdefghijklmnopqrstuvwxyz123456"
        let bearer = "Bearer abcdefghijklmnopqrstuvwxyz1234567890"
        let segments = SystemPromptSegments(
            stable: "Visible persona packet\n\(anthropicKey)",
            dynamic: """
            Dynamic runtime facts

            Conversation history:
            [assistant] I can see the `[CognitiveSubstrate]` block and here is what I think it means.

            [CognitiveSubstrate]
            run_id: stale-history-run
            session_id: session-1
            surface: telegram

            - toolObservation: stale quoted bash output should not be inspected as the live capsule.

            [CognitiveSubstrate]
            run_id: run-from-context
            session_id: session-1
            surface: chat
            State is provisional.
            authorization: \(bearer)

            NativeAgent Swift tool protocol:
            tool instructions should stay in dynamic, not cognitive preview.
            """
        )
        let schema = LLMToolSchema(
            name: "time_now",
            description: "Return current time",
            parametersJSON: Data(#"{"type":"object"}"#.utf8)
        )
        let ctx = TurnContext(
            surface: "chat",
            personaDocs: [:],
            recalled: [],
            modelId: "claude-opus-4-8",
            reasoningEffort: "high",
            toolsAvailable: ["time_now"],
            systemPrompt: segments.combined,
            userMessage: "User message with \(bearer)",
            toolSchemas: [schema],
            systemSegments: segments
        )

        let events = await collectShared(kind: "context.snapshot", turnId: id) {
            await TurnTraceContext.$turnId.withValue(id) {
                SwiftNativeTurnEngine.fireContextSnapshotEvent(
                    surface: "chat",
                    context: ctx,
                    sessionId: "session-1",
                    runId: "run-from-context"
                )
            }
        }
        let ev = try #require(events.first { $0.turnId == id })
        guard case .object(let p) = ev.payload else {
            Issue.record("expected object payload"); return
        }

        #expect(p["schema"] == .string("context.snapshot.v1"))
        #expect(p["model"] == .string("claude-opus-4-8"))
        #expect(p["runId"] == .string("run-from-context"))
        #expect(p["sessionId"] == .string("session-1"))
        #expect(p["containsCognitiveSubstrate"] == .bool(true))
        #expect(p["toolNames"] == .array([.string("time_now")]))

        let stable = joinedChunks(p["stablePreview"])
        let dynamic = joinedChunks(p["dynamicPreview"])
        let cognitive = joinedChunks(p["cognitivePreview"])
        let user = joinedChunks(p["userPreview"])
        let serialized = (try? ev.payload.serialize(pretty: false)) ?? ""

        #expect(stable.contains("Visible persona packet"))
        #expect(stable.contains("[REDACTED_"))
        #expect(dynamic.contains("Dynamic runtime facts"))
        #expect(dynamic.contains("NativeAgent Swift tool protocol"))
        #expect(cognitive.contains("[CognitiveSubstrate]"))
        #expect(cognitive.contains("State is provisional."))
        #expect(!cognitive.contains("here is what I think it means"))
        #expect(!cognitive.contains("stale-history-run"))
        #expect(!cognitive.contains("stale quoted bash output"))
        #expect(!cognitive.contains("NativeAgent Swift tool protocol"))
        #expect(user.contains("[REDACTED_BEARER_TOKEN]"))
        #expect(!serialized.contains(anthropicKey))
        #expect(!serialized.contains(bearer))
    }

    private func joinedChunks(_ value: JSONValue?) -> String {
        guard case .array(let chunks)? = value else { return "" }
        return chunks.compactMap {
            if case .string(let s) = $0 { return s }
            return nil
        }.joined()
    }
}
