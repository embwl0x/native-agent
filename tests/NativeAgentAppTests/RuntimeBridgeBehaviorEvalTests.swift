import Foundation
import Network
import Testing
import ActivityWatch
import BackgroundLoops
import NativeAgentCore
import PersistenceCore
@testable import NativeAgentApp

// These are behavior evaluations for the app-owned runtime seams.  They use
// fresh roots and injected Core managers; they never read the resident app's
// data root or exercise a real notification, bridge listener, or TCC grant.

private func runtimeBridgeTempRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeAgentRuntimeBridgeEval-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private struct RuntimeBridgeEvalLoop: LoopRunner {
    let loopId: String
    let interval: TimeInterval = 3_600

    func tickOutcome() async -> LoopTickOutcome {
        .completed(result: "eval")
    }
}

private struct RuntimeBridgeEvalLLM: LLMClient {
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        HeartbeatLoop.okToken
    }
}

@Suite("Runtime and bridge behavior evaluations", .serialized)
struct RuntimeBridgeBehaviorEvalTests {
    @Test("background loop replacement reports a real restart, relaunch requirement, or unknown id")
    func restartOutcomeNeverClaimsANoOpRestart() async {
        let core = BackgroundLoops.BackgroundLoopsManager()
        let manager = BackgroundLoopsManager(
            coreManager: core,
            assembleLoops: { [RuntimeBridgeEvalLoop(loopId: "ordinary")] },
            replacementLoop: { id in
                id == "telegram_poll" ? RuntimeBridgeEvalLoop(loopId: id) : nil
            },
            runAutoDoctorAtLaunch: { false },
            runHeartbeatAtLaunch: { false }
        )

        await manager.start(loops: [RuntimeBridgeEvalLoop(loopId: "ordinary")])
        #expect(await manager.restartLoop(id: "ordinary") == .requiresRelaunch(loopId: "ordinary"))
        #expect(await manager.restartLoop(id: "not-registered") == .unknown(loopId: "not-registered"))

        let restarted = await manager.restartLoop(id: "telegram_poll")
        #expect(restarted == .restarted(loopId: "telegram_poll"))
        #expect(await core.isRunning(loopId: "ordinary"))
        #expect(await core.isRunning(loopId: "telegram_poll"))
        await manager.stop()
    }

    @Test("a background failure card is durable, deduplicated, and only resurfaces for a new error class")
    func loopFailureNoticePreservesDismissalUntilTheFailureChanges() async throws {
        let root = try runtimeBridgeTempRoot("loop-failure")
        defer { try? FileManager.default.removeItem(at: root) }

        await BackgroundLoopsManager.fileLoopFailureNotice(
            dataRoot: root,
            loopId: "desk_notify",
            error: "first failure"
        )

        let inbox = root.appendingPathComponent("notifications/inbox.jsonl")
        func card() throws -> [String: Any] {
            let line = try String(contentsOf: inbox, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .joined(separator: "\n")
            return try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }

        var first = try card()
        #expect(first["id"] as? String == "loop-failure:desk_notify")
        #expect(first["status"] as? String == "unread")
        #expect((first["detail"] as? String)?.contains("first failure") == true)

        // Simulate the user's durable dismissal.  Repeating the same failure
        // must update evidence without re-opening or re-pushing the card.
        first["status"] = "dismissed"
        first["read_at"] = "2026-08-24T00:00:00Z"
        try Data(JSONSerialization.data(withJSONObject: first, options: [.sortedKeys]))
            .write(to: inbox, options: .atomic)
        await BackgroundLoopsManager.fileLoopFailureNotice(
            dataRoot: root,
            loopId: "desk_notify",
            error: "first failure"
        )
        let repeated = try card()
        #expect(repeated["status"] as? String == "dismissed")
        #expect(repeated["read_at"] as? String == "2026-08-24T00:00:00Z")

        // A materially different error is a new condition and must become
        // actionable again rather than remaining hidden behind the old dismiss.
        await BackgroundLoopsManager.fileLoopFailureNotice(
            dataRoot: root,
            loopId: "desk_notify",
            error: "second failure"
        )
        let changed = try card()
        #expect(changed["status"] as? String == "unread")
        #expect((changed["detail"] as? String)?.contains("second failure") == true)

        // A proven recovery retires the actionable card, but marks that the
        // archive was automatic so the same error in a NEW episode resurfaces.
        // An older durable completion cannot close a newer failure card.
        #expect(await BackgroundLoopsManager.resolveLoopFailureNotice(
            dataRoot: root, loopId: "desk_notify",
            healthyAt: Date(timeIntervalSince1970: 1_000_000),
            now: Date(timeIntervalSince1970: 2_000_000_000)
        ))
        #expect(try card()["status"] as? String == "unread")

