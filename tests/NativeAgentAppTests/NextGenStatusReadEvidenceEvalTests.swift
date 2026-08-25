import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.runtimes / client.nextGenStatusReads

@Suite("NextGen runtime status evidence", .serialized)
struct NextGenStatusReadEvidenceEvalTests {
    @Test("seeded runtime feeds project their evidence while an absent root stays unmeasured")
    func seededFeedsAndAbsentFeedsRemainDistinct() async throws {
        let absentRoot = try temporaryRoot("absent")
        let seededRoot = try temporaryRoot("seeded")
        let unavailableRoot = try temporaryRoot("unavailable")
        defer {
            try? FileManager.default.removeItem(at: absentRoot)
            try? FileManager.default.removeItem(at: seededRoot)
            try? FileManager.default.removeItem(at: unavailableRoot)
        }

        let absent = NativeClient(baseURL: "", dataRootOverride: absentRoot)
        let absentSummary = try await absent.getNextGenSummary()
        #expect(absentSummary.status == "unmeasured")
        #expect(absentSummary.totalPhaseCount == 0)
        #expect((try await absent.getNotificationStatus()).status == "unmeasured")
        #expect((try await absent.getBrowserStatus()).status == "unmeasured")
        #expect((try await absent.getMemoryVectorStatus()).status == "unmeasured")
        #expect((try await absent.getProductionHardening()).status == "unknown")

        try FileManager.default.createDirectory(
            at: unavailableRoot.appendingPathComponent("native_power/browser/runs.json"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: unavailableRoot.appendingPathComponent("native_power/notifications/receipts.jsonl"),
            withIntermediateDirectories: true
        )
        try write(
            "not valid next-gen JSON",
            to: unavailableRoot.appendingPathComponent("runtime/nextgen_phases.json")
        )
        let unavailable = NativeClient(baseURL: "", dataRootOverride: unavailableRoot)
        #expect((try await unavailable.getBrowserStatus()).status == "unavailable")
        #expect((try await unavailable.getNotificationStatus()).status == "unavailable")
        await #expect(throws: (any Error).self) {
            _ = try await unavailable.getNextGenPhases()
        }

        try write(
            #"{"phases":[{"id":"phase-1","name":"Seeded phase","status":"ready","ready":true}]}"#,
            to: seededRoot.appendingPathComponent("runtime/nextgen_phases.json")
        )
        try write(
            #"{"id":"nextgen-receipt-1","actionId":"ops.health.snapshot","status":"completed","createdAt":"2026-08-24T12:00:00Z"}"# + "\n",
            to: seededRoot.appendingPathComponent("nextgen/actions/receipts.jsonl")
        )
        try write(
            #"{"id":"notification-receipt-1","actionId":"notification.dry_run","status":"completed","createdAt":"2026-08-24T12:01:00Z"}"# + "\n",
            to: seededRoot.appendingPathComponent("native_power/notifications/receipts.jsonl")
        )
        try write(
            #"{"id":"native-action-1","actionId":"system_info","status":"completed","createdAt":"2026-08-24T12:01:30Z"}"# + "\n",
            to: seededRoot.appendingPathComponent("native_power/actions/receipts.jsonl")
        )
        try write(
            #"[{"id":"browser-run-1","status":"running","createdAt":"2026-08-24T12:02:00Z"}]"#,
            to: seededRoot.appendingPathComponent("native_power/browser/runs.json")
        )
        try write(
            #"{"status":"ready","provider":"fixture","providerConfigured":true,"nodeCount":7,"entityCount":3}"#,
            to: seededRoot.appendingPathComponent("memory/vector_status.json")
        )
        try write(
            #"{"id":"hygiene-1","status":"completed","createdAt":"2026-08-24T12:03:00Z"}"#,
            to: seededRoot.appendingPathComponent("memory/hygiene_last_run.json")
        )
        try write(
            #"{"status":"blocked","doctorStatus":"warn","detail":"Fixture hardening report requires attention."}"#,
            to: seededRoot.appendingPathComponent("runtime/hardening.json")
        )

        let seeded = NativeClient(baseURL: "", dataRootOverride: seededRoot)
        let summary = try await seeded.getNextGenSummary()
        #expect(summary.status == "ready")
        #expect(summary.totalPhaseCount == 1)
        #expect(summary.receiptCount == 1)
        #expect((try await seeded.getNextGenReceipts()).first?.id == "nextgen-receipt-1")
        #expect((try await seeded.getNativeActionReceipts()).first?.id == "native-action-1")

        let notifications = try await seeded.getNotificationStatus()
        #expect(notifications.status == "ready")
        #expect(notifications.receiptCount == 1)
        #expect(notifications.latestReceipt?.id == "notification-receipt-1")

        let browser = try await seeded.getBrowserStatus()
        #expect(browser.status == "ready")
        #expect(browser.activeRuns?.map(\.id) == ["browser-run-1"])
        #expect(browser.profilePath?.hasPrefix(seededRoot.path) == true)

        let vector = try await seeded.getMemoryVectorStatus()
        #expect(vector.status == "ready")
        #expect(vector.provider == "fixture")
        #expect(vector.nodeCount == 7)

        let memoryV2 = try await seeded.getMemoryV2Status()
        #expect(memoryV2.hygiene?.id == "hygiene-1")
        #expect(memoryV2.hygiene?.status == "completed")

        let hardening = try await seeded.getProductionHardening()
        #expect(hardening.status == "blocked")
        #expect(hardening.detail == "Fixture hardening report requires attention.")
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextgen-status-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }
}
