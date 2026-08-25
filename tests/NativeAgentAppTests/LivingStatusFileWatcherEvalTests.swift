import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mind / loop.livingStatus.fileWatcher

@MainActor
private final class LivingStatusFileWatcherProbe {
    private var observedAvailability: LivingStatusFileWatch.Availability?
    private var refreshCount = 0

    func recordAvailability(_ availability: LivingStatusFileWatch.Availability) {
        observedAvailability = availability
    }

    func recordRefresh() { refreshCount += 1 }
    func availability() -> LivingStatusFileWatch.Availability? { observedAvailability }
    func count() -> Int { refreshCount }
}

@MainActor
@Suite("Living Status file watcher")
struct LivingStatusFileWatcherEvalTests {
    @Test("an armed watcher reports availability and refreshes after a canonical file replacement")
    func armedWatcherObservesCanonicalOrganismState() async throws {
        let root = try temporaryRoot("armed")
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = LivingStatusFileWatcherProbe()
        let task = Task { @MainActor in
            await LivingStatusFileWatch.observe(
                dataRoot: root,
                debounceDelay: .milliseconds(20),
                availabilityDidChange: { availability in
                    probe.recordAvailability(availability)
                }
            ) {
                probe.recordRefresh()
            }
        }
        defer { task.cancel() }

        #expect(await waitForRefresh(probe, atLeast: 1) >= 1)
        #expect(probe.availability() == .watching(inputCount: 5))

        let beforeWrite = probe.count()
        let organism = root.appendingPathComponent("cognition/organism_state.json")
        try Data("{\"availability\":\"ready\"}".utf8).write(to: organism, options: .atomic)
        #expect(await waitForRefresh(probe, atLeast: beforeWrite + 1) >= beforeWrite + 1)

        task.cancel()
        await task.value
    }

    @Test("an unwatchable root reports unavailable and performs only its bounded initial refresh")
    func unwatchableParentsCannotMasqueradeAsLiveObservation() async throws {
        let root = try temporaryRoot("unwatchable")
        defer { try? FileManager.default.removeItem(at: root) }
        let blockedRoot = root.appendingPathComponent("blocked-root")
        try Data("not a directory".utf8).write(to: blockedRoot)
        let probe = LivingStatusFileWatcherProbe()

        await LivingStatusFileWatch.observe(
            dataRoot: blockedRoot,
            availabilityDidChange: { availability in
                probe.recordAvailability(availability)
            }
        ) {
            probe.recordRefresh()
        }

        // availability() diagnoses parents in sorted order, so the data root
        // itself — a regular file here — is deterministically reported first.
        #expect(probe.availability() == .unavailable("a status storage folder is not a directory"))
        #expect(probe.count() == 1)
    }

    private func waitForRefresh(
        _ probe: LivingStatusFileWatcherProbe,
        atLeast target: Int,
        timeout: Duration = .seconds(3)
    ) async -> Int {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let count = probe.count()
            if count >= target { return count }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return probe.count()
    }

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("living-status-file-watcher-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