        #expect(await BackgroundLoopsManager.resolveLoopFailureNotice(
            dataRoot: root, loopId: "desk_notify",
            healthyAt: Date(timeIntervalSince1970: 2_000_000_000),
            now: Date(timeIntervalSince1970: 2_000_000_000)
        ))
        let recovered = try card()
        #expect(recovered["status"] as? String == "archived")
        #expect(recovered["resolved_reason"] as? String == "loop_recovered")
        #expect(recovered["resolved_health_at"] != nil)

        await BackgroundLoopsManager.fileLoopFailureNotice(
            dataRoot: root,
            loopId: "desk_notify",
            error: "second failure"
        )
        let recurred = try card()
        #expect(recurred["status"] as? String == "unread")
        #expect(recurred["resolved_reason"] == nil)
    }

    @Test("heartbeat assembly reads its checklist from the supplied root and makes absence explicit")
    func heartbeatChecklistIsRootBoundAndMissingIsNotHealthy() async throws {
        let root = try runtimeBridgeTempRoot("heartbeat")
        defer { try? FileManager.default.removeItem(at: root) }

        let missing = BackgroundLoopsAssembly.makeHeartbeatLoop(
            dataRoot: root,
            llm: RuntimeBridgeEvalLLM()
        )
        #expect(await missing.tickOutcome() == .skipped(reason: "HEARTBEAT.md missing or empty"))

        let persona = PersistenceCore.defaultPersonaRoot(dataRoot: root)
        try FileManager.default.createDirectory(at: persona, withIntermediateDirectories: true)
        try Data("Check the deterministic status.\n".utf8)
            .write(to: persona.appendingPathComponent("HEARTBEAT.md"), options: .atomic)
        let present = BackgroundLoopsAssembly.makeHeartbeatLoop(
            dataRoot: root,
            llm: RuntimeBridgeEvalLLM()
        )
        #expect(await present.tickOutcome() != .skipped(reason: "HEARTBEAT.md missing or empty"))
    }

    @Test("activity privacy controls persist exactly and fresh disabled capture creates no activity database")
    @MainActor
    func activitySettingsAreDurableWithoutStartingCapture() throws {
        let root = try runtimeBridgeTempRoot("activity")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = ActivityWatchController(dataRoot: root)

        controller.startAtLaunch()
        #expect(!controller.isCapturing)
        #expect(!FileManager.default.fileExists(
            atPath: ActivityWatchPaths.databaseURL(dataRoot: root).path
        ))

        controller.setCaptureTitles(true)
        controller.setBrowserTitlesEnabled(true)
        controller.setModelAccessEnabled(true)
        controller.setAppNameOnlyMode(true)
        controller.setRetentionDays(0)

        let persisted = try ActivityPolicyStore(dataRoot: root).loadChecked()
        #expect(!persisted.captureEnabled)
        #expect(persisted.captureTitles)
        #expect(persisted.browserTitlesEnabled)
        #expect(persisted.allowModelAccess)
        #expect(persisted.appNameOnlyMode)
        #expect(persisted.retentionDays == 1)
        #expect(controller.lastError == nil)
    }

    @Test("canonical and legacy Mac-control audit rows retain a truthful stable identity")
    func macControlAuditRowsDecodeWithoutDroppingTheOutcome() throws {
        let canonical = try JSONDecoder().decode(MacControlAuditEntry.self, from: Data("""
        {"id":"op-1","method":"shell","executed_at":"2026-08-24T00:00:00Z","blocked":true,"block_reason":"policy_denied","stderr":"should-not-win"}
        """.utf8))
        #expect(canonical.id == "op-1")
        #expect(canonical.action == "shell")
        #expect(canonical.ts == "2026-08-24T00:00:00Z")
        #expect(canonical.allowed == false)
        #expect(canonical.detail == "policy_denied")

        let legacy = try JSONDecoder().decode(MacControlAuditEntry.self, from: Data("""
        {"ts":"2026-08-24T00:00:01Z","action":"shortcut","detail":"completed","allowed":true}
        """.utf8))
        #expect(legacy.id == "2026-08-24T00:00:01Z-shortcut")
        #expect(legacy.method == "shortcut")
        #expect(legacy.allowed == true)
        #expect(legacy.detail == "completed")
    }

    @Test("only exact loopback hosts can pass the bridge boundary")
    func bridgeRejectsLookalikeLoopbackHostnames() {
        func endpoint(_ host: String) -> NWEndpoint {
            .hostPort(host: NWEndpoint.Host(host), port: 8770)
        }

        #expect(BridgeCore.endpointIsLoopback(endpoint("127.0.0.1")))
        #expect(BridgeCore.endpointIsLoopback(endpoint("::1")))
        #expect(!BridgeCore.endpointIsLoopback(endpoint("evil127.0.0.1.attacker.invalid")))
        #expect(!BridgeCore.endpointIsLoopback(endpoint("evil::1.attacker.invalid")))
    }
}
