import Testing
import Foundation
@testable import PersistenceCore
import NativeAgentCore

// Tightness round 2 P-M1 / P-L4: the Telegram receipts.jsonl and notes.jsonl
// feeds were raw appenders that grew unbounded (receipts hit 1.6MB live). Both
// now route through the shared `appendJSONLCapped` at a receipt-class budget.
// These pin the cap constants and prove the shared trim fires on the receipts
// feed path.

private func capTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("telegram-receipts-cap-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func lineCount(_ url: URL) -> Int {
    guard let s = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
    return s.split(separator: "\n").filter { !$0.isEmpty }.count
}

@Test func telegramReceiptAndNoteCapConstantsArePinned() {
    #expect(JSONLLineCaps.telegramReceipts == 5000)
    #expect(JSONLLineCaps.telegramNotes == 5000)
}

@Test func receiptsFeedTrimsPastCap() async throws {
    let dir = capTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let receipts = dir.appendingPathComponent("receipts.jsonl")
    let store = SwiftNativePersistenceCore()
    let cap = 10
    // Append past the cap through the exact path recordReceipt now uses.
    for i in 0..<(cap + 15) {
        try await appendJSONLCapped(
            .object(["id": .string("r\(i)"), "kind": .string("reply")]),
            to: receipts,
            using: store,
            maxLines: cap,
            logLabel: "test.receipts"
        )
    }
    // The feed is trimmed to the newest `cap` rows...
    #expect(lineCount(receipts) == cap)
    // ...and the newest row survived while the oldest was dropped.
    let body = try String(contentsOf: receipts, encoding: .utf8)
    #expect(body.contains("\"r24\""))
    #expect(!body.contains("\"r0\""))
}
