import Testing
import Foundation
@testable import NotificationInbox
import NativeAgentCore
import PersistenceCore

// Tightness round 2 P-L5: ProactiveOutcomeLedger.recordOutcome re-implemented the
// shared line cap (capJSONLTail). It now routes through the shared
// enforceJSONLLineCap/appendJSONLCapped path (same flock, newest-1000). Pins that
// the outcomes feed stays bounded and keeps the newest record.

private func ledgerCapTempRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("proactive-cap-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func recordOutcomeCapsFeedAtThousand() async throws {
    let root = ledgerCapTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outcomesPath = root
        .appendingPathComponent("nextgen", isDirectory: true)
        .appendingPathComponent("proactive", isDirectory: true)
        .appendingPathComponent("outcomes.jsonl")
    try FileManager.default.createDirectory(
        at: outcomesPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Pre-seed just over the cap with dummy rows.
    var seed = ""
    for i in 0..<1005 {
        seed += "{\"id\":\"seed\(i)\",\"itemId\":\"seed\(i)\"}\n"
    }
    try Data(seed.utf8).write(to: outcomesPath)

    let ledger = ProactiveOutcomeLedger(root: root, persistence: SwiftNativePersistenceCore())
    _ = await ledger.recordOutcome(
        opportunityId: "opp-new", itemId: "item-new", kind: "code_review",
        outcome: "archive", useful: true, source: "inbox")

    let body = try String(contentsOf: outcomesPath, encoding: .utf8)
    let lines = body.split(separator: "\n").filter { !$0.isEmpty }
    #expect(lines.count == 1000)                 // trimmed to the newest 1000
    #expect(body.contains("item-new"))           // the just-appended record survived
    #expect(!body.contains("\"seed0\""))         // oldest rows were dropped
}
