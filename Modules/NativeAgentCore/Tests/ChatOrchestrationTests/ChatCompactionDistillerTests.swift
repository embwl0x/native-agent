import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore

// MARK: - helpers (self-contained; the ChatOrchestrationClientTests helpers are
// file-private, so this file carries its own minimal set)

private func makeDistillRoot(_ tag: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("distill-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func serializeRows(_ rows: [JSONValue]) throws -> Data {
    var payload = Data()
    for row in rows {
        payload.append(Data((try row.serialize(pretty: false)).utf8))
        payload.append(0x0A)
    }
    return payload
}

private func writeRows(_ rows: [JSONValue], to path: URL) throws {
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try serializeRows(rows).write(to: path, options: .atomic)
}

private func messagesURL(_ root: URL, _ sessionId: String) -> URL {
    root.appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("messages", isDirectory: true)
        .appendingPathComponent("\(sessionId).jsonl")
}

private func readMessageObjects(_ root: URL, _ sessionId: String) -> [[String: Any]] {
    let path = messagesURL(root, sessionId)
    guard let data = try? Data(contentsOf: path),
          let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
        guard let d = String(line).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}

private func readDistillTraces(_ root: URL) -> [[String: Any]] {
    let path = root.appendingPathComponent("traces", isDirectory: true)
        .appendingPathComponent("events.jsonl")
    guard let data = try? Data(contentsOf: path),
          let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
        guard let d = String(line).data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              obj["kind"] as? String == "context.compact.distill" else { return nil }
        return obj
    }
}

private func summaryRow(id: String, content: String) -> JSONValue {
    .object([
        "id": .string(id),
        "sessionId": .string("s"),
        "role": .string("system"),
        "content": .string(content),
        "createdAt": .string("2026-07-01T00:00:00Z"),
        "source": .string("native_autocompaction"),
        "metadata": .object([
            "kind": .string("compaction_summary"),
            "messages_replaced": .int(2),
            "trigger": .string("auto_threshold"),
            "distill": .string("pending"),
        ]),
    ])
}

private func plainRow(_ role: String, _ content: String, _ index: Int) -> JSONValue {
    .object([
        "id": .string("msg-\(index)"),
        "sessionId": .string("s"),
        "role": .string(role),
        "content": .string(content),
        "createdAt": .string("2026-07-01T00:00:\(String(format: "%02d", index))Z"),
    ])
}

