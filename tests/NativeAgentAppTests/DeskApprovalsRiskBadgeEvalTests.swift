import ApprovalInbox
import Foundation
import NativeAgentShared
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.desk / desk.approvals.riskBadge
@Suite("Desk approval risk badge")
struct DeskApprovalsRiskBadgeEvalTests {
    @Test("canonical approval records map every live risk value to a human label and known style")
    func persistedApprovalRisksHaveExplicitBadges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("desk-approval-risk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let inbox = SwiftNativeApprovalInbox(root: root)
        for risk in ["confirm", "medium", "high", "critical"] {
            _ = try await inbox.create(.object([
                "title": .string("Approve \(risk) fixture"),
                "action": .string("desk.risk.eval"),
                "risk": .string(risk),
                "reason": .string("exercise the canonical approval reader"),
                "payload": .object([:]),
            ]))
        }

        let approvals = try await NativeClient(baseURL: "", dataRootOverride: root).getApprovals()
        let badges = Dictionary(uniqueKeysWithValues: approvals.map {
            ($0.risk, ApprovalRiskBadgePresentation.badge(for: $0.risk))
        })

        #expect(badges["confirm"] == .some(.init(label: "Confirmation needed", status: "warn")))
        #expect(badges["medium"] == .some(.init(label: "Medium risk", status: "warn")))
        #expect(badges["high"] == .some(.init(label: "High risk", status: "fail")))
        #expect(badges["critical"] == .some(.init(label: "Critical risk", status: "fail")))
    }

    @Test("unknown and malformed risks fail visibly instead of exposing raw internal vocabulary")
    func unknownRiskIsAnExplicitWarning() {
        #expect(ApprovalRiskBadgePresentation.badge(for: " HIGH ")
            == .init(label: "High risk", status: "fail"))
        #expect(ApprovalRiskBadgePresentation.badge(for: "future_producer_risk")
            == .init(label: "Unrecognized risk", status: "warn"))
        #expect(ApprovalRiskBadgePresentation.badge(for: "")
            == .init(label: "Unrecognized risk", status: "warn"))
    }

    @Test("mounted approval panel renders the shared humanized badge")
    func approvalPanelUsesRiskPresentation() throws {
        let source = try AppSourceScraping.appSource("ApprovalsView.swift")
        #expect(source.contains("ApprovalRiskBadgePresentation.badge(for: approval.risk)"))
        #expect(source.contains("StatusBadge(text: riskBadge.label, status: riskBadge.status)"))
        #expect(!source.contains("StatusBadge(text: approval.risk, status: approval.risk)"))
    }
}
