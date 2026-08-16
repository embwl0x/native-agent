import Foundation
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
