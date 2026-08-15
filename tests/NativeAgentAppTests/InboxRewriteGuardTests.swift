import Foundation
import Testing
import PersistenceCore
@testable import NativeAgentApp

// MARK: - Inbox whole-file rewrite guard
//
// The notifications/inbox.jsonl upserts (heartbeat notice, disk-hygiene card,
// background-loop failure card, stale-card retirement) read the whole file and
// rewrite it in place. The read used to be LOSSY (`tailJSONL` compactMap'd
// away unparseable lines), so one malformed row among valid rows was silently
// dropped on rewrite. `InboxRewriteGuard.readLines` now returns every physical
// line with its original bytes, and rewrite sites carry undecodable lines
// through verbatim. The guard still distinguishes "the file is genuinely
// empty" (first append must work) from "the read lost everything".

private func tmpInbox() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("inbox-guard-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("inbox.jsonl")
}

/// Physical lines of the file as raw bytes (trailing empty split dropped).
private func physicalLines(of path: URL) throws -> [Data] {
    let slices: [Data] = try Data(contentsOf: path)
        .split(separator: 0x0A, omittingEmptySubsequences: false)
    var parts = slices.map { Data($0) }
    if parts.last?.isEmpty == true { parts.removeLast() }
    return parts
}

@Suite("Inbox whole-file rewrite guard")
struct InboxRewriteGuardTests {
    @Test("a missing inbox still accepts the very first card")
    func missingFileAllowsFirstAppend() throws {
        let path = try tmpInbox()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        #expect(try InboxRewriteGuard.readLines(path).isEmpty)
        #expect(InboxRewriteGuard.rewriteIsSafe(lines: [], path: path))
    }

    @Test("a legitimately empty inbox still accepts the very first card")
    func emptyFileAllowsFirstAppend() throws {
        let path = try tmpInbox()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try Data().write(to: path)
        #expect(try InboxRewriteGuard.readLines(path).isEmpty)
        #expect(InboxRewriteGuard.rewriteIsSafe(lines: [], path: path))
    }

    @Test("zero lines for a non-empty file must not be rewritten")
    func zeroLinesOfNonEmptyFileIsRefused() throws {
        // `readLines` cannot produce this state (a non-empty file always
        // yields at least one line) — the guard pins the invariant so a
        // future lossy read swap still refuses instead of wiping cards.
        let path = try tmpInbox()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        try Data("{\"id\":\"a\"}\n".utf8).write(to: path)
        #expect(!InboxRewriteGuard.rewriteIsSafe(lines: [], path: path))
    }

    @Test("a torn inbox reads back every physical line, bytes intact")
    func tornFileReadsAllLinesRaw() throws {
        let path = try tmpInbox()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        // Non-UTF8 bytes plus a truncated record: nothing parses, but every
        // byte must come back.
        let junk = Data([0xFF, 0xFE, 0xFF])
        let torn = Data("{\"id\":\"heartbeat-doctor\",\"status\":\"unr".utf8)
        try (junk + Data("\n".utf8) + torn).write(to: path)

        let lines = try InboxRewriteGuard.readLines(path)
        #expect(lines.count == 2)
        #expect(lines[0].raw == junk)
        #expect(lines[0].row == nil)
        #expect(lines[1].raw == torn)
        #expect(lines[1].row == nil)
        #expect(InboxRewriteGuard.rewriteIsSafe(lines: lines, path: path))
    }

    @Test("readLines → writeLines round-trips a newline-terminated file byte-identically")
    func roundTripIsByteIdentical() throws {
        let path = try tmpInbox()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        var original = Data("{\"id\":\"a\"}\n".utf8)
        original.append(Data([0xC0, 0xC1, 0x7B]))  // invalid UTF-8 garbage line
        original.append(Data("\n\n{\"id\":\"b\",\"status\":\"unread\"}\n".utf8))
        try original.write(to: path)

        let lines = try InboxRewriteGuard.readLines(path)
        try InboxRewriteGuard.writeLines(lines.map(\.raw), to: path)
        #expect(try Data(contentsOf: path) == original)
    }

