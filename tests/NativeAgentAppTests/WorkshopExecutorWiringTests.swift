import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import NativeAgentApp

// MISSIONS EXECUTOR PORT — app-layer wiring regressions for the gpt-5.5
// review blockers #1 (startMission routes through the ASSEMBLED
// WorkshopExecutorLoop via WorkshopExecutorRef, honest error when
// unconfigured) and #7 (missionExecutorGate honors the passed dataRoot and
// mirrors submit's strict missionPolicy semantics — malformed → deny).
// All roots are tmp dirs — no production data is touched.

private func makeWiringTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkshopExecutorWiringTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeTrustPolicy(_ policy: JSONValue, root: URL) async throws {
    let path = root
        .appendingPathComponent("trust", isDirectory: true)
        .appendingPathComponent("policy.json")
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try await SwiftNativePersistenceCore().writeJSON(policy, to: path)
}

// MARK: - Blocker #1: WorkshopExecutorRef + startWorkshopExecution routing

/// .serialized: these tests mutate the process-wide WorkshopExecutorRef.shared
/// (the same boot-configured singleton NativeClient.startWorkshopExecution reads), so
/// they must not interleave. Each test restores the prior value.
@Suite("startWorkshopExecution routes through the assembled executor", .serialized)
struct WorkshopExecutorRefWiringSuite {

    @Test func unconfiguredRefMakesStartWorkshopExecutionThrowHonestError() async throws {
        let prior = WorkshopExecutorRef.shared.current()
        defer { if let prior { WorkshopExecutorRef.shared.configure(prior) } }
        WorkshopExecutorRef.shared.reset()

        do {
            _ = try await NativeClient(baseURL: "").startWorkshopExecution(id: "some-mission")
            Issue.record("startWorkshopExecution must throw when no executor is configured")
        } catch {
            // Honest "executor not running" — NOT a silent no-op, NOT the old
            // dead-path WorkshopExecutionError.unavailable ("Workshop executions unavailable").
            #expect(error.localizedDescription.contains("Workshop executor is not running"))
            #expect(error.localizedDescription.contains("Workshop execution left queued"))
        }
    }

    @Test func canonicalLoopRunnerFactoryPublishesExecutorButAlternateRootDoesNot() async throws {
        let alternateRoot = try makeWiringTempRoot()
        defer { try? FileManager.default.removeItem(at: alternateRoot) }
        let prior = WorkshopExecutorRef.shared.current()
        defer {
            if let prior { WorkshopExecutorRef.shared.configure(prior) }
            else { WorkshopExecutorRef.shared.reset() }
        }
        WorkshopExecutorRef.shared.reset()
        #expect(WorkshopExecutorRef.shared.current() == nil)

        // An alternate/test body must never replace the process-global live
        // executor. It receives its own returned runner and stays hermetic.
        _ = BackgroundLoopsAssembly.makeWorkshopExecutorLoopRunner(dataRoot: alternateRoot)
        #expect(WorkshopExecutorRef.shared.current() == nil)

        // The SAME canonical-root factory assembleAllLoops calls at app boot
        // publishes the assembled live instance (AppRestartCoordinator shape).
        _ = BackgroundLoopsAssembly.makeWorkshopExecutorLoopRunner(
            dataRoot: PersistenceCore.defaultDataRoot()
        )
        #expect(WorkshopExecutorRef.shared.current() != nil)
    }

    @Test func configuredRefRoutesStartWorkshopExecutionToExecutorStart() async throws {
        let root = try makeWiringTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let prior = WorkshopExecutorRef.shared.current()
        defer {
            if let prior { WorkshopExecutorRef.shared.configure(prior) }
            else { WorkshopExecutorRef.shared.reset() }
        }
        // Configure with a real assembled executor rooted at the tmp root.
        WorkshopExecutorRef.shared.configure(
            BackgroundLoopsAssembly.makeWorkshopExecutor(dataRoot: root))

        do {
            _ = try await NativeClient(baseURL: "").startWorkshopExecution(id: "nonexistent")
            Issue.record("startWorkshopExecution of an unknown execution must throw")
        } catch {
            // The EXECUTOR's typed refusal — proof the call reached
            // WorkshopExecutorLoop.start (the retired protocol path threw the
            // generic "missions unavailable" instead).
            #expect(error.localizedDescription.contains("Workshop execution not found: nonexistent"))
        }
    }
}

// MARK: - Blocker #7: missionExecutorGate dataRoot + strict missionPolicy

@Suite("workshopExecutorGate policy semantics")
struct WorkshopExecutorGateSuite {

    @Test func freshRootWithoutEnableAutonomyGatesOff() async throws {
        let root = try makeWiringTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // No saved policy → enableAutonomy absent → executor stays off.
        #expect(await BackgroundLoopsAssembly.workshopExecutorGate(dataRoot: root) == false)
    }

    @Test func enableAutonomyWithDefaultWorkshopPolicyGatesOn() async throws {
        let root = try makeWiringTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeTrustPolicy(.object(["enableAutonomy": .bool(true)]), root: root)
        #expect(await BackgroundLoopsAssembly.workshopExecutorGate(dataRoot: root) == true)
    }

    /// The blocker's exact divergence: present-but-malformed missionPolicy
    /// was ALLOW here while submit's gate denies it. Must now DENY.
    @Test func malformedWorkshopPolicyDeniesLikeSubmitGate() async throws {
        let root = try makeWiringTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeTrustPolicy(.object([
            "enableAutonomy": .bool(true),
            "missionPolicy": .string("broken"),
        ]), root: root)
        #expect(await BackgroundLoopsAssembly.workshopExecutorGate(dataRoot: root) == false)
    }

    @Test func explicitDisabledWorkshopPolicyGatesOff() async throws {
        let root = try makeWiringTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeTrustPolicy(.object([
            "enableAutonomy": .bool(true),
            "missionPolicy": .object(["enabled": .bool(false)]),
        ]), root: root)
        #expect(await BackgroundLoopsAssembly.workshopExecutorGate(dataRoot: root) == false)
    }

    /// Saved authority is typed state, not Python-style truthiness. A numeric
    /// replacement for the boolean gate makes the policy unavailable and must
    /// deny both the background executor and submit paths.
    @Test func wrongTypedEnabledDeniesLikeSubmitGate() async throws {
        let root = try makeWiringTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeTrustPolicy(.object([
            "enableAutonomy": .bool(true),
            "missionPolicy": .object(["enabled": .int(1)]),
        ]), root: root)
        #expect(await BackgroundLoopsAssembly.workshopExecutorGate(dataRoot: root) == false)
    }

    /// The dataRoot half of the blocker: the gate used to construct
    /// SwiftNativeTrustCenter() on the DEFAULT data root, so per-root
    /// policies were ignored. Two tmp roots with opposite policies must now
    /// gate independently.
    @Test func gateHonorsThePassedDataRoot() async throws {
        let onRoot = try makeWiringTempRoot()
        let offRoot = try makeWiringTempRoot()
        defer {
            try? FileManager.default.removeItem(at: onRoot)
            try? FileManager.default.removeItem(at: offRoot)
        }
        try await writeTrustPolicy(.object(["enableAutonomy": .bool(true)]), root: onRoot)
        try await writeTrustPolicy(.object([
            "enableAutonomy": .bool(true),
            "missionPolicy": .object(["enabled": .bool(false)]),
        ]), root: offRoot)
        #expect(await BackgroundLoopsAssembly.workshopExecutorGate(dataRoot: onRoot) == true)
        #expect(await BackgroundLoopsAssembly.workshopExecutorGate(dataRoot: offRoot) == false)
    }
}
