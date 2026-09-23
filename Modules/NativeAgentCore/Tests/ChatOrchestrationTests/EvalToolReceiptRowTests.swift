import DreamREMCycle
import Foundation
import MacControl
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import Testing
import StandingBots
import MemoryV2
import Dispatcher
@testable import ChatOrchestration
import NativeAgentTestSupport

// Coverage-ledger fence `core.chat.persistence`:
//   * chat.persistence.toolReceiptRedaction (silent leak into an unencrypted,
//     long-lived, cross-surface-synced transcript)
//   * chat.persistence.toolRowKindTag       (stale UI via a two-vocabulary seam)
//
// The receipt row is the one transcript row that records an EXTERNAL EFFECT,
// and it is read back by every surface. Two things can go wrong without a
// symptom: a secret-bearing argument (or a base64 screenshot) lands verbatim,
// or the `metadata.kind` tag the renderer switches on drifts and every tool
// receipt silently flattens into an unstyled message.
@Suite("eval: persisted tool receipt row")
struct EvalToolReceiptRowTests {

    // Real local success paths, with every store and bridge root in a disposable
    // fixture. Network, UI, provider execution and process-global tools are not
    // invoked. Check the saved receipt as well as the classifier: ok:true alone
    // used to pass classification but lose its class in transcript persistence.
    @Test func builtInSuccessPathsKeepTheirReceiptClass() async throws {
        let root = try tempRoot("built-ins")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try MemoryStorage(inMemoryName: "receipt-\(UUID().uuidString)")
        let memory = SwiftNativeMemoryV2(embedder: MockEmbeddingProvider(dimensions: 32),
            storage: MemoryStorageBridge(storage: storage))
        let tools = SwiftToolDispatcher(dataRoot: root, memoryV2: memory, allowProcessGlobalTools: false,
            enforceLazyToolLoading: false, agentBridgeConfigRoot: root.appendingPathComponent("bridges"),
            standingBotRunEnqueue: { _ in UUID() })
        let writer = client(root: root)
        let persona = tools.personaRootForTools()
        try FileManager.default.createDirectory(at: persona, withIntermediateDirectories: true)
        try "# Growth\n\nFixture".write(to: persona.appendingPathComponent("GROWTH.md"), atomically: true, encoding: .utf8)
        let providers = root.appendingPathComponent("providers")
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        try Data(#"{"api_key":"sk-fixture"}"#.utf8).write(to: providers.appendingPathComponent("openai.json"))
        try writeTrustPolicy(root, .object(["memoryPolicy": .object(["knowledge_graph_enabled": .bool(true)])]))

        @discardableResult
        func check(_ name: String, _ input: [String: JSONValue] = [:]) async throws -> JSONValue {
            let result = try await tools.dispatch(tool: name, input: input, surface: "chat")
            #expect(ChatToolOutcome.exactResultClass(result) == .succeeded, "\(name): \(result)")
            if case .object = result {
                let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
                try await writer.appendToolMessage(sessionId: "success-walk", runId: UUID().uuidString,
                    toolName: name, inputJSON: "{}", resultSummary: json, ok: true)
                let metadata = try #require(try lastRow(root, sessionId: "success-walk")["metadata"] as? [String: Any])
                #expect(metadata["resultClass"] as? String == "succeeded", "\(name) lost its saved class")
            }
            return result
        }
        func field(_ result: JSONValue, _ key: String) throws -> JSONValue {
            guard case .object(let fields) = result else { throw CocoaError(.coderInvalidValue) }
            return try #require(fields[key])
        }

        for name in ["time_now", "bot_list", "shelf_read", "list_skills", "tool_catalog", "list_tools",
                     "task_ledger_list", "workshop_status", "desk_read", "context_lookup",
                     "scratchpad_read", "recent_trace_summary", "memory_moments_pending",
                     "list_memories", "studio_recall", "dream_diary_read", "remote_node_list"] {
            // remote_node_list has a Full Mac gate; exercise its pure local read
            // directly, without granting access to the host.
            if name == "remote_node_list" {
                #expect(ChatToolOutcome.exactResultClass(try await tools.impl_remote_node_list()) == .succeeded)
            } else {
                try await check(name, name == "scratchpad_read" ? ["session_id": .string("success-walk")] : [:])
            }
        }
        try await check("search_kg", ["query": .string("fixture")])
        try await check("tool_load", ["session_id": .string("success-walk"), "names": .array([.string("bot_list")])])
        try await check("tool_unload", ["session_id": .string("success-walk"), "names": .array([.string("bot_list")])])
        try await check("persona_read", ["kind": .string("growth")])
        try await check("get_persona_doc", ["doc": .string("GROWTH")])
        try await check("persona_write", ["kind": .string("growth"), "content": .string("# Growth\n\nFixture")])
        try await check("persona_append_section", ["kind": .string("growth"), "title": .string("Fixture"), "content": .string("Saved fixture.")])
        try await check("task_ledger_post", ["kind": .string("created"), "title": .string("Fixture")])
        try await check("save_skill", ["name": .string("Receipt fixture"), "description": .string("Fixture skill"),
            "content": .string("# Receipt fixture\n\nRead the fixture and report the result.")])
        try await check("read_skill", ["name": .string("Receipt fixture")])
        try await check("recall_memory", ["query": .string("fixture")])
        try await check("recall_search", ["query": .string("fixture")])

        let bot = try await check("bot_create", ["name": .string("Fixture"), "brief": .string("Read a fixture"),
            "provider": .string("openai"), "model": .string("gpt-5.6-sol"), "reasoning_effort": .string("high")])
        let botID = try field(bot, "id")
        try await check("bot_update", ["id": botID, "fields": .object(["brief": .string("Read another fixture")])])
        try await check("bot_pause", ["id": botID, "paused": .bool(true)])
        let queued = try await tools.dispatch(tool: "bot_run_once", input: ["id": botID], surface: "chat")
        #expect(try field(queued, "status") == .string("queued"))
        #expect(ChatToolOutcome.exactResultClass(queued) == .unknown)
        let savedBot = try #require(BotDefinitionStore(dataRoot: root).list().first)
        let entry = ShelfEntry(botId: savedBot.id, briefVersion: savedBot.briefVersion, runAt: Date(),
            coverageStart: Date(), coverageEnd: Date(), headline: "Fixture", findings: "Fixture reply",
            changedSinceLastGood: "", sourceLinks: [], uncertainties: [], runHealth: .ok,
            spend: ShelfSpend(tokens: 1, seconds: 1))
        try ShelfStore(dataRoot: root).append(entry)
        try await check("shelf_read")
        try await check("shelf_entry", ["id": .string(entry.id.uuidString)])
        try await check("bot_delete", ["id": botID])

        let item = try await check("desk_add_item", ["kind": .string("plan"), "project": .string("Fixture"), "title": .string("Receipt")])
        let handle = try field(item, "handle")
        let edits: [(String, [String: JSONValue])] = [
            ("desk_set_status", ["status": .string("now")]),
            ("desk_update_item", ["title": .string("Updated fixture")]),
            ("desk_note", ["text": .string("Fixture note")]),
            ("desk_add_ref", ["ref_kind": .string("url"), "url": .string("https://example.invalid/fixture")]),
            ("desk_set_cadence", ["mode": .string("manual")]),
            ("desk_set_notify", ["level": .string("quiet")]),
            ("desk_blocked_on", ["blocked_on": .string("")]),
            ("desk_close", ["outcome_summary": .string("Fixture complete")]),
            ("desk_archive", [:]),
        ]
        for (name, fields) in edits { try await check(name, fields.merging(["handle": handle]) { _, new in new }) }
        try await check("desk_nag_control", ["action": .string("status")])
        let consult = try await check("studio_consult", ["question": .string("What stands out?"),
            "description": .string("A fixture"), "description_only": .bool(true)])
        try await check("studio_consult_read", ["consult_id": try field(consult, "consult_id")])
    }

    @Test func localConnectorSuccessPathsKeepTheirReceiptClass() throws {
        let root = try tempRoot("local-actions").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let persona = root.appendingPathComponent("persona")
        for folder in [workspace, persona] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try "# Growth\nFixture".write(to: persona.appendingPathComponent("GROWTH.md"), atomically: true, encoding: .utf8)
        let path = workspace.appendingPathComponent("fixture.txt").path
        let context = ConnectorActionContext(repoRoot: root.path, dataRoot: root.appendingPathComponent("state").path,
            personaRoot: persona.path, workspaceRoot: workspace.path)
        let cases: [(String, [String: JSONValue])] = [
            ("write_file", ["path": .string(path), "content": .string("fixture\n")]),
            ("read_file", ["path": .string(path)]),
            ("file_excerpt", ["path": .string(path)]),
            ("list_dir", ["path": .string(workspace.path)]),
            ("grep", ["path": .string(workspace.path), "pattern": .string("fixture")]),
            ("persona_read", ["kind": .string("growth")]),
            ("persona_list_skills", [:]), ("workspace_list", [:]), ("time_now", [:]),
        ]
        for (name, input) in cases {
            let result = try #require(LocalConnectorActions.fileSystemDefault.run(name, input: input, ctx: context))
            #expect(ChatToolOutcome.exactResultClass(result) == .succeeded, "\(name): \(result)")
            guard case .object(let fields) = result else { Issue.record("Missing result for \(name)"); continue }
            #expect(fields["status"] != nil, "\(name) needs a status for the saved receipt")
        }
    }

    @Test func timeNowPersistsSuccessfulResultClass() async throws {
        let root = try tempRoot("time-now")
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await SwiftToolDispatcher(dataRoot: root).dispatch(tool: "time_now", input: [:], surface: "chat")
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        try await client(root: root).appendToolMessage(sessionId: "clock", runId: "clock-run",
            toolName: "time_now", inputJSON: "{}", resultSummary: json, ok: true)
        let metadata = try #require(try lastRow(root, sessionId: "clock")["metadata"] as? [String: Any])
        #expect(metadata["resultClass"] as? String == "succeeded")
        #expect(metadata["resultStatus"] as? String == "ok")
    }

    private func tempRoot(_ tag: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("eval-receipt-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func client(root: URL) -> SwiftNativeChatOrchestrationClient {
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
            turnTraceBus: TurnTraceBus(persistLane: TurnTracePersistLane(dataRootOverride: root))
        )
        return SwiftNativeChatOrchestrationClient(
            engine: engine,
            tools: tools,
            llm: llm,
            history: SessionHistoryReader(dataRoot: root),
            dataRoot: root,
            trust: hermeticTrust()
        )
    }

    private func transcriptText(_ root: URL, sessionId: String) -> String {
        let path = root
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
        return (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }

    private func lastRow(_ root: URL, sessionId: String) throws -> [String: Any] {
        let line = try #require(
            transcriptText(root, sessionId: sessionId)
                .split(separator: "\n", omittingEmptySubsequences: true).last
        )
        let data = try #require(String(line).data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: the tag the UI switches on

    /// The renderer keys the tool flip-box off `metadata.kind == "tool_use"`
    /// plus four sibling keys. This asserts the WRITER's half of that contract
    /// on a real persisted row: a rename here compiles clean and turns every
    /// historical and future receipt into a plain, unstyled message.
    @Test func aPersistedToolReceiptCarriesTheFiveKeysTheRendererReads() async throws {
        let root = try tempRoot("kind")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = "s-receipt-kind"

        try await client(root: root).appendToolMessage(
            sessionId: session,
            runId: "run-1",
            toolName: "read_file",
            inputJSON: #"{"path":"/tmp/x"}"#,
            resultSummary: #"{"ok":true}"#,
            ok: true
        )

        let row = try lastRow(root, sessionId: session)
        #expect(row["role"] as? String == "tool")
        let metadata = try #require(row["metadata"] as? [String: Any])
        #expect(metadata["kind"] as? String == "tool_use")
        #expect(metadata["toolName"] as? String == "read_file")
        #expect(metadata["inputJSON"] is String)
        #expect(metadata["resultSummary"] is String)
        #expect(metadata["ok"] as? Bool == true)
        #expect(metadata["resultClass"] == nil, "no-status receipts retain their legacy metadata")
    }

    @Test func queuedOutcomeSurvivesReceiptClippingWithoutChangingTransportSuccess() async throws {
        let root = try tempRoot("queued-clipped")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = "s-queued-clipped"
        // The status is beyond the persisted body cap, so a reader cannot
        // recover it by parsing that truncated JSON prefix.
        let result = "{\"detail\":\"" + String(repeating: "x", count: 9_000)
            + "\",\"status\":\"queued\"}"
        try await client(root: root).appendToolMessage(
            sessionId: session, runId: "queued-run", toolName: "claude_message",
            inputJSON: "{}", resultSummary: result, ok: true)
        let metadata = try #require(try lastRow(root, sessionId: session)["metadata"] as? [String: Any])
        #expect(metadata["ok"] as? Bool == true)
        #expect(metadata["resultClass"] as? String == ChatToolOutcome.ExactResultClass.unknown.rawValue)
        let stored = try #require(metadata["resultSummary"] as? String)
        #expect(stored.contains("truncated in transcript"))
        #expect(!stored.contains("queued"))
        #expect((try? JSONValue.parse(Data(stored.utf8))) == nil)
        let metadataJSON = try JSONValue.parse(JSONSerialization.data(withJSONObject: metadata))
        guard case .object(let fields) = metadataJSON else {
            Issue.record("persisted metadata must remain an object")
            return
        }
        // The exact word now survives the clipping too, beside the class, so
        // the row reports the state the work actually reached instead of
        // collapsing to "completion unconfirmed". Queueing succeeded; this
        // still must not claim that the queued work has finished.
        #expect(metadata["resultStatus"] as? String == "queued")
        #expect(SessionHistoryPromptRenderer.toolSummary(content: "", metadata: fields)
            .hasPrefix("queued: claude_message:"))
    }

    @Test func malformedOutcomeDoesNotCreateAResultClass() async throws {
        let root = try tempRoot("malformed-result")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = "s-malformed-result"
        try await client(root: root).appendToolMessage(
            sessionId: session, runId: "malformed-run", toolName: "read_file",
            inputJSON: "{}", resultSummary: #"{"status":"queued""#, ok: true)
        let metadata = try #require(try lastRow(root, sessionId: session)["metadata"] as? [String: Any])
        #expect(metadata["resultClass"] == nil)
    }

    // app.chat / ui.chat.transcript.approvalNeverCollapsed
    @Test func aNonBlockingApprovalReceiptCarriesTheSharedPendingPresentationKind() async throws {
        let root = try tempRoot("pending-approval")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = "s-pending-approval"

        try await client(root: root).appendToolMessage(
            sessionId: session,
            runId: "run-approval",
            toolName: "write_file",
            inputJSON: #"{"path":"/tmp/x"}"#,
            resultSummary: #"{"status":"waiting_approval","approvalId":"approval-visible"}"#,
            ok: true
        )

        let metadata = try #require(try lastRow(root, sessionId: session)["metadata"] as? [String: Any])
        #expect(metadata["kind"] as? String == ChatTranscriptToolMessageKind.approvalPending)
        #expect(metadata["approvalId"] as? String == "approval-visible")

        // Adverse result shapes must stay ordinary receipts. A lookalike
        // status or missing authority must never create a functional card.
        #expect(ChatTranscriptToolMessageKind.pendingApprovalID(in: "not json") == nil)
        #expect(ChatTranscriptToolMessageKind.pendingApprovalID(
            in: #"{"status":"waiting_approval"}"#
        ) == nil)
        #expect(ChatTranscriptToolMessageKind.pendingApprovalID(
            in: #"{"status":"pending_approval","approvalId":"approval-visible"}"#
        ) == nil)
    }

    // MARK: the redactors

    /// A password typed into a field comes back out through `ax_act`'s result
    /// as well as its argument. Neither may reach the file, and the ROW must
    /// still be a usable receipt (the tool is still named, the shape survives).
    @Test func anInjectionToolsSecretNeverReachesTheTranscript() async throws {
        let root = try tempRoot("secret")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = "s-receipt-secret"
        let secret = "hunter2-correct-horse-battery-staple" // gitleaks:allow — deliberate fake secret; this eval proves redaction

        try await client(root: root).appendToolMessage(
            sessionId: session,
            runId: "run-1",
            toolName: "mac_ax_act",
            inputJSON: #"{"action":"set_value","value":"\#(secret)"}"#,
            resultSummary: #"{"ok":true,"post_state":{"value":"\#(secret)"}}"#,
            ok: true
        )

        let text = transcriptText(root, sessionId: session)
        #expect(!text.isEmpty)
        #expect(!text.contains(secret), "the typed secret must never land in the transcript")
        #expect(!text.contains("hunter2"))
        let metadata = try #require(try lastRow(root, sessionId: session)["metadata"] as? [String: Any])
        #expect(metadata["toolName"] as? String == "mac_ax_act")
        #expect(metadata["kind"] as? String == "tool_use")
    }

    /// An unparseable body for a secret-bearing tool cannot be inspected, so it
    /// must be dropped whole rather than kept "just in case" — the fail-closed
    /// half of the same redactor.
    @Test func anUnparseableInjectionArgumentIsDroppedNotKept() async throws {
        let root = try tempRoot("unparseable")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = "s-receipt-unparseable"
        let secret = "sk-live-not-even-valid-json-abcdefghijklmnop"

        try await client(root: root).appendToolMessage(
            sessionId: session,
            runId: "run-1",
            toolName: "mac_keystroke",
            inputJSON: "{\"text\": \"\(secret)",  // truncated: will not parse
            resultSummary: "typed",
            ok: true
        )

        let text = transcriptText(root, sessionId: session)
        #expect(!text.contains(secret))
        #expect(text.contains("redacted"))
    }

    /// `mac_view` returns a base64 picture of whatever was on screen. The
    /// pixels must leave the receipt while the TEXT the model reasoned over
    /// stays — blanking the whole result would destroy the transcript.
    @Test func aScreenshotResultLosesItsPixelsAndKeepsItsText() async throws {
        let root = try tempRoot("view")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = "s-receipt-view"
        let picture = String(repeating: "QUJDREVG", count: 400)  // ~3.2KB of base64

        try await client(root: root).appendToolMessage(
            sessionId: session,
            runId: "run-1",
            toolName: "mac_view",
            inputJSON: #"{"app":"Finder"}"#,
            resultSummary: #"{"image":"\#(picture)","text":"Downloads — 12 items"}"#,
            ok: true
        )

        let text = transcriptText(root, sessionId: session)
        #expect(!text.contains(picture))
        #expect(text.contains("Downloads"))
        #expect(text.contains("image_redacted"))
    }

    // MARK: the vocabulary bridge (the rename the ledger names)

    /// The redactors switch on TOOL NAME. A new alias added to the injection
    /// vocabulary but forgotten in the secret-argument map is invisible: the
    /// receipt still looks well formed, it just carries the plaintext. Derived
    /// from the LIVE vocabulary, never a copied list, so adding
    /// `mac.type -> keystroke` tomorrow fails HERE.
    @Test func everyTypingInjectionAliasIsRegisteredAsSecretBearing() {
        let typingActions: Set<String> = ["keystroke", "ax_act", "act"]
        var checked = 0
        for tool in MacInjectionToolNames.all {
            guard let action = MacInjectionToolNames.action(forTool: tool),
                  typingActions.contains(action) else { continue }
            checked += 1
            #expect(
                MacInjectionArgRedaction.carriesSecretArgs(tool: tool),
                "\(tool) types literal characters but has no secret-arg mapping"
            )
        }
        #expect(checked >= 6, "the typing-injection vocabulary went empty — the guard would be vacuous")
    }

    /// Same shape for the picture-bearing vocabulary: every name `mac_view`
    /// answers to must actually lose its image through the persistence sink.
    @Test func everyScreenReadAliasLosesItsImageThroughThePersistenceSink() {
        let body = #"{"image":"QUJDREVGQUJDREVG","text":"visible"}"#
        #expect(!MacScreenViewResultRedaction.viewToolNames.isEmpty)
        for tool in MacScreenViewResultRedaction.viewToolNames {
            let stripped = SwiftNativeChatOrchestrationClient
                .screenViewRedactedResultJSON(tool: tool, json: body)
            #expect(!stripped.contains("QUJDREVGQUJDREVG"), "\(tool) kept its pixels")
            #expect(stripped.contains("visible"), "\(tool) lost its text as well")
        }
        // A non-screen tool is untouched — the sink must not blank ordinary
        // results that merely happen to have an `image` key.
        #expect(
            SwiftNativeChatOrchestrationClient
                .screenViewRedactedResultJSON(tool: "read_file", json: body) == body
        )
    }
}