/// Seeds a backup file (the replaced turns) and a messages file whose first row
/// is a `compaction_summary` with `summaryId`. Returns the backup URL.
private func seedDistillFixture(
    root: URL, sessionId: String, summaryId: String, mechanicalContent: String = "MECHANICAL"
) throws -> URL {
    let replaced: [JSONValue] = [
        plainRow("user", "I'm User. Remember: ship the R4 distiller today.", 0),
        plainRow("assistant", "On it — distilling the compaction summary now.", 1),
    ]
    let backup = root.appendingPathComponent("chat", isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent(sessionId, isDirectory: true)
        .appendingPathComponent("messages.compact.backup.jsonl")
    try writeRows(replaced, to: backup)

    let messages: [JSONValue] = [
        summaryRow(id: summaryId, content: mechanicalContent),
        plainRow("user", "kept row one", 10),
        plainRow("assistant", "kept row two", 11),
    ]
    try writeRows(messages, to: messagesURL(root, sessionId))
    return backup
}

private func makeDistiller(
    root: URL,
    pinned: String? = nil,
    llm: @escaping @Sendable (_ model: String, _ prompt: String) async throws -> String
) -> ChatCompactionDistiller {
    ChatCompactionDistiller(
        dataRoot: root,
        pinnedModelResolver: { _ in pinned },
        llmComplete: llm,
        now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
}

// MARK: - tests

@Test
func chatCompactionDistiller_success_swapsOnlySummaryRow() async throws {
    let root = try makeDistillRoot("ok")
    let sessionId = "s-distill-ok"
    let summaryId = "compact-abc123"
    let backup = try seedDistillFixture(root: root, sessionId: sessionId, summaryId: summaryId)

    // Snapshot the kept rows' raw bytes to prove byte-identity.
    let beforeLines = try String(contentsOf: messagesURL(root, sessionId), encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

    let distilled = "I'm working with User. Decision: ship the R4 distiller today; it's in progress."
    let distiller = makeDistiller(root: root) { model, prompt in
        #expect(model == "turn-model")   // unpinned → turn model
        #expect(prompt.contains("I'm User."))
        return distilled
    }

    await distiller.distill(
        sessionId: sessionId, summaryRowId: summaryId, backupPath: backup.path,
        messagesReplaced: 2, turnModel: "turn-model", surface: "chat", runId: "r-1"
    )

    let rows = readMessageObjects(root, sessionId)
    #expect(rows.count == 3)
    #expect(rows[0]["content"] as? String == distilled)
    let meta = rows[0]["metadata"] as? [String: Any]
    #expect(meta?["distill"] as? String == "llm")
    #expect(meta?["distill_model"] as? String == "turn-model")

    // Kept rows byte-identical.
    let afterLines = try String(contentsOf: messagesURL(root, sessionId), encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    #expect(afterLines.count == 3)
    #expect(afterLines[1] == beforeLines[1])
    #expect(afterLines[2] == beforeLines[2])

    let traces = readDistillTraces(root)
    let ok = try #require(traces.first { $0["status"] as? String == "ok" })
    let payload = try #require(ok["payload"] as? [String: Any])
    #expect(payload["schema"] as? String == "context.compact.distill.v1")
    #expect(payload["sessionId"] as? String == sessionId)
    #expect(payload["surface"] as? String == "chat")
    #expect(payload["model"] as? String == "turn-model")
    #expect((payload["charsOut"] as? Int ?? 0) == distilled.count)
}

@Test
func chatCompactionDistiller_pinResolvesModel() async throws {
    let root = try makeDistillRoot("pin")
    let sessionId = "s-distill-pin"
    let summaryId = "compact-pin1"
    let backup = try seedDistillFixture(root: root, sessionId: sessionId, summaryId: summaryId)

    let distiller = makeDistiller(root: root, pinned: "pinned-cheap-model") { model, _ in
        #expect(model == "pinned-cheap-model")
        return "distilled via pinned model"
    }
    await distiller.distill(
        sessionId: sessionId, summaryRowId: summaryId, backupPath: backup.path,
        messagesReplaced: 2, turnModel: "turn-model", surface: "chat", runId: nil
    )
    let rows = readMessageObjects(root, sessionId)
    #expect((rows[0]["metadata"] as? [String: Any])?["distill_model"] as? String == "pinned-cheap-model")
}

@Test
func chatCompactionDistiller_llmThrows_leavesFileUntouched() async throws {
    let root = try makeDistillRoot("throw")
    let sessionId = "s-distill-throw"
    let summaryId = "compact-throw1"
    let backup = try seedDistillFixture(root: root, sessionId: sessionId, summaryId: summaryId)
    let before = try Data(contentsOf: messagesURL(root, sessionId))

    struct Boom: Error {}
    let distiller = makeDistiller(root: root) { _, _ in throw Boom() }
    await distiller.distill(
        sessionId: sessionId, summaryRowId: summaryId, backupPath: backup.path,
        messagesReplaced: 2, turnModel: "turn-model", surface: "chat", runId: "r-2"
    )

    let after = try Data(contentsOf: messagesURL(root, sessionId))
    #expect(before == after)   // untouched
    let traces = readDistillTraces(root)
    #expect(traces.contains { $0["status"] as? String == "failed" })
}

@Test
func chatCompactionDistiller_emptyDistillation_leavesFileUntouched() async throws {
    let root = try makeDistillRoot("empty")
    let sessionId = "s-distill-empty"
    let summaryId = "compact-empty1"
    let backup = try seedDistillFixture(root: root, sessionId: sessionId, summaryId: summaryId)
    let before = try Data(contentsOf: messagesURL(root, sessionId))

    let distiller = makeDistiller(root: root) { _, _ in "   \n  " }  // whitespace only
    await distiller.distill(
        sessionId: sessionId, summaryRowId: summaryId, backupPath: backup.path,
        messagesReplaced: 2, turnModel: "turn-model", surface: "chat", runId: nil
    )
    #expect(try Data(contentsOf: messagesURL(root, sessionId)) == before)
    #expect(readDistillTraces(root).contains { $0["status"] as? String == "failed" })
}

@Test
func chatCompactionDistiller_rowIdAbsent_noOpAndTracesRowMissing() async throws {
    let root = try makeDistillRoot("missing")
    let sessionId = "s-distill-missing"
    // Seed with a DIFFERENT summary id than we ask the distiller to swap.
    let backup = try seedDistillFixture(root: root, sessionId: sessionId, summaryId: "compact-present")
    let before = try Data(contentsOf: messagesURL(root, sessionId))

    let distiller = makeDistiller(root: root) { _, _ in "should never be written" }
    await distiller.distill(
        sessionId: sessionId, summaryRowId: "compact-ABSENT", backupPath: backup.path,
        messagesReplaced: 2, turnModel: "turn-model", surface: "chat", runId: nil
    )

    #expect(try Data(contentsOf: messagesURL(root, sessionId)) == before)   // untouched
    #expect(readDistillTraces(root).contains { $0["status"] as? String == "row_missing" })
}

@Test
func chatCompactionDistiller_backupUnreadable_tracesSkipped() async throws {
    let root = try makeDistillRoot("skip")
    let sessionId = "s-distill-skip"
    let summaryId = "compact-skip1"
    _ = try seedDistillFixture(root: root, sessionId: sessionId, summaryId: summaryId)
    let before = try Data(contentsOf: messagesURL(root, sessionId))

    let distiller = makeDistiller(root: root) { _, _ in "unused" }
    await distiller.distill(
        sessionId: sessionId, summaryRowId: summaryId,
        backupPath: root.appendingPathComponent("does-not-exist.jsonl").path,
        messagesReplaced: 2, turnModel: "turn-model", surface: "chat", runId: nil
    )
    #expect(try Data(contentsOf: messagesURL(root, sessionId)) == before)
    #expect(readDistillTraces(root).contains { $0["status"] as? String == "skipped" })
}

// MARK: - autocompactor contract: distill flag threads into the summary row

@Test
func chatSessionAutocompactor_distillDisabled_noPendingMetaOrRowId() async throws {
    let root = try makeDistillRoot("autocompact-off")
    let sessionId = "s-autocompact-off"
    let rows = (0..<26).map { index -> JSONValue in
        let fillCount = index < 6 ? 8_000 : 40
        return plainRow(
            index.isMultiple(of: 2) ? "user" : "assistant",
            "OFF-MSG-\(index) " + String(repeating: "x", count: fillCount),
            index
        )
    }
    try writeRows(rows, to: messagesURL(root, sessionId))

    let outcome = try await ChatSessionAutocompactor(
        dataRoot: root,
        config: ChatSessionAutocompactionConfig(
            thresholdTokens: 2_000, keepCount: 20, distillEnabled: false
        )
    ).compactIfNeeded(sessionId: sessionId, model: "m", surface: "chat", runId: "r")

    #expect(outcome.compacted)
    // Both distill fields are gated: nil when disabled, so the hook never
    // spawns and the outcome doesn't advertise a distill input it won't use.
    // (The backup file itself is still taken on disk — fail-safe, unchanged.)
    #expect(outcome.summaryRowId == nil)
    #expect(outcome.backupPath == nil)
    let compacted = readMessageObjects(root, sessionId)
    let meta = compacted.first?["metadata"] as? [String: Any]
    #expect(meta?["kind"] as? String == "compaction_summary")
    #expect(meta?["distill"] == nil)   // no pending marker when disabled
}

@Test
func chatSessionAutocompactor_distillEnabled_pendingMetaAndRowId() async throws {
    let root = try makeDistillRoot("autocompact-on")
    let sessionId = "s-autocompact-on"
    let rows = (0..<26).map { index -> JSONValue in
        let fillCount = index < 6 ? 8_000 : 40
        return plainRow(
            index.isMultiple(of: 2) ? "user" : "assistant",
            "ON-MSG-\(index) " + String(repeating: "x", count: fillCount),
            index
        )
    }
    try writeRows(rows, to: messagesURL(root, sessionId))

    let outcome = try await ChatSessionAutocompactor(
        dataRoot: root,
        config: ChatSessionAutocompactionConfig(
            thresholdTokens: 2_000, keepCount: 20, distillEnabled: true
        )
    ).compactIfNeeded(sessionId: sessionId, model: "m", surface: "chat", runId: "r")

    #expect(outcome.compacted)
    let rowId = try #require(outcome.summaryRowId)
    #expect(try #require(outcome.backupPath).contains("messages.compact."))
    let compacted = readMessageObjects(root, sessionId)
    #expect(compacted.first?["id"] as? String == rowId)
    let meta = compacted.first?["metadata"] as? [String: Any]
    #expect(meta?["distill"] as? String == "pending")
}

// MARK: - review fix-round regressions (gpt-5.5 findings, 2026-07-01)

/// HIGH fix: transcript appends now take the same sidecar lock as the
/// distiller's read-modify-rewrite. An append landing while the distiller is
/// between its backup read and its locked swap must survive the swap.
@Test
func chatCompactionDistiller_concurrentLockedAppend_isNeverDropped() async throws {
    let root = try makeDistillRoot("race")
    let sessionId = "s-race"
    let summaryId = "compact-race"
    _ = try seedDistillFixture(root: root, sessionId: sessionId, summaryId: summaryId)
    let path = messagesURL(root, sessionId)
    let persistence = SwiftNativePersistenceCore()

    let appended: JSONValue = .object([
        "id": .string("msg-appended-mid-distill"),
        "sessionId": .string(sessionId),
        "role": .string("assistant"),
        "content": .string("landed while distilling"),
        "createdAt": .string("2026-07-01T00:01:00Z"),
    ])
    let distiller = makeDistiller(root: root) { _, _ in
        // Fires between the distiller's backup read and its locked swap —
        // exactly the window where the pre-fix rewrite dropped rows. The
        // append uses the same locked discipline the client's appendMessage/
        // appendToolMessage/appendPartial now use.
        try await persistence.withFileLock(path) {
            try await persistence.appendJSONL(appended, to: path)
        }
        return "DISTILLED-RACE"
    }
    await distiller.distill(
        sessionId: sessionId, summaryRowId: summaryId,
        backupPath: root.appendingPathComponent("chat/sessions/\(sessionId)/messages.compact.backup.jsonl").path,
        messagesReplaced: 2, turnModel: "m", surface: "chat", runId: nil
    )

    let objs = readMessageObjects(root, sessionId)
    #expect(objs.first?["content"] as? String == "DISTILLED-RACE")
    #expect(objs.contains { $0["id"] as? String == "msg-appended-mid-distill" })
    #expect(readDistillTraces(root).contains { $0["status"] as? String == "ok" })
}

/// MED fix: two compactions in the same clock second produce DISTINCT backups;
/// a collision must never hand the distiller a stale backup as fresh.
@Test
func chatSessionAutocompactor_sameSecondBackups_areDistinct() async throws {
    let root = try makeDistillRoot("backup-unique")
    let sessionId = "s-backup-unique"
    let frozen = Date(timeIntervalSince1970: 1_800_000_000)
    let config = ChatSessionAutocompactionConfig(
        thresholdTokens: 2_000, keepCount: 20, distillEnabled: true
    )
    func seedBig() throws {
        let rows = (0..<26).map { index -> JSONValue in
            plainRow(
                index.isMultiple(of: 2) ? "user" : "assistant",
                "BK-\(index) " + String(repeating: "x", count: index < 6 ? 8_000 : 40),
                index
            )
        }
        try writeRows(rows, to: messagesURL(root, sessionId))
    }

    try seedBig()
    let first = try await ChatSessionAutocompactor(dataRoot: root, config: config, now: { frozen })
        .compactIfNeeded(sessionId: sessionId, model: "m", surface: "chat", runId: nil)
    try seedBig()
    let second = try await ChatSessionAutocompactor(dataRoot: root, config: config, now: { frozen })
        .compactIfNeeded(sessionId: sessionId, model: "m", surface: "chat", runId: nil)

    let firstBackup = try #require(first.backupPath)
    let secondBackup = try #require(second.backupPath)
    #expect(firstBackup != secondBackup)
    #expect(FileManager.default.fileExists(atPath: firstBackup))
    #expect(FileManager.default.fileExists(atPath: secondBackup))
}

/// LOW fix: the swap is line-surgical — a legacy/noncanonical row (unsorted
/// keys, unknown fields) must survive the rewrite byte-for-byte.
@Test
func chatCompactionDistiller_noncanonicalUntouchedLine_survivesByteForByte() async throws {
    let root = try makeDistillRoot("bytes")
    let sessionId = "s-bytes"
    let summaryId = "compact-bytes"
    let backup = try seedDistillFixture(root: root, sessionId: sessionId, summaryId: summaryId)
    let path = messagesURL(root, sessionId)

    // Noncanonical: keys deliberately not in serializer order + extra field.
    let rawLegacyLine = #"{"zebra":true,"id":"msg-legacy","role":"user","content":"legacy row","sessionId":"s-bytes"}"#
    let existing = try String(contentsOf: path, encoding: .utf8)
    try (existing + rawLegacyLine + "\n").write(to: path, atomically: true, encoding: .utf8)

    let distiller = makeDistiller(root: root) { _, _ in "DISTILLED-BYTES" }
    await distiller.distill(
        sessionId: sessionId, summaryRowId: summaryId, backupPath: backup.path,
        messagesReplaced: 2, turnModel: "m", surface: "chat", runId: nil
    )

    let after = try String(contentsOf: path, encoding: .utf8)
    #expect(after.contains(rawLegacyLine))
    #expect(readMessageObjects(root, sessionId).first?["content"] as? String == "DISTILLED-BYTES")
}
