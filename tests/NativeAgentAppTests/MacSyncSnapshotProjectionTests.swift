import Foundation
import NativeAgentShared
import PersistenceCore
import Testing
@testable import NativeAgentApp

private struct SnapshotThreadProbe: Encodable, Sendable {
    func encode(to encoder: Encoder) throws {
        #expect(!Thread.isMainThread)
        var container = encoder.singleValueContainer()
        try container.encode("background")
    }
}

@Test("the engine's normal snapshot encoder leaves the main actor")
@MainActor
func macSyncSnapshotEncodingRunsOffMainThread() async throws {
    let engine = MacSyncEngine(stateDataRootOverride: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let bytes = try await engine.encodeSnapshot(SnapshotThreadProbe())
    #expect(bytes == Data("\"background\"".utf8))
}

@Test("background inbox projection and activity envelope preserve exact bytes")
@MainActor
func macSyncBackgroundSnapshotGroupPreservesBytes() async throws {
    let rows = (0..<320).map { index in
        ["id": "row-\(index)", "created_at": "2026-09-10T12:00:00Z",
         "source": "test", "severity": "info", "title": "Snapshot \(index)",
         "summary": String(repeating: "snapshot 🧭 ", count: 400),
         "status": index < 20 ? "unread" : "read"]
    }
    let items = try JSONDecoder().decode(
        [InboxItemRecord].self, from: JSONSerialization.data(withJSONObject: rows)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = .sortedKeys
    let before = try MobileInboxProjection.data(from: items, encoder: encoder, alreadyNewestFirst: true)
    #expect(before.included < MobileInboxProjection.maximumRows)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let engine = MacSyncEngine(stateDataRootOverride: directory)
    let after = await engine.buildInboxSnapshot(items)
    #expect(after.data == before.data)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var files = Dictionary(uniqueKeysWithValues: NAMobileSnapshotGroup.activity.filenames.map {
        ($0, Data("[]".utf8))
    })
    files["inbox.json"] = try #require(after.data)
    for (filename, data) in files { try data.write(to: directory.appendingPathComponent(filename)) }
    let expected = try NAMobileSnapshotStatusCodec.encode(group: .activity, files: files)
    let actual = try await MobileSnapshotBuilder.shared.status(group: .activity, directory: directory)
    #expect(actual == expected)
    #expect(try NAMobileSnapshotStatusCodec.decode(#require(actual), expectedGroup: .activity) == files)
}

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
