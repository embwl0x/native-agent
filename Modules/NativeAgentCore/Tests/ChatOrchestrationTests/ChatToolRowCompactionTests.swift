import Foundation
import NativeAgentCore
import PersistenceCore
import Testing

@testable import ChatOrchestration

/// Tool rows persist with `content: ""` and their payload under `metadata`
/// (`ChatOrchestrationClient+MessagePersistence.swift`). Compaction used to read
/// `content` only, so a tool-heavy session (a) measured as ~zero characters and
/// never reached the token threshold — it died on a provider context-length
/// error instead — and (b) lost every record of the tools it ran the moment it
/// did compact. These tests pin both halves.
@Suite("Tool rows are visible to compaction")
struct ChatToolRowCompactionTests {

    // MARK: - (1) sizing

    @Test("a tool row's metadata counts toward the transcript size estimate")
    func toolRowMetadataCountsTowardSize() throws {
        let object = try #require(toolRowObject(name: "web_search", ok: true, index: 0))
        // The defect in one line: content is empty, so content-only sizing saw 0.
        #expect(ChatCompactionRowRendering.characterCount(object) > 0)

        var withoutMetadata = object
        withoutMetadata["metadata"] = nil
        #expect(ChatCompactionRowRendering.characterCount(withoutMetadata) == 0)

        // Non-empty content still wins over metadata.
        var withContent = object
        withContent["content"] = .string("hello there")
        #expect(ChatCompactionRowRendering.characterCount(withContent) == 11)
    }

    @Test("a tool-heavy transcript now crosses the size gate and compacts")
    func toolHeavyTranscriptCrossesSizeGate() async throws {
        let fixture = try Fixture(name: "size-gate")
        let rows = try toolHeavyTranscript()
        try writeRows(rows, to: fixture.messagesURL)

        // Content-only sizing: the two conversational rows and nothing else.
        let contentOnlyChars = rows.reduce(into: 0) { total, row in
            guard case .object(let obj) = row,
                  case .string(let content)? = obj["content"] else { return }
            total += content.count
        }
        let thresholdTokens = 200
        #expect(contentOnlyChars / 4 < thresholdTokens, "fixture must be under the gate on content alone")

        let outcome = try await fixture.compactor(thresholdTokens: thresholdTokens, keepCount: 2)
            .compactIfNeeded(
                sessionId: fixture.sessionID,
                model: "gpt-5.6",
                surface: "chat",
                runId: nil
            )

        #expect(outcome.compacted)
        #expect(outcome.estimatedTokensBefore >= thresholdTokens)
        #expect(outcome.messagesReplaced > 0)
    }

    // MARK: - (2) continuity

    @Test("the compaction summary records the tool activity it replaced")
    func compactionSummaryMentionsTools() async throws {
        let fixture = try Fixture(name: "summary")
        try writeRows(try toolHeavyTranscript(), to: fixture.messagesURL)

        let outcome = try await fixture.compactor(thresholdTokens: 200, keepCount: 2)
            .compactIfNeeded(
                sessionId: fixture.sessionID,
                model: "gpt-5.6",
                surface: "chat",
                runId: nil
            )
        #expect(outcome.compacted)

        let summary = try #require(try fixture.summaryContent())
        #expect(summary.contains("web_search"))
        #expect(summary.contains("run_tests"))
        #expect(summary.contains("(failed)"), "a failed tool call must stay legible as a failure")
        #expect(summary.contains("result summary 0"))
    }

    @Test("the distill prompt carries the tool activity too")
    func distillPromptMentionsTools() async throws {
        let fixture = try Fixture(name: "distill")
        let replaced = try toolHeavyTranscript()
        let backup = fixture.root
            .appendingPathComponent("chat/sessions", isDirectory: true)
            .appendingPathComponent(fixture.sessionID, isDirectory: true)
            .appendingPathComponent("messages.compact.backup.jsonl")
        try writeRows(replaced, to: backup)

        let summaryID = "compact-tool-rows"
        try writeRows([
            .object([
                "id": .string(summaryID),
                "sessionId": .string(fixture.sessionID),
                "role": .string("system"),
                "content": .string("[NativeAgent compacted \(replaced.count) earlier message(s).]"),
                "metadata": .object([
                    "kind": .string("compaction_summary"),
                    "distill": .string("pending"),
                ]),
            ]),
        ], to: fixture.messagesURL)

        let captured = CapturedPrompt()
        let distiller = ChatCompactionDistiller(
            dataRoot: fixture.root,
            pinnedModelResolver: { _ in nil },
            llmComplete: { _, prompt in
                await captured.record(prompt)
                return "I ran the search and the tests."
            },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        await distiller.distill(
            sessionId: fixture.sessionID,
            summaryRowId: summaryID,
            backupPath: backup.path,
            messagesReplaced: replaced.count,
            turnModel: "gpt-5.6",
            surface: "chat",
            runId: nil
        )

        let prompt = try #require(await captured.value)
        #expect(prompt.contains("web_search"))
        #expect(prompt.contains("run_tests"))
    }

    // MARK: - fixtures

    private actor CapturedPrompt {
        private(set) var value: String?
        func record(_ prompt: String) { value = prompt }
    }

    /// Two short conversational rows plus twelve tool rows whose only payload is
    /// metadata — the shape a tool-heavy session actually persists.
    private func toolHeavyTranscript() throws -> [JSONValue] {
        var rows: [JSONValue] = [
            .object(["role": .string("user"), "content": .string("audit the repo")]),
        ]
        for index in 0..<12 {
            let name = index.isMultiple(of: 2) ? "web_search" : "run_tests"
            let object = try #require(toolRowObject(name: name, ok: index != 3, index: index))
            rows.append(.object(object))
        }
        rows.append(.object(["role": .string("assistant"), "content": .string("done")]))
        return rows
    }

    private func toolRowObject(name: String, ok: Bool, index: Int) -> [String: JSONValue]? {
        [
            "role": .string("tool"),
            "content": .string(""),
            "metadata": .object([
                "kind": .string("tool_use"),
                "toolName": .string(name),
                "inputJSON": .string(#"{"query":"\#(name)-\#(index)"}"#),
                "resultSummary": .string("result summary \(index) " + String(repeating: "detail ", count: 40)),
                "ok": .bool(ok),
            ]),
        ]
    }

    private func writeRows(_ rows: [JSONValue], to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var payload = Data()
        for row in rows {
            payload.append(Data(try row.serialize(pretty: false).utf8))
            payload.append(0x0A)
        }
        try payload.write(to: path, options: .atomic)
    }

    private struct Fixture {
        let root: URL
        let sessionID: String
        let messagesURL: URL

        init(name: String) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("nativeagent-toolrow-\(name)-\(UUID().uuidString)", isDirectory: true)
            sessionID = "session-toolrow-\(name)"
            messagesURL = root
                .appendingPathComponent("chat/messages", isDirectory: true)
                .appendingPathComponent("\(sessionID).jsonl")
            try FileManager.default.createDirectory(
                at: messagesURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        func compactor(thresholdTokens: Int, keepCount: Int) -> ChatSessionAutocompactor {
            ChatSessionAutocompactor(
                dataRoot: root,
                config: ChatSessionAutocompactionConfig(
                    thresholdTokens: thresholdTokens,
                    keepCount: keepCount,
                    distillEnabled: false
                )
            )
        }

        func summaryContent() throws -> String? {
            let text = try String(contentsOf: messagesURL, encoding: .utf8)
            guard let first = text.split(separator: "\n", omittingEmptySubsequences: true).first,
                  let data = String(first).data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return nil
            }
            return object["content"] as? String
        }
    }
}
