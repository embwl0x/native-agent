import Testing
import Foundation
@testable import BackgroundLoops
import NativeAgentCore
import PersistenceCore
import DreamREMCycle

// Sanity tests for the BackgroundLoops constructors used by the app-side
// BackgroundLoopsAssembly (Sources/NativeAgentApp/BackgroundLoopsAssembly.swift).
// These mirror the assembly's call shape at the module-test level so a
// regression in any of the loop initializers shows up here BEFORE it lights
// up the app build.
//
// The assembly itself is exercised at app-target level (no app test target
// today) — these tests cover the loop-init contract the assembly relies on:
//   1. Each loop instance can be constructed with realistic deps.
//   2. Every constructor exposes the expected canonical id and cadence.

private struct StubLLMClient: LLMClient {
    func complete(prompt: String, system: String?, model: String?) async throws -> String {
        "stub"
    }
}

private struct StubRecaller: MemoryConsolidationRecaller {
    func listAllForConsolidation() async throws -> [ConsolidationCandidate] { [] }
    func remove(id: String) async throws {}
}

private func mkTmpRoot() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bg-loops-assembly-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("BackgroundLoopsAssembly sanity (module level)")
struct BackgroundLoopsAssemblySanityTests {

    // MARK: - per-loop sanity

    @Test("REMCycleLoop constructs with consolidator + tombstones + growth")
    func remCycleLoopConstructs() {
        let root = mkTmpRoot()
        let reader = DreamDiaryReader(dataRoot: root)
        let consolidator = SwiftNativeREMConsolidator(llm: StubLLMClient(), diary: reader)
        let tombstones = REMTombstoneStore(dataRoot: root)
        let growth = GrowthDocManager(personaRoot: root.appendingPathComponent("persona", isDirectory: true))
        let loop = REMCycleLoop(
            consolidator: consolidator,
            tombstones: tombstones,
            growth: growth,
            dataRoot: root
        )
        #expect(loop.loopId == "rem_cycle")
        #expect(loop.interval == 604_800)
    }

    @Test("MemoryConsolidationLoop constructs with stub recaller")
    func memoryConsolidationLoopConstructs() {
        let root = mkTmpRoot()
        let loop = MemoryConsolidationLoop(recaller: StubRecaller(), dataRoot: root)
        #expect(loop.loopId == "memory_consolidation")
        #expect(loop.interval == 3600)
    }
}
