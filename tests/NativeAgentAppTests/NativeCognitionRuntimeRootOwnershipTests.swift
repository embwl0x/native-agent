import CognitiveSubstrate
import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

@Test func alternateRootCognitionGroundingUsesOnlyInjectedMemoryAndGraphOwners() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("cognition-grounding-root-\(UUID().uuidString)", isDirectory: true)
        .standardizedFileURL
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let runtime = NativeCognitionRuntime(
        dataRoot: root,
        configurationOverride: CognitiveConfiguration(enabled: true, persistenceEnabled: false),
        organismConfigurationOverride: .disabled,
        microcycleSchedulingMode: .manuallyFlushed,
        installedPhysiologySoakEnabled: false
    )
    let paths = await runtime._testExternalGroundingOwnerPaths()

    #expect(paths.memory == root
        .appendingPathComponent("memory", isDirectory: true)
        .appendingPathComponent("memory.sqlite"))
    #expect(paths.graph == root
        .appendingPathComponent("memory", isDirectory: true)
        .appendingPathComponent("knowledge_graph.json"))
}
