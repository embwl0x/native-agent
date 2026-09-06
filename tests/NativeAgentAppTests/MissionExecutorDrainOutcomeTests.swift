import Foundation
import Testing
import BackgroundLoops
import PersistenceCore
@testable import NativeAgentApp

// MARK: - Sweep FIX 4 — mission_executor stops booking success for idle ticks
//
// `drainOnce()` returned Void, so the runner stamped `.completed` on every tick
// whether or not it claimed anything. `lastSuccessfulWorkAt` therefore advanced
// on an executor that had not run a mission in weeks, and the dormancy rule
// could never see it — while the lanes that honestly report `.skipped` looked
// like the dead ones.

@Test func missionExecutorTickWithAnEmptyQueueSkipsRatherThanCompleting() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mission-drain-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let loop = BackgroundLoopsAssembly.makeWorkshopExecutorLoopRunner(dataRoot: root)
    #expect(loop.loopId == "mission_executor")

    let outcome = await loop.tickOutcome()

    guard case .skipped(let reason, _) = outcome else {
        Issue.record("an empty queue must not report .completed, got \(outcome)")
        return
    }
    #expect(reason.contains("no queued Desk executions"))
}
