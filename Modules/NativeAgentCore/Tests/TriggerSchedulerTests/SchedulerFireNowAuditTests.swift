import Testing
import Foundation
@testable import TriggerScheduler
import NativeAgentCore
import PersistenceCore

// MARK: - Wave 36 W18: scheduler fire_now native guards

@Suite("Wave 36 W18: scheduler fire_now AUDIT-FIRST guard")
struct SchedulerFireNowAuditTests {

    // Workshop fire_now is Swift-native. Missing rows return the native
    // not_found envelope instead of delegating to any fallback route.
    @Test func workshopExecutionFireNow_swiftNativeReturnsNotFound() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchedulerFireNowAudit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SwiftNativeTriggerScheduler(root: root)
        let result = try await client.fireWorkshopTrigger(name: "definitely_missing")
        #expect(result.status == "not_found")
    }

    // The fire_now surfaces still resolve through SwiftNativeTriggerScheduler.
    @Test func factory_returnsSwiftNative() async throws {
        let impl = makeTriggerScheduler()
        #expect(impl is SwiftNativeTriggerScheduler)
    }

    // Audit 2026-06-09 regression: the periodic tick fired EVERY enabled
    // trigger unconditionally every 60s (4 stub inbox items/minute on the
    // live install, churning the whole 1000-line items.jsonl cap every ~4
    // minutes). Until real per-kind due-conditions are ported,
    // evaluateAndFire must fire NOTHING — enabled or not. Explicit
    // fire_now stays live (covered above and by fireInboxTrigger tests).
    @Test func evaluateAndFire_doesNotFireUnconditionedTriggers() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EvaluateAndFireGate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = SwiftNativeTriggerScheduler(root: root)
        // Default inbox configs include enabled rows (e.g. mission_followup).
        let enabledBefore = (try await client.listInboxTriggers()).filter(\.enabled)
        #expect(!enabledBefore.isEmpty, "test needs at least one enabled default trigger")
        let fired = await client.evaluateAndFire()
        #expect(fired.isEmpty)
        let itemsPath = root.appendingPathComponent("inbox/items.jsonl")
        #expect(!FileManager.default.fileExists(atPath: itemsPath.path))
    }
}
