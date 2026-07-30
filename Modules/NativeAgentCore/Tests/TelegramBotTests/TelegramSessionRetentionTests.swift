import Testing
import Foundation
@testable import TelegramBot
import NativeAgentCore
import PersistenceCore

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
