import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore

/// THE TAIL MUST REACH THE CURSOR. The window cursor pins the prefix head to
/// a row identity; the reader hands the projection the transcript's tail. If
/// the tail is bounded by bytes below the cursor's row window, the boundary
/// falls out of the tail, the projection fails open, and the head becomes
/// whatever row the byte cap happened to reach — sliding with every append
/// while every cursor receipt says stable. Live 2026-09-02: 192 KB against
/// 242 KB of tool-heavy rows, four history rebuilds in seven turns.
@Suite("TurnRegression.Reader") struct PromptTailReachTurnRegressionTests {
    @Test("a tail of 160 rows is returned even when those rows weigh more than 192 KB")
    func tailReachesTheCursorWindowUnderHeavyRows() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tail-reach-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("chat/messages", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sid = "TAILREACH-0000-0000-0000-000000000001"
        var lines: [String] = []
        let filler = String(repeating: "x", count: 4_000)
        for index in 0..<200 {
            let role = index % 2 == 0 ? "user" : "assistant"
            lines.append("{\"id\":\"row-\(index)\",\"role\":\"\(role)\",\"content\":\"\(filler)\",\"createdAt\":\"2026-09-02T10:00:00Z\"}")
        }
        try lines.joined(separator: "\n").appending("\n")
            .write(to: dir.appendingPathComponent("\(sid).jsonl"), atomically: true, encoding: .utf8)
        let reader = SessionHistoryReader(dataRoot: root)
        let result = try await reader.promptMessagesWithStats(forSessionId: sid, anchorLimit: 0, tailLimit: 160)
        // 160 rows × ~4 KB = ~640 KB: far past the old 192 KB cap.
        #expect(result.messages.count >= 160, "tail returned \(result.messages.count) rows; the cursor's window is 160")
        let ids = result.messages.compactMap { m -> String? in
            if case .object(let o)? = m.extras, case .string(let id)? = o["id"] { return id }
            return nil
        }
        #expect(ids.contains("row-40"), "the cursor boundary 160 rows back is not in the tail")
    }
}
