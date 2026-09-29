import Foundation
import BackgroundLoops
import MemoryV2
import NativeAgentCore
import TrustCenter

// MARK: - LoopRunner

/// Weekly slow-path consolidation tick. Same loopId as the retired JSONL
/// loop so NSBackgroundActivityScheduler's "memory_consolidation" slot and
/// runTickOnce keep routing here; the in-app cadence matches the weekly
/// design (the OS scheduler slot is the primary driver).
///
/// The tick runs MemoryConsolidationHygiene.runOnce directly. See that owner's
/// file header.
public struct MemoryConsolidationHygieneRunner: LoopRunner {
    public let loopId: String = "memory_consolidation"
    public let interval: TimeInterval
    let dataRoot: URL

    /// U5 W-D fix-round (gpt-5.5 NEEDS_FIX): the 3600s budget must live on
    /// THIS type — it is what assembleAllLoops actually registers for the
    /// "memory_consolidation" slot. The override previously existed only on
    /// the retired JSONL loop rather than this registered type, so the live
    /// slot silently rode the scheduler's 300s default. The weekly tick runs the
    /// full hygiene pass — give it the same wide weekly-loop budget as its
    /// siblings rather than gambling on the default.
    public var tickTimeoutOverride: TimeInterval? { 3600 }

    public init(dataRoot: URL, interval: TimeInterval = 7 * 24 * 60 * 60) {
        self.dataRoot = dataRoot
        self.interval = interval
    }

    public func tick() async {
        _ = await tickOutcome()
    }

    public func tickOutcome() async -> LoopTickOutcome {
        // Settings ▸ "Nightly memory consolidation": off means this tick does
        // not run. Read fresh on the tick, so a flip lands on the next run.
        guard MemoryPolicyGate.consolidationEnabled(dataRoot: dataRoot) else {
            return .skipped(reason:
                "Memory consolidation is turned off in Settings, so hygiene did not run.")
        }
        let yolo = await SwiftNativeSecurityCenter(dataRoot: dataRoot)
            .fullMacYoloAuthority(
                tool: "self_improvement.apply",
                origin: SecurityOriginContext(
                    surface: "desk",
                    source: "memory_consolidation_background",
                    isRemote: false
                )
            )
        // User, 2026-09-04: only an EXPLICIT block stops the tick. 8eccf9a1
        // (Full Mac, prompt-free) also skipped whenever Full Mac was admitted,
        // and on a Mac that never expires that meant weekly hygiene never ran
        // again after 08-28, silently: the skip stamped the loop as run and
        // wrote no failure.
        if yolo.state == .explicitlyBlocked {
            let now = Date()
            let report = MemoryHygieneReport(
                id: "hygiene-\(UUID().uuidString.lowercased())",
                status: "refused",
                reason: "Memory consolidation is explicitly blocked; hygiene did not run.",
                version: "swift-memory-v2-consolidator",
                createdAt: ISO8601DateFormatter().string(from: now),
                beforeCount: nil,
                afterCount: nil,
                normalized: nil,
                archivedDuplicates: nil,
                archivedReflections: nil,
                distilledFactsAdded: nil,
                decayedMemories: nil,
                proposalHygiene: nil,
                consolidationRunId: nil,
                nextScheduled: nil
            )
            try? MemoryConsolidationHygiene.write(report, dataRoot: dataRoot)
            return .skipped(reason: report.reason ?? "memory hygiene deferred")
        }
        do {
            let report = try await MemoryConsolidationHygiene.runOnce(
                dataRoot: dataRoot, approvedDirectRun: true, autoApproveSwap: true)
            if report.status == "failed" {
                return .failed(error: "memory hygiene: \(report.reason ?? "swap not applied")")
            }
            if report.status == "staged" {
                return .skipped(reason: report.reason ?? "a consolidation card is already pending")
            }
            return .completed(result: "memory hygiene \(report.status ?? "done")"
                + (report.reason.map { ": \($0)" } ?? ""))
        } catch {
            return .failed(error: "memory hygiene failed: \(error)")
        }
    }
}
