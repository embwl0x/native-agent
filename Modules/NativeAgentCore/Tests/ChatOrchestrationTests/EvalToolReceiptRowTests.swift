import DreamREMCycle
import Foundation
import MacControl
import NativeAgentCore
import PersistenceCore
import ProviderRouting
import Testing
@testable import ChatOrchestration

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
