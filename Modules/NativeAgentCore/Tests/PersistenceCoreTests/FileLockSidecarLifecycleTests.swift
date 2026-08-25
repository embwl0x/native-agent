import Testing
import Foundation
@testable import PersistenceCore

private actor SidecarLifecycleGate {
    private var isOpen = false

    func open() { isOpen = true }

    func wait() async {
        while !isOpen {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

private enum SimulatedInterruptedWriter: Error {
    case interrupted
}

@Suite("File-lock sidecar lifecycle")
struct FileLockSidecarLifecycleTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("filelock-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func leaveCrashResidue(
        core: SwiftNativePersistenceCore,
        target: URL
    ) async {
        do {
            try await core.withFileLock(target) { () -> Void in
                throw SimulatedInterruptedWriter.interrupted
            }
            Issue.record("interrupted writer should throw")
        } catch {
            // `flock`/fd release is guaranteed by withFileLock's defer, but
            // its sidecar deliberately remains as the crash-recovery residue.
        }
    }

    private func age(_ sidecar: URL, hours: TimeInterval, now: Date) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-hours * 60 * 60)],
            ofItemAtPath: sidecar.path
        )
    }

    @Test
    func reaperReclaimsInterruptedResidueButLeavesLiveFreshAndDeferredSidecars() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let core = SwiftNativePersistenceCore()
        let now = Date(timeIntervalSince1970: 1_784_160_000)

        // These mimic a process dying after it took a lock but before it wrote
        // the target. The real API's defer releases flock, leaving only the
        // sidecar that the next mounted sweep must be able to reclaim.
        let oldest = root.appendingPathComponent("crashed-oldest.json")
        let middle = root.appendingPathComponent("crashed-middle.json")
        let newest = root.appendingPathComponent("crashed-newest.json")
        for target in [oldest, middle, newest] {
            await leaveCrashResidue(core: core, target: target)
        }
        try age(oldest.appendingPathExtension("lock"), hours: 5, now: now)
        try age(middle.appendingPathExtension("lock"), hours: 4, now: now)
        try age(newest.appendingPathExtension("lock"), hours: 3, now: now)

        // A real target keeps its aged sidecar: existence beats age.
        let live = root.appendingPathComponent("live-state.json")
        try await core.withFileLock(live) {
            try Data("live".utf8).write(to: live, options: .atomic)
        }
        try age(live.appendingPathExtension("lock"), hours: 5, now: now)

        // A fresh orphan can be an in-flight writer between lock acquisition
        // and target creation, so it is never touched by the normal sweep.
        let fresh = root.appendingPathComponent("fresh-in-flight.json.lock")
        try Data().write(to: fresh)

        let first = try await FileLockSidecarLifecycle.reapOrphanedSidecars(
            dataRoot: root,
            now: now,
            minimumAge: 60 * 60,
            maximumCandidates: 2,
            persistence: core
        )
        #expect(first.candidates == 3)
        #expect(first.attempted == 2)
        #expect(first.reaped == 2)
        #expect(first.deferred == 1)
        #expect(first.skippedLiveTarget == 1)
        #expect(first.skippedFresh == 1)
        #expect(first.failures == 0)
        #expect(!FileManager.default.fileExists(atPath: oldest.appendingPathExtension("lock").path))
        #expect(!FileManager.default.fileExists(atPath: middle.appendingPathExtension("lock").path))
        #expect(FileManager.default.fileExists(atPath: newest.appendingPathExtension("lock").path))
        #expect(FileManager.default.fileExists(atPath: live.appendingPathExtension("lock").path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))

        // A later bounded wake drains the truthful deferred count rather than
        // leaving it as permanent invisible residue.
        let second = try await FileLockSidecarLifecycle.reapOrphanedSidecars(
            dataRoot: root,
            now: now,
            minimumAge: 60 * 60,
            maximumCandidates: 2,
            persistence: core
        )
        #expect(second.reaped == 1)
        #expect(second.deferred == 0)
        #expect(!FileManager.default.fileExists(atPath: newest.appendingPathExtension("lock").path))
    }

    @Test
    func reaperWaitsForAnActiveWriterThenRechecksBeforeUnlinking() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let core = SwiftNativePersistenceCore()
        let now = Date(timeIntervalSince1970: 1_784_160_000)
        let target = root.appendingPathComponent("writer-is-active.json")

        // Seed an old sidecar, then have a new writer take that exact flock.
        // Its old mtime is not proof of idleness, which is why the reaper must
        // wait and recheck rather than unlink from its initial directory scan.
        try await core.withFileLock(target) { }
        try age(target.appendingPathExtension("lock"), hours: 5, now: now)
        let holderAcquired = SidecarLifecycleGate()
        let allowCommit = SidecarLifecycleGate()
        let candidateSelected = SidecarLifecycleGate()
        let allowReaperAcquire = SidecarLifecycleGate()
        let holder = Task {
            try? await core.withFileLock(target) {
                await holderAcquired.open()
                await allowCommit.wait()
                try Data("committed".utf8).write(to: target, options: .atomic)
            }
        }
        await holderAcquired.wait()

        let sweep = Task {
            try? await FileLockSidecarLifecycle.reapOrphanedSidecars(
                dataRoot: root,
                now: now,
                minimumAge: 60 * 60,
                maximumCandidates: 4,
                persistence: core,
                candidateBeforeAcquire: { _ in
                    await candidateSelected.open()
                    await allowReaperAcquire.wait()
                }
            )
        }
        // This is the exact pre-acquire boundary in the real reaper: the
        // candidate was observed as an old orphan while the writer held its
        // flock. A target created later must therefore be caught by the
        // in-lock recheck, not by the initial directory scan.
        await candidateSelected.wait()
        await allowCommit.open()
        _ = await holder.result
        await allowReaperAcquire.open()
        let report = try #require(await sweep.value)

        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(FileManager.default.fileExists(atPath: target.appendingPathExtension("lock").path))
        #expect(report.reaped == 0)
        #expect(report.skippedLiveTarget == 0)
        #expect(report.skippedAfterContention == 1)
        #expect(report.failures == 0)
    }
}
