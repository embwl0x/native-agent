import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Mac Control bridge audit behavior")
struct MacControlBridgeAuditEvalTests {
    private func root(_ name: String = "bridge-audit") throws -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    // MARK: - LEDGER: feed.macControlBridgeAudit

    @Test("producer receipts, bounded retention, and reader evidence are honest")
    func bridgeAuditBehaviorEval() async throws {
        let evidenceRoot = try root()
        defer { try? FileManager.default.removeItem(at: evidenceRoot) }

        let success = MacControlBridge.appendExecAudit(
            argv: ["/usr/bin/true"],
            status: "completed",
            reason: "exit_0",
            operationId: "bridge-audit-success",
            dataRoot: evidenceRoot
        )
        let refusal = MacControlBridge.appendExecAudit(
            argv: ["/usr/bin/osascript"],
            status: "blocked",
            reason: "osascript_high_risk_marker",
            operationId: "bridge-audit-refusal",
            dataRoot: evidenceRoot
        )
        let executionFailure = MacControlBridge.appendExecAudit(
            argv: ["/usr/bin/false"],
            status: "failed",
            reason: "exit_1",
            operationId: "bridge-audit-failure",
            dataRoot: evidenceRoot
        )
        for index in 0..<3 {
            let noOp = MacControlBridge.appendExecAudit(
                argv: ["emergency_stop"],
                status: "cancel_requested",
                reason: "bridge_stop: 0",
                operationId: "bridge-audit-noop-\(index)",
                dataRoot: evidenceRoot
            )
            #expect(noOp.state == .appended)
        }
        #expect(success.state == .appended)
        #expect(refusal.state == .appended)
        #expect(executionFailure.state == .appended)
        #expect(success.lineStored)
        #expect(success.retentionEnforced)

        let report = await MacControlBridgeAuditStore.readReport(dataRoot: evidenceRoot)
        #expect(report.state == .ready)
        #expect(report.dataRoot == evidenceRoot.path)
        #expect(report.path == evidenceRoot.appendingPathComponent(MacControlBridgeAuditStore.filename).path)
        #expect(report.physicalRowCount == 6)
        #expect(report.validRowCount == 6)
        #expect(report.statusCounts["completed"] == 1)
        #expect(report.statusCounts["blocked"] == 1)
        #expect(report.statusCounts["failed"] == 1)
        #expect(report.argv0Counts["emergency_stop"] == 3)
        #expect(report.repeatedZeroEffectReasons[
            "emergency_stop / cancel_requested / bridge_stop: 0"
        ] == 3)
        #expect(report.leads.contains { $0.hasPrefix("repeated_zero_effect:") })

        // The producer's same write boundary trims to the named maximum while
        // preserving the newest whole rows. This is intentionally exercised
        // through `appendExecAudit`, not by directly manufacturing a file.
        let boundedRoot = try root("bridge-audit-bounded")
        defer { try? FileManager.default.removeItem(at: boundedRoot) }
        for index in 0..<(MacControlBridgeAuditStore.retentionLimit + 2) {
            _ = MacControlBridge.appendExecAudit(
                argv: ["bounded-\(index)"],
                status: "completed",
                operationId: "bounded-\(index)",
                dataRoot: boundedRoot
            )
        }
        let bounded = await MacControlBridgeAuditStore.readReport(dataRoot: boundedRoot)
        #expect(bounded.state == .ready)
        #expect(bounded.physicalRowCount == MacControlBridgeAuditStore.retentionLimit)
        #expect(bounded.argv0Counts["bounded-0"] == nil)
        #expect(bounded.argv0Counts["bounded-501"] == 1)

        // A root that cannot contain the feed yields an explicit append failure;
        // it cannot be recast as an empty successful audit.
        let invalidRoot = evidenceRoot.appendingPathComponent("not-a-directory")
        try Data("not a directory".utf8).write(to: invalidRoot)
        let failed = MacControlBridge.appendExecAudit(
            argv: ["/usr/bin/false"],
            status: "failed",
            reason: "simulated_write_failure",
            dataRoot: invalidRoot
        )
        #expect(failed.state == .appendFailed)
        #expect(!failed.lineStored)
        #expect(!failed.retentionEnforced)
        #expect(failed.error != nil)
        #expect(failed.responseObject()["lineStored"] as? Bool == false)
        #expect(failed.responseObject()["retentionEnforced"] as? Bool == false)
    }

    @Test("reader distinguishes missing, malformed, partial, and unavailable evidence")
    func bridgeAuditReaderAdverseEvidenceEval() async throws {
        let missingRoot = try root("bridge-audit-missing")
        defer { try? FileManager.default.removeItem(at: missingRoot) }
        let missing = await MacControlBridgeAuditStore.readReport(dataRoot: missingRoot)
        #expect(missing.state == .missing)
        #expect(missing.physicalRowCount == 0)
        #expect(missing.validRowCount == 0)

        let damagedRoot = try root("bridge-audit-damaged")
        defer { try? FileManager.default.removeItem(at: damagedRoot) }
        let damagedPath = damagedRoot.appendingPathComponent(MacControlBridgeAuditStore.filename)
        try Data("{bad}\n{\"argv0\":\"ok\",\"status\":\"completed\",\"reason\":\"exit_0\"}\n{\"argv0\":\"partial\"".utf8)
            .write(to: damagedPath)
        let damaged = await MacControlBridgeAuditStore.readReport(dataRoot: damagedRoot)
        #expect(damaged.state == .incompleteEvidence)
        #expect(damaged.physicalRowCount == 3)
        #expect(damaged.validRowCount == 1)
        #expect(damaged.malformedRowCount == 1)
        #expect(damaged.trailingPartialRow)
        #expect(damaged.statusCounts["completed"] == 1)
        let malformedRetention = MacControlBridge.appendExecAudit(
            argv: ["/usr/bin/true"],
            status: "completed",
            reason: "cannot_claim_retention",
            dataRoot: damagedRoot
        )
        #expect(malformedRetention.state == .retentionFailed)
        #expect(malformedRetention.lineStored,
                "the new line landed even though the cap could not be enforced")
        #expect(!malformedRetention.retentionEnforced)
        #expect(malformedRetention.isStored)
        #expect(malformedRetention.error?.contains("retention") == true)
        #expect(malformedRetention.responseObject()["lineStored"] as? Bool == true)
        #expect(malformedRetention.responseObject()["retentionEnforced"] as? Bool == false)

        let unavailableRoot = try root("bridge-audit-unavailable")
        defer { try? FileManager.default.removeItem(at: unavailableRoot) }
        let unavailablePath = unavailableRoot.appendingPathComponent(MacControlBridgeAuditStore.filename)
        try FileManager.default.createDirectory(at: unavailablePath, withIntermediateDirectories: true)
        let unavailable = await MacControlBridgeAuditStore.readReport(dataRoot: unavailableRoot)
        #expect(unavailable.state == .unavailable)
        #expect(unavailable.byteCount == nil)
        #expect(unavailable.error != nil)
    }
}
