import Testing
import Foundation
@testable import WorkshopExecution
import NativeAgentCore
import PersistenceCore

// Coverage ledger: `workshop.plannerCatalog`
// (WorkshopExecution+PlannerLLM.swift `WorkshopPlannerCatalog.configure` / `.current`).
//
// SILENT-FAILURE CLASS: silent zero / dead capability. The process-global tool
// catalog is configured exactly ONCE, at app launch. Unconfigured it returns
// [] and the planner falls back to synthesis-only — which is ALSO the
// documented test posture, so a launch-order regression that drops the
// configure call produces plans that look completely plausible and can never
// use a tool. No test, no instrument row, no runtime counter sees it.
//
// This file pins the seam that regression travels through: that the DEFAULT
// connector-actions provider — the one every planner gets when nobody passes
// one, including the trigger scheduler's `makeWorkshopRunner` — really reads
// the catalog, and that a configured catalog really reaches the planner
// prompt's tool menu.
//
// PROCESS-GLOBAL STATE: the catalog is a set-once-at-launch global. The suite
// is `.serialized` and every test restores the documented unconfigured value
// (`{ [] }`) on exit. No other test in the package reads the catalog.

private func catalogEvalRoot() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkshopCatalogEval-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func resetCatalog() {
    WorkshopPlannerCatalog.configure { [] }
}

private func action(_ id: String, _ description: String) -> JSONValue {
    .object(["id": .string(id), "description": .string(description)])
}

private actor PromptBox {
    private var prompts: [String] = []
    func record(_ prompt: String) { prompts.append(prompt) }
    func all() -> [String] { prompts }
}

/// A planner that takes its tool menu from a REAL, default-constructed
/// `SwiftNativeWorkshopPlannerLLM` (so the production default provider is what
/// is under test) but captures the assembled prompt instead of calling out.
private struct CatalogProbePlanner: WorkshopPlannerLLM {
    let inner: SwiftNativeWorkshopPlannerLLM
    let box: PromptBox
    var directProviderCallCountPerInvocation: Int? { 1 }

    func availableConnectorActions() async -> [JSONValue] {
        await inner.availableConnectorActions()
    }

    func runCodex(
        prompt: String, surface: String, timeoutSeconds: Int
    ) async throws -> (model: String, output: String) {
        await box.record(prompt)
        throw WorkshopExecutionError.plannerFailure("catalog-eval probe")
    }
}

@Suite("EVAL workshop.plannerCatalog", .serialized)
struct WorkshopPlannerCatalogEvalSuite {

    /// `configure` → `current` is the whole contract of the global, and the
    /// last write wins (launch configures once; a second configure is a
    /// re-wire, not an append).
    @Test func configureIsReadBackByCurrentAndLastWriteWins() async {
        defer { resetCatalog() }
        WorkshopPlannerCatalog.configure { [action("first.tool", "d")] }
        #expect(await WorkshopPlannerCatalog.current().count == 1)

        WorkshopPlannerCatalog.configure { [action("second.tool", "d"), action("third.tool", "d")] }
        let current = await WorkshopPlannerCatalog.current()
        #expect(current.count == 2)
        let ids = current.compactMap { value -> String? in
            guard case .object(let object) = value,
                  case .string(let id)? = object["id"] else { return nil }
            return id
        }
        #expect(ids == ["second.tool", "third.tool"])

        resetCatalog()
        #expect(await WorkshopPlannerCatalog.current().isEmpty)
    }

    /// THE LOAD-BEARING ASSERTION: a planner built WITHOUT an explicit provider
    /// — the production default — sees the configured catalog. If the default
    /// argument stops pointing at the catalog, every unwired planner goes
    /// synthesis-only and nothing else fails.
    @Test func defaultProviderOnARealPlannerReadsTheCatalog() async {
        defer { resetCatalog() }
        let root = catalogEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        resetCatalog()
        let planner = SwiftNativeWorkshopPlannerLLM(dataRoot: root)
        #expect(await planner.availableConnectorActions().isEmpty,
                "unconfigured must be empty — the documented pre-launch posture")

        WorkshopPlannerCatalog.configure {
            [action("mac.screen.look", "Look at the screen"),
             action("local_files.search", "Search local files")]
        }
        let ids = await planner.availableConnectorActions().compactMap { value -> String? in
            guard case .object(let object) = value,
                  case .string(let id)? = object["id"] else { return nil }
            return id
        }
        #expect(ids == ["mac.screen.look", "local_files.search"],
                "the default provider must read the LIVE catalog, not a snapshot from init")
    }

    /// End to end into the planner prompt: a configured catalog reaches the
    /// `Available tools:` menu the model actually reads. Unconfigured, the menu
    /// carries `chat.synthesize` ONLY — the synthesis-only floor that a dropped
    /// configure call is indistinguishable from without this test.
    @Test func configuredCatalogReachesThePlannerToolMenu() async throws {
        defer { resetCatalog() }
        let root = catalogEvalRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let box = PromptBox()
        let probe = CatalogProbePlanner(
            inner: SwiftNativeWorkshopPlannerLLM(dataRoot: root), box: box)
        let runner = SwiftNativeWorkshopRunner(
            executorAvailable: true, root: root,
            persistence: SwiftNativePersistenceCore(), planner: probe)

        resetCatalog()
        _ = try await runner.planWorkshopExecution(
            spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        let floor = try #require(await box.all().last)
        #expect(floor.contains("chat.synthesize"))
        #expect(floor.contains("mac.screen.look") == false)

        WorkshopPlannerCatalog.configure {
            [action("mac.screen.look", "Look at the screen")]
        }
        _ = try await runner.planWorkshopExecution(
            spec: WorkshopExecutionSpec(title: "T", objective: "O"))
        let wired = try #require(await box.all().last)
        #expect(wired.contains("mac.screen.look"),
                "a configured catalog must reach the planner's tool menu")
        #expect(wired.contains("Look at the screen"))
        // chat.synthesize is always appended, catalog or not.
        #expect(wired.contains("chat.synthesize"))
        #expect(await box.all().count == 2)
    }
}
