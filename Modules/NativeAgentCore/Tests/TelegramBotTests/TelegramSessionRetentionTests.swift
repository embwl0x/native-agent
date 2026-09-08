import Testing
import Foundation
@testable import TelegramBot
import NativeAgentCore
import PersistenceCore
import ApprovalInbox

@Test func telegramCompactionCarriesMiddleAndPreviousSummary() async throws {
    let root = sessionRetentionTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    actor Summarizer {
        var prompts: [String] = []
        func complete(_ prompt: String) -> String {
            prompts.append(prompt)
            return prompt.contains("MIDDLE_DECISION")
                ? "I agreed to MIDDLE_DECISION because the rollout must remain reversible."
                : "I discussed the initial request."
        }
    }
    let summarizer = Summarizer()
    let store = TelegramSessionStore(dataRoot: root, summarize: { await summarizer.complete($0) })
    let destination = TelegramDestination.chat(42)
    let id = try await store.activeSessionId(destination: destination)
    let path = root.appendingPathComponent("chat/messages/\(id).jsonl")
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let rows: [JSONValue] = (0..<100).map { index in
        .object(["role": .string("user"), "content": .string(
            "ROW_\(index) " + String(repeating: "detail ", count: 90) + (index == 50 ? " MIDDLE_DECISION" : "")
        )])
    }
    let original = try rows.map { try $0.serialize(pretty: false) }.joined(separator: "\n") + "\n"
    try Data(original.utf8).write(to: path)
    let first = try await store.compactSession(destination: destination, force: true)
    #expect(first.compacted)
    let prompts = await summarizer.prompts.joined(separator: "\n")
    for index in 0..<80 { #expect(prompts.contains("ROW_\(index) ")) }
    #expect(try String(contentsOf: path, encoding: .utf8).contains("MIDDLE_DECISION"))
    let second = try await store.compactSession(destination: destination, force: true)
    #expect(second.compacted)
    #expect(try String(contentsOf: path, encoding: .utf8).contains("MIDDLE_DECISION"))

    for _ in 0..<4 {
        let previous = try Data(contentsOf: path)
        #expect(try await store.compactSession(destination: destination, force: true).compacted)
        let directory = root.appendingPathComponent("chat/sessions/\(id)")
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("messages.compact.") }
        #expect(backups.count == 3)
        #expect(try backups.contains { try Data(contentsOf: $0) == previous })
    }

    let beforeFailure = try Data(contentsOf: path)
    let refusing = TelegramSessionStore(dataRoot: root, summarize: { _ in "" })
    let failure = try await refusing.compactSession(destination: destination, force: true)
    #expect(!failure.compacted)
    #expect(try Data(contentsOf: path) == beforeFailure)
}

@Test func telegramStatusKeepsPendingApprovalAfterTurnAndScopesTopic() async throws {
    let root = sessionRetentionTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = SwiftNativeApprovalInbox(root: root)
    _ = try await inbox.create(.object([
        "title": .string("Confirm action"), "action": .string("test.action"),
        "payload": .object(["telegram": .object(["chatId": .int(42), "threadId": .int(7)])])
    ]))
    let bot = SwiftNativeTelegramBot(dataRoot: root)
    #expect(await bot.approvalStatusSentence(destination: .init(chatId: 42, threadId: 7)).contains("1 approval"))
    #expect(await bot.approvalStatusSentence(destination: .chat(42)).contains("No pending"))
    let path = root.appendingPathComponent("workflows/approvals/requests.json")
    try Data("broken".utf8).write(to: path)
    #expect(await bot.approvalStatusSentence(destination: .chat(42)).contains("unavailable"))
}

@Test func telegramDelegateProgressUsesUserFacingWords() {
    #expect(TelegramPollLoop.voiceTranscriptionNotice(for: TelegramBotError.notConfigured)
        == "Voice transcription needs an OpenAI API key.")
    for (kind, text) in [("invoke_started", "Invoking Claude"),
                         ("invoke_heartbeat", "Claude still working"),
                         ("invoke_timeout", "Codex invoke timed out")] {
        let rendered = TelegramPollLoop.progressMessage(for: .notice(kind: kind, text: text)) ?? ""
        #expect(rendered.contains("background work"))
        #expect(!rendered.contains("Claude"))
        #expect(!rendered.contains("Codex"))
    }
}

// Tightness round 2 P-L4: compactSession wrote a pre-compaction backup every
// time and never pruned them; appendNote appended notes.jsonl uncapped. These
// pin the newest-3 backup retention and that the note append routes through the
// shared capped path.

private func sessionRetentionTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tg-session-retention-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func pruneCompactBackupsKeepsNewestThree() throws {
    let dir = sessionRetentionTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fm = FileManager.default
    // Six timestamped backups (lexicographically sortable) plus two files that
    // must never be touched.
    let stamps = [
        "20260101-000000", "20260102-000000", "20260103-000000",
        "20260104-000000", "20260105-000000", "20260106-000000",
    ]
    for s in stamps {
        try Data("x".utf8).write(to: dir.appendingPathComponent("messages.compact.\(s).jsonl"))
    }
    try Data("live".utf8).write(to: dir.appendingPathComponent("messages.jsonl"))
    try Data("ctx".utf8).write(to: dir.appendingPathComponent("context.json"))

    TelegramSessionStore.pruneCompactBackups(in: dir, keep: 3)

    let remaining = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .map(\.lastPathComponent).sorted()
    // Newest 3 backups survive; older 3 are gone; unrelated files untouched.
    #expect(remaining.contains("messages.compact.20260106-000000.jsonl"))
    #expect(remaining.contains("messages.compact.20260105-000000.jsonl"))
    #expect(remaining.contains("messages.compact.20260104-000000.jsonl"))
    #expect(!remaining.contains("messages.compact.20260103-000000.jsonl"))
    #expect(!remaining.contains("messages.compact.20260101-000000.jsonl"))
    #expect(remaining.contains("messages.jsonl"))
    #expect(remaining.contains("context.json"))
    // Exactly the 3 kept backups + 2 unrelated files.
    #expect(remaining.count == 5)
}

@Test func pruneCompactBackupsNoOpUnderLimit() throws {
    let dir = sessionRetentionTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    for s in ["20260101-000000", "20260102-000000"] {
        try Data("x".utf8).write(to: dir.appendingPathComponent("messages.compact.\(s).jsonl"))
    }
    TelegramSessionStore.pruneCompactBackups(in: dir, keep: 3)
    let remaining = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    #expect(remaining.count == 2)
}

@Test func appendNoteWritesThroughCappedPath() async throws {
    let dir = sessionRetentionTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TelegramSessionStore(dataRoot: dir)
    let id1 = try await store.appendNote(text: "first", kind: "note", source: "test")
    let id2 = try await store.appendNote(text: "second", kind: "note", source: "test")
    #expect(id1 != id2)
    let notesPath = dir
        .appendingPathComponent("memory", isDirectory: true)
        .appendingPathComponent("NativeAgent", isDirectory: true)
        .appendingPathComponent("notes.jsonl")
    let body = try String(contentsOf: notesPath, encoding: .utf8)
    let lines = body.split(separator: "\n").filter { !$0.isEmpty }
    // Both notes present (well under the cap, so nothing trimmed).
    #expect(lines.count == 2)
    #expect(body.contains("first"))
    #expect(body.contains("second"))
}
