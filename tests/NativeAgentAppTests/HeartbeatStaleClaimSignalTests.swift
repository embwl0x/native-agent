import Foundation
import Testing
import PersistenceCore
import SelfImprovement
@testable import NativeAgentApp

// MARK: - U6 heartbeat stale-claim signal tests
//
// gatherHeartbeatAssessment composes a live-signal block; U6 added section 5 — a
// stale-task-claim gatherer (claims with status=claimed older than 24h, no
// update since). Asserts the line APPEARS when a stale claim exists and reads
// "none" when there are no stale claims.

private func tmpRoot() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("heartbeat-stale-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeDoctorSnapshot(_ root: URL, statuses: [String]) throws {
    let doctorDir = root.appendingPathComponent("doctor", isDirectory: true)
    try FileManager.default.createDirectory(at: doctorDir, withIntermediateDirectories: true)
    let checks = statuses.enumerated().map { index, status in
        ["id": "check\(index)", "title": "Check \(index)", "status": status]
    }
    let payload: [String: Any] = [
        "checks": checks,
        "runAt": "2026-06-17T00:00:00Z",
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: doctorDir.appendingPathComponent("latest.json"))
}

private func heartbeatSignals(dataRoot: URL) async -> String {
    await BackgroundLoopsAssembly.gatherHeartbeatAssessment(dataRoot: dataRoot).signals
}

@Test func heartbeatSurfacesStaleClaim() async throws {
    let root = tmpRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = SwiftNativeTaskLedger(dataRoot: root)

    // A claim 30h ago, never updated → stale.
    let old = TaskLedgerClock.nowISO(Date().addingTimeInterval(-30 * 3600))
    _ = try await ledger.append(TaskLedgerEvent(
        taskId: "STALE-1", ts: old, actor: .codex, kind: .claimed, title: "Long-running port"))

    let signals = await heartbeatSignals(dataRoot: root)
    #expect(signals.contains("Stale task claims (1"))
    #expect(signals.contains("Long-running port"))
    #expect(signals.contains("codex"))
}

@Test func heartbeatSaysNoneWhenNoStaleClaims() async throws {
    let root = tmpRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = SwiftNativeTaskLedger(dataRoot: root)

    // A FRESH claim (1h ago) is not stale.
    let recent = TaskLedgerClock.nowISO(Date().addingTimeInterval(-3600))
    _ = try await ledger.append(TaskLedgerEvent(
        taskId: "FRESH-1", ts: recent, actor: .claude, kind: .claimed, title: "Just claimed"))

    let signals = await heartbeatSignals(dataRoot: root)
    #expect(signals.contains("Stale task claims: none."))
}

@Test func resolvedDoctorSelfHealCloseoutDeniesOnlyDoctorNeedsDiffProposal() async throws {
    let root = tmpRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeDoctorSnapshot(root, statuses: ["ok"])

    let store = EvolutionProposalStore(dataRoot: root)
    let doctor = try await store.propose(
        source: .selfHeal,
        title: "Self-heal: Doctor failure detected",
        evidence: "Trigger: Doctor health transitioned healthy→fail.\n## Doctor snapshot (failing)"
    )
    let weekly = try await store.propose(
        source: .weekly,
        title: "Investigate multi-step Workshop failures",
        evidence: "Weekly scoring found a completion drop."
    )
    let burst = try await store.propose(
        source: .selfHeal,
        title: "Self-heal: error burst detected",
        evidence: "Trigger: 10 errors logged within 10m."
    )

    let closed = await BackgroundLoopsAssembly.closeResolvedDoctorSelfHealProposals(dataRoot: root)
    #expect(closed == 1)

    let doctorAfter = try #require(try await store.get(id: doctor.id))
    let weeklyAfter = try #require(try await store.get(id: weekly.id))
    let burstAfter = try #require(try await store.get(id: burst.id))
    #expect(doctorAfter.status == .denied)
    #expect(doctorAfter.denyReason?.contains("Doctor is currently healthy") == true)
    #expect(weeklyAfter.status == .needsDiff)
    #expect(burstAfter.status == .needsDiff)
}

@Test func resolvedDoctorSelfHealCloseoutSkipsWhenDoctorStillFailing() async throws {
    let root = tmpRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeDoctorSnapshot(root, statuses: ["fail"])

    let store = EvolutionProposalStore(dataRoot: root)
    let doctor = try await store.propose(
        source: .selfHeal,
        title: "Self-heal: Doctor failure detected",
        evidence: "Trigger: Doctor health transitioned healthy→fail.\n## Doctor snapshot (failing)"
    )

    let closed = await BackgroundLoopsAssembly.closeResolvedDoctorSelfHealProposals(dataRoot: root)
    let doctorAfter = try #require(try await store.get(id: doctor.id))
    #expect(closed == 0)
    #expect(doctorAfter.status == .needsDiff)
}

@Test func heartbeatStaleClaimAbsentAfterUpdate() async throws {
    let root = tmpRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = SwiftNativeTaskLedger(dataRoot: root)

    let old = TaskLedgerClock.nowISO(Date().addingTimeInterval(-30 * 3600))
    _ = try await ledger.append(TaskLedgerEvent(taskId: "T", ts: old, actor: .codex, kind: .claimed, title: "x"))
    // A recent update clears the stale signal.
    _ = try await ledger.append(TaskLedgerEvent(taskId: "T", actor: .codex, kind: .update, note: "alive"))

    let signals = await heartbeatSignals(dataRoot: root)
    #expect(signals.contains("Stale task claims: none."))
}
