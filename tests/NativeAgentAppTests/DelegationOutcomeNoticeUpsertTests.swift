import Foundation
import Testing
import BackgroundLoops
import PersistenceCore
@testable import NativeAgentApp

// MARK: - DelegationOutcomeLoop → notifications/inbox.jsonl upsert contract
//
// `fileDelegationOutcomeNotice` is the PRODUCTION write path behind the
// loop's `fileCard` closure. The core tests pin what the loop decides; this
// pins what actually lands on disk (gpt-5.5 review 2026-08-21, LOW):
//
//   • a legacy row whose `error_signature` is the bare job key counts as the
//     SAME outcome — a retried upsert keeps the user's read/archived status;
//   • a CHANGED outcome signature (finished → unconfirmed) replaces the row
//     as a fresh unread one with the new title/severity;
//   • the same outcome re-upserted keeps a non-unread status;
//   • the backlog-cleared card lands already read.
//
// The temp data root is never the live app root, so InboxPushNotifier's
// `usesLiveAppDataRoot` gate keeps every push out of these tests.

private func tmpDataRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("delegation-upsert-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: dir.appendingPathComponent("notifications", isDirectory: true),
        withIntermediateDirectories: true)
    return dir
}

private func inboxRows(_ root: URL) throws -> [[String: JSONValue]] {
    let path = root.appendingPathComponent("notifications/inbox.jsonl")
    guard let data = try? Data(contentsOf: path) else { return [] }
    return data.split(separator: 0x0A).compactMap { line in
        guard let parsed = try? JSONValue.parse(Data(line)), case .object(let obj) = parsed else { return nil }
        return obj
    }
}

private func codexJob(undelivered: Bool) -> DelegationJobSnapshot {
    DelegationJobSnapshot(
        id: "cx-1", source: "codex", agent: "codex", topicSlug: "mac-chat-658-16",
        state: "watching_turn", runStatus: "completed", completedAt: "2026-08-20T11:22:44.000Z",
        deliveryOutcome: undelivered ? "unknown" : nil,
        completionTextHead: "658.16 is complete.")
}

@Suite("DelegationOutcome inbox upsert")
struct DelegationOutcomeNoticeUpsertTests {
    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    @Test("a legacy bare-jobKey row keeps its read status on a same-outcome retry")
    func legacySignatureKeepsStatus() async throws {
        let root = try tmpDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let card = try #require(DelegationOutcomeCard.make(from: codexJob(undelivered: false), now: now))
        // Seed a pre-outcome-signature row the user already read.
        let legacy = """
        {"id":"\(card.cardId)","source":"delegation_outcome","severity":"info","title":"Codex finished","error_signature":"\(card.jobKey)","status":"read","read_at":"2026-08-20T12:00:00Z"}
        """
        try Data((legacy + "\n").utf8).write(to: root.appendingPathComponent("notifications/inbox.jsonl"))

        #expect(await BackgroundLoopsAssembly.fileDelegationOutcomeNotice(dataRoot: root, card: card))
        let rows = try inboxRows(root)
        #expect(rows.count == 1)
        #expect(rows[0]["status"] == .string("read"))
        #expect(rows[0]["error_signature"] == .string(card.signature))
    }

    @Test("a legacy bare-jobKey 'finished' row met by an unconfirmed upsert resurfaces unread")
    func legacyRowUpgradesWhenOutcomeWorsens() async throws {
        let root = try tmpDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let preserved = try #require(DelegationOutcomeCard.make(from: codexJob(undelivered: true), now: now))
        // Legacy "Codex finished" info row the user had dismissed.
        let legacy = """
        {"id":"\(preserved.cardId)","source":"delegation_outcome","severity":"info","title":"Codex finished","error_signature":"\(preserved.jobKey)","status":"dismissed","read_at":"2026-08-20T12:00:00Z"}
        """
        try Data((legacy + "\n").utf8).write(to: root.appendingPathComponent("notifications/inbox.jsonl"))
        #expect(await BackgroundLoopsAssembly.fileDelegationOutcomeNotice(dataRoot: root, card: preserved))
        let rows = try inboxRows(root)
        #expect(rows.count == 1)
        #expect(rows[0]["status"] == .string("unread"))
        #expect(rows[0]["severity"] == .string("actionable"))
        #expect(rows[0]["title"] == .string("Codex outcome is unconfirmed"))
        #expect(rows[0]["error_signature"] == .string(preserved.signature))
    }

    @Test("a changed outcome lands as a fresh unread row with the new title and severity")
    func changedOutcomeResetsToUnread() async throws {
        let root = try tmpDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let finished = try #require(DelegationOutcomeCard.make(from: codexJob(undelivered: false), now: now))
        #expect(await BackgroundLoopsAssembly.fileDelegationOutcomeNotice(dataRoot: root, card: finished))
        // The user dismissed the "finished" card …
        var rows = try inboxRows(root)
        #expect(rows.count == 1)
        var dismissed = rows[0]
        dismissed["status"] = .string("dismissed")
        try Data((try JSONValue.object(dismissed).serialize(pretty: false) + "\n").utf8)
            .write(to: root.appendingPathComponent("notifications/inbox.jsonl"))

        // … then the bridge preserved the reply: the same card id upgrades.
        let preserved = try #require(DelegationOutcomeCard.make(from: codexJob(undelivered: true), now: now))
        #expect(await BackgroundLoopsAssembly.fileDelegationOutcomeNotice(dataRoot: root, card: preserved))
        rows = try inboxRows(root)
        #expect(rows.count == 1)
        #expect(rows[0]["id"] == .string(finished.cardId))
        #expect(rows[0]["status"] == .string("unread"))
        #expect(rows[0]["severity"] == .string("actionable"))
        #expect(rows[0]["title"] == .string("Codex outcome is unconfirmed"))
        #expect(rows[0]["error_signature"] == .string("codex:cx-1:unknown"))

        // Same outcome again (a retried upsert) after the user read it: sticky.
        var read = rows[0]
        read["status"] = .string("read")
        try Data((try JSONValue.object(read).serialize(pretty: false) + "\n").utf8)
            .write(to: root.appendingPathComponent("notifications/inbox.jsonl"))
        #expect(await BackgroundLoopsAssembly.fileDelegationOutcomeNotice(dataRoot: root, card: preserved))
        rows = try inboxRows(root)
        #expect(rows.count == 1)
        #expect(rows[0]["status"] == .string("read"))
    }

    @Test("the backlog-cleared card lands already read and replaces the backlog card")
    func clearedCardLandsRead() async throws {
        let root = try tmpDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let backlog = try #require(DelegationOutcomeCard.makeBacklog(jobs: [codexJob(undelivered: true)], now: now))
        #expect(await BackgroundLoopsAssembly.fileDelegationOutcomeNotice(dataRoot: root, card: backlog))
        var rows = try inboxRows(root)
        #expect(rows.count == 1)
        #expect(rows[0]["status"] == .string("unread"))
        #expect(rows[0]["severity"] == .string("info"))

        let cleared = DelegationOutcomeCard.makeBacklogCleared(now: now)
        #expect(await BackgroundLoopsAssembly.fileDelegationOutcomeNotice(dataRoot: root, card: cleared))
        rows = try inboxRows(root)
        #expect(rows.count == 1)
        #expect(rows[0]["id"] == .string(DelegationOutcomeCard.codexBacklogCardId))
        #expect(rows[0]["status"] == .string("read"))
        #expect(rows[0]["title"] == .string("Codex undelivered backlog is clear"))
    }
}