    // The regression the guard rewrite exists for: a SINGLE malformed row
    // among valid rows used to be silently dropped by any card upsert.
    @Test("a real card upsert carries a malformed row through byte-identical")
    func upsertPreservesMalformedRow() async throws {
        let dataRoot = try tmpInbox().deletingLastPathComponent()
        let inboxPath = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        try FileManager.default.createDirectory(
            at: inboxPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        let valid1 = Data("{\"id\":\"card-one\",\"status\":\"unread\"}".utf8)
        // Truncated JSON with an embedded non-UTF8 byte: unparseable, and a
        // String round-trip would corrupt it — only verbatim bytes survive.
        let malformed = Data("{\"id\":\"card-torn\",\"summ".utf8) + Data([0xFF, 0x80])
        let valid2 = Data("{\"id\":\"card-two\",\"status\":\"read\"}".utf8)
        let nl = Data("\n".utf8)
        try (valid1 + nl + malformed + nl + valid2 + nl).write(to: inboxPath)

        await BackgroundLoopsManager.fileLoopFailureNotice(
            dataRoot: dataRoot, loopId: "unit-test-loop", error: "boom")

        let after = try physicalLines(of: inboxPath)
        #expect(after.count == 4)
        #expect(after[0] == valid1)
        #expect(after[1] == malformed)  // byte-identical survival
        #expect(after[2] == valid2)
        let appended = try JSONValue.parse(after[3])
        guard case .object(let obj) = appended,
              case .string(let id)? = obj["id"] else {
            Issue.record("appended card is not an object with an id")
            return
        }
        #expect(id == "loop-failure:unit-test-loop")
    }

    @Test("upsert replacing an existing card still preserves the malformed row")
    func upsertReplacePreservesMalformedRow() async throws {
        let dataRoot = try tmpInbox().deletingLastPathComponent()
        let inboxPath = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        try FileManager.default.createDirectory(
            at: inboxPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        let stale = Data(
            "{\"id\":\"loop-failure:unit-test-loop\",\"status\":\"read\"}".utf8)
        let malformed = Data([0x00, 0x00]) + Data("not json".utf8)
        let valid = Data("{\"id\":\"card-two\",\"status\":\"unread\"}".utf8)
        let nl = Data("\n".utf8)
        try (stale + nl + malformed + nl + valid + nl).write(to: inboxPath)

        await BackgroundLoopsManager.fileLoopFailureNotice(
            dataRoot: dataRoot, loopId: "unit-test-loop", error: "boom again")

        let after = try physicalLines(of: inboxPath)
        #expect(after.count == 3)  // replaced in place, nothing appended
        let replaced = try JSONValue.parse(after[0])
        guard case .object(let obj) = replaced,
              case .string(let id)? = obj["id"],
              case .string(let detail)? = obj["detail"] else {
            Issue.record("replaced card is not the loop-failure card")
            return
        }
        #expect(id == "loop-failure:unit-test-loop")
        #expect(detail.contains("boom again"))
        #expect(after[1] == malformed)
        #expect(after[2] == valid)
    }

    @Test("the user-facing status write preserves a malformed row")
    func statusWritePreservesMalformedRow() async throws {
        let path = try tmpInbox()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        let valid1 = Data("{\"id\":\"card-one\",\"status\":\"unread\"}".utf8)
        let malformed = Data("{\"id\":\"card-torn\",\"stat".utf8) + Data([0xFE, 0xFF])
        let valid2 = Data("{\"id\":\"card-two\",\"status\":\"unread\"}".utf8)
        let nl = Data("\n".utf8)
        try (valid1 + nl + malformed + nl + valid2 + nl).write(to: path)

        let updated = await NativeClient.updateVisibleNotificationInboxStatus(
            id: "card-two", action: "dismiss", inboxPath: path)
        #expect(updated)

        let after = try physicalLines(of: path)
        #expect(after.count == 3)
        #expect(after[0] == valid1)  // untouched rows keep their exact bytes
        #expect(after[1] == malformed)  // byte-identical survival
        let dismissed = try JSONValue.parse(after[2])
        guard case .object(let obj) = dismissed,
              case .string(let status)? = obj["status"] else {
            Issue.record("dismissed card is not an object with a status")
            return
        }
        #expect(status == "dismissed")
    }

    @Test("dream-card archival preserves a malformed row and untouched bytes")
    func dreamArchivalPreservesMalformedRow() async throws {
        let dataRoot = try tmpInbox().deletingLastPathComponent()
        let inboxPath = dataRoot
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        try FileManager.default.createDirectory(
            at: inboxPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataRoot) }

        let oldDream = Data(
            "{\"id\":\"dream-old\",\"source\":\"dream_cycle\",\"status\":\"unread\"}".utf8)
        let malformed = Data("{\"id\":\"dream-t".utf8) + Data([0x80, 0xFF])
        let other = Data("{\"id\":\"card-other\",\"source\":\"heartbeat\",\"status\":\"unread\"}".utf8)
        let keptDream = Data(
            "{\"id\":\"dream-new\",\"source\":\"dream_cycle\",\"status\":\"unread\"}".utf8)
        let nl = Data("\n".utf8)
        try (oldDream + nl + malformed + nl + other + nl + keptDream + nl).write(to: inboxPath)

        let runner = SchedulerDueJobRunner(root: dataRoot)
        let archived = try await runner.archiveOlderDreamInboxItems(keeping: "dream-new")
        #expect(archived == 1)

        let after = try physicalLines(of: inboxPath)
        #expect(after.count == 4)
        let archivedRow = try JSONValue.parse(after[0])
        guard case .object(let obj) = archivedRow,
              case .string(let status)? = obj["status"] else {
            Issue.record("archived dream row is not an object with a status")
            return
        }
        #expect(status == "archived")
        #expect(after[1] == malformed)  // byte-identical survival
        #expect(after[2] == other)      // untouched rows keep their exact bytes
        #expect(after[3] == keptDream)
    }
}
