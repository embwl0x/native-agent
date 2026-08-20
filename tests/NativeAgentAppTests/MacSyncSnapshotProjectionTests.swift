import Foundation
import NativeAgentShared
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Test("mobile inbox projection is bounded and keeps active rows ahead of history")
func mobileInboxProjectionIsBounded() throws {
    var rows: [[String: Any]] = []
    for index in 0..<420 {
        rows.append([
            "id": "item-\(index)",
            "created_at": String(format: "2026-08-16T10:%02d:00Z", index % 60),
            "source": "test",
            "severity": "info",
            "title": "Item \(index)",
            "summary": String(repeating: "x", count: 2_000),
            "actions": [],
            "status": index < 25 ? "unread" : "read",
        ])
    }
    let data = try JSONSerialization.data(withJSONObject: rows)
    let items = try JSONDecoder().decode([InboxItemRecord].self, from: data)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys

    let projection = try MobileInboxProjection.data(from: items, encoder: encoder)
    let decoded = try JSONDecoder().decode([InboxItemRecord].self, from: projection.data)

    #expect(projection.data.count <= MobileInboxProjection.maximumEncodedBytes)
    #expect(decoded.count <= MobileInboxProjection.maximumRows)
    #expect(Set(decoded.filter(\.isUnread).map(\.id)) == Set(items.filter(\.isUnread).map(\.id)))
    #expect(decoded.count < items.count)
}

@Test("mobile Desk projection is bounded, prioritizes live work, and clips note history")
func mobileDeskProjectionIsBounded() throws {
    let rows = (0..<340).map { index in
        DeskItem(
            handle: "desk_\(index)",
            alias: "\(index + 1)",
            kind: .plan,
            status: index < 20 ? .now : .done,
            project: "NativeAgent",
            title: "Item \(index)",
            notes: (0..<10).map {
                DeskNote(ts: "2026-08-19T00:00:\($0)Z", text: String(repeating: "🧭", count: 800))
            },
            openedAt: "2026-08-19T00:00:00Z",
            updatedAt: String(format: "2026-08-19T00:%02d:00Z", index % 60)
        )
    }

    let projection = try MobileDeskProjection.data(from: rows, encoder: JSONEncoder())
    let projected = try JSONDecoder().decode([MobileDeskItem].self, from: projection.data)

    #expect(projection.data.count <= MobileDeskProjection.maximumEncodedBytes)
    #expect(projected.count <= MobileDeskProjection.maximumRows)
    #expect(projected.prefix(20).allSatisfy { $0.status == "now" })
    #expect(projected.allSatisfy { $0.recentNotes.count <= MobileDeskProjection.maximumNotesPerItem })
    #expect(projected.first?.handle.hasPrefix("desk_") == true)
}
