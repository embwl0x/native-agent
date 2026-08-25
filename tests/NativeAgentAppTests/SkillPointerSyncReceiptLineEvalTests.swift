import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Skills.pointerSyncReceiptLine
@MainActor
@Suite("Skill pointer-sync receipt line", .serialized)
struct SkillPointerSyncReceiptLineEvalTests {
    @Test("the receipt presentation reports the root-scoped reconciled pointer count, not an inventory guess")
    func receiptPresentationUsesDurableRootScopedCounts() throws {
        let root = try temporaryRoot("current")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeReceipt(
            in: root,
            object: [
                "status": "ok",
                "at": "2026-08-24T12:00:00Z",
                "added": "2",
                "updated": "1",
                "removed": "7",
                "unchanged": "4",
            ]
        )

        let state = SkillPointerSyncReceiptPresentation.read(dataRoot: root)
        guard case .current(let receipt) = state else {
            Issue.record("a complete durable success receipt must be current")
            return
        }
        #expect(receipt.reconciledPointerCount == 7)
        #expect(receipt.removed == 7)
        let line = SkillPointerSyncReceiptPresentation.line(for: state)
        #expect(line.contains("7 recall pointers confirmed"))
        #expect(!line.contains("pointer sync failed"))

        let otherRoot = try temporaryRoot("other")
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        try writeReceipt(
            in: otherRoot,
            object: [
                "status": "ok",
                "at": "2026-08-24T12:00:00Z",
                "added": "9",
                "updated": "0",
                "removed": "0",
                "unchanged": "0",
            ]
        )
        #expect(SkillPointerSyncReceiptPresentation.line(
            for: SkillPointerSyncReceiptPresentation.read(dataRoot: root)
        ).contains("7 recall pointers confirmed"))
    }

    @Test("missing, malformed, and failed receipts remain explicit and bounded")
    func adverseReceiptStatesDoNotMasqueradeAsZeroOrSuccess() throws {
        let root = try temporaryRoot("adverse")
        defer { try? FileManager.default.removeItem(at: root) }
        let receiptURL = SkillPointerSyncReceiptPresentation.receiptURL(dataRoot: root)

        let missing = SkillPointerSyncReceiptPresentation.read(dataRoot: root)
        #expect(SkillPointerSyncReceiptPresentation.line(for: missing).contains("unavailable"))
        #expect(!SkillPointerSyncReceiptPresentation.line(for: missing).contains("0 recall pointers"))

        try FileManager.default.createDirectory(at: receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: receiptURL)
        let malformed = SkillPointerSyncReceiptPresentation.read(dataRoot: root)
        #expect(SkillPointerSyncReceiptPresentation.line(for: malformed).contains("unavailable"))

        try writeReceipt(
            in: root,
            object: [
                "status": "ok",
                "at": "2026-08-24T12:00:00Z",
                "added": "100001",
                "updated": "0",
                "removed": "0",
                "unchanged": "0",
            ]
        )
        let unbounded = SkillPointerSyncReceiptPresentation.read(dataRoot: root)
        #expect(SkillPointerSyncReceiptPresentation.line(for: unbounded).contains("unavailable"))

        let longError = String(repeating: "pointer backend unavailable ", count: 40)
        try writeReceipt(
            in: root,
            object: ["status": "failed", "error": longError]
        )
        let failed = SkillPointerSyncReceiptPresentation.read(dataRoot: root)
        let line = SkillPointerSyncReceiptPresentation.line(for: failed)
        #expect(line.contains("Pointer sync failed"))
        #expect(line.count <= 270)
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skills-pointer-sync-line-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func writeReceipt(in root: URL, object: [String: String]) throws -> URL {
        let receipt = root.appendingPathComponent("skills/.pointer_sync_receipt.json")
        try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: receipt, options: .atomic)
        return receipt
    }

}
