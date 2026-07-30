import Testing
import Foundation
@testable import SelfImprovement
import NativeAgentCore
import PersistenceCore

// MARK: - U5 W-G (2026-06-11): pending_actions.json expiry

@Suite("PendingActionsExpiry")
struct PendingActionsExpiryTests {
    private func makeDataRoot() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("si-expiry-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url.appendingPathComponent("improvements", isDirectory: true),
            withIntermediateDirectories: true
        )
        // listPending() is gated on selfImprovementAvailable() — a bare .git
        // directory satisfies the existence check without a real repo.
        try? FileManager.default.createDirectory(
            at: url.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        return url
    }

    private func seedPendingActions(_ root: URL, entries: [[String: Any]]) throws {
        let path = root.appendingPathComponent("improvements/pending_actions.json")
        let data = try JSONSerialization.data(withJSONObject: entries)
        try data.write(to: path)
    }

    /// Entries past the 14-day retention window (any status — non-terminal
    /// "pending"/"staged" included) must be swept from the queue on
    /// rehydrate; fresh entries and undateable entries survive.
    @Test func rehydrate_expiresStaleEntries_keepsFreshAndUndateable() async throws {
        let dataRoot = makeDataRoot()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let fmt = ISO8601DateFormatter()
        let oldDate = fmt.string(from: Date().addingTimeInterval(-20 * 86_400))
        let freshDate = fmt.string(from: Date().addingTimeInterval(-3_600))
        try seedPendingActions(dataRoot, entries: [
            ["id": "imp_old_pending", "status": "pending", "createdAt": oldDate],
            ["id": "imp_old_staged", "status": "staged", "createdAt": oldDate],
            ["id": "imp_fresh", "status": "pending", "createdAt": freshDate],
            ["id": "imp_undateable", "status": "pending"],
        ])

        let orch = SelfImprovementOrchestrator(
            dataRoot: dataRoot,
            repoRoot: dataRoot,
            packagePath: nil
        )
        let actions = try await orch.listPending()
        let ids = Set(actions.map(\.id))
        #expect(!ids.contains("imp_old_pending"), "20-day-old pending entry must expire")
        #expect(!ids.contains("imp_old_staged"), "20-day-old staged entry must expire")
        #expect(ids.contains("imp_fresh"), "fresh entry must survive")
        #expect(ids.contains("imp_undateable"), "undateable entry must be kept, not guessed away")

        // The pruned set must be persisted back to disk.
        let path = dataRoot.appendingPathComponent("improvements/pending_actions.json")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [[String: Any]]
        let diskIds = Set((raw ?? []).compactMap { $0["id"] as? String })
        #expect(diskIds == ["imp_fresh", "imp_undateable"],
                "expiry must rewrite pending_actions.json; got \(diskIds)")
    }

    /// U5 fix-round (2026-06-11, gpt-5.5 review): corrupt-preserve. An
    /// undecodable entry (corrupt row / future-schema row) must SURVIVE an
    /// expiry rewrite of pending_actions.json — the old code decoded what it
    /// could, skipped the rest, and persistPending rewrote only the decoded
    /// map, permanently destroying the skipped rows.
    @Test func rehydrate_corruptEntry_survivesExpiryRewrite() async throws {
        let dataRoot = makeDataRoot()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let fmt = ISO8601DateFormatter()
        let oldDate = fmt.string(from: Date().addingTimeInterval(-20 * 86_400))
        let freshDate = fmt.string(from: Date().addingTimeInterval(-3_600))
        try seedPendingActions(dataRoot, entries: [
            // Expired decodable entry — forces persistPending to rewrite.
            ["id": "imp_old", "status": "pending", "createdAt": oldDate],
            ["id": "imp_fresh", "status": "pending", "createdAt": freshDate],
            // Undecodable: no "id" key, future-schema fields. Must survive.
            ["schemaVersion": 99, "futureField": "do not drop me",
             "createdAt": oldDate],
        ])

        let orch = SelfImprovementOrchestrator(
            dataRoot: dataRoot, repoRoot: dataRoot, packagePath: nil
        )
        let actions = try await orch.listPending()
        #expect(actions.map(\.id) == ["imp_fresh"],
                "expired decoded entry gone, fresh survives, corrupt not surfaced as decoded")

        // The expiry rewrite already ran inside listPending's rehydrate.
        let path = dataRoot.appendingPathComponent("improvements/pending_actions.json")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [[String: Any]]
        let rows = raw ?? []
        #expect(!rows.contains { ($0["id"] as? String) == "imp_old" },
                "expired decoded entry must be swept")
        #expect(rows.contains { ($0["id"] as? String) == "imp_fresh" })
        let corrupt = rows.first { $0["futureField"] != nil }
        #expect(corrupt != nil,
                "corrupt/future-schema entry must SURVIVE the expiry rewrite; rows: \(rows)")
        #expect((corrupt?["futureField"] as? String) == "do not drop me")
        #expect((corrupt?["schemaVersion"] as? Int) == 99,
                "corrupt entry must be preserved VERBATIM, fields intact")
    }

    @Test func rehydrate_noStaleEntries_leavesFileAlone() async throws {
        let dataRoot = makeDataRoot()
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let fmt = ISO8601DateFormatter()
        let freshDate = fmt.string(from: Date().addingTimeInterval(-60))
        try seedPendingActions(dataRoot, entries: [
            ["id": "imp_only", "status": "pending", "createdAt": freshDate],
        ])
        let orch = SelfImprovementOrchestrator(
            dataRoot: dataRoot, repoRoot: dataRoot, packagePath: nil
        )
        let actions = try await orch.listPending()
        #expect(actions.map(\.id) == ["imp_only"])
    }
}
