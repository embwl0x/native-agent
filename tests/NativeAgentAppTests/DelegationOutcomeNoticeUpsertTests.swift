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
//   • legacy unread successful per-job rows are archived in one reconciliation
//     while handled history and attention-worthy rows remain untouched;
//   • a CHANGED adverse outcome (finished → unconfirmed) lands as a fresh
//     unread exact-job row beside the informational success rollup;
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

private func codexJob(id: String = "cx-1", undelivered: Bool) -> DelegationJobSnapshot {
    DelegationJobSnapshot(
        id: id, source: "codex", agent: "codex", topicSlug: "mac-chat-658-16",
        state: "watching_turn", runStatus: "completed", completedAt: "2026-08-20T11:22:44.000Z",
        deliveryOutcome: undelivered ? "unknown" : nil,
        completionTextHead: "658.16 is complete.")
}

@Suite("DelegationOutcome inbox upsert")
struct DelegationOutcomeNoticeUpsertTests {
    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    @Test("successful jobs share one bounded informational rollup per source")
    func successfulJobsRollUpWithoutHidingAdverseOutcomes() async throws {
        let root = try tmpDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try #require(DelegationOutcomeCard.make(
            from: codexJob(id: "cx-1", undelivered: false), now: now
        ))
        let second = try #require(DelegationOutcomeCard.make(
            from: codexJob(id: "cx-2", undelivered: false), now: now.addingTimeInterval(1)
        ))

        #expect(await BackgroundLoopsAssembly.fileDelegationOutcomeNotice(dataRoot: root, card: first))
        #expect(await BackgroundLoopsAssembly.fileDelegationOutcomeNotice(dataRoot: root, card: second))

        var rows = try inboxRows(root)
        #expect(rows.count == 1)
        #expect(rows[0]["id"] == .string("delegation-outcome:codex:successful-rollup"))
        #expect(rows[0]["informational_rollup_key"] == .string("delegation_outcome.successful.codex"))
        #expect(rows[0]["occurrence_count"] == .int(2))

        let worsened = try #require(DelegationOutcomeCard.make(
            from: codexJob(id: "cx-2", undelivered: true), now: now.addingTimeInterval(2)
        ))
        #expect(await BackgroundLoopsAssembly.fileDelegationOutcomeNotice(dataRoot: root, card: worsened))
        rows = try inboxRows(root)
        #expect(rows.count == 2)
        #expect(rows.contains { $0["id"] == .string(worsened.cardId)
            && $0["severity"] == .string("actionable") })
    }

    @Test("legacy unread success cards retire without hiding attention or handled history")
    func legacySuccessReconciliationIsNarrowAndIdempotent() async throws {
        let root = try tmpDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("notifications/inbox.jsonl")
        let rows = [
            #"{"id":"delegation-outcome:codex:old-1","source":"delegation_outcome","severity":"info","title":"Codex finished","error_signature":"codex:old-1","status":"unread","read_at":null}"#,
            #"{"id":"delegation-outcome:claude:old-2","source":"delegation_outcome","severity":"info","title":"Claude finished","error_signature":"claude:old-2:succeeded","status":"read","read_at":"2026-08-20T12:00:00Z"}"#,
            #"{"id":"delegation-outcome:codex:bad-1","source":"delegation_outcome","severity":"actionable","title":"Codex outcome is unconfirmed","error_signature":"codex:bad-1:unknown","status":"unread","read_at":null}"#,
            #"{"id":"delegation-outcome:codex:undelivered-backlog","source":"delegation_outcome","severity":"info","title":"Codex: 21 undelivered replies preserved","error_signature":"codex-undelivered-backlog:21","status":"unread","read_at":null}"#,
            #"{"id":"delegation-outcome:codex:successful-rollup","source":"delegation_outcome","severity":"info","title":"Codex finished","error_signature":"delegation_outcome.successful.codex","informational_rollup_key":"delegation_outcome.successful.codex","status":"unread","read_at":null}"#,
        ]
        try Data((rows.joined(separator: "\n") + "\n").utf8).write(to: path)

        let migratedAt = Date(timeIntervalSince1970: 1_787_000_000)
        #expect(try await BackgroundLoopsAssembly.reconcileLegacySuccessfulDelegationNotices(
            dataRoot: root, now: migratedAt
        ) == 1)
        #expect(try await BackgroundLoopsAssembly.reconcileLegacySuccessfulDelegationNotices(
            dataRoot: root, now: migratedAt
        ) == 0)

        let reconciled = try inboxRows(root)
        let legacyUnread = try #require(reconciled.first {
            $0["id"] == .string("delegation-outcome:codex:old-1")
        })
        #expect(legacyUnread["status"] == .string("archived"))
        #expect(legacyUnread["read_at"] == .string(DelegationOutcomeCursor.formatISO(migratedAt)))
        #expect(reconciled.first {
            $0["id"] == .string("delegation-outcome:claude:old-2")
        }?["status"] == .string("read"))
        #expect(reconciled.first {
            $0["id"] == .string("delegation-outcome:codex:bad-1")
        }?["status"] == .string("unread"))
        #expect(reconciled.first {
            $0["id"] == .string("delegation-outcome:codex:undelivered-backlog")
        }?["status"] == .string("unread"))
        #expect(reconciled.first {
            $0["id"] == .string("delegation-outcome:codex:successful-rollup")
        }?["status"] == .string("unread"))
    }

    @Test("a bound terminal job writes one truthful Desk settlement receipt")
    func boundJobSettlesDeskExactlyOnce() async throws {
        let root = try tmpDataRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SwiftNativeDeskStore(dataRoot: root)
        let item = try await store.createItem(kind: .plan, project: "Agent", title: "delegated work")
        var job = codexJob(id: "cx-bound", undelivered: false)
        job.deskHandle = item.handle

        #expect(await BackgroundLoopsAssembly.recordBoundDelegationSettlement(dataRoot: root, job: job))
        #expect(await BackgroundLoopsAssembly.recordBoundDelegationSettlement(dataRoot: root, job: job))

        let row = try #require(try await store.liveState().items.first { $0.handle == item.handle })
        let receipts = row.notes.filter { $0.text.hasPrefix("delegation-settlement:codex:cx-bound") }
        #expect(receipts.count == 1)
        #expect(receipts[0].text.contains("Execution/delivery evidence only"))
        #expect(row.status == .watch)
    }

    @Test("a legacy successful per-job row stays read when the new rollup lands")
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
        #expect(rows.count == 2)
        let legacyRow = try #require(rows.first { $0["id"] == .string(card.cardId) })
        #expect(legacyRow["status"] == .string("read"))
        #expect(legacyRow["error_signature"] == .string(card.jobKey))
        #expect(rows.contains {
            $0["id"] == .string("delegation-outcome:codex:successful-rollup")
                && $0["occurrence_count"] == .int(1)
        })
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

    @Test("an adverse outcome lands as a fresh exact-job row beside the success rollup")
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

        // … then the bridge preserved the reply: the adverse event gets exact
        // job identity and must not be hidden inside the success rollup.
        let preserved = try #require(DelegationOutcomeCard.make(from: codexJob(undelivered: true), now: now))
        #expect(await BackgroundLoopsAssembly.fileDelegationOutcomeNotice(dataRoot: root, card: preserved))
        rows = try inboxRows(root)
        #expect(rows.count == 2)
        var adverse = try #require(rows.first { $0["id"] == .string(finished.cardId) })
        #expect(adverse["status"] == .string("unread"))
        #expect(adverse["severity"] == .string("actionable"))
        #expect(adverse["title"] == .string("Codex outcome is unconfirmed"))
        #expect(adverse["error_signature"] == .string("codex:cx-1:unknown"))

        // Same outcome again (a retried upsert) after the user read it: sticky.
        adverse["status"] = .string("read")
        let rewritten = rows.map { row in
            row["id"] == .string(finished.cardId) ? adverse : row
        }
        let encoded = try rewritten.map {
            try JSONValue.object($0).serialize(pretty: false)
        }.joined(separator: "\n") + "\n"
        try Data(encoded.utf8)
            .write(to: root.appendingPathComponent("notifications/inbox.jsonl"))
        #expect(await BackgroundLoopsAssembly.fileDelegationOutcomeNotice(dataRoot: root, card: preserved))
        rows = try inboxRows(root)
        #expect(rows.count == 2)
        let retried = try #require(rows.first { $0["id"] == .string(finished.cardId) })
        #expect(retried["status"] == .string("read"))
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
