import Foundation
import Testing
import PersistenceCore
@testable import NativeAgentApp

// MARK: - Inbox whole-file rewrite guard
//
// The three notifications/inbox.jsonl upserts (heartbeat notice, disk-hygiene
// card, background-loop failure card) read the whole file with `tailJSONL` and
// rewrite it in place. That read is LOSSY: unparseable lines are dropped and
// non-UTF8 bytes decode with replacement, so a torn file reads as `[]` and the
// rewrite wipes every pending card. The guard has to distinguish "the file is
// genuinely empty" (first append must still work) from "the read lost rows".

private func tmpInbox() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("inbox-guard-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("inbox.jsonl")
}

@Suite("Inbox whole-file rewrite guard")
struct InboxRewriteGuardTests {
    @Test("a missing inbox still accepts the very first card")
    func missingFileAllowsFirstAppend() throws {
        let path = try tmpInbox()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        #expect(InboxRewriteGuard.rewriteIsSafe(rows: [], path: path))
    }

    @Test("a legitimately empty inbox still accepts the very first card")
    func emptyFileAllowsFirstAppend() throws {
        let path = try tmpInbox()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try Data().write(to: path)
        #expect(InboxRewriteGuard.rewriteIsSafe(rows: [], path: path))
    }

    @Test("a torn inbox that reads as zero rows must not be rewritten")
    func lossyReadOfNonEmptyFileIsRefused() async throws {
        let path = try tmpInbox()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        // Non-UTF8 bytes plus a truncated record: real cards are on disk, but
        // `tailJSONL` parses none of them.
        var torn = Data([0xFF, 0xFE, 0xFF])
        torn.append(Data("\n{\"id\":\"heartbeat-doctor\",\"status\":\"unr".utf8))
        try torn.write(to: path)

        let rows = try await SwiftNativePersistenceCore()
            .tailJSONL(path, limit: Int.max, maxBytes: nil)
        #expect(rows.isEmpty)  // the lossy read that used to drive the rewrite
        #expect(!InboxRewriteGuard.rewriteIsSafe(rows: rows, path: path))
    }

    @Test("rows that did read back are always safe to rewrite")
    func nonEmptyRowsAreSafe() throws {
        let path = try tmpInbox()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try Data("{\"id\":\"a\"}\n".utf8).write(to: path)
        #expect(InboxRewriteGuard.rewriteIsSafe(
            rows: [.object(["id": .string("a")])], path: path
        ))
    }
}
