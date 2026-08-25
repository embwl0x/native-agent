import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.desk / workshop.observatory.receiptStatusTint
@Suite("Workshop observatory receipt status tint")
struct WorkshopObservatoryReceiptStatusTintEvalTests {
    private func receiptLine(_ status: String, index: Int) -> String {
        """
        {"handle":"desk-\(index)","reservationId":"receipt-\(index)","status":"\(status)",
         "summary":"fixture","artifactCount":0,"ts":"2026-08-24T00:00:0\(index)Z"}
        """
    }

    @Test("persisted completed, blocked, cancelled, failed, and refused rows retain distinct non-success tints")
    func liveReceiptVocabularyDoesNotRenderFailuresAsNeutral() {
        // This is the vocabulary carried by the durable receipts feed, including
        // legacy failed/cancelled rows that are wider than the current writer's enum.
        let statuses = ["completed", "blocked", "cancelled", "failed", "refused"]
        guard case .rows(let rows) = WorkshopReceiptsReader.rows(
            fromLines: statuses.enumerated().map { receiptLine($0.element, index: $0.offset) }
        ) else {
            Issue.record("fixture receipts should parse through the panel reader")
            return
        }

        let tints = Dictionary(uniqueKeysWithValues: rows.map {
            ($0.status, WorkshopReceiptStatusPresentation.tint(for: $0.status))
        })
        #expect(tints.count == statuses.count)
        #expect(tints["completed"] == .some(.success))
        for failureish in ["blocked", "cancelled", "failed", "refused"] {
            #expect(tints[failureish] != .some(.success), "\(failureish) cannot render as successful or neutral chrome")
        }
        #expect(tints["failed"] == .some(.failure))
        #expect(tints["refused"] == .some(.failure))
    }

    @Test("unknown or malformed statuses are visibly warning, never success")
    func unexpectedStatusFailsVisibly() {
        #expect(WorkshopReceiptStatusPresentation.tint(for: "  FaiLeD ") == .failure)
        #expect(WorkshopReceiptStatusPresentation.tint(for: "future_writer_state") == .warning)
        #expect(WorkshopReceiptStatusPresentation.tint(for: "") == .warning)
    }

    @Test("mounted receipt row converts the shared tint to a non-neutral SwiftUI color")
    func observatoryUsesSharedStatusPresentation() throws {
        let source = try AppSourceScraping.appSource("WorkshopObservatoryPanel.swift")
        #expect(source.contains(".foregroundStyle(statusTint(row.status))"))
        #expect(source.contains("WorkshopReceiptStatusPresentation.tint(for: status)"))
        #expect(source.contains("case .warning: return .orange"))
        #expect(source.contains("case .failure: return .red"))
    }
}
