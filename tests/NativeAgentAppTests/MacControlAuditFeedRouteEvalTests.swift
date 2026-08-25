import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.bridges / bridge.macctl.auditFeed

@Suite("Mac Control route audit feed", .serialized)
struct MacControlAuditFeedRouteEvalTests {
    @Test("completion, policy refusal, and route validation rejection each retain one attributable row")
    func terminalRouteOutcomesAreDurablyAudited() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macctl-route-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = MacControlBridge.appendExecAudit(argv: ["/usr/bin/true"], status: "completed", operationId: "op-complete", dataRoot: root)
        _ = MacControlBridge.appendExecAudit(argv: ["/usr/bin/osascript"], status: "blocked", reason: "mac_control_policy_denied", operationId: "op-blocked", dataRoot: root)
        _ = MacControlBridge.auditExecValidationRejection(argv: ["bad"], reason: "invalid_operation_id", operationId: "op-invalid", dataRoot: root)

        let report = await MacControlBridgeAuditStore.readReport(dataRoot: root)
        #expect(report.state == .ready)
        #expect(report.physicalRowCount == 3)
        #expect(report.statusCounts["completed"] == 1)
        #expect(report.statusCounts["blocked"] == 1)
        #expect(report.statusCounts["validation_rejected"] == 1)
        let lines = try String(contentsOf: root.appendingPathComponent(MacControlBridgeAuditStore.filename), encoding: .utf8)
            .split(separator: "\n")
        let operationIDs = try Set(lines.map { line in
            let row = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return try #require(row["operationId"] as? String)
        })
        #expect(operationIDs == Set(["op-complete", "op-blocked", "op-invalid"]))
    }
}
