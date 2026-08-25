import Foundation
import Testing
@testable import NativeAgentApp
import Context

private func contextFlowHealthRowsFixture(
    mode: ContextFlowMode = .active,
    started: Bool = true,
    storeGeneration: Int64? = 12,
    arenaGeneration: Int64? = 13,
    lastError: String? = nil
) throws -> ContextFlowCoordinatorHealth {
    let arena = try ContextArena(budget: .mib32)
    return ContextFlowCoordinatorHealth(
        mode: mode,
        started: started,
        activeStoreGenerationID: storeGeneration,
        activeArenaGenerationID: arenaGeneration,
        registeredSourceCount: 4,
        degradedSourceCount: 0,
        arenaMetrics: arena.metrics(),
        pendingPrewarmHints: 0,
        trackedPrewarmPlanCount: 0,
        prewarmUsefulnessReceipts: 0,
        lastReconciledAt: nil,
        lastError: lastError
    )
}

@Suite("Context Flow health rows")
struct ContextFlowHealthRowsEvalTests {
    // app.mind / ui.contextFlow.healthRows
    @Test("the real disabled Context Flow runtime reports off rather than unavailable")
    func configuredOffRuntimeProjectsAnOffHealthState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextFlowHealthRows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = NativeContextFlowRuntime(
            dataRoot: root,
            configurationOverride: NativeContextFlowConfiguration(mode: .off, budget: .mib32)
        )
        await runtime.start()
        #expect(await runtime.observatoryHealthState() == .off)
        await runtime.stop()
    }

    // app.mind / ui.contextFlow.healthRows
    @Test("unavailable, off, and reported-error health states have distinct text")
    func healthStateTextKeepsItsProvenance() throws {
        let unavailable = ContextFlowHealthRowsPresentation(health: nil)
        let off = ContextFlowHealthRowsPresentation(
            health: try contextFlowHealthRowsFixture(mode: .off)
        )
        let errored = ContextFlowHealthRowsPresentation(
            health: try contextFlowHealthRowsFixture(lastError: "Store receipt could not be read")
        )

        #expect(unavailable.state == .unavailable)
        #expect(unavailable.statusText == "Context Flow health is unavailable.")
        #expect(unavailable.rows.isEmpty)

        #expect(off.state == .off)
        #expect(off.statusText == "Context Flow is off.")
        #expect(off.rows.contains(.init(label: "Mode", value: "off")))

        #expect(errored.state == .attention)
        #expect(errored.statusText == "Context Flow needs attention.")
        #expect(errored.errorDetail == "Store receipt could not be read")

        let texts = [
            try #require(unavailable.statusText),
            try #require(off.statusText),
            try #require(errored.statusText),
        ]
        #expect(Set(texts).count == 3)
    }

    // app.mind / ui.contextFlow.healthRows
    @Test("missing generations and malformed error detail remain honest")
    func missingGenerationIsNoneAndBlankErrorDoesNotDisappear() throws {
        let missingGenerations = ContextFlowHealthRowsPresentation(
            health: try contextFlowHealthRowsFixture(
                storeGeneration: nil,
                arenaGeneration: nil
            )
        )
        #expect(ContextFlowHealthRowsPresentation.generationText(nil) == "none")
        #expect(missingGenerations.rows.contains(.init(label: "Store generation", value: "none")))
        #expect(missingGenerations.rows.contains(.init(label: "RAM generation", value: "none")))
        #expect(!missingGenerations.rows.contains(.init(label: "Store generation", value: "0")))

        let blankError = ContextFlowHealthRowsPresentation(
            health: try contextFlowHealthRowsFixture(lastError: " \n ")
        )
        #expect(blankError.state == .attention)
        #expect(blankError.errorDetail == "Context Flow reported an unspecified error.")
    }

    // app.mind / ui.contextFlow.healthRows
    @Test("the panel projection keeps unavailable, off, error, and missing generations distinct")
    func panelProjectionCarriesEachHealthProvenance() throws {
        let unavailable = ContextFlowHealthRowsPresentation(healthState: .unavailable)
        let off = ContextFlowHealthRowsPresentation(healthState: .off)
        let errored = ContextFlowHealthRowsPresentation(healthState: .health(
            try contextFlowHealthRowsFixture(lastError: "Context store unreadable")
        ))
        let missingGenerations = ContextFlowHealthRowsPresentation(healthState: .health(
            try contextFlowHealthRowsFixture(storeGeneration: nil, arenaGeneration: nil)
        ))

        #expect(unavailable.state == .unavailable)
        #expect(unavailable.rows.isEmpty)
        #expect(off.state == .off)
        #expect(off.rows.contains(.init(label: "Mode", value: "off")))
        #expect(errored.state == .attention)
        #expect(errored.errorDetail == "Context store unreadable")
        #expect(missingGenerations.rows.contains(.init(label: "Store generation", value: "none")))
        #expect(missingGenerations.rows.contains(.init(label: "RAM generation", value: "none")))
        #expect(unavailable.statusText != off.statusText)
        #expect(off.statusText != errored.statusText)
    }
}
