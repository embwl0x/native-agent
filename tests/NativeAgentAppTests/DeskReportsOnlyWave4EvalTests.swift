import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

// Wave 4 closes only rendered claims that cross a real action/store or a
// producer-backed record boundary. It deliberately does not treat source-text
// presence as control coverage.

private func wave4Root(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeskReportsOnlyWave4-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("Desk reports-only wave 4 behavior", .serialized)
struct DeskReportsOnlyWave4EvalTests {
    @Test("a scheduled proactive digest forwards groups into its durable inbox card and Review Groups filters InboxView's list")
    func proactiveDigestGroupsSurviveSurfaceToInboxToDetailAndListFilter() async throws {
        let root = try wave4Root("digest-groups")
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = SwiftNativePersistenceCore()
        let inboxPath = root
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        for id in ["actionable-a", "actionable-b"] {
            try await persistence.appendJSONL(.object([
                "id": .string(id),
                "source": .string("heartbeat"),
                "severity": .string("actionable"),
                "title": .string("Needs attention \(id)"),
                "status": .string("unread"),
                "actions": .array([]),
            ]), to: inboxPath)
        }

        let runner = SchedulerDueJobRunner(root: root)
        let result = try await runner.surfaceProactiveScan(job: .init(
            id: "proactive-scan",
            name: "Proactive scan",
            kind: "proactive_scan",
            payload: ["limit": .int(10), "surfaceLimit": .int(4)],
            row: .object([:]),
            dueEpoch: 1_800_000_000
        ))
        let digestID = try #require(result.itemIds.first)
        #expect(result.itemIds.count >= 1)

        // Read the JSONL surface produced by `surfaceProactiveScan(job:)`, not
        // a manually assembled notification row. Removing its relatedGroups
        // argument therefore makes this proof fail.
        let rows = try await persistence.readJSONL(inboxPath)
        let cards = try rows.map { row in
            try JSONDecoder().decode(InboxItemRecord.self, from: Data(try row.serialize(pretty: false).utf8))
        }
        let card = try #require(cards.first { $0.id == digestID })
        let group = try #require(card.related_groups?.first)
        #expect(group.itemIDs == ["actionable-a", "actionable-b"])
        #expect(group.displayCount == 2)

        // This selection helper is called by InboxView's actual Review Groups
        // callback, and the same helper supplies its rendered list items.
        let selected = InboxReviewGroupSelection.select(group)
        let filtered = InboxReviewGroupSelection.displayItems(
            items: cards,
            lane: .system,
            showAll: false,
            groupFilter: selected
        )
        #expect(Set(filtered.map(\.id)) == Set(["actionable-a", "actionable-b"]))
    }

    @Test("legacy inbox-digest prose from JSONL projects groups while unrelated cards do not")
    func legacyInboxDigestProseProjectsOnlyDigestCards() async throws {
        let root = try wave4Root("legacy-digest-groups")
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = SwiftNativePersistenceCore()
        let inboxPath = root
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        for row: JSONValue in [
            .object([
                "id": .string("legacy-digest"),
                "source": .string("autonomy_maintenance:inbox_digest"),
                "title": .string("Inbox digest"),
                "detail": .string("Top groups:\n- Reconcile account (2)\n"),
                "status": .string("unread"),
            ]),
            .object([
                "id": .string("legacy-a"),
                "source": .string("heartbeat"),
                "title": .string("Reconcile account"),
                "status": .string("unread"),
            ]),
            .object([
                "id": .string("legacy-b"),
                "source": .string("heartbeat"),
                "title": .string("Reconcile account"),
                "status": .string("unread"),
            ]),
            .object([
                "id": .string("unrelated"),
                "source": .string("heartbeat"),
                "title": .string("Not a digest"),
                "detail": .string("Top groups:\n- Reconcile account (2)\n"),
                "status": .string("unread"),
            ]),
        ] {
            try await persistence.appendJSONL(row, to: inboxPath)
        }
        let rows = try await persistence.readJSONL(inboxPath)
        let cards = try rows.map { row in
            try JSONDecoder().decode(InboxItemRecord.self, from: Data(try row.serialize(pretty: false).utf8))
        }
        let legacyDigest = try #require(cards.first { $0.id == "legacy-digest" })
        let groups = InboxDetailGroupProjection.groups(item: legacyDigest, allItems: cards)
        let group = try #require(groups.first)
        #expect(group.itemIDs == ["legacy-a", "legacy-b"])
        #expect(group.displayCount == 2)

        let unrelated = try #require(cards.first { $0.id == "unrelated" })
        #expect(InboxDetailGroupProjection.groups(item: unrelated, allItems: cards).isEmpty)
    }

}
