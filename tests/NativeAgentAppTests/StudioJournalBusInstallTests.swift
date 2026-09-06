import CognitiveSubstrate
import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

/// `StudioJournalCognitiveBus` is process-global and a second `install`
/// REPLACES the first. Every bootstrapped runtime used to install
/// unconditionally, so any runtime on an alternate data root — a test harness, a
/// workshop profile, a second window pointed elsewhere — silently took over the
/// resident mind's sink and fed her journal entries into a substrate that is not
/// hers.
///
/// There is one resident mind and it lives on the canonical root. A runtime on
/// any other root installs nothing and stays out of the way.
@Suite("Studio journal bus install", .serialized)
struct StudioJournalBusInstallTests {

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-bus-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeRuntime(root: URL) -> NativeCognitionRuntime {
        NativeCognitionRuntime(
            dataRoot: root,
            configurationOverride: CognitiveConfiguration(
                enabled: true,
                persistenceEnabled: true,
                workspaceEnabled: true,
                affectEnabled: true,
                thoughtSeedsEnabled: true,
                backgroundMicrocyclesEnabled: true,
                observatoryEnabled: true,
                defaultDecayHalfLife: 24 * 60 * 60,
                maximumThoughtSeeds: 64
            ),
            microcycleSchedulingMode: .manuallyFlushed
        )
    }

    /// Compared BEFORE and AFTER rather than asserted absolutely: the bus is
    /// process-global, so another suite may legitimately have installed the real
    /// sink already. What must never happen is this bootstrap CHANGING it.
    @Test("a runtime on an alternate data root never claims the process-wide sink")
    func alternateRootRuntimeDoesNotInstallTheSink() async throws {
        let root = try temporaryRoot("alternate")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(root.standardizedFileURL != PersistenceCore.defaultDataRoot().standardizedFileURL)

        let before = await StudioJournalCognitiveBus.isInstalled
        let runtime = makeRuntime(root: root)
        await runtime.bootstrap()
        let after = await StudioJournalCognitiveBus.isInstalled
        #expect(before == after)
    }
}
